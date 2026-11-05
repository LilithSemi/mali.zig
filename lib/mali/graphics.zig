//! Initial Valhall v10 graphics path: linear RGBA8 images and fragment clears.

const std = @import("std");
const csf = @import("csf.zig");
const descriptors = @import("descriptors.zig");
const device = @import("device.zig");
const queue = @import("queue.zig");
const session_mod = @import("session.zig");

pub const Error = device.Error || queue.Error || csf.Error || error{ InvalidImage, InvalidShader };

const probe_vertex_shader = [_]u8{
    0x7c, 0x7d, 0x00, 0x12, 0x04, 0x80, 0x66, 0x00, 0x83, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x08,
    0x40, 0x80, 0x42, 0x00, 0x00, 0xc0, 0xb2, 0x00, 0x84, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x00,
    0x41, 0x81, 0x42, 0x00, 0x00, 0xc1, 0xb2, 0x00, 0x7b, 0x0d, 0x00, 0x40, 0x04, 0x82, 0x5e, 0x10,
    0x02, 0x00, 0x00, 0x99, 0x02, 0x40, 0x61, 0x00, 0x86, 0x00, 0x00, 0x00, 0x00, 0xc4, 0x91, 0x00,
    0xc0, 0x00, 0x00, 0x00, 0x00, 0xc5, 0x91, 0x00, 0x44, 0x02, 0x07, 0x00, 0x00, 0xc4, 0xab, 0x21,
    0x44, 0x00, 0x00, 0x19, 0x02, 0x41, 0x61, 0x00, 0x87, 0x00, 0x00, 0x00, 0x00, 0xc0, 0x91, 0x00,
    0xc0, 0x00, 0x00, 0x00, 0x00, 0xc1, 0x91, 0x00, 0x40, 0x02, 0x07, 0x00, 0x00, 0xc0, 0xab, 0x01,
    0x85, 0x00, 0x00, 0x00, 0x00, 0xc4, 0x91, 0x08, 0x40, 0x00, 0x00, 0x59, 0x02, 0x44, 0x61, 0x00,
    0x88, 0x00, 0x00, 0x00, 0x00, 0xc0, 0x91, 0x00, 0xc0, 0x00, 0x00, 0x00, 0x00, 0xc1, 0x91, 0x00,
    0x40, 0x42, 0x07, 0x00, 0x00, 0xc0, 0xab, 0x01, 0xc0, 0x00, 0x00, 0x80, 0x3f, 0xc2, 0x10, 0x11,
    0x40, 0x00, 0x00, 0x99, 0x02, 0x42, 0x61, 0x78,
};

const probe_fragment_shader = [_]u8{
    0x00, 0x00, 0x00, 0x00, 0x00, 0xc0, 0x00, 0x40, 0x7c, 0xd0, 0xea, 0x00, 0x02, 0xbc, 0x7d, 0x08,
    0xd0, 0x00, 0x00, 0x00, 0x00, 0xc0, 0x91, 0x68, 0xc0, 0x00, 0x00, 0x00, 0x00, 0xc1, 0x91, 0x00,
    0xc0, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x00, 0xd0, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x91, 0x48,
    0x84, 0x00, 0x3c, 0x32, 0x08, 0x40, 0x7f, 0x78, 0xc0, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x10, 0x01,
    0xc0, 0x85, 0x00, 0x00, 0x10, 0xc1, 0x2f, 0x00,
};

const vertex_color_varying_shader = [_]u8{
    0x7b, 0x0d, 0x00, 0x00, 0x04, 0x80, 0x5e, 0x00, 0x7c, 0x7d, 0x10, 0x62, 0x06, 0x82, 0x66, 0x18,
    0x00, 0x00, 0x00, 0x9a, 0x02, 0x42, 0x61, 0x00, 0x86, 0x00, 0x00, 0x00, 0x00, 0xc6, 0x91, 0x00,
    0xc0, 0x00, 0x00, 0x00, 0x00, 0xc7, 0x91, 0x00, 0x46, 0x00, 0x07, 0x00, 0x00, 0xc6, 0xab, 0x21,
    0x46, 0x00, 0x00, 0x1a, 0x02, 0x43, 0x61, 0x00, 0x87, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x00,
    0xc0, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x91, 0x00, 0x42, 0x40, 0x07, 0x00, 0x00, 0xc0, 0xab, 0x09,
    0x40, 0x00, 0x00, 0x5a, 0x02, 0x44, 0x61, 0x78,
};

const vertex_color_fragment_shader = [_]u8{
    0x00, 0x00, 0x00, 0x00, 0x00, 0xc0, 0x00, 0x40, 0x7c, 0xd0, 0xea, 0x00, 0x02, 0xbc, 0x7d, 0x08,
    0x7d, 0x00, 0x00, 0x22, 0x06, 0x80, 0x5c, 0x68, 0xd0, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x91, 0x48,
    0x84, 0x00, 0x3c, 0x72, 0x08, 0x40, 0x7f, 0x78, 0xc0, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x10, 0x01,
    0xc0, 0x85, 0x00, 0x00, 0x10, 0xc1, 0x2f, 0x00,
};

// Mesa 26.2 PanVK output for PhantomUI's text/image vertex ABI: position,
// UV, then RGBA color. The 24-byte logical payload occupies two 16-byte
// varying slots.
const textured_color_varying_shader = [_]u8{
    0x7b, 0x0d, 0x00, 0x00, 0x04, 0x80, 0x5e, 0x00, 0x3c, 0x3d, 0x10, 0x52, 0x04, 0x82, 0x66, 0x18,
    0x00, 0x00, 0x00, 0x9a, 0x02, 0x42, 0x61, 0x00, 0x86, 0x00, 0x00, 0x00, 0x00, 0xc4, 0x91, 0x00,
    0xc0, 0x00, 0x00, 0x00, 0x00, 0xc5, 0x91, 0x00, 0x44, 0x00, 0x07, 0x00, 0x00, 0xc4, 0xab, 0x21,
    0x44, 0x00, 0x00, 0x1a, 0x02, 0x43, 0x61, 0x00, 0x89, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x00,
    0xc0, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x91, 0x00, 0x00, 0x42, 0x07, 0x00, 0x00, 0xc2, 0xab, 0x01,
    0x7c, 0x7d, 0x20, 0x72, 0x08, 0x84, 0x66, 0x18, 0x42, 0x00, 0x00, 0x9a, 0x02, 0x44, 0x61, 0x00,
    0x8a, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x00, 0xc0, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x91, 0x00,
    0x42, 0x00, 0x07, 0x00, 0x00, 0xc2, 0xab, 0x21, 0x42, 0x00, 0x00, 0x1a, 0x02, 0x45, 0x61, 0x00,
    0x8b, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x00, 0xc0, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x91, 0x00,
    0x42, 0x00, 0x07, 0x00, 0x00, 0xc2, 0xab, 0x09, 0x42, 0x00, 0x00, 0x5a, 0x02, 0x46, 0x61, 0x00,
    0x8c, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x00, 0xc0, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x91, 0x00,
    0x42, 0x40, 0x07, 0x00, 0x00, 0xc0, 0xab, 0x11, 0x40, 0x00, 0x00, 0x9a, 0x02, 0x47, 0x61, 0x78,
};

const text_fragment_shader = [_]u8{
    0x3d, 0x00, 0x00, 0x12, 0x04, 0x80, 0x5c, 0x00, 0x86, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x00,
    0xc0, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x91, 0x08, 0x42, 0x20, 0x00, 0x52, 0x84, 0x40, 0x28, 0x69,
    0x7d, 0x00, 0x10, 0xb2, 0x08, 0x82, 0x5c, 0x30, 0x45, 0x40, 0xc0, 0x00, 0x04, 0xc5, 0xb2, 0x40,
    0x7c, 0x05, 0xea, 0x00, 0x02, 0xbc, 0x7d, 0x08, 0x42, 0x00, 0x00, 0x00, 0x00, 0xc0, 0x91, 0x00,
    0x43, 0x00, 0x00, 0x00, 0x00, 0xc1, 0x91, 0x00, 0x44, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x00,
    0x45, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x91, 0x48, 0x84, 0x00, 0x3c, 0x32, 0x08, 0x40, 0x7f, 0x78,
    0xc0, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x10, 0x01, 0xc0, 0x85, 0x00, 0x00, 0x10, 0xc1, 0x2f, 0x00,
};

const image_fragment_shader = [_]u8{
    0x3d, 0x00, 0x10, 0x32, 0x08, 0x80, 0x5c, 0x08, 0x7d, 0x00, 0x00, 0x52, 0x04, 0x80, 0x5c, 0x00,
    0x86, 0x00, 0x00, 0x00, 0x00, 0xc4, 0x91, 0x00, 0xc0, 0x00, 0x00, 0x00, 0x00, 0xc5, 0x91, 0x10,
    0x44, 0x20, 0xc4, 0x93, 0xb4, 0x40, 0x28, 0x21, 0x47, 0x43, 0xc0, 0x00, 0x04, 0xc3, 0xb2, 0x40,
    0x7c, 0x03, 0xea, 0x00, 0x02, 0xbc, 0x7d, 0x08, 0x44, 0x00, 0x00, 0x00, 0x00, 0xc0, 0x91, 0x68,
    0x45, 0x00, 0x00, 0x00, 0x00, 0xc1, 0x91, 0x00, 0x46, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x48,
    0x84, 0x00, 0x3c, 0x32, 0x08, 0x40, 0x7f, 0x78, 0xc0, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x10, 0x01,
    0xc0, 0x85, 0x00, 0x00, 0x10, 0xc1, 0x2f, 0x00,
};

// Mesa 26.2 PanVK output for PhantomUI's rounded-rectangle shader pair. The
// primary position shader is shared with the simpler pipelines; IDVS runs this
// secondary shader to write 40 bytes of generic varyings per vertex.
const rrect_varying_shader = [_]u8{
    0x7b, 0x0d, 0x00, 0x00, 0x04, 0x80, 0x5e, 0x00, 0x3c, 0x3d, 0x10, 0x52, 0x04, 0x82, 0x66, 0x18,
    0x00, 0x00, 0x00, 0x9a, 0x02, 0x42, 0x61, 0x00, 0x86, 0x00, 0x00, 0x00, 0x00, 0xc4, 0x91, 0x00,
    0xc0, 0x00, 0x00, 0x00, 0x00, 0xc5, 0x91, 0x00, 0x44, 0x00, 0x07, 0x00, 0x00, 0xc4, 0xab, 0x21,
    0x44, 0x00, 0x00, 0x1a, 0x02, 0x43, 0x61, 0x00, 0x89, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x00,
    0xc0, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x91, 0x00, 0x00, 0x42, 0x07, 0x00, 0x00, 0xc2, 0xab, 0x01,
    0x3c, 0x3d, 0x20, 0x72, 0x08, 0x84, 0x66, 0x18, 0x42, 0x00, 0x00, 0x9a, 0x02, 0x44, 0x61, 0x00,
    0x8a, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x00, 0xc0, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x91, 0x00,
    0x42, 0x00, 0x07, 0x00, 0x00, 0xc2, 0xab, 0x21, 0x42, 0x00, 0x00, 0x1a, 0x02, 0x45, 0x61, 0x00,
    0x8b, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x00, 0xc0, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x91, 0x00,
    0x42, 0x00, 0x07, 0x00, 0x00, 0xc2, 0xab, 0x09, 0x42, 0x00, 0x00, 0x5a, 0x02, 0x46, 0x61, 0x00,
    0x8c, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x00, 0xc0, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x91, 0x00,
    0x42, 0x00, 0x07, 0x00, 0x00, 0xc2, 0xab, 0x11, 0x42, 0x00, 0x00, 0x9a, 0x02, 0x47, 0x61, 0x00,
    0x8d, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x00, 0xc0, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x91, 0x00,
    0x00, 0x42, 0x07, 0x00, 0x00, 0xc2, 0xab, 0x01, 0x7c, 0x7d, 0x30, 0x32, 0x08, 0x84, 0x66, 0x28,
    0x42, 0x00, 0x00, 0x5a, 0x02, 0x44, 0x61, 0x00, 0x8e, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x00,
    0xc0, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x91, 0x00, 0x42, 0x00, 0x07, 0x00, 0x00, 0xc2, 0xab, 0x11,
    0x42, 0x00, 0x00, 0x9a, 0x02, 0x45, 0x61, 0x00, 0x8f, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x00,
    0xc0, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x91, 0x00, 0x42, 0x00, 0x07, 0x00, 0x00, 0xc2, 0xab, 0x21,
    0x42, 0x00, 0x00, 0x1a, 0x02, 0x46, 0x61, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x00,
    0xc0, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x91, 0x00, 0x42, 0x40, 0x07, 0x00, 0x00, 0xc0, 0xab, 0x09,
    0x40, 0x00, 0x00, 0x5a, 0x02, 0x47, 0x61, 0x78,
};

const rrect_fragment_shader = [_]u8{
    0x3d, 0x00, 0x00, 0x12, 0x04, 0x80, 0x5c, 0x08, 0x3d, 0x00, 0x10, 0x72, 0x08, 0x82, 0x5c, 0x10,
    0x40, 0x42, 0x00, 0x00, 0x90, 0xc0, 0xa4, 0x68, 0x41, 0x43, 0x00, 0x00, 0x90, 0xc1, 0xa4, 0x00,
    0x40, 0x04, 0x00, 0x00, 0x00, 0xc0, 0xa4, 0x00, 0x41, 0x04, 0x00, 0x00, 0x00, 0xc1, 0xa4, 0x00,
    0x00, 0x01, 0x03, 0x00, 0x00, 0xc2, 0xa4, 0x00, 0x42, 0xc0, 0x02, 0x00, 0x00, 0xc2, 0xa4, 0x00,
    0x40, 0xc0, 0x00, 0x00, 0x11, 0xc0, 0xa4, 0x00, 0x41, 0xc0, 0x00, 0x00, 0x11, 0xc1, 0xa4, 0x00,
    0x41, 0x41, 0xc0, 0x00, 0x04, 0xc1, 0xb2, 0x00, 0x40, 0x40, 0x41, 0x00, 0x00, 0xc0, 0xb2, 0x00,
    0x40, 0x00, 0x02, 0x00, 0x00, 0xc0, 0x9c, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0xc0, 0x9c, 0x00,
    0x42, 0x40, 0x00, 0x00, 0x00, 0xc0, 0xa4, 0x00, 0x40, 0x44, 0x00, 0x00, 0x10, 0xc0, 0xa4, 0x00,
    0x05, 0xda, 0x00, 0x08, 0x00, 0xc1, 0xb2, 0x00, 0x05, 0xda, 0x41, 0x08, 0x48, 0xc1, 0xb2, 0x00,
    0xda, 0x41, 0x00, 0x20, 0x13, 0xc1, 0xa4, 0x00, 0xda, 0x40, 0x00, 0x20, 0x13, 0xc0, 0xa4, 0x00,
    0xc0, 0x45, 0xc0, 0x80, 0x04, 0xc2, 0xf4, 0x00, 0x42, 0xc0, 0x40, 0x41, 0x00, 0xc0, 0x50, 0x01,
    0x7d, 0x00, 0x20, 0xb2, 0x08, 0x82, 0x5c, 0x20, 0x45, 0x40, 0xc0, 0x00, 0x04, 0xc5, 0xb2, 0x40,
    0x7c, 0x05, 0xea, 0x00, 0x02, 0xbc, 0x7d, 0x08, 0x42, 0x00, 0x00, 0x00, 0x00, 0xc0, 0x91, 0x00,
    0x43, 0x00, 0x00, 0x00, 0x00, 0xc1, 0x91, 0x00, 0x44, 0x00, 0x00, 0x00, 0x00, 0xc2, 0x91, 0x00,
    0x45, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x91, 0x48, 0x84, 0x00, 0x3c, 0x32, 0x08, 0x40, 0x7f, 0x78,
    0xc0, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x10, 0x01, 0xc0, 0x85, 0x00, 0x00, 0x10, 0xc1, 0x2f, 0x00,
};

pub const Image = struct {
    bo: device.Bo,
    width: u16,
    height: u16,
    row_stride: u32,

    pub fn create(session: *session_mod.Session, width: u16, height: u16) Error!Image {
        if (width == 0 or height == 0) return error.InvalidImage;
        const row_stride = std.mem.alignForward(u32, @as(u32, width) * 4, 64);
        const size = @as(u64, row_stride) * height;
        if (size > std.math.maxInt(u32)) return error.InvalidImage;
        return .{
            .bo = try session.allocBo(size, .{}),
            .width = width,
            .height = height,
            .row_stride = row_stride,
        };
    }

    pub fn deinit(self: *Image, session: *session_mod.Session) void {
        session.freeBo(self.bo);
        self.* = undefined;
    }

    pub fn pixels(self: *const Image) []const u8 {
        return self.bo.cpu[0 .. @as(usize, self.row_stride) * self.height];
    }
};

/// Retained native Valhall graphics shaders using Panfrost's v10 IDVS ABI.
/// A SPIR-V compiler supplies the stage binaries, preload masks, and register
/// counts; command buffers can then reuse these descriptors across draws.
pub const NativeGraphicsPipeline = struct {
    bo: device.Bo,
    vertex_spd_va: u64,
    varying_spd_va: u64,
    fragment_spd_va: u64,
    tsd_va: u64,
    vertex_layout: VertexLayout,
    blend: BlendMode = .replace,

    pub const BlendMode = enum {
        replace,
        src_alpha,
    };

    pub const VertexLayout = enum {
        position,
        position_color,
        textured_color,
        rrect,

        pub fn stride(self: VertexLayout) u32 {
            return switch (self) {
                .position => 8,
                .position_color => 20,
                .textured_color => 32,
                .rrect => 48,
            };
        }

        fn varyingSize(self: VertexLayout) u32 {
            return switch (self) {
                .position => 0,
                .position_color => 12,
                .textured_color => 32,
                .rrect => 48,
            };
        }
    };

    pub const Stage = struct {
        code: []const u8,
        register_count: u8,
        preload: u16,
        descriptor_flags: u32 = 1 << 8,
    };

    const vertex_code_offset = 0;
    const varying_code_offset = 512;
    const fragment_code_offset = 1024;
    const vertex_spd_offset = 2048;
    const varying_spd_offset = 2080;
    const fragment_spd_offset = 2112;
    // LOCAL_STORAGE has a stricter alignment than SHADER_PROGRAM. Keep the
    // three 32-byte SPDs packed together, then round the TSD up to 64 bytes.
    // An address at the old 0x860 offset is rejected when RUN_IDVS validates
    // its position/varying/fragment thread-storage selection.
    const tsd_offset = 2176;

    pub fn create(session: *session_mod.Session, vertex: Stage, fragment: Stage) Error!NativeGraphicsPipeline {
        return createStages(session, vertex, null, fragment, .position);
    }

    fn createStages(
        session: *session_mod.Session,
        vertex: Stage,
        varying: ?Stage,
        fragment: Stage,
        vertex_layout: VertexLayout,
    ) Error!NativeGraphicsPipeline {
        if (!validStage(vertex) or !validStage(fragment) or
            (varying != null and !validStage(varying.?))) return error.InvalidShader;
        const bo = try session.allocBo(4096, .{ .executable = true });
        errdefer session.freeBo(bo);
        @memset(bo.cpu, 0);
        @memcpy(bo.cpu[vertex_code_offset..][0..vertex.code.len], vertex.code);
        if (varying) |stage| @memcpy(bo.cpu[varying_code_offset..][0..stage.code.len], stage.code);
        @memcpy(bo.cpu[fragment_code_offset..][0..fragment.code.len], fragment.code);

        var vertex_spd = descriptors.ShaderProgram.init(
            .vertex,
            bo.gpu_va + vertex_code_offset,
            vertex.preload,
            allocation(vertex.register_count),
        );
        vertex_spd.words[0] |= vertex.descriptor_flags;
        copyWords(bo.cpu, vertex_spd_offset, &vertex_spd.words);
        if (varying) |stage| {
            var varying_spd = descriptors.ShaderProgram.init(
                .vertex,
                bo.gpu_va + varying_code_offset,
                stage.preload,
                allocation(stage.register_count),
            );
            varying_spd.words[0] |= stage.descriptor_flags;
            copyWords(bo.cpu, varying_spd_offset, &varying_spd.words);
        }
        var fragment_spd = descriptors.ShaderProgram.init(
            .fragment,
            bo.gpu_va + fragment_code_offset,
            fragment.preload,
            allocation(fragment.register_count),
        );
        fragment_spd.words[0] |= fragment.descriptor_flags;
        copyWords(bo.cpu, fragment_spd_offset, &fragment_spd.words);
        const tsd = descriptors.LocalStorage.empty();
        copyWords(bo.cpu, tsd_offset, &tsd.words);
        return .{
            .bo = bo,
            .vertex_spd_va = bo.gpu_va + vertex_spd_offset,
            .varying_spd_va = if (varying != null) bo.gpu_va + varying_spd_offset else 0,
            .fragment_spd_va = bo.gpu_va + fragment_spd_offset,
            .tsd_va = bo.gpu_va + tsd_offset,
            .vertex_layout = vertex_layout,
            .blend = .replace,
        };
    }

    /// Create the small, Mesa-derived pipeline used by the Prism device probe:
    /// location 0 is a `vec2<f32>` clip-space position and the fragment output
    /// is opaque red.  Prism validates that a SPIR-V pair has exactly those
    /// semantics before selecting this native template.
    pub fn createProbe(session: *session_mod.Session) Error!NativeGraphicsPipeline {
        return createConstantColor(session, .{ 1, 0, 0, 1 });
    }

    /// Create the passthrough-position pipeline with an arbitrary constant
    /// fragment color. Each channel is materialized with Valhall's canonical
    /// `IADD_IMM.i32 0, #bits` encoding, avoiding any dependency on FAU slots.
    pub fn createConstantColor(session: *session_mod.Session, color: [4]f32) Error!NativeGraphicsPipeline {
        const fragment = constantFragmentShader(color);
        return create(session, .{
            .code = &probe_vertex_shader,
            .register_count = 6,
            .preload = 0x3800,
        }, .{
            .code = &fragment,
            .register_count = 4,
            .preload = 0x3000,
        });
    }

    /// Create the Mesa-derived IDVS split pipeline for interleaved
    /// `vec2<f32>` position plus `vec3<f32>` color. The secondary vertex
    /// stage writes a 12-byte generic varying packet and the fragment stage
    /// reads it with smooth interpolation.
    pub fn createVertexColor(session: *session_mod.Session) Error!NativeGraphicsPipeline {
        return createStages(session, .{
            .code = &probe_vertex_shader,
            .register_count = 6,
            .preload = 0x3800,
        }, .{
            .code = &vertex_color_varying_shader,
            .register_count = 8,
            .preload = 0x3800,
            // v10 secondary/varying shaders run with the full warp limit.
            .descriptor_flags = 0,
        }, .{
            .code = &vertex_color_fragment_shader,
            .register_count = 4,
            .preload = 0x3000,
        }, .position_color);
    }

    /// PhantomUI rounded rectangle: position/local vec2 inputs followed by
    /// params/color vec4 inputs, with three 16-byte generic varying slots.
    pub fn createRoundedRectangle(session: *session_mod.Session) Error!NativeGraphicsPipeline {
        return createStages(session, .{
            .code = &probe_vertex_shader,
            .register_count = 6,
            .preload = 0x3800,
        }, .{
            .code = &rrect_varying_shader,
            .register_count = 8,
            .preload = 0x3800,
            .descriptor_flags = 0,
        }, .{
            .code = &rrect_fragment_shader,
            .register_count = 6,
            .preload = 0x3000,
        }, .rrect);
    }

    /// PhantomUI text shader. The sampled texture alpha masks the per-vertex
    /// color while RGB comes from that color.
    pub fn createText(session: *session_mod.Session) Error!NativeGraphicsPipeline {
        return createTextured(session, &text_fragment_shader);
    }

    /// PhantomUI image shader. Sampled RGBA is output, with vertex alpha
    /// multiplying the sampled alpha channel.
    pub fn createImage(session: *session_mod.Session) Error!NativeGraphicsPipeline {
        return createTextured(session, &image_fragment_shader);
    }

    fn createTextured(session: *session_mod.Session, fragment_code: []const u8) Error!NativeGraphicsPipeline {
        return createStages(session, .{
            .code = &probe_vertex_shader,
            .register_count = 6,
            .preload = 0x3800,
        }, .{
            .code = &textured_color_varying_shader,
            .register_count = 8,
            .preload = 0x3800,
            .descriptor_flags = 0,
        }, .{
            .code = fragment_code,
            .register_count = 6,
            .preload = 0x3000,
            .descriptor_flags = (1 << 8) | (1 << 28),
        }, .textured_color);
    }

    pub fn deinit(self: *NativeGraphicsPipeline, session: *session_mod.Session) void {
        session.freeBo(self.bo);
        self.* = undefined;
    }

    fn validStage(stage: Stage) bool {
        return stage.code.len != 0 and stage.code.len <= 1024 and stage.code.len % 8 == 0 and
            stage.register_count != 0 and stage.register_count <= 64;
    }

    fn allocation(register_count: u8) descriptors.RegisterAllocation {
        return if (register_count <= 32) .per_thread_32 else .per_thread_64;
    }
};

fn constantFragmentShader(color: [4]f32) [probe_fragment_shader.len]u8 {
    var code = probe_fragment_shader;
    for (color, 0..) |channel, register| {
        const bits: u32 = @bitCast(channel);
        const destination: u64 = 0xc0 | register;
        const flow: u64 = if (register == 0) 0x68 else if (register == 3) 0x48 else 0;
        const raw = @as(u64, 0xc0) | (@as(u64, bits) << 8) | (destination << 40) |
            (@as(u64, 0x110) << 48) | (flow << 56);
        std.mem.writeInt(u64, code[16 + register * 8 ..][0..8], raw, .little);
    }
    return code;
}

pub fn clearRgba8(
    session: *session_mod.Session,
    image: Image,
    color: [4]u8,
    timeout_ns: u64,
) Error!void {
    if (image.width == 0 or image.height == 0 or image.bo.size < @as(u64, image.row_stride) * image.height)
        return error.InvalidImage;

    const state = try session.allocBo(4096, .{});
    defer session.freeBo(state);
    @memset(state.cpu, 0);

    const fbd = descriptors.FramebufferRgba8.init(image.width, image.height, session.sample_positions.gpu_va, 0);
    const clear = @as(u32, color[0]) | (@as(u32, color[1]) << 8) |
        (@as(u32, color[2]) << 16) | (@as(u32, color[3]) << 24);
    const surface_stride: u32 = @intCast(@as(u64, image.row_stride) * image.height);
    const rt = descriptors.RenderTargetRgba8.init(image.bo.gpu_va, image.row_stride, surface_stride, clear);
    @memcpy(state.cpu[0..128], std.mem.sliceAsBytes(&fbd.words));
    @memcpy(state.cpu[128..192], std.mem.sliceAsBytes(&rt.words));

    var command = try session.createCommandBuffer(4096);
    defer session.destroyCommandBuffer(&command);
    const b = &command.encoder;
    try b.requestResources(.{ .fragment = true });
    try b.move48(0, session.tiler_heap.context_gpu_va);
    try b.heapSet(0);
    try b.move32(0, 0);
    try b.flushCache(.{ .l2_mode = 3, .lsc_mode = 3, .other_mode = 2, .latest_flush_id_register = 0, .signal_slot = 0 });
    try b.wait(1, false);
    try b.move48(csf.fragment_register.framebuffer_descriptor, descriptors.FramebufferRgba8.taggedPointer(state.gpu_va));
    try b.move32(csf.fragment_register.bounding_box_min, 0);
    try b.move32(csf.fragment_register.bounding_box_max, (@as(u32, image.width) - 1) | ((@as(u32, image.height) - 1) << 16));
    try b.setScoreboardEntry(0, 0);
    try b.runFragment(false, 0, false);
    try b.move32(0, 0);
    try b.flushCache(.{ .l2_mode = 3, .lsc_mode = 3, .other_mode = 0, .latest_flush_id_register = 0, .signal_slot = 0 });
    try b.wait(1, false);
    try command.submitAndWait(&session.dev, session.group, @backingInt(session_mod.Queue.fragment), &.{}, timeout_ns);
}

/// Draw the same oversized red triangle used by Prism's device-selection
/// probe. The target is first cleared blue, making center-pixel validation
/// distinguish a working draw from a fragment-only clear.
pub fn drawProbeTriangleRgba8(
    session: *session_mod.Session,
    image: Image,
    timeout_ns: u64,
) Error!void {
    return drawConstantColorTriangleRgba8(session, image, .{ 1, 0, 0, 1 }, timeout_ns);
}

pub fn drawProbeTriangleDiagnosticRgba8(
    session: *session_mod.Session,
    image: Image,
    diagnostics: *DrawDiagnostics,
    timeout_ns: u64,
) Error!void {
    if (image.width == 0 or image.height == 0 or image.bo.size < @as(u64, image.row_stride) * image.height)
        return error.InvalidImage;

    var vertices = try session.allocBo(4096, .{});
    defer session.freeBo(vertices);
    const positions = [_]f32{ -1, -1, 3, -1, -1, 3 };
    @memcpy(vertices.cpu[0..@sizeOf(@TypeOf(positions))], std.mem.asBytes(&positions));

    var pipeline = try NativeGraphicsPipeline.createProbe(session);
    defer pipeline.deinit(session);
    return drawBatchRgba8WithDiagnostics(session, image, &.{.{
        .pipeline = pipeline,
        .vertices = vertices,
        .vertex_count = 3,
    }}, 0xffff_0000, timeout_ns, diagnostics);
}

/// Diagnostic oversized triangle with a caller-selected constant fragment
/// color. This deliberately uses the same retained pipeline and submission
/// route as Prism rather than a fragment-clear shortcut.
pub fn drawConstantColorTriangleRgba8(
    session: *session_mod.Session,
    image: Image,
    color: [4]f32,
    timeout_ns: u64,
) Error!void {
    if (image.width == 0 or image.height == 0 or image.bo.size < @as(u64, image.row_stride) * image.height)
        return error.InvalidImage;

    var vertices = try session.allocBo(4096, .{});
    defer session.freeBo(vertices);
    const positions = [_]f32{ -1, -1, 3, -1, -1, 3 };
    @memcpy(vertices.cpu[0..@sizeOf(@TypeOf(positions))], std.mem.asBytes(&positions));

    var pipeline = try NativeGraphicsPipeline.createConstantColor(session, color);
    defer pipeline.deinit(session);
    return drawTrianglesRgba8(session, pipeline, image, vertices, 3, 0xffff_0000, timeout_ns);
}

pub const FullscreenDiagnostics = struct {
    pre_run_error_status: u64 = 0,
    post_run_error_status: u64 = 0,
    fragment_error_status: u64 = 0,
};

pub const FullscreenProbeVariant = enum {
    baseline,
    hierarchy_level_one,
    no_fragment_shader,
    fragment_nop,
    fragment_no_color,
};

/// Diagnostic path that bypasses vertex shading and asks the tiler to emit a
/// fullscreen primitive from an in-memory Draw descriptor. This isolates the
/// common tiler/fragment path from IDVS attribute and position processing.
pub fn drawFullscreenDiagnosticRgba8(
    session: *session_mod.Session,
    image: Image,
    color: [4]f32,
    diagnostics: *FullscreenDiagnostics,
    timeout_ns: u64,
) Error!void {
    return drawFullscreenDiagnosticVariantRgba8(
        session,
        image,
        color,
        .baseline,
        diagnostics,
        timeout_ns,
    );
}

pub fn drawFullscreenDiagnosticVariantRgba8(
    session: *session_mod.Session,
    image: Image,
    color: [4]f32,
    variant: FullscreenProbeVariant,
    diagnostics: *FullscreenDiagnostics,
    timeout_ns: u64,
) Error!void {
    if (image.width == 0 or image.height == 0 or
        image.bo.size < @as(u64, image.row_stride) * image.height)
        return error.InvalidImage;

    const nop_shader = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xc0, 0x00, 0x78 };
    var pipeline = if (variant == .fragment_nop)
        try NativeGraphicsPipeline.create(session, .{
            .code = &probe_vertex_shader,
            .register_count = 6,
            .preload = 0x3800,
        }, .{
            .code = &nop_shader,
            .register_count = 1,
            .preload = 0,
        })
    else
        try NativeGraphicsPipeline.createConstantColor(session, color);
    defer pipeline.deinit(session);
    const state = try session.allocBo(4096, .{});
    defer session.freeBo(state);
    @memset(state.cpu, 0);

    const resource_offset: usize = 0;
    const fragment_fau_offset: usize = 64;
    const blend_offset: usize = 128;
    const depth_stencil_offset: usize = 192;
    const tiler_offset: usize = 256;
    const fbd_offset: usize = 384;
    const rt_offset: usize = 512;
    const draw_offset: usize = 576;
    const pre_error_offset: usize = 1152;
    const post_error_offset: usize = 1160;
    const fragment_error_offset: usize = 1168;

    const resource = descriptors.Resource.init(0, 0, false);
    copyWords(state.cpu, resource_offset, &resource.words);
    const blend = blendDescriptor(.replace);
    copyWords(state.cpu, blend_offset, &blend);
    const fragment_blend = blendFauDescriptor(.replace);
    const fragment_fau = [_]u32{ 0, 0, 0, 0, fragment_blend[0], fragment_blend[1], 0, 0 };
    copyWords(state.cpu, fragment_fau_offset, &fragment_fau);
    var depth_stencil: [16]u32 = @splat(0);
    depth_stencil[0] = 7;
    depth_stencil[4] = 0xe4c0_0000;
    copyWords(state.cpu, depth_stencil_offset, &depth_stencil);

    var tiler = descriptors.TilerContext.init(
        image.width,
        image.height,
        session.tiler_resources.gpu_va,
        session.tiler_resources.gpu_va + 4096,
    );
    if (variant == .hierarchy_level_one)
        tiler.words[2] = (1 << 1) | (1 << 18);
    copyWords(state.cpu, tiler_offset, &tiler.words);
    const fbd = descriptors.FramebufferRgba8.init(
        image.width,
        image.height,
        session.sample_positions.gpu_va,
        state.gpu_va + tiler_offset,
    );
    copyWords(state.cpu, fbd_offset, &fbd.words);
    const surface_stride: u32 = @intCast(@as(u64, image.row_stride) * image.height);
    const rt = descriptors.RenderTargetRgba8.init(image.bo.gpu_va, image.row_stride, surface_stride, 0);
    copyWords(state.cpu, rt_offset, &rt.words);

    // v10 DRAW embeds a fragment Shader Environment at word 16.
    var draw: [128]u32 = @splat(0);
    draw[0] = if (variant == .no_fragment_shader) 0x0081_0183 else blendShaderFlags(.replace);
    draw[1] = if (variant == .no_fragment_shader or variant == .fragment_no_color) 0x0000_ffff else 0x0001_ffff;
    draw[5] = if (variant == .fragment_no_color) 0 else 0x0000_1000;
    draw[7] = 0x3f80_0000;
    writeU64Words(&draw, 10, state.gpu_va + depth_stencil_offset);
    if (variant != .no_fragment_shader) {
        writeU64Words(&draw, 12, state.gpu_va + blend_offset | 1);
        draw[17] = 3;
        writeU64Words(&draw, 24, state.gpu_va + resource_offset + 4);
        writeU64Words(&draw, 26, pipeline.fragment_spd_va);
        writeU64Words(&draw, 28, pipeline.tsd_va);
        writeU64Words(&draw, 30, state.gpu_va + fragment_fau_offset);
    }
    copyWords(state.cpu, draw_offset, &draw);

    var tiling_command = try session.createCommandBuffer(4096);
    defer session.destroyCommandBuffer(&tiling_command);
    const vt = &tiling_command.encoder;
    try vt.requestResources(.{ .tiler = true });
    try vt.move48(62, session.tiler_heap.context_gpu_va);
    try vt.heapSet(62);
    try vt.move32(62, 0);
    try vt.flushCache(.{ .l2_mode = 3, .lsc_mode = 3, .other_mode = 2, .latest_flush_id_register = 62, .signal_slot = 0 });
    try vt.wait(1, false);
    try vt.heapOperation(0, 0, 0);
    try vt.move48(40, state.gpu_va + tiler_offset);
    try vt.move32(42, 0);
    try vt.move32(43, (@as(u32, image.width) - 1) | ((@as(u32, image.height) - 1) << 16));
    try vt.move32(56, 0);
    try vt.move48(0, state.gpu_va + draw_offset);
    try vt.move48(62, state.gpu_va + pre_error_offset);
    try vt.storeState(62, 0, .error_status, 0, 0);
    try vt.wait(1, false);
    try vt.setScoreboardEntry(3, 0);
    try vt.runFullscreen(0, 0, false);
    try vt.wait(1 << 3, false);
    try vt.move48(62, state.gpu_va + post_error_offset);
    try vt.storeState(62, 0, .error_status, 0, 0);
    try vt.wait(1, false);
    try vt.finishTiling(false);
    try vt.wait(1 << 3, false);
    try vt.heapOperation(1, 0, 0);
    try vt.move32(62, 0);
    try vt.flushCache(.{ .l2_mode = 3, .lsc_mode = 3, .other_mode = 0, .latest_flush_id_register = 62, .signal_slot = 0 });
    try vt.wait(1, false);
    try tiling_command.submitAndWait(&session.dev, session.group, @backingInt(session_mod.Queue.vertex_tiler), &.{}, timeout_ns);

    var fragment_command = try session.createCommandBuffer(4096);
    defer session.destroyCommandBuffer(&fragment_command);
    const frag = &fragment_command.encoder;
    try frag.requestResources(.{ .fragment = true });
    try frag.move48(0, session.tiler_heap.context_gpu_va);
    try frag.heapSet(0);
    try frag.move32(0, 0);
    try frag.flushCache(.{ .l2_mode = 3, .lsc_mode = 3, .other_mode = 2, .latest_flush_id_register = 0, .signal_slot = 0 });
    try frag.wait(1, false);
    try frag.move48(40, descriptors.FramebufferRgba8.taggedPointer(state.gpu_va + fbd_offset));
    try frag.move32(42, 0);
    try frag.move32(43, (@as(u32, image.width) - 1) | ((@as(u32, image.height) - 1) << 16));
    try frag.setScoreboardEntry(3, 0);
    try frag.runFragment(false, 0, false);
    // RUN_FRAGMENT is not fully retired until FINISH_FRAGMENT consumes its
    // endpoint. Read the completed heap range written into TILER_CONTEXT and
    // advance from render-iteration scoreboard 3 to 4, matching PanVK.
    try frag.move48(4, state.gpu_va + tiler_offset);
    try frag.loadMultiple(10, 4, 0x000f, 40);
    try frag.wait(1, false);
    try frag.finishFragment(true, 10, 12, 1 << 3, 4);
    try frag.wait(1 << 4, false);
    try frag.move48(0, state.gpu_va + fragment_error_offset);
    try frag.storeState(0, 0, .error_status, 0, 0);
    try frag.wait(1, false);
    try frag.move32(0, 0);
    try frag.flushCache(.{ .l2_mode = 3, .lsc_mode = 3, .other_mode = 0, .latest_flush_id_register = 0, .signal_slot = 0 });
    try frag.wait(1, false);
    try fragment_command.submitAndWait(&session.dev, session.group, @backingInt(session_mod.Queue.fragment), &.{}, timeout_ns);

    diagnostics.pre_run_error_status = std.mem.readInt(u64, state.cpu[pre_error_offset..][0..8], .little);
    diagnostics.post_run_error_status = std.mem.readInt(u64, state.cpu[post_error_offset..][0..8], .little);
    diagnostics.fragment_error_status = std.mem.readInt(u64, state.cpu[fragment_error_offset..][0..8], .little);
}

/// Diagnostic oversized triangle whose color is carried through the full
/// secondary-vertex varying path. A uniform per-vertex value makes readback
/// exact while still exercising attribute 1, varying storage, interpolation,
/// and the fragment varying load.
pub fn drawVertexColorTriangleRgba8(
    session: *session_mod.Session,
    image: Image,
    color: [3]f32,
    timeout_ns: u64,
) Error!void {
    if (image.width == 0 or image.height == 0 or image.bo.size < @as(u64, image.row_stride) * image.height)
        return error.InvalidImage;

    var vertices = try session.allocBo(4096, .{});
    defer session.freeBo(vertices);
    const data = [_]f32{
        -1, -1, color[0], color[1], color[2],
        3,  -1, color[0], color[1], color[2],
        -1, 3,  color[0], color[1], color[2],
    };
    @memcpy(vertices.cpu[0..@sizeOf(@TypeOf(data))], std.mem.asBytes(&data));

    var pipeline = try NativeGraphicsPipeline.createVertexColor(session);
    defer pipeline.deinit(session);
    return drawTrianglesRgba8(session, pipeline, image, vertices, 3, 0xffff_0000, timeout_ns);
}

/// Diagnostic two-draw render pass. The left and right halves use different
/// retained pipelines and vertex buffers but share one tiler/fragment pass.
pub fn drawBatchedHalvesRgba8(
    session: *session_mod.Session,
    image: Image,
    timeout_ns: u64,
) Error!void {
    var left_vertices = try session.allocBo(4096, .{});
    defer session.freeBo(left_vertices);
    var right_vertices = try session.allocBo(4096, .{});
    defer session.freeBo(right_vertices);
    const left = [_]f32{ -1, -1, 0, -1, 0, 1, -1, -1, 0, 1, -1, 1 };
    const right = [_]f32{ 0, -1, 1, -1, 1, 1, 0, -1, 1, 1, 0, 1 };
    @memcpy(left_vertices.cpu[0..@sizeOf(@TypeOf(left))], std.mem.asBytes(&left));
    @memcpy(right_vertices.cpu[0..@sizeOf(@TypeOf(right))], std.mem.asBytes(&right));

    var red = try NativeGraphicsPipeline.createConstantColor(session, .{ 1, 0, 0, 1 });
    defer red.deinit(session);
    var green = try NativeGraphicsPipeline.createConstantColor(session, .{ 0, 1, 0, 1 });
    defer green.deinit(session);
    return drawBatchRgba8(session, image, &.{
        .{ .pipeline = red, .vertices = left_vertices, .vertex_count = 6 },
        .{ .pipeline = green, .vertices = right_vertices, .vertex_count = 6 },
    }, 0xffff_0000, timeout_ns);
}

/// Diagnostic fixed-function alpha blend: 50%-alpha red over opaque blue.
pub fn drawAlphaBlendTriangleRgba8(
    session: *session_mod.Session,
    image: Image,
    timeout_ns: u64,
) Error!void {
    var vertices = try session.allocBo(4096, .{});
    defer session.freeBo(vertices);
    const positions = [_]f32{ -1, -1, 3, -1, -1, 3 };
    @memcpy(vertices.cpu[0..@sizeOf(@TypeOf(positions))], std.mem.asBytes(&positions));
    var pipeline = try NativeGraphicsPipeline.createConstantColor(session, .{ 1, 0, 0, 0.5 });
    defer pipeline.deinit(session);
    pipeline.blend = .src_alpha;
    return drawTrianglesRgba8(session, pipeline, image, vertices, 3, 0xffff_0000, timeout_ns);
}

/// Diagnostic per-draw scissor: green only in the centered half-size box over
/// a red render-pass clear.
pub fn drawScissorProbeRgba8(
    session: *session_mod.Session,
    image: Image,
    timeout_ns: u64,
) Error!void {
    var vertices = try session.allocBo(4096, .{});
    defer session.freeBo(vertices);
    const positions = [_]f32{ -1, -1, 3, -1, -1, 3 };
    @memcpy(vertices.cpu[0..@sizeOf(@TypeOf(positions))], std.mem.asBytes(&positions));
    var pipeline = try NativeGraphicsPipeline.createConstantColor(session, .{ 0, 1, 0, 1 });
    defer pipeline.deinit(session);
    return drawBatchRgba8(session, image, &.{.{
        .pipeline = pipeline,
        .vertices = vertices,
        .vertex_count = 3,
        .scissor = .{
            .x = image.width / 4,
            .y = image.height / 4,
            .width = image.width / 2,
            .height = image.height / 2,
        },
    }}, 0xff00_00ff, timeout_ns);
}

/// PhantomUI's actual rounded-rectangle shaders and 48-byte vertex ABI. The
/// probe draws a translucent red 48x48 rounded box over opaque blue.
pub fn drawRoundedRectangleProbeRgba8(
    session: *session_mod.Session,
    image: Image,
    timeout_ns: u64,
) Error!void {
    return drawRoundedRectangleProbeWithBlendRgba8(session, image, .src_alpha, timeout_ns);
}

fn drawRoundedRectangleProbeWithBlendRgba8(
    session: *session_mod.Session,
    image: Image,
    blend: NativeGraphicsPipeline.BlendMode,
    timeout_ns: u64,
) Error!void {
    var vertices = try session.allocBo(4096, .{});
    defer session.freeBo(vertices);
    const data = [_]f32{
        -0.75, -0.75, -24, -24, 24, 24, 8, 0, 1, 0, 0, 0.5,
        0.75,  -0.75, 24,  -24, 24, 24, 8, 0, 1, 0, 0, 0.5,
        0.75,  0.75,  24,  24,  24, 24, 8, 0, 1, 0, 0, 0.5,
        -0.75, -0.75, -24, -24, 24, 24, 8, 0, 1, 0, 0, 0.5,
        0.75,  0.75,  24,  24,  24, 24, 8, 0, 1, 0, 0, 0.5,
        -0.75, 0.75,  -24, 24,  24, 24, 8, 0, 1, 0, 0, 0.5,
    };
    @memcpy(vertices.cpu[0..@sizeOf(@TypeOf(data))], std.mem.asBytes(&data));
    var pipeline = try NativeGraphicsPipeline.createRoundedRectangle(session);
    defer pipeline.deinit(session);
    pipeline.blend = blend;
    return drawTrianglesRgba8(session, pipeline, image, vertices, 6, 0xffff_0000, timeout_ns);
}

/// One hardware round-trip covering both texture consumers required by
/// PhantomUI: glyph-alpha masking on the left and sampled RGBA images on the
/// right. A constant 2x2 texel pattern makes linear filtering deterministic.
pub fn drawTextAndImageProbeRgba8(
    session: *session_mod.Session,
    image: Image,
    timeout_ns: u64,
) Error!void {
    var texture = try Image.create(session, 2, 2);
    defer texture.deinit(session);
    for (0..texture.height) |y| {
        for (0..texture.width) |x| {
            const offset = y * texture.row_stride + x * 4;
            texture.bo.cpu[offset..][0..4].* = .{ 0x20, 0xc0, 0x40, 0x80 };
        }
    }

    var text_vertices = try session.allocBo(4096, .{});
    defer session.freeBo(text_vertices);
    var image_vertices = try session.allocBo(4096, .{});
    defer session.freeBo(image_vertices);
    const left = [_]f32{
        -1, -1, 0, 0, 1, 0, 0, 1, 0,  -1, 1, 0, 1, 0, 0, 1,
        0,  1,  1, 1, 1, 0, 0, 1, -1, -1, 0, 0, 1, 0, 0, 1,
        0,  1,  1, 1, 1, 0, 0, 1, -1, 1,  0, 1, 1, 0, 0, 1,
    };
    const right = [_]f32{
        0, -1, 0, 0, 1, 1, 1, 1, 1, -1, 1, 0, 1, 1, 1, 1,
        1, 1,  1, 1, 1, 1, 1, 1, 0, -1, 0, 0, 1, 1, 1, 1,
        1, 1,  1, 1, 1, 1, 1, 1, 0, 1,  0, 1, 1, 1, 1, 1,
    };
    @memcpy(text_vertices.cpu[0..@sizeOf(@TypeOf(left))], std.mem.asBytes(&left));
    @memcpy(image_vertices.cpu[0..@sizeOf(@TypeOf(right))], std.mem.asBytes(&right));

    var text_pipeline = try NativeGraphicsPipeline.createText(session);
    defer text_pipeline.deinit(session);
    text_pipeline.blend = .src_alpha;
    var image_pipeline = try NativeGraphicsPipeline.createImage(session);
    defer image_pipeline.deinit(session);
    image_pipeline.blend = .src_alpha;
    return drawBatchRgba8(session, image, &.{
        .{ .pipeline = text_pipeline, .vertices = text_vertices, .vertex_count = 6, .texture = texture },
        .{ .pipeline = image_pipeline, .vertices = image_vertices, .vertex_count = 6, .texture = texture },
    }, 0xffff_0000, timeout_ns);
}

/// Submit a non-indexed triangle-list draw using the native v10 pipeline ABI.
/// Vertex input is location 0 as tightly interleaved `vec2<f32>` values.
pub const DrawRgba8 = struct {
    pipeline: NativeGraphicsPipeline,
    vertices: device.Bo,
    vertex_count: u32,
    texture: ?Image = null,
    texture_swizzle: u12 = 0x688,
    texture_min_filter: descriptors.SamplerLinearClamp.Filter = .linear,
    texture_mag_filter: descriptors.SamplerLinearClamp.Filter = .linear,
    texture_address_u: descriptors.SamplerLinearClamp.AddressMode = .clamp_to_edge,
    texture_address_v: descriptors.SamplerLinearClamp.AddressMode = .clamp_to_edge,
    scissor: ?Scissor = null,
};

pub const Scissor = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

/// Readback captured around an IDVS draw. These fields deliberately sample
/// kernel/GPU-owned tiler memory so mali-info can distinguish an idle IDVS
/// launch from geometry generation and a later fragment-pass failure.
pub const DrawDiagnostics = struct {
    tiler_context_before: [32]u32 = @splat(0),
    tiler_context_after_tiling: [32]u32 = @splat(0),
    tiler_context_after_fragment: [32]u32 = @splat(0),
    heap_descriptor_before: [8]u32 = @splat(0),
    heap_descriptor_after_tiling: [8]u32 = @splat(0),
    heap_descriptor_after_fragment: [8]u32 = @splat(0),
    geometry_nonzero_bytes_after_tiling: u32 = 0,
    geometry_first_nonzero_offset: ?u32 = null,
    idvs_registers_after_run: [61]u32 = @splat(0),
    pre_idvs_error_status: u64 = 0,
    tiling_error_status: u64 = 0,
    fragment_error_status: u64 = 0,
};

pub fn drawTrianglesRgba8(
    session: *session_mod.Session,
    pipeline: NativeGraphicsPipeline,
    image: Image,
    vertices: device.Bo,
    vertex_count: u32,
    clear_rgba8: u32,
    timeout_ns: u64,
) Error!void {
    return drawBatchRgba8(session, image, &.{.{
        .pipeline = pipeline,
        .vertices = vertices,
        .vertex_count = vertex_count,
    }}, clear_rgba8, timeout_ns);
}

/// Submit several non-indexed triangle-list draws into one tiler pass followed
/// by one fragment pass. This preserves draw order and the shared tile buffer,
/// which is the render-pass shape Prism needs for batched UI geometry.
pub fn drawBatchRgba8(
    session: *session_mod.Session,
    image: Image,
    draws: []const DrawRgba8,
    clear_rgba8: u32,
    timeout_ns: u64,
) Error!void {
    return drawBatchRgba8Internal(session, image, draws, clear_rgba8, timeout_ns, null);
}

pub fn drawBatchRgba8WithDiagnostics(
    session: *session_mod.Session,
    image: Image,
    draws: []const DrawRgba8,
    clear_rgba8: u32,
    timeout_ns: u64,
    diagnostics: *DrawDiagnostics,
) Error!void {
    diagnostics.* = .{};
    return drawBatchRgba8Internal(session, image, draws, clear_rgba8, timeout_ns, diagnostics);
}

fn drawBatchRgba8Internal(
    session: *session_mod.Session,
    image: Image,
    draws: []const DrawRgba8,
    clear_rgba8: u32,
    timeout_ns: u64,
    diagnostics: ?*DrawDiagnostics,
) Error!void {
    if (image.width == 0 or image.height == 0 or draws.len == 0 or
        image.bo.size < @as(u64, image.row_stride) * image.height)
        return error.InvalidImage;
    for (draws) |draw| {
        if (draw.vertex_count == 0 or draw.vertex_count % 3 != 0 or
            draw.vertices.size < @as(u64, draw.vertex_count) * draw.pipeline.vertex_layout.stride())
            return error.InvalidImage;
        if (draw.pipeline.vertex_layout == .textured_color and draw.texture == null)
            return error.InvalidImage;
        if (draw.texture) |texture| {
            if (texture.width == 0 or texture.height == 0 or
                texture.bo.size < @as(u64, texture.row_stride) * texture.height)
                return error.InvalidImage;
        }
        if (draw.scissor) |clip| {
            if (clip.width == 0 or clip.height == 0 or clip.x >= image.width or clip.y >= image.height or
                @as(u32, clip.x) + clip.width > image.width or @as(u32, clip.y) + clip.height > image.height)
                return error.InvalidImage;
        }
    }

    const draw_count: u64 = std.math.cast(u64, draws.len) orelse return error.InvalidImage;
    const state_size = std.math.mul(u64, draw_count, 4096) catch return error.InvalidImage;
    const state = try session.allocBo(state_size, .{});
    defer session.freeBo(state);
    @memset(state.cpu, 0);

    // Match PanVK's v10 vertex driver set exactly: 16 attribute descriptors,
    // one dummy sampler, then vertex-buffer descriptors. IDVS validates this
    // fixed ABI even when a shader consumes only location zero.
    const vertex_buffer_descriptor_index: u32 = 17;
    const vertex_buffer_offset: usize = vertex_buffer_descriptor_index * 32;
    const vertex_driver_set_size: u64 = 18 * 32;
    // Resource tables are 64-byte aligned arrays of four 16-byte entries.
    // Fragment table entry 1 points at the user descriptor set containing a
    // Texture followed by its Sampler; shaders address them as handles
    // 0x01000000 and 0x01000001.
    const vertex_resource_offset: usize = 576;
    const fragment_resource_offset: usize = 640;
    const fragment_descriptors_offset: usize = 704;
    const texture_plane_offset: usize = 768;
    // The largest secondary shader uses u3..u8 for compact varying-store
    // offsets. Keep the 72-byte FAU block clear of the texture plane and the
    // following blend descriptor.
    const vertex_fau_offset = 832;
    const blend_offset = 960;
    const fragment_fau_offset = 976;
    const depth_stencil_offset = 1024;
    const tiler_offset = 1088;
    const fbd_offset = 1216;
    const rt_offset = 1344;
    const diagnostic_registers_offset = 1536;
    const diagnostic_tiling_error_offset = 1792;
    const diagnostic_fragment_error_offset = 1800;
    const diagnostic_pre_idvs_error_offset = 1808;

    const half_width: u32 = @bitCast(@as(f32, @floatFromInt(image.width)) * 0.5);
    const half_height: u32 = @bitCast(@as(f32, @floatFromInt(image.height)) * 0.5);
    // u0..u2 are viewport scale/bias and Z. u3..u8 are the offsets selected
    // by Mesa's secondary vertex shaders when writing compact generic
    // varyings. vec2+vec4 and vec2+vec4+vec4 layouts align each vec4 to 16
    // bytes, hence the gap between 4 and 16. u4.w0 remains 12 for the primary
    // position shader's W store.
    const vertex_fau = [_]u32{
        half_width,  half_height,
        0x3f80_0000, half_width,
        half_height, 0,
        4,           8,
        12,          16,
        20,          24,
        28,          32,
        36,          40,
        44,          0,
    };
    var depth_stencil: [16]u32 = @splat(0);
    depth_stencil[0] = 7;
    depth_stencil[4] = 0xe4c0_0000;

    for (draws, 0..) |draw, draw_index| {
        const state_offset = draw_index * 4096;
        const state_cpu = state.cpu[state_offset..][0..4096];
        const state_va = state.gpu_va + state_offset;
        const stride = draw.pipeline.vertex_layout.stride();
        const position = descriptors.VertexAttributeF32.init(2, 0, vertex_buffer_descriptor_index, stride);
        copyWords(state_cpu, 0, &position.words);
        if (draw.pipeline.vertex_layout == .position_color) {
            const color = descriptors.VertexAttributeF32.init(3, 8, vertex_buffer_descriptor_index, stride);
            copyWords(state_cpu, 32, &color.words);
        } else if (draw.pipeline.vertex_layout == .textured_color) {
            const uv = descriptors.VertexAttributeF32.init(2, 8, vertex_buffer_descriptor_index, stride);
            const color = descriptors.VertexAttributeF32.init(4, 16, vertex_buffer_descriptor_index, stride);
            copyWords(state_cpu, 32, &uv.words);
            copyWords(state_cpu, 64, &color.words);
        } else if (draw.pipeline.vertex_layout == .rrect) {
            const local = descriptors.VertexAttributeF32.init(2, 8, vertex_buffer_descriptor_index, stride);
            const params = descriptors.VertexAttributeF32.init(4, 16, vertex_buffer_descriptor_index, stride);
            const color = descriptors.VertexAttributeF32.init(4, 32, vertex_buffer_descriptor_index, stride);
            copyWords(state_cpu, 32, &local.words);
            copyWords(state_cpu, 64, &params.words);
            copyWords(state_cpu, 96, &color.words);
        }
        const dummy_sampler = descriptors.SamplerLinearClamp.init();
        copyWords(state_cpu, 16 * 32, &dummy_sampler.words);
        const vertex_buffer = descriptors.Buffer.init(draw.vertices.gpu_va, draw.vertex_count * stride);
        copyWords(state_cpu, vertex_buffer_offset, &vertex_buffer.words);
        const vertex_resource = descriptors.Resource.init(state_va, vertex_driver_set_size, true);
        copyWords(state_cpu, vertex_resource_offset, &vertex_resource.words);
        const fragment_resource = descriptors.Resource.init(state_va + 160, 32, true);
        copyWords(state_cpu, fragment_resource_offset, &fragment_resource.words);
        if (draw.texture) |texture| {
            const descriptor_set_resource = descriptors.Resource.init(
                state_va + fragment_descriptors_offset,
                64,
                true,
            );
            copyWords(state_cpu, fragment_resource_offset + 16, &descriptor_set_resource.words);
            const texture_header = descriptors.TextureRgba8.initSwizzle(
                texture.width,
                texture.height,
                state_va + texture_plane_offset,
                draw.texture_swizzle,
            );
            const sampler = descriptors.SamplerLinearClamp.initState(
                draw.texture_min_filter,
                draw.texture_mag_filter,
                draw.texture_address_u,
                draw.texture_address_v,
            );
            const texture_size: u32 = @intCast(@as(u64, texture.row_stride) * texture.height);
            const plane = descriptors.GenericPlaneRgba8.init(
                texture.bo.gpu_va,
                texture_size,
                texture.row_stride,
                texture.width,
                texture.height,
            );
            copyWords(state_cpu, fragment_descriptors_offset, &texture_header.words);
            copyWords(state_cpu, fragment_descriptors_offset + 32, &sampler.words);
            copyWords(state_cpu, texture_plane_offset, &plane.words);
        }
        copyWords(state_cpu, vertex_fau_offset, &vertex_fau);
        // Fixed-function RGBA8 blend descriptors captured from Mesa 26.2
        // PanVK. The alpha mode is PhantomUI's SRC_ALPHA / ONE_MINUS_SRC_ALPHA
        // RGB and ONE / ONE_MINUS_SRC_ALPHA alpha equation.
        const blend = blendDescriptor(draw.pipeline.blend);
        const fragment_blend = blendFauDescriptor(draw.pipeline.blend);
        // PanVK's lowered texture shaders load a Valhall-packed combined
        // texture/sampler handle from u3.w0. Resource table 1 contains the
        // Texture at descriptor 0 and Sampler at descriptor 1. TEX_SINGLE's
        // compact encoding is:
        //   tex_table[31:27] | tex_index[25:16] |
        //   sampler_table[15:11] | sampler_index[9:0].
        const texture_handle: u32 = if (draw.texture != null) 0x0800_0801 else 0;
        const fragment_fau = [_]u32{
            0,                 0,                 0,              0,
            fragment_blend[0], fragment_blend[1], texture_handle, 0,
        };
        copyWords(state_cpu, blend_offset, &blend);
        copyWords(state_cpu, fragment_fau_offset, &fragment_fau);
        copyWords(state_cpu, depth_stencil_offset, &depth_stencil);
    }

    const tiler = descriptors.TilerContext.init(
        image.width,
        image.height,
        session.tiler_resources.gpu_va,
        session.tiler_resources.gpu_va + 4096,
    );
    copyWords(state.cpu, tiler_offset, &tiler.words);
    const fbd = descriptors.FramebufferRgba8.init(
        image.width,
        image.height,
        session.sample_positions.gpu_va,
        state.gpu_va + tiler_offset,
    );
    copyWords(state.cpu, fbd_offset, &fbd.words);
    const surface_stride: u32 = @intCast(@as(u64, image.row_stride) * image.height);
    const rt = descriptors.RenderTargetRgba8.init(image.bo.gpu_va, image.row_stride, surface_stride, clear_rgba8);
    copyWords(state.cpu, rt_offset, &rt.words);

    if (diagnostics) |diag| {
        diag.tiler_context_before = readWords(32, state.cpu[tiler_offset..]);
        diag.heap_descriptor_before = readWords(8, session.tiler_resources.cpu);
    }

    const command_extra = std.math.mul(u64, draw_count, 512) catch return error.InvalidImage;
    const command_size = std.math.add(u64, 4096, command_extra) catch return error.InvalidImage;
    var tiling_command = try session.createCommandBuffer(command_size);
    defer session.destroyCommandBuffer(&tiling_command);
    const vt = &tiling_command.encoder;
    try vt.requestResources(.{ .tiler = true, .idvs = true });
    try vt.move48(62, session.tiler_heap.context_gpu_va);
    try vt.heapSet(62);
    try vt.move32(62, 0);
    try vt.flushCache(.{ .l2_mode = 3, .lsc_mode = 3, .other_mode = 2, .latest_flush_id_register = 62, .signal_slot = 0 });
    try vt.wait(1, false);
    try vt.heapOperation(0, 0, 0);
    for (draws, 0..) |draw, draw_index| {
        const state_va = state.gpu_va + @as(u64, @intCast(draw_index)) * 4096;
        const pipeline = draw.pipeline;
        try vt.move48(0, state_va + vertex_resource_offset + 4);
        try vt.move48(4, state_va + fragment_resource_offset + 4);
        try vt.move64(8, state_va + vertex_fau_offset | (@as(u64, 9) << 56));
        try vt.move64(12, state_va + fragment_fau_offset | (@as(u64, 4) << 56));
        try vt.move48(16, pipeline.vertex_spd_va);
        try vt.move48(18, pipeline.varying_spd_va);
        try vt.move48(20, pipeline.fragment_spd_va);
        try vt.move48(24, pipeline.tsd_va);
        try vt.move48(40, state.gpu_va + tiler_offset);
        const bbox_min: u32, const bbox_max: u32 = if (draw.scissor) |clip| .{
            @as(u32, clip.x) | (@as(u32, clip.y) << 16),
            (@as(u32, clip.x) + clip.width - 1) | ((@as(u32, clip.y) + clip.height - 1) << 16),
        } else .{
            0,
            (@as(u32, image.width) - 1) | ((@as(u32, image.height) - 1) << 16),
        };
        try vt.move32(42, bbox_min);
        try vt.move32(43, bbox_max);
        try vt.move32(44, 0);
        try vt.move32(45, 0x3f80_0000);
        try vt.move32(48, pipeline.vertex_layout.varyingSize());
        try vt.move48(50, state_va + blend_offset | 1);
        try vt.move48(52, state_va + depth_stencil_offset);
        try vt.move48(54, 0);
        try vt.move32(56, if (pipeline.varying_spd_va == 0) 0x0043_0008 else 0x0047_0008);
        try vt.move32(57, blendShaderFlags(pipeline.blend));
        try vt.move32(58, 0x0001_ffff);
        try vt.move32(38, 0x0000_1000);
        try vt.move32(32, 0);
        try vt.move32(33, draw.vertex_count);
        try vt.move32(34, 1);
        try vt.move32(35, 0);
        try vt.move32(36, 0);
        try vt.move32(37, 0);
        if (diagnostics != null and draw_index == 0) {
            try vt.move48(62, state.gpu_va + diagnostic_pre_idvs_error_offset);
            try vt.storeState(62, 0, .error_status, 0, 0);
            try vt.wait(1, false);
        }
        // Match Mesa's v10 CSF convention: slots 0-2 are reserved for
        // load/store and deferred work, while render iterations start at 3.
        try vt.setScoreboardEntry(3, 0);
        try vt.runIdvs(.{ .malloc_enable = true, .fragment_srt_select = true });
        try vt.wait(1 << 3, false);
    }
    if (diagnostics != null) {
        // Mirror Mesa's CS tracing layout: capture every IDVS staging
        // register after RUN_IDVS, then snapshot the queue-local error state.
        try vt.move48(62, state.gpu_va + diagnostic_registers_offset);
        try vt.storeMultiple(0, 62, 0xffff, 0);
        try vt.storeMultiple(16, 62, 0xffff, 64);
        try vt.storeMultiple(32, 62, 0xffff, 128);
        try vt.storeMultiple(48, 62, 0x1fff, 192);
        try vt.wait(1, false);
        try vt.move48(62, state.gpu_va + diagnostic_tiling_error_offset);
        try vt.storeState(62, 0, .error_status, 0, 0);
        try vt.wait(1, false);
    }
    try vt.finishTiling(false);
    try vt.wait(1 << 3, false);
    try vt.heapOperation(1, 0, 0);
    try vt.move32(62, 0);
    try vt.flushCache(.{ .l2_mode = 3, .lsc_mode = 3, .other_mode = 0, .latest_flush_id_register = 62, .signal_slot = 0 });
    try vt.wait(1, false);
    try tiling_command.submitAndWait(&session.dev, session.group, @backingInt(session_mod.Queue.vertex_tiler), &.{}, timeout_ns);

    if (diagnostics) |diag| {
        diag.tiler_context_after_tiling = readWords(32, state.cpu[tiler_offset..]);
        diag.heap_descriptor_after_tiling = readWords(8, session.tiler_resources.cpu);
        const geometry = session.tiler_resources.cpu[4096..];
        for (geometry, 0..) |byte, offset| {
            if (byte == 0) continue;
            diag.geometry_nonzero_bytes_after_tiling += 1;
            if (diag.geometry_first_nonzero_offset == null)
                diag.geometry_first_nonzero_offset = @intCast(offset);
        }
        diag.idvs_registers_after_run = readWords(61, state.cpu[diagnostic_registers_offset..]);
        diag.pre_idvs_error_status = std.mem.readInt(
            u64,
            state.cpu[diagnostic_pre_idvs_error_offset..][0..8],
            .little,
        );
        diag.tiling_error_status = std.mem.readInt(
            u64,
            state.cpu[diagnostic_tiling_error_offset..][0..8],
            .little,
        );
    }

    var fragment_command = try session.createCommandBuffer(4096);
    defer session.destroyCommandBuffer(&fragment_command);
    const frag = &fragment_command.encoder;
    try frag.requestResources(.{ .fragment = true });
    try frag.move48(0, session.tiler_heap.context_gpu_va);
    try frag.heapSet(0);
    try frag.move32(0, 0);
    try frag.flushCache(.{ .l2_mode = 3, .lsc_mode = 3, .other_mode = 2, .latest_flush_id_register = 0, .signal_slot = 0 });
    try frag.wait(1, false);
    try frag.move48(csf.fragment_register.framebuffer_descriptor, descriptors.FramebufferRgba8.taggedPointer(state.gpu_va + fbd_offset));
    try frag.move32(csf.fragment_register.bounding_box_min, 0);
    try frag.move32(csf.fragment_register.bounding_box_max, (@as(u32, image.width) - 1) | ((@as(u32, image.height) - 1) << 16));
    try frag.setScoreboardEntry(3, 0);
    try frag.runFragment(false, 0, false);
    try frag.move48(4, state.gpu_va + tiler_offset);
    try frag.loadMultiple(10, 4, 0x000f, 40);
    try frag.wait(1, false);
    try frag.finishFragment(true, 10, 12, 1 << 3, 4);
    try frag.wait(1 << 4, false);
    if (diagnostics != null) {
        try frag.move48(0, state.gpu_va + diagnostic_fragment_error_offset);
        try frag.storeState(0, 0, .error_status, 0, 0);
        try frag.wait(1, false);
    }
    try frag.move32(0, 0);
    try frag.flushCache(.{ .l2_mode = 3, .lsc_mode = 3, .other_mode = 0, .latest_flush_id_register = 0, .signal_slot = 0 });
    try frag.wait(1, false);
    try fragment_command.submitAndWait(&session.dev, session.group, @backingInt(session_mod.Queue.fragment), &.{}, timeout_ns);
    if (diagnostics) |diag| {
        diag.tiler_context_after_fragment = readWords(32, state.cpu[tiler_offset..]);
        diag.heap_descriptor_after_fragment = readWords(8, session.tiler_resources.cpu);
        diag.fragment_error_status = std.mem.readInt(
            u64,
            state.cpu[diagnostic_fragment_error_offset..][0..8],
            .little,
        );
    }
}

fn readWords(comptime count: usize, bytes: []const u8) [count]u32 {
    var result: [count]u32 = undefined;
    for (&result, 0..) |*word, i|
        word.* = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
    return result;
}

fn blendDescriptor(mode: NativeGraphicsPipeline.BlendMode) [4]u32 {
    return switch (mode) {
        .replace => .{ 0x0000_0a00, 0xf012_2122, 0x0000_0019, 0x000e_d000 },
        .src_alpha => .{ 0x0000_0a01, 0xf0d3_2503, 0x0000_001a, 0x000e_d000 },
    };
}

/// PanVK lowers `load_blend_descriptor_pan` to a pushed 64-bit sysval. Keep
/// the two words in their native Internal Blend layout; this is not the
/// compact pixel-format encoding used by texture descriptors.
fn blendFauDescriptor(mode: NativeGraphicsPipeline.BlendMode) [2]u32 {
    return switch (mode) {
        .replace => .{ 0x0000_0019, 0x000e_d000 },
        .src_alpha => .{ 0x0000_001a, 0x000e_d000 },
    };
}

fn blendShaderFlags(mode: NativeGraphicsPipeline.BlendMode) u32 {
    return switch (mode) {
        .replace => 0x0081_002b,
        .src_alpha => 0x0081_002a,
    };
}

fn copyWords(destination: []u8, offset: usize, words: []const u32) void {
    const bytes = std.mem.sliceAsBytes(words);
    @memcpy(destination[offset..][0..bytes.len], bytes);
}

fn writeU64Words(words: []u32, offset: usize, value: u64) void {
    words[offset] = @truncate(value);
    words[offset + 1] = @truncate(value >> 32);
}

test "linear RGBA8 image sizing and clear packing remain overflow-safe" {
    try std.testing.expectEqual(@as(u32, 256), std.mem.alignForward(u32, 63 * 4, 64));
    const color = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    const packed_color = @as(u32, color[0]) | (@as(u32, color[1]) << 8) |
        (@as(u32, color[2]) << 16) | (@as(u32, color[3]) << 24);
    try std.testing.expectEqual(@as(u32, 0x4433_2211), packed_color);
}

test "Prism probe shaders preserve Mesa's Valhall compiler output" {
    try std.testing.expectEqual(@as(usize, 168), probe_vertex_shader.len);
    try std.testing.expectEqual(@as(usize, 72), probe_fragment_shader.len);
    try std.testing.expectEqual(@as(u8, 0x78), probe_vertex_shader[167]);
    try std.testing.expectEqual(@as(usize, 88), vertex_color_varying_shader.len);
    try std.testing.expectEqual(@as(usize, 56), vertex_color_fragment_shader.len);
    try std.testing.expectEqual(@as(usize, 328), rrect_varying_shader.len);
    try std.testing.expectEqual(@as(usize, 256), rrect_fragment_shader.len);
    var varying_digest: [32]u8 = undefined;
    var fragment_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&rrect_varying_shader, &varying_digest, .{});
    std.crypto.hash.sha2.Sha256.hash(&rrect_fragment_shader, &fragment_digest, .{});
    try std.testing.expectEqualSlices(u8, &.{
        0x7b, 0x0c, 0xe7, 0x28, 0x62, 0x59, 0xf5, 0xec, 0x93, 0x33, 0xf8, 0x80, 0xe3, 0xc3, 0x0f, 0x5d,
        0x1a, 0xf7, 0xb7, 0x71, 0x42, 0x0e, 0x43, 0x32, 0x92, 0x8c, 0xe4, 0xda, 0x0e, 0x65, 0x4d, 0xa8,
    }, &varying_digest);
    try std.testing.expectEqualSlices(u8, &.{
        0xf5, 0x3e, 0xaa, 0x5d, 0xcc, 0xd1, 0xd5, 0x70, 0xb9, 0xee, 0x83, 0x03, 0xfc, 0xee, 0x79, 0xf6,
        0xcf, 0x29, 0xb5, 0x3b, 0xaf, 0x3a, 0x3a, 0x0f, 0x94, 0x77, 0xee, 0x19, 0x15, 0x6f, 0x59, 0x19,
    }, &fragment_digest);
}

test "constant fragment channels use Mesa's canonical Valhall immediate moves" {
    const code = constantFragmentShader(.{ 0.25, 0.5, 0.75, 1.0 });
    try std.testing.expectEqual(@as(u64, 0x6910c03e800000c0), std.mem.readInt(u64, code[16..24], .little));
    try std.testing.expectEqual(@as(u64, 0x0110c13f000000c0), std.mem.readInt(u64, code[24..32], .little));
    try std.testing.expectEqual(@as(u64, 0x0110c23f400000c0), std.mem.readInt(u64, code[32..40], .little));
    try std.testing.expectEqual(@as(u64, 0x4910c33f800000c0), std.mem.readInt(u64, code[40..48], .little));
}

test "RGBA8 blend ABI matches PanVK replace and Phantom alpha traces" {
    try std.testing.expectEqual([4]u32{ 0x0000_0a00, 0xf012_2122, 0x0000_0019, 0x000e_d000 }, blendDescriptor(.replace));
    try std.testing.expectEqual([4]u32{ 0x0000_0a01, 0xf0d3_2503, 0x0000_001a, 0x000e_d000 }, blendDescriptor(.src_alpha));
    try std.testing.expectEqual([2]u32{ 0x0000_0019, 0x000e_d000 }, blendFauDescriptor(.replace));
    try std.testing.expectEqual([2]u32{ 0x0000_001a, 0x000e_d000 }, blendFauDescriptor(.src_alpha));
    try std.testing.expectEqual(@as(u32, 0x0081_002a), blendShaderFlags(.src_alpha));
}

test "native graphics pipeline rejects malformed stage binaries before allocation" {
    try std.testing.expectEqual(@as(usize, 0), NativeGraphicsPipeline.vertex_spd_offset % 32);
    try std.testing.expectEqual(@as(usize, 0), NativeGraphicsPipeline.varying_spd_offset % 32);
    try std.testing.expectEqual(@as(usize, 0), NativeGraphicsPipeline.fragment_spd_offset % 32);
    try std.testing.expectEqual(@as(usize, 0), NativeGraphicsPipeline.tsd_offset % 64);
    try std.testing.expect(NativeGraphicsPipeline.validStage(.{
        .code = &probe_vertex_shader,
        .register_count = 6,
        .preload = 0x3800,
    }));
    try std.testing.expect(!NativeGraphicsPipeline.validStage(.{
        .code = &.{ 0, 1, 2 },
        .register_count = 6,
        .preload = 0,
    }));
    try std.testing.expect(!NativeGraphicsPipeline.validStage(.{
        .code = &probe_fragment_shader,
        .register_count = 0,
        .preload = 0,
    }));
}
