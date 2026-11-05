//! Hardware-defined sample-position lookup table used by framebuffer state.
//!
//! Each pattern occupies 256 bytes: 32 packed 8.8 positions, an origin, and
//! padding. This mirrors Mesa's `pan_samples.c` layout.

const std = @import("std");

pub const pattern_size = 256;
pub const pattern_count = 6;
pub const table_size = pattern_size * pattern_count;

const Position = struct { x: i8, y: i8 };

const patterns = [_][]const Position{
    &.{.{ .x = 0, .y = 0 }},
    &.{
        .{ .x = -4, .y = -4 }, .{ .x = 4, .y = -4 },
        .{ .x = -4, .y = 4 },  .{ .x = 4, .y = 4 },
    },
    &.{
        .{ .x = -2, .y = -6 }, .{ .x = 6, .y = -2 },
        .{ .x = -6, .y = 2 },  .{ .x = 2, .y = 6 },
    },
    &.{
        .{ .x = 1, .y = -3 }, .{ .x = -1, .y = 3 },
        .{ .x = 5, .y = 1 },  .{ .x = -3, .y = -5 },
        .{ .x = -5, .y = 5 }, .{ .x = -7, .y = -1 },
        .{ .x = 3, .y = 7 },  .{ .x = 7, .y = -7 },
    },
    &.{
        .{ .x = 1, .y = 1 },   .{ .x = -1, .y = -3 },
        .{ .x = -3, .y = 2 },  .{ .x = 4, .y = -1 },
        .{ .x = -5, .y = -2 }, .{ .x = 2, .y = 5 },
        .{ .x = 5, .y = 3 },   .{ .x = 3, .y = -5 },
        .{ .x = -2, .y = 6 },  .{ .x = 0, .y = -7 },
        .{ .x = -4, .y = -6 }, .{ .x = -6, .y = 4 },
        .{ .x = -8, .y = 0 },  .{ .x = 7, .y = -4 },
        .{ .x = 6, .y = 7 },   .{ .x = -7, .y = -8 },
    },
    &.{ .{ .x = 4, .y = 4 }, .{ .x = -4, .y = -4 } },
};

fn fixed(value: i8) u16 {
    return @intCast((@as(i16, value) + 8) * 16);
}

fn writePosition(destination: []u8, offset: usize, position: Position) void {
    std.mem.writeInt(u16, destination[offset..][0..2], fixed(position.x), .little);
    std.mem.writeInt(u16, destination[offset + 2 ..][0..2], fixed(position.y), .little);
}

pub fn writeTable(destination: []u8) error{BufferTooSmall}!void {
    if (destination.len < table_size) return error.BufferTooSmall;
    @memset(destination[0..table_size], 0);
    for (patterns, 0..) |pattern, pattern_index| {
        const base = pattern_index * pattern_size;
        for (pattern, 0..) |position, sample_index|
            writePosition(destination, base + sample_index * 4, position);
        writePosition(destination, base + 32 * 4, .{ .x = 0, .y = 0 });
    }
}

test "sample position LUT matches Mali packed 8.8 layout" {
    var table: [table_size]u8 = undefined;
    try writeTable(&table);
    try std.testing.expectEqual(@as(u16, 128), std.mem.readInt(u16, table[0..2], .little));
    try std.testing.expectEqual(@as(u16, 128), std.mem.readInt(u16, table[2..4], .little));
    try std.testing.expectEqual(@as(u16, 64), std.mem.readInt(u16, table[pattern_size..][0..2], .little));
    try std.testing.expectEqual(@as(u16, 64), std.mem.readInt(u16, table[pattern_size + 2 ..][0..2], .little));
    try std.testing.expectEqual(@as(u16, 128), std.mem.readInt(u16, table[32 * 4 ..][0..2], .little));
}
