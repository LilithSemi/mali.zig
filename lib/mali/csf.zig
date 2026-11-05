//! Arm Mali CSF command-stream encoder for Valhall v10.
//!
//! Every instruction is one little-endian 64-bit word. The field locations
//! mirror Mesa's `src/panfrost/genxml/v10.xml`; this module deliberately stays
//! below shader/descriptor policy so both compute and graphics can share it.

const std = @import("std");

pub const Error = error{ BufferFull, InvalidArgument };

pub const Opcode = enum(u8) {
    nop = 0,
    move48 = 1,
    move32 = 2,
    wait = 3,
    run_compute = 4,
    run_tiling = 5,
    run_idvs = 6,
    run_fragment = 7,
    run_fullscreen = 8,
    finish_tiling = 9,
    finish_fragment = 11,
    add_immediate32 = 16,
    add_immediate64 = 17,
    compare_select32 = 18,
    load_multiple = 20,
    store_multiple = 21,
    branch = 22,
    set_sb_entry = 23,
    progress_wait = 24,
    set_exception_handler = 25,
    call = 32,
    jump = 33,
    request_resource = 34,
    flush_cache2 = 36,
    sync_add32 = 37,
    sync_set32 = 38,
    sync_wait32 = 39,
    store_state = 40,
    protected_region = 41,
    progress_store = 42,
    progress_load = 43,
    run_compute_indirect = 44,
    error_barrier = 47,
    heap_set = 48,
    heap_operation = 49,
    trace_point = 50,
    sync_add64 = 51,
    sync_set64 = 52,
    sync_wait64 = 53,
};

pub const Resource = packed struct(u4) {
    compute: bool = false,
    fragment: bool = false,
    tiler: bool = false,
    idvs: bool = false,
};

pub const TaskAxis = enum(u2) { x = 0, y = 1, z = 2 };

pub const State = enum(u8) {
    timestamp = 0,
    cycle_count = 1,
    disjoint_count = 2,
    error_status = 3,
};

pub const RunCompute = struct {
    task_increment: u14 = 0,
    task_axis: TaskAxis = .x,
    progress_increment: bool = false,
    srt_select: u2 = 0,
    spd_select: u2 = 0,
    tsd_select: u2 = 0,
    fau_select: u2 = 0,
};

pub const RunIdvs = struct {
    flags_override: u32 = 0,
    progress_increment: bool = false,
    malloc_enable: bool = false,
    draw_id_register_enable: bool = false,
    varying_srt_select: bool = false,
    varying_fau_select: bool = false,
    varying_tsd_select: bool = false,
    fragment_srt_select: bool = false,
    fragment_tsd_select: bool = false,
    draw_id: u8 = 0,
};

pub const CacheFlush = struct {
    l2_mode: u4 = 0,
    lsc_mode: u4 = 0,
    other_mode: u4 = 0,
    wait_mask: u16 = 0,
    latest_flush_id_register: u8 = 0,
    signal_slot: u4 = 0,
};

pub const compute_register = struct {
    pub const srt_0: u8 = 0;
    pub const fau_0: u8 = 8;
    pub const spd_0: u8 = 16;
    pub const tsd_0: u8 = 24;
    pub const global_attribute_offset: u8 = 32;
    pub const workgroup_size: u8 = 33;
    pub const job_offset_x: u8 = 34;
    pub const job_offset_y: u8 = 35;
    pub const job_offset_z: u8 = 36;
    pub const job_size_x: u8 = 37;
    pub const job_size_y: u8 = 38;
    pub const job_size_z: u8 = 39;
};

pub const idvs_register = struct {
    pub const tiler_context: u8 = 40;
    pub const scissor_box: u8 = 42;
    pub const blend_descriptor: u8 = 50;
    pub const depth_stencil_descriptor: u8 = 52;
    pub const index_buffer: u8 = 54;
    pub const tiler_flags: u8 = 56;
};

pub const fragment_register = struct {
    pub const framebuffer_descriptor: u8 = 40;
    pub const bounding_box_min: u8 = 42;
    pub const bounding_box_max: u8 = 43;
    pub const tile_enable_map: u8 = 44;
    pub const tile_enable_map_row_stride: u8 = 46;
};

pub const Builder = struct {
    storage: []u64,
    len: usize = 0,

    pub fn init(storage: []u64) Builder {
        return .{ .storage = storage };
    }

    pub fn reset(self: *Builder) void {
        self.len = 0;
    }

    pub fn words(self: *const Builder) []const u64 {
        return self.storage[0..self.len];
    }

    pub fn bytes(self: *const Builder) []const u8 {
        return std.mem.sliceAsBytes(self.words());
    }

    pub fn emit(self: *Builder, opcode: Opcode, data: u56) Error!void {
        if (self.len == self.storage.len) return error.BufferFull;
        self.storage[self.len] = (@as(u64, @backingInt(opcode)) << 56) | data;
        self.len += 1;
    }

    pub fn nop(self: *Builder, metadata_type: u8, payload: u48) Error!void {
        try self.emit(.nop, @as(u56, payload) | (@as(u56, metadata_type) << 48));
    }

    pub fn move32(self: *Builder, destination: u8, immediate: u32) Error!void {
        try self.emit(.move32, @as(u56, immediate) | (@as(u56, destination) << 48));
    }

    /// Write a 48-bit address/value into a 64-bit register tuple. The
    /// destination register must be even because it names two 32-bit words.
    pub fn move48(self: *Builder, destination: u8, immediate: u64) Error!void {
        if (destination & 1 != 0 or immediate >= (@as(u64, 1) << 48)) return error.InvalidArgument;
        try self.emit(.move48, @as(u56, @truncate(immediate)) | (@as(u56, destination) << 48));
    }

    /// Move a full 64-bit value. Tagged pointers such as FAU address|count do
    /// not fit MOVE48 and are split into two MOVE32 instructions.
    pub fn move64(self: *Builder, destination: u8, immediate: u64) Error!void {
        if (destination & 1 != 0) return error.InvalidArgument;
        if (immediate < (@as(u64, 1) << 48)) return self.move48(destination, immediate);
        try self.move32(destination, @truncate(immediate));
        try self.move32(destination + 1, @truncate(immediate >> 32));
    }

    pub fn wait(self: *Builder, mask: u16, increment_progress: bool) Error!void {
        const data = (@as(u56, mask) << 16) | (@as(u56, @intFromBool(increment_progress)) << 32);
        try self.emit(.wait, data);
    }

    pub fn requestResources(self: *Builder, resources: Resource) Error!void {
        const bits: u4 = @bitCast(resources);
        try self.emit(.request_resource, @as(u56, bits));
    }

    pub fn runCompute(self: *Builder, config: RunCompute) Error!void {
        const data = @as(u56, config.task_increment) |
            (@as(u56, @backingInt(config.task_axis)) << 14) |
            (@as(u56, @intFromBool(config.progress_increment)) << 32) |
            (@as(u56, config.srt_select) << 40) |
            (@as(u56, config.spd_select) << 42) |
            (@as(u56, config.tsd_select) << 44) |
            (@as(u56, config.fau_select) << 46);
        try self.emit(.run_compute, data);
    }

    pub fn runIdvs(self: *Builder, config: RunIdvs) Error!void {
        const data = @as(u56, config.flags_override) |
            (@as(u56, @intFromBool(config.progress_increment)) << 32) |
            (@as(u56, @intFromBool(config.malloc_enable)) << 33) |
            (@as(u56, @intFromBool(config.draw_id_register_enable)) << 34) |
            (@as(u56, @intFromBool(config.varying_srt_select)) << 35) |
            (@as(u56, @intFromBool(config.varying_fau_select)) << 36) |
            (@as(u56, @intFromBool(config.varying_tsd_select)) << 37) |
            (@as(u56, @intFromBool(config.fragment_srt_select)) << 38) |
            (@as(u56, @intFromBool(config.fragment_tsd_select)) << 39) |
            (@as(u56, config.draw_id) << 40);
        try self.emit(.run_idvs, data);
    }

    pub fn runFragment(self: *Builder, enable_tem: bool, tile_order: u4, increment_progress: bool) Error!void {
        const data = @as(u56, @intFromBool(enable_tem)) |
            (@as(u56, tile_order) << 4) |
            (@as(u56, @intFromBool(increment_progress)) << 32);
        try self.emit(.run_fragment, data);
    }

    pub fn runFullscreen(self: *Builder, flags_override: u32, dcd_register: u8, increment_progress: bool) Error!void {
        if (dcd_register & 1 != 0) return error.InvalidArgument;
        const data = @as(u56, flags_override) |
            (@as(u56, @intFromBool(increment_progress)) << 32) |
            (@as(u56, dcd_register) << 40);
        try self.emit(.run_fullscreen, data);
    }

    pub fn setScoreboardEntry(self: *Builder, endpoint: u4, other: u4) Error!void {
        try self.emit(.set_sb_entry, @as(u56, endpoint) | (@as(u56, other) << 4));
    }

    pub fn finishTiling(self: *Builder, increment_progress: bool) Error!void {
        try self.emit(.finish_tiling, @as(u56, @intFromBool(increment_progress)) << 32);
    }

    /// Retire a v10 fragment iteration after RUN_FRAGMENT. The first/last
    /// registers contain heap-chunk completion pointers; zero is valid when
    /// the iteration did not complete a whole releasable chunk.
    pub fn finishFragment(
        self: *Builder,
        increment_fragment_completed: bool,
        first_heap_chunk_register: u8,
        last_heap_chunk_register: u8,
        wait_mask: u16,
        signal_slot: u4,
    ) Error!void {
        if (first_heap_chunk_register & 1 != 0 or last_heap_chunk_register & 1 != 0)
            return error.InvalidArgument;
        const data = @as(u56, @intFromBool(increment_fragment_completed)) |
            (@as(u56, wait_mask) << 16) |
            (@as(u56, last_heap_chunk_register) << 32) |
            (@as(u56, first_heap_chunk_register) << 40) |
            (@as(u56, signal_slot) << 48);
        try self.emit(.finish_fragment, data);
    }

    pub fn loadMultiple(self: *Builder, base_register: u8, address_register: u8, mask: u16, offset: i16) Error!void {
        const data = @as(u56, @as(u16, @bitCast(offset))) |
            (@as(u56, mask) << 16) |
            (@as(u56, address_register) << 40) |
            (@as(u56, base_register) << 48);
        try self.emit(.load_multiple, data);
    }

    pub fn storeMultiple(self: *Builder, base_register: u8, address_register: u8, mask: u16, offset: i16) Error!void {
        const data = @as(u56, @as(u16, @bitCast(offset))) |
            (@as(u56, mask) << 16) |
            (@as(u56, address_register) << 40) |
            (@as(u56, base_register) << 48);
        try self.emit(.store_multiple, data);
    }

    /// Snapshot a 64-bit CS state value to memory. The address register names
    /// an even-aligned 64-bit register tuple.
    pub fn storeState(
        self: *Builder,
        address_register: u8,
        offset: i16,
        state: State,
        wait_mask: u16,
        signal_slot: u4,
    ) Error!void {
        if (address_register & 1 != 0) return error.InvalidArgument;
        const data = @as(u56, @as(u16, @bitCast(offset))) |
            (@as(u56, wait_mask) << 16) |
            (@as(u56, @backingInt(state)) << 32) |
            (@as(u56, address_register) << 40) |
            (@as(u56, signal_slot) << 48);
        try self.emit(.store_state, data);
    }

    pub fn flushCache(self: *Builder, config: CacheFlush) Error!void {
        const data = @as(u56, config.l2_mode) |
            (@as(u56, config.lsc_mode) << 4) |
            (@as(u56, config.other_mode) << 8) |
            (@as(u56, config.wait_mask) << 16) |
            (@as(u56, config.latest_flush_id_register) << 40) |
            (@as(u56, config.signal_slot) << 48);
        try self.emit(.flush_cache2, data);
    }

    pub fn heapSet(self: *Builder, address_register: u8) Error!void {
        try self.emit(.heap_set, @as(u56, address_register) << 40);
    }

    pub fn heapOperation(self: *Builder, operation: u3, wait_mask: u16, signal_slot: u4) Error!void {
        try self.emit(.heap_operation, (@as(u56, wait_mask) << 16) |
            (@as(u56, operation) << 32) | (@as(u56, signal_slot) << 48));
    }
};

test "v10 CSF instruction encodings match genxml field positions" {
    var words: [8]u64 = undefined;
    var b = Builder.init(&words);
    try b.move32(33, 0x12345678);
    try b.move48(16, 0x1234_5678_9abc);
    try b.wait(0x12, true);
    try b.requestResources(.{ .compute = true, .tiler = true });
    try b.runCompute(.{ .task_increment = 7, .task_axis = .z, .progress_increment = true, .spd_select = 2 });
    try std.testing.expectEqualSlices(u64, &.{
        0x0221_0000_1234_5678,
        0x0110_1234_5678_9abc,
        0x0300_0001_0012_0000,
        0x2200_0000_0000_0005,
        0x0400_0801_0000_8007,
    }, b.words());
    try std.testing.expectEqual(@as(usize, 5 * 8), b.bytes().len);
}

test "move48 rejects odd registers and values wider than the GPU VA" {
    var words: [1]u64 = undefined;
    var b = Builder.init(&words);
    try std.testing.expectError(error.InvalidArgument, b.move48(1, 0));
    try std.testing.expectError(error.InvalidArgument, b.move48(2, @as(u64, 1) << 48));
}

test "finish fragment defers retirement on the render scoreboard" {
    var words: [1]u64 = undefined;
    var b = Builder.init(&words);
    try b.finishFragment(true, 0, 2, 1 << 3, 4);
    try std.testing.expectEqual(@as(u64, 0x0b04_0002_0008_0001), b.words()[0]);
}

test "move64 uses MOVE48 for addresses and two MOVE32s for tagged pointers" {
    var words: [3]u64 = undefined;
    var b = Builder.init(&words);
    try b.move64(8, 0x1234_5678_9abc);
    try b.move64(10, 0x0200_1234_5678_9000);
    try std.testing.expectEqualSlices(u64, &.{
        0x0108_1234_5678_9abc,
        0x020a_0000_5678_9000,
        0x020b_0000_0200_1234,
    }, b.words());
}

test "store state matches v10 genxml field positions" {
    var words: [1]u64 = undefined;
    var b = Builder.init(&words);
    try b.storeState(62, -16, .error_status, 0x1234, 5);
    try std.testing.expectEqualSlices(u64, &.{0x2805_3e03_1234_fff0}, b.words());
}

test "run fullscreen matches v10 genxml field positions" {
    var words: [1]u64 = undefined;
    var b = Builder.init(&words);
    try b.runFullscreen(0x1234_5678, 62, true);
    try std.testing.expectEqualSlices(u64, &.{0x0800_3e01_1234_5678}, b.words());
}

test "builder reports capacity instead of writing past command memory" {
    var words: [1]u64 = undefined;
    var b = Builder.init(&words);
    try b.nop(0, 0);
    try std.testing.expectError(error.BufferFull, b.nop(0, 0));
}
