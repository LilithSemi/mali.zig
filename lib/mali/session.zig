//! Prism-oriented ownership and GPU virtual-address management.

const std = @import("std");
const device = @import("device.zig");
const queue = @import("queue.zig");
const samples = @import("samples.zig");

pub const Queue = enum(u32) {
    vertex_tiler = 0,
    fragment = 1,
    compute = 2,
};

/// A fully initialized Panthor execution context. Teardown order is encoded in
/// `deinit`: tiler heap, scheduling group, VM, then render-node fd.
pub const Session = struct {
    dev: device.Device,
    info: device.GpuInfo,
    vm: device.Vm,
    group: device.Group,
    tiler_heap: device.TilerHeap,
    /// Userspace tiler-heap descriptor followed by a 64 KiB geometry buffer.
    tiler_resources: device.Bo,
    sample_positions: device.Bo,
    page_size: u64,
    next_va: u64,

    pub fn open(allocator: std.mem.Allocator) device.Error!Session {
        var dev = try device.Device.open(allocator);
        errdefer dev.deinit();
        if (dev.driver != .panthor) return error.UnsupportedDriver;

        const info = try dev.query();
        const vm = try dev.vmCreate();
        errdefer dev.vmDestroy(vm);

        const priorities = dev.queryGroupPriorities() catch null;
        const group_priority: u8 = if (priorities) |p|
            if (p.allowed_mask & (1 << 1) != 0) 1 else 0
        else
            1;
        const queues = [_]device.QueueConfig{ .{}, .{}, .{} };
        const group = try dev.groupCreateWithConfig(vm, .{
            .queues = &queues,
            .max_compute_cores = info.shader_core_count,
            .max_fragment_cores = info.shader_core_count,
            .max_tiler_cores = @intCast(@popCount(info.tiler_present)),
            .priority = group_priority,
            .compute_core_mask = info.shader_present,
            .fragment_core_mask = info.shader_present,
            .tiler_core_mask = info.tiler_present,
        });
        errdefer dev.groupDestroy(group);

        // Mesa's PanVK defaults for v10: enough space for several in-flight
        // frames while allowing the kernel to grow to 64 chunks on demand.
        const tiler_heap = try dev.tilerHeapCreate(vm, 5, 2 * 1024 * 1024, 64, 65535);
        errdefer dev.tilerHeapDestroy(tiler_heap);

        const mmu = dev.queryMmu() catch null;
        const page_size: u64 = if (mmu) |m|
            if (m.page_size_bitmap == 0) 4096 else @as(u64, 1) << @intCast(@ctz(m.page_size_bitmap))
        else
            4096;
        const first_va = std.mem.alignForward(u64, 0x1_0000, page_size);
        if (first_va >= vm.user_va_range) return error.AddressSpaceExhausted;

        const sample_bo_size = std.mem.alignForward(u64, samples.table_size, page_size);
        if (sample_bo_size > vm.user_va_range - first_va) return error.AddressSpaceExhausted;
        const sample_positions = try dev.allocBoWithOptions(vm, sample_bo_size, first_va, .{});
        errdefer dev.freeBo(vm, sample_positions);
        samples.writeTable(sample_positions.cpu) catch return error.InvalidArgument;

        const tiler_resources_va = first_va + sample_bo_size;
        const tiler_resources_size = std.mem.alignForward(u64, 4096 + 64 * 1024, page_size);
        if (tiler_resources_size > vm.user_va_range - tiler_resources_va)
            return error.AddressSpaceExhausted;
        const tiler_resources = try dev.allocBoWithOptions(vm, tiler_resources_size, tiler_resources_va, .{});
        errdefer dev.freeBo(vm, tiler_resources);
        @memset(tiler_resources.cpu, 0);
        // v10 TILER_HEAP is a buffer descriptor with type=Tiler heap.
        const heap_words: *align(1) [8]u32 = @ptrCast(tiler_resources.cpu.ptr);
        heap_words[0] = 9 | (2 << 4);
        heap_words[1] = tiler_heap.chunk_size;
        heap_words[2] = @truncate(tiler_heap.first_chunk_gpu_va);
        heap_words[3] = @truncate(tiler_heap.first_chunk_gpu_va >> 32);
        heap_words[4] = @truncate(tiler_heap.first_chunk_gpu_va + 64);
        heap_words[5] = @truncate((tiler_heap.first_chunk_gpu_va + 64) >> 32);
        heap_words[6] = @truncate(tiler_heap.first_chunk_gpu_va + tiler_heap.chunk_size);
        heap_words[7] = @truncate((tiler_heap.first_chunk_gpu_va + tiler_heap.chunk_size) >> 32);

        return .{
            .dev = dev,
            .info = info,
            .vm = vm,
            .group = group,
            .tiler_heap = tiler_heap,
            .tiler_resources = tiler_resources,
            .sample_positions = sample_positions,
            .page_size = page_size,
            .next_va = tiler_resources_va + tiler_resources_size,
        };
    }

    pub fn deinit(self: *Session) void {
        self.dev.freeBo(self.vm, self.tiler_resources);
        self.dev.freeBo(self.vm, self.sample_positions);
        self.dev.tilerHeapDestroy(self.tiler_heap);
        self.dev.groupDestroy(self.group);
        self.dev.vmDestroy(self.vm);
        self.dev.deinit();
        self.* = undefined;
    }

    fn reserveVa(self: *Session, size: u64) device.Error!struct { va: u64, size: u64 } {
        if (size == 0 or size > std.math.maxInt(u64) - (self.page_size - 1)) return error.InvalidArgument;
        const alloc_size = std.mem.alignForward(u64, size, self.page_size);
        const va = std.mem.alignForward(u64, self.next_va, self.page_size);
        if (va >= self.vm.user_va_range or alloc_size > self.vm.user_va_range - va)
            return error.AddressSpaceExhausted;
        self.next_va = va + alloc_size;
        return .{ .va = va, .size = alloc_size };
    }

    pub fn allocBo(self: *Session, size: u64, options: device.BoOptions) device.Error!device.Bo {
        const reservation = try self.reserveVa(size);
        errdefer self.next_va = reservation.va;
        return self.dev.allocBoWithOptions(self.vm, reservation.size, reservation.va, options);
    }

    pub fn freeBo(self: *Session, bo: device.Bo) void {
        self.dev.freeBo(self.vm, bo);
        if (self.next_va == bo.gpu_va + bo.size) self.next_va = bo.gpu_va;
    }

    pub fn createCommandBuffer(self: *Session, size: u64) queue.Error!queue.CommandBuffer {
        const reservation = try self.reserveVa(size);
        errdefer self.next_va = reservation.va;
        return queue.CommandBuffer.create(&self.dev, self.vm, reservation.size, reservation.va);
    }

    pub fn destroyCommandBuffer(self: *Session, command: *queue.CommandBuffer) void {
        const va = command.bo.gpu_va;
        const size = command.bo.size;
        command.deinit(&self.dev, self.vm);
        if (self.next_va == va + size) self.next_va = va;
    }
};

test "queue indices are stable for Prism command routing" {
    try std.testing.expectEqual(@as(u32, 0), @backingInt(Queue.vertex_tiler));
    try std.testing.expectEqual(@as(u32, 1), @backingInt(Queue.fragment));
    try std.testing.expectEqual(@as(u32, 2), @backingInt(Queue.compute));
}
