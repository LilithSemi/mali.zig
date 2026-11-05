//! Valhall v10 descriptor packing used by Panthor command streams.
//!
//! Fields mirror Mesa's `src/panfrost/genxml/v10.xml`. Descriptors are arrays
//! of little-endian 32-bit words so layouts remain explicit and testable.

const std = @import("std");

pub const ShaderStage = enum(u4) { compute = 1, fragment = 2, vertex = 3 };
pub const RegisterAllocation = enum(u2) { per_thread_64 = 0, per_thread_32 = 2 };

pub const ShaderProgram = struct {
    words: [8]u32 = @splat(0),

    pub fn init(stage: ShaderStage, binary: u64, preload: u16, allocation: RegisterAllocation) ShaderProgram {
        var result = ShaderProgram{};
        result.words[0] = 8 | (@as(u32, @backingInt(stage)) << 4) |
            (@as(u32, @backingInt(allocation)) << 30);
        result.words[1] = preload;
        result.words[2] = @truncate(binary);
        result.words[3] = @truncate(binary >> 32);
        return result;
    }

    pub fn bytes(self: *const ShaderProgram) []const u8 {
        return std.mem.sliceAsBytes(&self.words);
    }
};

pub const LocalStorage = struct {
    words: [8]u32 = @splat(0),

    /// No TLS and no workgroup-local memory, using packed TLS addressing.
    pub fn empty() LocalStorage {
        var result = LocalStorage{};
        // WLS instances uses log2 encoding; the special no-memory value is
        // 0x80000000, whose encoded exponent is 31.
        result.words[1] = 31;
        result.words[3] = 1 << 28; // MALI_ADDRESS_MODE_PACKED
        return result;
    }

    pub fn bytes(self: *const LocalStorage) []const u8 {
        return std.mem.sliceAsBytes(&self.words);
    }
};

pub const Buffer = struct {
    words: [8]u32 = @splat(0),

    pub fn init(address: u64, size: u32) Buffer {
        var result = Buffer{};
        result.words[0] = 9 | (1 << 4); // descriptor=Buffer, type=Simple
        result.words[1] = size;
        result.words[2] = @truncate(address);
        result.words[3] = @truncate(address >> 32);
        return result;
    }
};

pub const Resource = struct {
    words: [4]u32 = @splat(0),

    pub fn init(address: u64, size: u64, contains_descriptors: bool) Resource {
        var result = Resource{};
        result.words[0] = @truncate(address);
        result.words[1] = @as(u32, @truncate(address >> 32)) & 0x00ff_ffff;
        result.words[1] |= @as(u32, @intFromBool(contains_descriptors)) << 24;
        result.words[2] = @truncate(size);
        result.words[3] = @truncate(size >> 32);
        return result;
    }
};

/// Single-level, single-layer linear RGBA8 UNORM texture header. `surfaces`
/// points at one 32-byte `GenericPlaneRgba8` descriptor.
pub const TextureRgba8 = struct {
    words: [8]u32 = @splat(0),

    pub fn init(width: u16, height: u16, surfaces: u64) TextureRgba8 {
        return initSwizzle(width, height, surfaces, 0x688);
    }

    pub fn initSwizzle(width: u16, height: u16, surfaces: u64, swizzle: u12) TextureRgba8 {
        std.debug.assert(width != 0 and height != 0);
        var result = TextureRgba8{};
        // Descriptor=Texture, dimension=2D, and pixel format
        // RGBA8_UNORM/RGBA/linear (0x0bb000) in the 22-bit format field.
        result.words[0] = 2 | (2 << 4) | (@as(u32, 0x000b_b000) << 10);
        result.words[1] = (@as(u32, width) - 1) | ((@as(u32, height) - 1) << 16);
        result.words[2] = swizzle;
        result.words[4] = @truncate(surfaces);
        result.words[5] = @truncate(surfaces >> 32);
        return result;
    }
};

/// Linear-filtering, normalized-coordinate sampler clamped on all axes.
pub const SamplerLinearClamp = struct {
    words: [8]u32 = @splat(0),

    pub const Filter = enum { nearest, linear };
    pub const AddressMode = enum(u4) { repeat = 8, clamp_to_edge = 9, mirrored_repeat = 12 };

    pub fn init() SamplerLinearClamp {
        return initState(.linear, .linear, .clamp_to_edge, .clamp_to_edge);
    }

    pub fn initState(min: Filter, mag: Filter, u: AddressMode, v: AddressMode) SamplerLinearClamp {
        var result = SamplerLinearClamp{};
        // Descriptor=Sampler; S/T/R=clamp-to-edge; round-to-nearest-even;
        // seamless cube maps; normalized coordinates.
        result.words[0] = 1 |
            (@as(u32, @backingInt(AddressMode.clamp_to_edge)) << 8) |
            (@as(u32, @backingInt(v)) << 12) |
            (@as(u32, @backingInt(u)) << 16) |
            (1 << 23) | (1 << 25) |
            (@as(u32, @intFromBool(min == .nearest)) << 27) |
            (@as(u32, @intFromBool(mag == .nearest)) << 28);
        if (min != .nearest or mag != .nearest) result.words[0] |= 1 << 21;
        return result;
    }
};

/// One linear RAW32 plane used as the payload of `TextureRgba8`.
pub const GenericPlaneRgba8 = struct {
    words: [8]u32 = @splat(0),

    pub fn init(address: u64, size: u32, row_stride: u32, width: u16, height: u16) GenericPlaneRgba8 {
        std.debug.assert(width != 0 and height != 0);
        var result = GenericPlaneRgba8{};
        // Descriptor=Plane, type=Generic, linear clump ordering, RAW32 clumps.
        result.words[0] = 10 | (1 << 4) | (2 << 8) | (2 << 24);
        result.words[1] = size;
        result.words[2] = @truncate(address);
        result.words[3] = @truncate(address >> 32);
        result.words[4] = row_stride;
        result.words[7] = (@as(u32, width) - 1) | ((@as(u32, height) - 1) << 16);
        return result;
    }
};

/// Valhall v10 framebuffer descriptor for one single-sampled RGBA8 target.
/// The descriptor occupies 128 bytes so the following render target remains
/// 64-byte aligned.
pub const FramebufferRgba8 = struct {
    words: [32]u32 = @splat(0),

    pub fn init(width: u16, height: u16, sample_positions: u64, tiler: u64) FramebufferRgba8 {
        var result = FramebufferRgba8{};
        result.words[4] = @truncate(sample_positions);
        result.words[5] = @truncate(sample_positions >> 32);
        result.words[8] = (@as(u32, width) - 1) | ((@as(u32, height) - 1) << 16);
        result.words[10] = (@as(u32, width) - 1) | ((@as(u32, height) - 1) << 16);
        // Single sampling, -180-in/0-out tie break, a 32x32 effective tile,
        // one render target, and 4 KiB of RGBA8 tile-buffer storage.
        result.words[11] = (@as(u32, 2) << 6) | (@as(u32, 10) << 9) |
            (@as(u32, 1) << 14) | (@as(u32, 4) << 24);
        result.words[12] = 1 << 16; // Default depth format D24; no Z attachment.
        // Fragment jobs consume the polygon list through the tiler-context
        // pointer embedded in the framebuffer parameters. A zero pointer is
        // valid for clear-only jobs but cannot rasterize submitted geometry.
        result.words[14] = @truncate(tiler);
        result.words[15] = @truncate(tiler >> 32);
        return result;
    }

    pub fn taggedPointer(address: u64) u64 {
        return address | 1; // type=MFBD, no ZS/CRC extension, one RT.
    }
};

pub const RenderTargetRgba8 = struct {
    words: [16]u32 = @splat(0),

    pub fn init(address: u64, row_stride: u32, surface_stride: u32, clear: u32) RenderTargetRgba8 {
        var result = RenderTargetRgba8{};
        result.words[0] = 1 << 26; // R8G8B8A8 internal tile-buffer format.
        result.words[1] = 1 | (@as(u32, 19) << 3) | (@as(u32, 2) << 8) |
            (@as(u32, 1) << 15) | (@as(u32, 0x688) << 16) | (@as(u32, 1) << 31);
        result.words[8] = @truncate(address);
        result.words[9] = @truncate(address >> 32);
        result.words[10] = row_stride;
        result.words[11] = surface_stride;
        result.words[12] = clear;
        result.words[13] = clear;
        result.words[14] = clear;
        result.words[15] = clear;
        return result;
    }
};

pub const TilerContext = struct {
    words: [32]u32 = @splat(0),

    pub fn init(width: u16, height: u16, heap: u64, geometry_buffer: u64) TilerContext {
        var result = TilerContext{};
        // The G610 exposes eight hierarchy levels; single-sampling uses the
        // standard hierarchy mask and first-vertex provoking convention.
        result.words[2] = 0x0004_00fe;
        result.words[3] = (@as(u32, width) - 1) | ((@as(u32, height) - 1) << 16);
        result.words[6] = @truncate(heap);
        result.words[7] = @truncate(heap >> 32);
        // Low 12 bits encode geometry-buffer size in 4 KiB units.
        const encoded_geometry = geometry_buffer | ((64 * 1024) >> 12);
        result.words[8] = @truncate(encoded_geometry);
        result.words[9] = @truncate(encoded_geometry >> 32);
        return result;
    }
};

pub const VertexAttributeF32 = struct {
    words: [8]u32 = @splat(0),

    pub fn init(components: u3, offset: u32, buffer_index: u32, stride: u32) VertexAttributeF32 {
        var result = VertexAttributeF32{};
        // Descriptor type Attribute (5), 1D, offset enabled, table 0,
        // per-vertex. Pixel formats are the v10 RGB component-order packed
        // encodings used by PanVK for R32G32[_B32]_FLOAT.
        result.words[0] = switch (components) {
            2 => 0x2bc0_4115,
            3 => 0x2dc0_4115,
            4 => 0x2fc0_0115,
            else => unreachable,
        };
        result.words[2] = offset;
        result.words[3] = buffer_index;
        result.words[4] = stride;
        return result;
    }
};

pub const VertexAttributeVec2F32 = struct {
    pub fn init(stride: u32) VertexAttributeF32 {
        return VertexAttributeF32.init(2, 0, 1, stride);
    }
};

pub fn computeWorkgroupSize(x: u10, y: u10, z: u10, allow_merge: bool) u32 {
    if (x == 0 or y == 0 or z == 0) return 0;
    return (@as(u32, x) - 1) |
        ((@as(u32, y) - 1) << 10) |
        ((@as(u32, z) - 1) << 20) |
        (@as(u32, @intFromBool(allow_merge)) << 31);
}

test "compute shader descriptor matches v10 genxml fields" {
    const spd = ShaderProgram.init(.compute, 0x1234_5678_9abc, 0xa500, .per_thread_32);
    try std.testing.expectEqualSlices(u32, &.{
        0x8000_0018,
        0x0000_a500,
        0x5678_9abc,
        0x0000_1234,
        0,
        0,
        0,
        0,
    }, &spd.words);
    try std.testing.expectEqual(@as(usize, 32), spd.bytes().len);
}

test "empty local storage descriptor encodes packed mode and no WLS" {
    const tsd = LocalStorage.empty();
    try std.testing.expectEqual(@as(u32, 31), tsd.words[1]);
    try std.testing.expectEqual(@as(u32, 1 << 28), tsd.words[3]);
    try std.testing.expectEqual(@as(usize, 32), tsd.bytes().len);
}

test "resource and buffer descriptors preserve addresses and sizes" {
    const buffer = Buffer.init(0x1234_5678_9000, 4096);
    try std.testing.expectEqual(@as(u32, 0x19), buffer.words[0]);
    try std.testing.expectEqual(@as(u32, 4096), buffer.words[1]);
    try std.testing.expectEqual(@as(u32, 0x5678_9000), buffer.words[2]);
    try std.testing.expectEqual(@as(u32, 0x1234), buffer.words[3]);

    const resource = Resource.init(0x1234_5678_9000, 32, true);
    try std.testing.expectEqual(@as(u32, 0x5678_9000), resource.words[0]);
    try std.testing.expectEqual(@as(u32, 0x0100_1234), resource.words[1]);
    try std.testing.expectEqual(@as(u32, 32), resource.words[2]);
}

test "linear RGBA8 texture descriptors match Valhall v10 genxml" {
    const texture = TextureRgba8.init(64, 32, 0x1234_5678_9000);
    try std.testing.expectEqual(@as(u32, 0x2ec0_0022), texture.words[0]);
    try std.testing.expectEqual(@as(u32, 0x001f_003f), texture.words[1]);
    try std.testing.expectEqual(@as(u32, 0x688), texture.words[2]);
    try std.testing.expectEqual(@as(u32, 0x5678_9000), texture.words[4]);

    const sampler = SamplerLinearClamp.init();
    try std.testing.expectEqual(@as(u32, 0x02a9_9901), sampler.words[0]);

    const plane = GenericPlaneRgba8.init(0x1234_5678_9000, 8192, 256, 64, 32);
    try std.testing.expectEqual(@as(u32, 0x0200_021a), plane.words[0]);
    try std.testing.expectEqual(@as(u32, 8192), plane.words[1]);
    try std.testing.expectEqual(@as(u32, 256), plane.words[4]);
    try std.testing.expectEqual(@as(u32, 0x001f_003f), plane.words[7]);
}

test "compute workgroup size uses minus-one fields" {
    try std.testing.expectEqual(@as(u32, 0x8000_0000), computeWorkgroupSize(1, 1, 1, true));
    try std.testing.expectEqual(@as(u32, 3 | (7 << 10) | (1 << 20)), computeWorkgroupSize(4, 8, 2, false));
}

test "RGBA8 framebuffer and render-target packing matches v10 genxml" {
    const fb = FramebufferRgba8.init(64, 32, 0x1234_5678_9000, 0x2345_6789_a000);
    try std.testing.expectEqual(@as(u32, 0x5678_9000), fb.words[4]);
    try std.testing.expectEqual(@as(u32, 0x001f_003f), fb.words[8]);
    try std.testing.expectEqual(@as(u32, 0x6789_a000), fb.words[14]);
    try std.testing.expectEqual(@as(u32, 0x0000_2345), fb.words[15]);
    try std.testing.expectEqual(@as(u32, 0x0400_5480), fb.words[11]);
    try std.testing.expectEqual(@as(u64, 0x1234_0001), FramebufferRgba8.taggedPointer(0x1234_0000));

    const rt = RenderTargetRgba8.init(0x1234_5678_9000, 256, 8192, 0xff00_00ff);
    try std.testing.expectEqual(@as(u32, 0x0400_0000), rt.words[0]);
    try std.testing.expectEqual(@as(u32, 0x8688_8299), rt.words[1]);
    try std.testing.expectEqual(@as(u32, 0x5678_9000), rt.words[8]);
    try std.testing.expectEqual(@as(u32, 0xff00_00ff), rt.words[15]);
}

test "graphics input and tiler descriptors match the PanVK v10 trace" {
    const attr = VertexAttributeVec2F32.init(8);
    try std.testing.expectEqual(@as(u32, 0x2bc0_4115), attr.words[0]);
    try std.testing.expectEqual(@as(u32, 1), attr.words[3]);
    try std.testing.expectEqual(@as(u32, 8), attr.words[4]);
    const color = VertexAttributeF32.init(3, 8, 2, 20);
    try std.testing.expectEqual(@as(u32, 0x2dc0_4115), color.words[0]);
    try std.testing.expectEqual(@as(u32, 8), color.words[2]);
    try std.testing.expectEqual(@as(u32, 2), color.words[3]);
    try std.testing.expectEqual(@as(u32, 20), color.words[4]);
    const rgba = VertexAttributeF32.init(4, 16, 4, 48);
    try std.testing.expectEqual(@as(u32, 0x2fc0_0115), rgba.words[0]);
    try std.testing.expectEqual(@as(u32, 16), rgba.words[2]);
    try std.testing.expectEqual(@as(u32, 4), rgba.words[3]);
    try std.testing.expectEqual(@as(u32, 48), rgba.words[4]);
    const tiler = TilerContext.init(8, 8, 0x12000, 0x13000);
    try std.testing.expectEqual(@as(u32, 0x0004_00fe), tiler.words[2]);
    try std.testing.expectEqual(@as(u32, 0x0007_0007), tiler.words[3]);
    try std.testing.expectEqual(@as(u32, 0x0001_3010), tiler.words[8]);
}
