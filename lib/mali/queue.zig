//! GPU-resident CSF command buffers and synchronized Panthor submission.

const std = @import("std");
const csf = @import("csf.zig");
const device = @import("device.zig");
const uapi = @import("uapi.zig");

pub const Error = device.Error || csf.Error || error{ EmptyCommandStream, GroupFault };

pub const Fence = struct {
    handle: u32,

    pub fn wait(self: Fence, dev: *device.Device, timeout_ns: u64) device.Error!void {
        const handles = [_]u32{self.handle};
        return dev.syncobjWait(&handles, timeout_ns);
    }

    pub fn deinit(self: Fence, dev: *device.Device) void {
        dev.syncobjDestroy(self.handle);
    }
};

pub const CommandBuffer = struct {
    bo: device.Bo,
    encoder: csf.Builder,

    /// Allocate executable command memory and bind it into `vm` at `gpu_va`.
    /// Panthor requires submitted stream addresses to be 64-byte aligned.
    pub fn create(dev: *device.Device, vm: device.Vm, size: u64, gpu_va: u64) Error!CommandBuffer {
        if (size < 64 or size % 8 != 0 or gpu_va % 64 != 0) return error.InvalidArgument;
        const bo = try dev.allocBoWithOptions(vm, size, gpu_va, .{ .executable = true });
        errdefer dev.freeBo(vm, bo);
        const aligned: []align(@alignOf(u64)) u8 = @alignCast(bo.cpu);
        const words = std.mem.bytesAsSlice(u64, aligned);
        return .{ .bo = bo, .encoder = csf.Builder.init(words) };
    }

    pub fn deinit(self: *CommandBuffer, dev: *device.Device, vm: device.Vm) void {
        dev.freeBo(vm, self.bo);
        self.* = undefined;
    }

    pub fn reset(self: *CommandBuffer) void {
        self.encoder.reset();
    }

    /// Queue the currently encoded stream and return an owned completion
    /// fence. The command buffer and every referenced BO must remain alive
    /// until the fence signals.
    pub fn submit(
        self: *CommandBuffer,
        dev: *device.Device,
        group: device.Group,
        queue_index: u32,
        waits: []const device.SyncPoint,
    ) Error!Fence {
        const byte_len = self.encoder.bytes().len;
        if (byte_len == 0) return error.EmptyCommandStream;
        const stream_size = std.math.cast(u32, byte_len) orelse return error.InvalidArgument;

        const out = try dev.syncobjCreate(false);
        errdefer dev.syncobjDestroy(out);
        const signals = [_]device.SyncPoint{.{ .handle = out }};
        const submissions = [_]device.QueueSubmission{.{
            .queue_index = queue_index,
            .stream_addr = self.bo.gpu_va,
            .stream_size = stream_size,
            .waits = waits,
            .signals = &signals,
        }};
        try dev.groupSubmit(group, &submissions);
        return .{ .handle = out };
    }

    /// Submit, wait for completion, and verify the scheduling group did not
    /// time out or fault. This matches Prism's currently synchronous HAL.
    pub fn submitAndWait(
        self: *CommandBuffer,
        dev: *device.Device,
        group: device.Group,
        queue_index: u32,
        waits: []const device.SyncPoint,
        timeout_ns: u64,
    ) Error!void {
        const fence = try self.submit(dev, group, queue_index, waits);
        defer fence.deinit(dev);
        try fence.wait(dev, timeout_ns);
        const state = try dev.groupState(group);
        if (state.state & (uapi.panthor_group_state_timed_out | uapi.panthor_group_state_fatal_fault) != 0)
            return error.GroupFault;
    }
};

test "command buffers require submit-compatible alignment" {
    // The check is intentionally factored before device access. A dummy device
    // is never dereferenced for invalid requests.
    const dummy: *device.Device = undefined;
    const vm = device.Vm{ .id = 1, .user_va_range = 1 << 20 };
    try std.testing.expectError(error.InvalidArgument, CommandBuffer.create(dummy, vm, 63, 0x10000));
    try std.testing.expectError(error.InvalidArgument, CommandBuffer.create(dummy, vm, 64, 0x10001));
}
