//! Identifiers as Publr writes them: 24 lowercase hex characters, either time-ordered
//! (records, users: they sort in the order they were made), random (tokens: a visitor, a
//! sign-in's state) or derived from a name (content types, the same in every database).

const std = @import("std");

pub const len: u32 = 24;

pub fn random(io: std.Io, out: *[len]u8) []const u8 {
    std.debug.assert(len % 2 == 0);

    var raw: [len / 2]u8 = undefined;
    io.random(&raw);
    out.* = std.fmt.bytesToHex(raw, .lower);

    std.debug.assert(out[0] != 0);

    return out;
}

/// Time-ordered: the milliseconds since 1970 (12 hex characters, until the year 10889),
/// a counter within the millisecond (4), then random (8). `latest` is the greatest id the
/// table holds for the same millisecond, if any: the counter goes on from it, so ids made
/// together sort in the order they were made; copies of a database merged later cannot
/// collide, the random part being theirs alone.
pub fn ordered(io: std.Io, now_ms: i64, latest: ?[]const u8, out: *[len]u8) []const u8 {
    std.debug.assert(now_ms >= 0);
    std.debug.assert(latest == null or latest.?.len == len);

    const counter: u16 = if (latest) |last|
        (std.fmt.parseInt(u16, last[12..16], 16) catch 0xfffe) +| 1
    else
        0;
    var random_part: [4]u8 = undefined;

    io.random(&random_part);

    const written = std.fmt.bufPrint(out, "{x:0>12}{x:0>4}{x:0>8}", .{
        @as(u64, @intCast(now_ms)),
        counter,
        std.mem.readInt(u32, &random_part, .big),
    }) catch unreachable;

    std.debug.assert(written.len == len);

    return out;
}

/// The ids `ordered` makes in one millisecond lie between these two.
pub fn millisecond_range(now_ms: i64, low: *[len]u8, high: *[len]u8) void {
    std.debug.assert(now_ms >= 0);

    _ = std.fmt.bufPrint(low, "{x:0>12}000000000000", .{@as(u64, @intCast(now_ms))}) catch {
        unreachable;
    };
    _ = std.fmt.bufPrint(high, "{x:0>12}ffffffffffff", .{@as(u64, @intCast(now_ms))}) catch {
        unreachable;
    };

    std.debug.assert(std.mem.order(u8, low, high) == .lt);
}

pub fn derived(name: []const u8, out: *[len]u8) []const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(len % 2 == 0);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(name, &digest, .{});
    out.* = std.fmt.bytesToHex(digest[0 .. len / 2].*, .lower);

    return out;
}

test "ordered ids sort by time, then by their counter within a millisecond" {
    var first: [len]u8 = undefined;
    var second: [len]u8 = undefined;
    var later: [len]u8 = undefined;

    _ = ordered(std.testing.io, 1_790_000_000_000, null, &first);
    _ = ordered(std.testing.io, 1_790_000_000_000, &first, &second);
    _ = ordered(std.testing.io, 1_790_000_000_001, null, &later);

    try std.testing.expectEqualStrings(first[0..12], second[0..12]);
    try std.testing.expectEqualStrings("0000", first[12..16]);
    try std.testing.expectEqualStrings("0001", second[12..16]);
    try std.testing.expect(std.mem.order(u8, &first, &second) == .lt);
    try std.testing.expect(std.mem.order(u8, &second, &later) == .lt);

    var low: [len]u8 = undefined;
    var high: [len]u8 = undefined;

    millisecond_range(1_790_000_000_000, &low, &high);
    try std.testing.expect(std.mem.order(u8, &low, &first) != .gt);
    try std.testing.expect(std.mem.order(u8, &second, &high) == .lt);
}

test "random ids are hex and differ; derived ids are stable" {
    var first: [len]u8 = undefined;
    var second: [len]u8 = undefined;
    _ = random(std.testing.io, &first);
    _ = random(std.testing.io, &second);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));

    for (first) |char| {
        try std.testing.expect(std.ascii.isHex(char) and !std.ascii.isUpper(char));
    }

    var one: [len]u8 = undefined;
    var two: [len]u8 = undefined;
    try std.testing.expectEqualStrings(derived("post", &one), derived("post", &two));
    try std.testing.expect(!std.mem.eql(u8, derived("post", &one), derived("page", &two)));
}
