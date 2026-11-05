//! Minimal reusable Valhall compute-kernel and dispatch support.

const std = @import("std");
const csf = @import("csf.zig");
const descriptors = @import("descriptors.zig");
const device = @import("device.zig");
const queue = @import("queue.zig");
const session_mod = @import("session.zig");

pub const Error = device.Error || queue.Error || csf.Error || error{InvalidShader};

pub const Kernel = struct {
    bo: device.Bo,
    shader_va: u64,
    tsd_va: u64,
    spd_va: u64,

    const shader_offset = 0;
    const tsd_offset = 64;
    const spd_offset = 128;

    pub fn create(
        session: *session_mod.Session,
        code: []const u8,
        register_count: u8,
        preload: u16,
    ) Error!Kernel {
        if (code.len == 0 or code.len > tsd_offset or code.len % 8 != 0 or register_count == 0 or register_count > 64)
            return error.InvalidShader;
        const bo = try session.allocBo(4096, .{ .executable = true });
        errdefer session.freeBo(bo);
        @memcpy(bo.cpu[shader_offset..][0..code.len], code);

        const tsd = descriptors.LocalStorage.empty();
        @memcpy(bo.cpu[tsd_offset..][0..tsd.bytes().len], tsd.bytes());
        const allocation: descriptors.RegisterAllocation = if (register_count <= 32) .per_thread_32 else .per_thread_64;
        const spd = descriptors.ShaderProgram.init(.compute, bo.gpu_va + shader_offset, preload, allocation);
        @memcpy(bo.cpu[spd_offset..][0..spd.bytes().len], spd.bytes());
        return .{
            .bo = bo,
            .shader_va = bo.gpu_va + shader_offset,
            .tsd_va = bo.gpu_va + tsd_offset,
            .spd_va = bo.gpu_va + spd_offset,
        };
    }

    pub fn deinit(self: *Kernel, session: *session_mod.Session) void {
        session.freeBo(self.bo);
        self.* = undefined;
    }
};

pub const Grid = struct {
    x: u32 = 1,
    y: u32 = 1,
    z: u32 = 1,
};

/// Dispatch a kernel with no resources or FAU data. This is useful for shader
/// bring-up and is also the common command skeleton extended by resource-aware
/// dispatch below.
pub fn dispatchNoResources(
    session: *session_mod.Session,
    kernel: Kernel,
    grid: Grid,
    timeout_ns: u64,
) Error!void {
    return dispatch(session, kernel, &.{}, grid, timeout_ns);
}

fn encodeDispatch(b: *csf.Builder, kernel: Kernel, grid: Grid, fau_va: u64, fau_count: u8) Error!void {
    if (grid.x == 0 or grid.y == 0 or grid.z == 0 or fau_count > 128) return error.InvalidArgument;

    try b.requestResources(.{ .compute = true });
    try b.move32(0, 0);
    try b.flushCache(.{ .l2_mode = 3, .lsc_mode = 3, .other_mode = 2, .latest_flush_id_register = 0, .signal_slot = 0 });
    try b.wait(1, false);

    try b.move48(csf.compute_register.srt_0, 0);
    try b.move64(csf.compute_register.fau_0, fau_va | (@as(u64, fau_count) << 56));
    try b.move48(csf.compute_register.spd_0, kernel.spd_va);
    try b.move48(csf.compute_register.tsd_0, kernel.tsd_va);
    try b.move32(csf.compute_register.global_attribute_offset, 0);
    try b.move32(csf.compute_register.workgroup_size, descriptors.computeWorkgroupSize(1, 1, 1, true));
    try b.move32(csf.compute_register.job_offset_x, 0);
    try b.move32(csf.compute_register.job_offset_y, 0);
    try b.move32(csf.compute_register.job_offset_z, 0);
    try b.move32(csf.compute_register.job_size_x, grid.x);
    try b.move32(csf.compute_register.job_size_y, grid.y);
    try b.move32(csf.compute_register.job_size_z, grid.z);
    try b.setScoreboardEntry(0, 0);
    try b.runCompute(.{ .task_increment = 1, .task_axis = .x });
    try b.wait(1, false);

    try b.move32(0, 0);
    try b.flushCache(.{ .l2_mode = 3, .lsc_mode = 3, .other_mode = 0, .latest_flush_id_register = 0, .signal_slot = 0 });
    try b.wait(1, false);
}

/// Dispatch arbitrary native Valhall code with up to 128 32-bit FAU words.
/// `fau_data` is copied into GPU-visible memory and remains alive through the
/// completion fence.
pub fn dispatch(
    session: *session_mod.Session,
    kernel: Kernel,
    fau_data: []const u8,
    grid: Grid,
    timeout_ns: u64,
) Error!void {
    if (fau_data.len % 4 != 0 or fau_data.len > 128 * 4) return error.InvalidArgument;
    var fau: ?device.Bo = null;
    defer if (fau) |bo| session.freeBo(bo);
    if (fau_data.len != 0) {
        fau = try session.allocBo(fau_data.len, .{});
        @memcpy(fau.?.cpu[0..fau_data.len], fau_data);
    }

    var command = try session.createCommandBuffer(4096);
    defer session.destroyCommandBuffer(&command);
    try encodeDispatch(
        &command.encoder,
        kernel,
        grid,
        if (fau) |bo| bo.gpu_va else 0,
        @intCast(fau_data.len / 4),
    );
    try command.submitAndWait(&session.dev, session.group, @backingInt(session_mod.Queue.compute), &.{}, timeout_ns);
}

/// Prism compute ABI: each bound buffer contributes its 64-bit GPU address as
/// two consecutive FAU words, in binding order.
pub fn dispatchBuffers(
    session: *session_mod.Session,
    kernel: Kernel,
    buffers: []const device.Bo,
    grid: Grid,
    timeout_ns: u64,
) Error!void {
    if (buffers.len > 64) return error.InvalidArgument;
    var fau: [64 * 8]u8 = @splat(0);
    for (buffers, 0..) |bo, i|
        std.mem.writeInt(u64, fau[i * 8 ..][0..8], bo.gpu_va, .little);
    return dispatch(session, kernel, fau[0 .. buffers.len * 8], grid, timeout_ns);
}

/// Dispatch the validation shader below. The target's first u32 becomes
/// 0x11223344, proving FAU delivery, shader execution, and GPU memory stores.
pub fn dispatchWriteConstant(
    session: *session_mod.Session,
    kernel: Kernel,
    target: device.Bo,
    timeout_ns: u64,
) Error!void {
    if (target.size < @sizeOf(u32)) return error.InvalidArgument;
    return dispatchBuffers(session, kernel, &.{target}, .{}, timeout_ns);
}

/// Valhall v9-v14 instruction assembled by Mesa's standalone assembler:
/// `NOP.end`. It performs no memory access and terminates the shader cleanly.
pub const noop_shader = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xc0, 0x00, 0x78 };

/// Mesa Valhall assembler source:
///   MOV.i32 r0, u0.w0
///   MOV.i32 r1, u0.w1
///   IADD_IMM.i32 r2, 0x0, #0x11223344
///   STORE.i32.slot0.end @r2, [r0:r1], offset:0
pub const write_constant_shader = [_]u8{
    0x80, 0x00, 0x00, 0x00, 0x00, 0xc0, 0x91, 0x00,
    0x81, 0x00, 0x00, 0x00, 0x00, 0xc1, 0x91, 0x00,
    0xc0, 0x44, 0x33, 0x22, 0x11, 0xc2, 0x10, 0x01,
    0x00, 0x00, 0x00, 0x18, 0x02, 0x42, 0x61, 0x78,
};

test "no-op shader is one complete Valhall instruction" {
    try std.testing.expectEqual(@as(usize, 8), noop_shader.len);
    try std.testing.expectEqual(@as(u8, 0x78), noop_shader[7]);
}

test "write-constant shader preserves Mesa assembler output" {
    try std.testing.expectEqual(@as(usize, 32), write_constant_shader.len);
    try std.testing.expectEqualSlices(u8, &.{ 0xc0, 0x44, 0x33, 0x22, 0x11, 0xc2, 0x10, 0x01 }, write_constant_shader[16..24]);
    try std.testing.expectEqual(@as(u8, 0x78), write_constant_shader[31]);
}
