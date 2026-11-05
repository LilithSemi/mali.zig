//! Linux DRM render-node discovery plus Panthor VM, memory, synchronization,
//! scheduling-group, tiler-heap, and submission transport.

const std = @import("std");
const drm = @import("drm");
const uapi = @import("uapi.zig");

pub const Error = error{ AddressSpaceExhausted, OpenFailed, NoDevice, IoctlFailed, InvalidArgument, MapFailed, OutOfMemory, Timeout, UnsupportedDriver };

pub const Driver = enum { panthor, panfrost };

pub const Vm = struct {
    id: u32,
    user_va_range: u64,
};

pub const Bo = struct {
    handle: u32,
    gpu_va: u64,
    cpu: []u8,
    size: u64,
};

pub const BoOptions = struct {
    /// Shader and command code needs an executable GPU mapping. Data and image
    /// allocations should retain the safer non-executable default.
    executable: bool = false,
    /// Available with Panthor UAPI 1.7+. Callers must explicitly synchronize
    /// cached CPU mappings with boSyncToGpu/boSyncToCpu.
    write_back: bool = false,
    /// Leave the BO shareable between VMs so it can be exported as a PRIME
    /// dma-buf. Private allocations use Panthor's exclusive-VM optimization,
    /// which the kernel deliberately rejects in PRIME_HANDLE_TO_FD.
    exportable: bool = false,
};

pub const DriverVersion = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn atLeast(self: DriverVersion, major: u32, minor: u32) bool {
        return self.major > major or (self.major == major and self.minor >= minor);
    }
};

pub const Group = struct {
    handle: u32,
    queue_count: u32,
};

pub const QueueConfig = struct {
    priority: u8 = 1,
    ring_size: u32 = 64 * 1024,
};

pub const GroupConfig = struct {
    queues: []const QueueConfig,
    max_compute_cores: u8 = 0,
    max_fragment_cores: u8 = 0,
    max_tiler_cores: u8 = 0,
    priority: u8 = uapi.panthor_group_priority_medium,
    compute_core_mask: u64 = 0,
    fragment_core_mask: u64 = 0,
    tiler_core_mask: u64 = 0,
};

pub const SyncPoint = struct {
    handle: u32,
    timeline_value: u64 = 0,
};

pub const QueueSubmission = struct {
    queue_index: u32,
    stream_addr: u64 = 0,
    stream_size: u32 = 0,
    latest_flush: u32 = 0,
    waits: []const SyncPoint = &.{},
    signals: []const SyncPoint = &.{},
};

pub const TilerHeap = struct {
    handle: u32,
    context_gpu_va: u64,
    first_chunk_gpu_va: u64,
    chunk_size: u32,
};

pub const CsifInfo = uapi.PanthorCsifInfo;
pub const TimestampInfo = uapi.PanthorTimestampInfo;
pub const GroupPrioritiesInfo = uapi.PanthorGroupPrioritiesInfo;
pub const MmuInfo = uapi.PanthorMmuInfo;

pub const GpuInfo = struct {
    driver: Driver,
    name: []const u8,
    gpu_id: u32,
    gpu_revision: u32,
    architecture_major: u8,
    architecture_minor: u8,
    product_major: u8,
    shader_present: u64,
    l2_present: u64,
    tiler_present: u64,
    as_present: u32,
    shader_core_count: u8,
    l2_count: u8,
    address_space_count: u8,
    mmu_va_bits: u8,
    max_threads: u32,
    max_workgroup_size: u32,
    selected_coherency: u32,
    csf_id: ?u32,
};

pub const Device = struct {
    node: drm.Node,
    driver: Driver,
    version: DriverVersion,
    render_minor: ?u32,
    last_errno: u16 = 0,
    last_request: u32 = 0,

    pub fn renderNodeDriver(allocator: std.mem.Allocator, n: u32, name_buf: []u8) ?[]const u8 {
        const minor: u8 = std.math.cast(u8, n) orelse return null;
        var node = drm.Node.openMinor(allocator, minor, .render) catch return null;
        defer node.deinit();
        const version = node.getVersion() catch return null;
        defer version.deinit(allocator);
        const name = version.name[0..version.nameLen];
        if (name.len > name_buf.len) return null;
        @memcpy(name_buf[0..name.len], name);
        return name_buf[0..name.len];
    }

    pub fn open(allocator: std.mem.Allocator) Error!Device {
        var n: u32 = 128;
        while (n < 192) : (n += 1) {
            const minor: u8 = @intCast(n);
            var node = drm.Node.openMinor(allocator, minor, .render) catch continue;
            const version = node.getVersion() catch {
                node.deinit();
                continue;
            };
            const driver = parseDriver(version.name[0..version.nameLen]);
            const driver_version = decodeVersion(version);
            version.deinit(allocator);
            if (driver) |kind| return .{ .node = node, .driver = kind, .version = driver_version, .render_minor = n };
            node.deinit();
        }
        return error.NoDevice;
    }

    pub fn openNode(allocator: std.mem.Allocator, path: []const u8) Error!Device {
        const base = std.fs.path.basename(path);
        const prefix = "renderD";
        if (!std.mem.startsWith(u8, base, prefix)) return error.UnsupportedDriver;
        const minor = std.fmt.parseInt(u32, base[prefix.len..], 10) catch return error.UnsupportedDriver;
        const drm_minor: u8 = std.math.cast(u8, minor) orelse return error.UnsupportedDriver;
        var node = drm.Node.openMinor(allocator, drm_minor, .render) catch return error.OpenFailed;
        errdefer node.deinit();
        const version = node.getVersion() catch return error.OpenFailed;
        defer version.deinit(allocator);
        const driver = parseDriver(version.name[0..version.nameLen]) orelse return error.UnsupportedDriver;
        return .{ .node = node, .driver = driver, .version = decodeVersion(version), .render_minor = minor };
    }

    pub fn deinit(self: *Device) void {
        self.node.deinit();
    }

    /// Export a GEM-backed BO as a caller-owned dma-buf fd suitable for
    /// Wayland/GBM presentation. Close the returned fd separately.
    pub fn boExportDmaBuf(self: *Device, bo: Bo) Error!std.posix.fd_t {
        if (bo.handle == 0) return error.InvalidArgument;
        var arg = drm.types.ModePrimeHandle{
            .handle = bo.handle,
            .flags = uapi.drm_prime_export_flags,
            .fd = -1,
        };
        try self.ioctl(drm.types.ModePrimeHandle.req, @intFromPtr(&arg));
        if (arg.fd < 0) return error.IoctlFailed;
        return arg.fd;
    }

    pub fn query(self: *Device) Error!GpuInfo {
        return switch (self.driver) {
            .panthor => self.queryPanthor(),
            .panfrost => self.queryPanfrost(),
        };
    }

    fn ioctl(self: *Device, request: u32, ptr: usize) Error!void {
        const rc = std.os.linux.ioctl(self.node.fd, request, ptr);
        const err = std.os.linux.errno(rc);
        if (err != .SUCCESS) {
            self.last_errno = @backingInt(err);
            self.last_request = request;
            return error.IoctlFailed;
        }
    }

    fn queryPanthor(self: *Device) Error!GpuInfo {
        const raw = try self.queryPanthorRaw(uapi.PanthorGpuInfo, uapi.panthor_dev_query_gpu_info);
        return decode(.panthor, raw.gpu_id, raw.gpu_rev, raw.shader_present, raw.l2_present, raw.tiler_present, raw.as_present, raw.mmu_features, raw.max_threads, raw.thread_max_workgroup_size, raw.selected_coherency, raw.csf_id);
    }

    fn queryPanthorRaw(self: *Device, comptime T: type, query_type: u32) Error!T {
        if (self.driver != .panthor) return error.UnsupportedDriver;
        var raw = std.mem.zeroes(T);
        var query_arg = uapi.PanthorDevQuery{
            .type = query_type,
            .size = @sizeOf(T),
            .pointer = @intFromPtr(&raw),
        };
        try self.ioctl(uapi.ioctl_panthor_dev_query, @intFromPtr(&query_arg));
        return raw;
    }

    pub fn queryCsif(self: *Device) Error!CsifInfo {
        return self.queryPanthorRaw(CsifInfo, uapi.panthor_dev_query_csif_info);
    }

    pub fn queryTimestamp(self: *Device) Error!TimestampInfo {
        return self.queryPanthorRaw(TimestampInfo, uapi.panthor_dev_query_timestamp_info);
    }

    pub fn queryGroupPriorities(self: *Device) Error!GroupPrioritiesInfo {
        return self.queryPanthorRaw(GroupPrioritiesInfo, uapi.panthor_dev_query_group_priorities_info);
    }

    pub fn queryMmu(self: *Device) Error!MmuInfo {
        return self.queryPanthorRaw(MmuInfo, uapi.panthor_dev_query_mmu_info);
    }

    fn getPanfrostParam(self: *Device, param: uapi.PanfrostParam) Error!u64 {
        var arg = uapi.PanfrostGetParam{ .param = @backingInt(param) };
        try self.ioctl(uapi.ioctl_panfrost_get_param, @intFromPtr(&arg));
        return arg.value;
    }

    fn queryPanfrost(self: *Device) Error!GpuInfo {
        const product: u32 = @truncate(try self.getPanfrostParam(.gpu_prod_id));
        const revision: u32 = @truncate(try self.getPanfrostParam(.gpu_revision));
        const gpu_id = product << 16;
        return decode(
            .panfrost,
            gpu_id,
            revision,
            try self.getPanfrostParam(.shader_present),
            try self.getPanfrostParam(.l2_present),
            try self.getPanfrostParam(.tiler_present),
            @truncate(try self.getPanfrostParam(.as_present)),
            @truncate(try self.getPanfrostParam(.mmu_features)),
            @truncate(try self.getPanfrostParam(.max_threads)),
            @truncate(try self.getPanfrostParam(.thread_max_workgroup_size)),
            @truncate(try self.getPanfrostParam(.selected_coherency)),
            null,
        );
    }

    /// Create a Panthor GPU address space. A zero requested range asks the
    /// kernel to select a safe split between user and kernel-owned GPU VAs.
    pub fn vmCreate(self: *Device) Error!Vm {
        if (self.driver != .panthor) return error.UnsupportedDriver;
        var arg = uapi.PanthorVmCreate{};
        try self.ioctl(uapi.ioctl_panthor_vm_create, @intFromPtr(&arg));
        return .{ .id = arg.id, .user_va_range = arg.user_va_range };
    }

    pub fn vmDestroy(self: *Device, vm: Vm) void {
        var arg = uapi.PanthorVmDestroy{ .id = vm.id };
        self.ioctl(uapi.ioctl_panthor_vm_destroy, @intFromPtr(&arg)) catch {};
    }

    pub fn vmState(self: *Device, vm: Vm) Error!u32 {
        var arg = uapi.PanthorVmGetState{ .vm_id = vm.id };
        try self.ioctl(uapi.ioctl_panthor_vm_get_state, @intFromPtr(&arg));
        return arg.state;
    }

    /// Create one medium-priority compute queue backed by a 64-KiB ring. More
    /// queues can be added without changing the group abstraction when the
    /// graphics path needs separate vertex/tiler and fragment streams.
    pub fn groupCreate(self: *Device, vm: Vm, info: GpuInfo) Error!Group {
        const queues = [_]QueueConfig{.{}};
        return self.groupCreateWithConfig(vm, .{
            .queues = &queues,
            .max_compute_cores = info.shader_core_count,
            .compute_core_mask = info.shader_present,
        });
    }

    /// Create an arbitrary Panthor scheduling group. Graphics normally uses
    /// three queues (vertex/tiler, fragment, compute); compute-only clients can
    /// use one. Queue descriptors are copied by the ioctl before this returns.
    pub fn groupCreateWithConfig(self: *Device, vm: Vm, config: GroupConfig) Error!Group {
        if (self.driver != .panthor) return error.UnsupportedDriver;
        if (config.queues.len == 0 or config.queues.len > std.math.maxInt(u32)) return error.InvalidArgument;
        const queues = self.node.allocator.alloc(uapi.PanthorQueueCreate, config.queues.len) catch return error.OutOfMemory;
        defer self.node.allocator.free(queues);
        for (config.queues, queues) |src, *dst| {
            if (src.priority > 15 or src.ring_size == 0) return error.InvalidArgument;
            dst.* = .{ .priority = src.priority, .ringbuf_size = src.ring_size };
        }
        var arg = uapi.PanthorGroupCreate{
            .queues = uapi.PanthorObjArray.init(uapi.PanthorQueueCreate, queues),
            .max_compute_cores = config.max_compute_cores,
            .max_fragment_cores = config.max_fragment_cores,
            .max_tiler_cores = config.max_tiler_cores,
            .priority = config.priority,
            .compute_core_mask = config.compute_core_mask,
            .fragment_core_mask = config.fragment_core_mask,
            .tiler_core_mask = config.tiler_core_mask,
            .vm_id = vm.id,
        };
        try self.ioctl(uapi.ioctl_panthor_group_create, @intFromPtr(&arg));
        return .{ .handle = arg.group_handle, .queue_count = @intCast(queues.len) };
    }

    pub fn groupDestroy(self: *Device, group: Group) void {
        var arg = uapi.PanthorGroupDestroy{ .group_handle = group.handle };
        self.ioctl(uapi.ioctl_panthor_group_destroy, @intFromPtr(&arg)) catch {};
    }

    pub fn groupState(self: *Device, group: Group) Error!uapi.PanthorGroupGetState {
        var arg = uapi.PanthorGroupGetState{ .group_handle = group.handle };
        try self.ioctl(uapi.ioctl_panthor_group_get_state, @intFromPtr(&arg));
        return arg;
    }

    pub fn tilerHeapCreate(
        self: *Device,
        vm: Vm,
        initial_chunks: u32,
        chunk_size: u32,
        max_chunks: u32,
        target_in_flight: u32,
    ) Error!TilerHeap {
        if (self.driver != .panthor) return error.UnsupportedDriver;
        if (initial_chunks == 0 or max_chunks < initial_chunks or chunk_size < 128 * 1024 or
            chunk_size > 8 * 1024 * 1024 or !std.mem.isAligned(chunk_size, 4096))
            return error.InvalidArgument;
        var arg = uapi.PanthorTilerHeapCreate{
            .vm_id = vm.id,
            .initial_chunk_count = initial_chunks,
            .chunk_size = chunk_size,
            .max_chunks = max_chunks,
            .target_in_flight = target_in_flight,
        };
        try self.ioctl(uapi.ioctl_panthor_tiler_heap_create, @intFromPtr(&arg));
        return .{
            .handle = arg.handle,
            .context_gpu_va = arg.tiler_heap_ctx_gpu_va,
            .first_chunk_gpu_va = arg.first_heap_chunk_gpu_va,
            .chunk_size = chunk_size,
        };
    }

    pub fn tilerHeapDestroy(self: *Device, heap: TilerHeap) void {
        var arg = uapi.PanthorTilerHeapDestroy{ .handle = heap.handle };
        self.ioctl(uapi.ioctl_panthor_tiler_heap_destroy, @intFromPtr(&arg)) catch {};
    }

    /// Submit a queue synchronization point with no command stream and signal
    /// `syncobj` when all earlier work on queue zero is complete.
    pub fn groupSubmitSync(self: *Device, group: Group, syncobj: u32) Error!void {
        const signals = [_]SyncPoint{.{ .handle = syncobj }};
        const submits = [_]QueueSubmission{.{
            .queue_index = 0,
            .signals = &signals,
        }};
        return self.groupSubmit(group, &submits);
    }

    /// Submit one or more command streams atomically to queues in `group`.
    /// Streams are raw CSF instructions in GPU-visible memory and must be
    /// 64-byte-address aligned with an 8-byte-multiple size.
    pub fn groupSubmit(self: *Device, group: Group, submissions: []const QueueSubmission) Error!void {
        if (submissions.len == 0 or submissions.len > group.queue_count) return error.InvalidArgument;
        var sync_count: usize = 0;
        for (submissions) |submission| {
            if (submission.queue_index >= group.queue_count or
                (submission.stream_size == 0) != (submission.stream_addr == 0) or
                (submission.stream_size != 0 and (submission.stream_size % 8 != 0 or submission.stream_addr % 64 != 0)))
                return error.InvalidArgument;
            sync_count = std.math.add(usize, sync_count, submission.waits.len + submission.signals.len) catch return error.InvalidArgument;
        }

        const raw_submits = self.node.allocator.alloc(uapi.PanthorQueueSubmit, submissions.len) catch return error.OutOfMemory;
        defer self.node.allocator.free(raw_submits);
        const raw_syncs = self.node.allocator.alloc(uapi.PanthorSyncOp, sync_count) catch return error.OutOfMemory;
        defer self.node.allocator.free(raw_syncs);

        var sync_offset: usize = 0;
        for (submissions, raw_submits) |submission, *raw_submit| {
            const begin = sync_offset;
            for (submission.waits) |point| {
                raw_syncs[sync_offset] = syncOp(point, false);
                sync_offset += 1;
            }
            for (submission.signals) |point| {
                raw_syncs[sync_offset] = syncOp(point, true);
                sync_offset += 1;
            }
            raw_submit.* = .{
                .queue_index = submission.queue_index,
                .stream_size = submission.stream_size,
                .stream_addr = submission.stream_addr,
                .latest_flush = submission.latest_flush,
                .syncs = uapi.PanthorObjArray.init(uapi.PanthorSyncOp, raw_syncs[begin..sync_offset]),
            };
        }
        var arg = uapi.PanthorGroupSubmit{
            .group_handle = group.handle,
            .queue_submits = uapi.PanthorObjArray.init(uapi.PanthorQueueSubmit, raw_submits),
        };
        try self.ioctl(uapi.ioctl_panthor_group_submit, @intFromPtr(&arg));
    }

    pub fn syncobjCreate(self: *Device, signaled: bool) Error!u32 {
        var arg = uapi.DrmSyncobjCreate{
            .flags = if (signaled) uapi.drm_syncobj_create_signaled else 0,
        };
        try self.ioctl(uapi.ioctl_drm_syncobj_create, @intFromPtr(&arg));
        return arg.handle;
    }

    pub fn syncobjDestroy(self: *Device, handle: u32) void {
        var arg = uapi.DrmSyncobjDestroy{ .handle = handle };
        self.ioctl(uapi.ioctl_drm_syncobj_destroy, @intFromPtr(&arg)) catch {};
    }

    pub fn syncobjSignal(self: *Device, handle: u32) Error!void {
        var handles = [_]u32{handle};
        var arg = uapi.DrmSyncobjArray{
            .handles = @intFromPtr(&handles),
            .count_handles = handles.len,
        };
        try self.ioctl(uapi.ioctl_drm_syncobj_signal, @intFromPtr(&arg));
    }

    pub fn syncobjWait(self: *Device, handles: []const u32, timeout_ns: u64) Error!void {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        const now_ns: i128 = @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
        const deadline = now_ns + @as(i128, timeout_ns);
        var arg = uapi.DrmSyncobjWait{
            .handles = @intFromPtr(handles.ptr),
            .timeout_nsec = if (deadline > std.math.maxInt(i64)) std.math.maxInt(i64) else @intCast(deadline),
            .count_handles = @intCast(handles.len),
            .flags = uapi.drm_syncobj_wait_all | uapi.drm_syncobj_wait_for_submit,
        };
        const rc = std.os.linux.ioctl(self.node.fd, uapi.ioctl_drm_syncobj_wait, @intFromPtr(&arg));
        const err = std.os.linux.errno(rc);
        if (err == .SUCCESS) return;
        if (err == .TIME) return error.Timeout;
        self.last_errno = @backingInt(err);
        self.last_request = uapi.ioctl_drm_syncobj_wait;
        return error.IoctlFailed;
    }

    fn boCreate(self: *Device, vm: Vm, size: u64, options: BoOptions) Error!struct { handle: u32, size: u64 } {
        if (options.write_back and !self.version.atLeast(1, 7)) return error.UnsupportedDriver;
        var arg = uapi.PanthorBoCreate{
            .size = size,
            .flags = if (options.write_back) uapi.panthor_bo_write_back else 0,
            .exclusive_vm_id = exclusiveVmId(vm, options),
        };
        try self.ioctl(uapi.ioctl_panthor_bo_create, @intFromPtr(&arg));
        return .{ .handle = arg.handle, .size = arg.size };
    }

    fn boMmap(self: *Device, handle: u32, size: u64) Error![]u8 {
        var arg = uapi.PanthorBoMmapOffset{ .handle = handle };
        try self.ioctl(uapi.ioctl_panthor_bo_mmap_offset, @intFromPtr(&arg));
        const rc = std.os.linux.mmap(
            null,
            @intCast(size),
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            self.node.fd,
            @intCast(arg.offset),
        );
        if (std.os.linux.errno(rc) != .SUCCESS) return error.MapFailed;
        const ptr: [*]u8 = @ptrFromInt(rc);
        return ptr[0..@intCast(size)];
    }

    fn vmMap(self: *Device, vm: Vm, handle: u32, gpu_va: u64, size: u64, options: BoOptions) Error!void {
        const op = uapi.PanthorVmBindOp{
            .flags = if (options.executable) 0 else uapi.panthor_vm_bind_map_noexec,
            .bo_handle = handle,
            .va = gpu_va,
            .size = size,
        };
        var ops = [_]uapi.PanthorVmBindOp{op};
        var arg = uapi.PanthorVmBind{
            .vm_id = vm.id,
            .ops = uapi.PanthorObjArray.init(uapi.PanthorVmBindOp, &ops),
        };
        try self.ioctl(uapi.ioctl_panthor_vm_bind, @intFromPtr(&arg));
    }

    fn vmUnmap(self: *Device, vm: Vm, gpu_va: u64, size: u64) Error!void {
        const op = uapi.PanthorVmBindOp{
            .flags = uapi.panthor_vm_bind_type_unmap,
            .va = gpu_va,
            .size = size,
        };
        var ops = [_]uapi.PanthorVmBindOp{op};
        var arg = uapi.PanthorVmBind{
            .vm_id = vm.id,
            .ops = uapi.PanthorObjArray.init(uapi.PanthorVmBindOp, &ops),
        };
        try self.ioctl(uapi.ioctl_panthor_vm_bind, @intFromPtr(&arg));
    }

    fn boClose(self: *Device, handle: u32) void {
        var arg = drm.types.GemClose{ .handle = handle };
        arg.close(self.node.fd) catch {};
    }

    /// Allocate, CPU-map, and synchronously bind a private data BO into `vm`.
    pub fn allocBo(self: *Device, vm: Vm, size: u64, gpu_va: u64) Error!Bo {
        return self.allocBoWithOptions(vm, size, gpu_va, .{});
    }

    pub fn allocBoWithOptions(self: *Device, vm: Vm, size: u64, gpu_va: u64, options: BoOptions) Error!Bo {
        if (self.driver != .panthor) return error.UnsupportedDriver;
        if (size == 0 or gpu_va == 0 or gpu_va >= vm.user_va_range or size > vm.user_va_range - gpu_va)
            return error.MapFailed;

        const created = try self.boCreate(vm, size, options);
        errdefer self.boClose(created.handle);

        const cpu = try self.boMmap(created.handle, created.size);
        errdefer _ = std.os.linux.munmap(@ptrCast(cpu.ptr), cpu.len);

        try self.vmMap(vm, created.handle, gpu_va, created.size, options);
        return .{ .handle = created.handle, .gpu_va = gpu_va, .cpu = cpu, .size = created.size };
    }

    fn boSync(self: *Device, bo: Bo, op_type: u32, offset: u64, size: u64) Error!void {
        if (!self.version.atLeast(1, 7)) return error.UnsupportedDriver;
        if (offset > bo.size or size > bo.size - offset) return error.InvalidArgument;
        var ops = [_]uapi.PanthorBoSyncOp{.{
            .handle = bo.handle,
            .type = op_type,
            .offset = offset,
            .size = size,
        }};
        var arg = uapi.PanthorBoSync{ .ops = uapi.PanthorObjArray.init(uapi.PanthorBoSyncOp, &ops) };
        try self.ioctl(uapi.ioctl_panthor_bo_sync, @intFromPtr(&arg));
    }

    pub fn boSyncToGpu(self: *Device, bo: Bo, offset: u64, size: u64) Error!void {
        return self.boSync(bo, uapi.panthor_bo_sync_flush, offset, size);
    }

    pub fn boSyncToCpu(self: *Device, bo: Bo, offset: u64, size: u64) Error!void {
        return self.boSync(bo, uapi.panthor_bo_sync_flush_invalidate, offset, size);
    }

    pub fn freeBo(self: *Device, vm: Vm, bo: Bo) void {
        self.vmUnmap(vm, bo.gpu_va, bo.size) catch {};
        if (bo.cpu.len != 0) _ = std.os.linux.munmap(@ptrCast(bo.cpu.ptr), bo.cpu.len);
        self.boClose(bo.handle);
    }
};

fn exclusiveVmId(vm: Vm, options: BoOptions) u32 {
    return if (options.exportable) 0 else vm.id;
}

fn decodeVersion(version: drm.types.Version) DriverVersion {
    return .{
        .major = if (version.major < 0) 0 else @intCast(version.major),
        .minor = if (version.minor < 0) 0 else @intCast(version.minor),
        .patch = if (version.patchlevel < 0) 0 else @intCast(version.patchlevel),
    };
}

fn syncOp(point: SyncPoint, signal: bool) uapi.PanthorSyncOp {
    return .{
        .flags = (if (signal) uapi.panthor_sync_op_signal else 0) |
            (if (point.timeline_value != 0) uapi.panthor_sync_op_timeline else 0),
        .handle = point.handle,
        .timeline_value = point.timeline_value,
    };
}

fn parseDriver(name: []const u8) ?Driver {
    if (std.mem.eql(u8, name, "panthor")) return .panthor;
    if (std.mem.eql(u8, name, "panfrost")) return .panfrost;
    return null;
}

fn decode(driver: Driver, gpu_id: u32, revision: u32, shader_present: u64, l2_present: u64, tiler_present: u64, as_present: u32, mmu_features: u32, max_threads: u32, max_workgroup_size: u32, coherency: u32, csf_id: ?u32) GpuInfo {
    const raw_product = gpu_id >> 16;
    const new_arch_major: u8 = @truncate(gpu_id >> 28);
    const is_midgard = new_arch_major == 0;
    const arch_major: u8 = if (is_midgard) switch (raw_product) {
        0x600, 0x620, 0x720 => 4,
        0x750, 0x820, 0x830, 0x860, 0x880 => 5,
        else => 0,
    } else new_arch_major;
    const arch_minor: u8 = if (is_midgard) 0 else @truncate((gpu_id >> 24) & 0xf);
    const product_major: u8 = @truncate((gpu_id >> 16) & 0xf);
    const product_id = if (is_midgard)
        raw_product
    else
        (@as(u32, arch_major) << 16) | (@as(u32, arch_minor) << 8) | product_major;
    return .{
        .driver = driver,
        .name = productName(product_id),
        .gpu_id = gpu_id,
        .gpu_revision = revision,
        .architecture_major = arch_major,
        .architecture_minor = arch_minor,
        .product_major = product_major,
        .shader_present = shader_present,
        .l2_present = l2_present,
        .tiler_present = tiler_present,
        .as_present = as_present,
        .shader_core_count = @intCast(@popCount(shader_present)),
        .l2_count = @intCast(@popCount(l2_present)),
        .address_space_count = @intCast(@popCount(as_present)),
        .mmu_va_bits = @truncate(mmu_features),
        .max_threads = max_threads,
        .max_workgroup_size = max_workgroup_size,
        .selected_coherency = coherency,
        .csf_id = csf_id,
    };
}

fn productName(product_id: u32) []const u8 {
    return switch (product_id) {
        0x600 => "Mali-T600",
        0x620 => "Mali-T620",
        0x720 => "Mali-T720",
        0x750 => "Mali-T760",
        0x820 => "Mali-T820",
        0x830 => "Mali-T830",
        0x860 => "Mali-T860",
        0x880 => "Mali-T880",
        0x060000 => "Mali-G71",
        0x060201 => "Mali-G72",
        0x070000 => "Mali-G51",
        0x070003 => "Mali-G31",
        0x070201 => "Mali-G76",
        0x070202, 0x070402 => "Mali-G52",
        0x090001, 0x090003 => "Mali-G57",
        0x090204 => "Mali-G68",
        0x0a0807 => "Mali-G610",
        0x0a0c04 => "Mali-G310",
        0x0b0802 => "Mali-G715",
        0x0b0803 => "Mali-G615",
        0x0c0800 => "Mali-G720",
        0x0d0800 => "Mali-G725",
        else => "Arm Mali (unknown model)",
    };
}

test "decode FydeTab Duo Mali-G610 identity" {
    const info = decode(.panthor, 0xa8670005, 0, 0x50005, 0x1, 0x1, 0xff, 48, 2048, 1024, 0, 0x040a0412);
    try std.testing.expectEqualStrings("Mali-G610", info.name);
    try std.testing.expectEqual(@as(u8, 10), info.architecture_major);
    try std.testing.expectEqual(@as(u8, 4), info.shader_core_count);
    try std.testing.expectEqual(@as(u8, 48), info.mmu_va_bits);
}

test "decode legacy Midgard identity" {
    const info = decode(.panfrost, 0x07500000, 0, 0xf, 1, 1, 0xff, 40, 256, 256, 0, null);
    try std.testing.expectEqualStrings("Mali-T760", info.name);
    try std.testing.expectEqual(@as(u8, 5), info.architecture_major);
}

test "driver versions compare major then minor" {
    const v = DriverVersion{ .major = 1, .minor = 7, .patch = 3 };
    try std.testing.expect(v.atLeast(1, 6));
    try std.testing.expect(v.atLeast(1, 7));
    try std.testing.expect(!v.atLeast(1, 8));
    try std.testing.expect(!v.atLeast(2, 0));
}

test "exportable BOs are not exclusive to one VM" {
    const vm = Vm{ .id = 7, .user_va_range = 1 << 40 };
    try std.testing.expectEqual(@as(u32, 7), exclusiveVmId(vm, .{}));
    try std.testing.expectEqual(@as(u32, 0), exclusiveVmId(vm, .{ .exportable = true }));
}

test "Panthor sync operations encode binary and timeline directions" {
    const wait = syncOp(.{ .handle = 3 }, false);
    try std.testing.expectEqual(@as(u32, 0), wait.flags);
    const signal = syncOp(.{ .handle = 4 }, true);
    try std.testing.expectEqual(uapi.panthor_sync_op_signal, signal.flags);
    const timeline = syncOp(.{ .handle = 5, .timeline_value = 9 }, true);
    try std.testing.expectEqual(uapi.panthor_sync_op_signal | uapi.panthor_sync_op_timeline, timeline.flags);
}
