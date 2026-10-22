//! Rate limits: how many calls a caller made in the current minute, the general limit's
//! and an operation's own `.limit`. A fixed table like the sign-in throttle: no clock of
//! its own (the caller passes `now_ms`), no allocation, subjects hashed under a secret so
//! nobody chooses a collision; a full table forgets the slot used longest ago.
const std = @import("std");

const SipHash = std.crypto.auth.siphash.SipHash64(2, 4);

/// The general limit: calls a minute one caller makes, whatever they call.
pub const general_per_minute: u32 = 600;
pub const slots_max: u32 = 4096;
pub const window_ms: i64 = 60 * 1000;

/// Where a caller stands after a call was counted, for the `RateLimit-*` headers.
pub const Outcome = struct {
    allowed: bool,
    limit: u32,
    remaining: u32,
    /// Seconds until the window starts again.
    reset_s: u32,
};

pub const Limits = struct {
    secret: [SipHash.key_length]u8 = @splat(0),
    slots: [slots_max]Slot = @splat(.{}),

    pub const Slot = struct {
        /// The subject and scope hashed; 0 marks a free slot.
        key: u64 = 0,
        window_start_ms: i64 = 0,
        count: u32 = 0,
    };

    /// Counts one call of `subject` (an account, a visitor, an address) in `scope` (empty
    /// for the general limit, else the operation's name) against `per_minute`.
    pub fn take(
        limits: *Limits,
        subject: []const u8,
        scope: []const u8,
        per_minute: u32,
        now_ms: i64,
    ) Outcome {
        std.debug.assert(subject.len > 0);
        std.debug.assert(per_minute > 0);

        const key = limits.key_for(subject, scope);
        const slot = limits.slot_for(key, now_ms);

        if (now_ms - slot.window_start_ms >= window_ms) {
            slot.window_start_ms = now_ms;
            slot.count = 0;
        }

        const allowed = slot.count < per_minute;

        if (allowed) {
            slot.count += 1;
        }

        const reset_ms = slot.window_start_ms + window_ms - now_ms;

        std.debug.assert(reset_ms > 0 and reset_ms <= window_ms);

        return .{
            .allowed = allowed,
            .limit = per_minute,
            .remaining = per_minute - @min(slot.count, per_minute),
            .reset_s = @intCast(@divFloor(reset_ms + 999, 1000)),
        };
    }

    fn key_for(limits: *const Limits, subject: []const u8, scope: []const u8) u64 {
        std.debug.assert(subject.len > 0);
        std.debug.assert(scope.len <= 256);

        var hasher = SipHash.init(&limits.secret);

        hasher.update(subject);
        hasher.update(&.{0});
        hasher.update(scope);

        const hashed = hasher.finalInt();

        return if (hashed == 0) 1 else hashed;
    }

    /// The subject's slot: found, else a free one, else the one whose window began longest
    /// ago, emptied.
    fn slot_for(limits: *Limits, key: u64, now_ms: i64) *Slot {
        std.debug.assert(key != 0);
        std.debug.assert(now_ms >= 0);

        var oldest: *Slot = &limits.slots[0];

        for (&limits.slots) |*slot| {
            if (slot.key == key) {
                return slot;
            }

            if (slot.key == 0 or slot.window_start_ms < oldest.window_start_ms) {
                oldest = slot;
            }
        }

        oldest.* = .{
            .key = key,
            .window_start_ms = now_ms,
        };

        return oldest;
    }
};

/// The address a caller came from: the request's peer, or behind a proxy on this machine
/// the last hop of `X-Forwarded-For`, the one that proxy added. Empty when unknown.
pub fn address_of(arena: std.mem.Allocator, peer: ?[4]u8, forwarded: ?[]const u8) []const u8 {
    std.debug.assert(peer == null or peer.?.len == 4);

    const ip = peer orelse return "";

    if (ip[0] == 127) {
        if (forwarded) |hops| {
            const last = std.mem.lastIndexOfScalar(u8, hops, ',');
            const hop = std.mem.trim(u8, if (last) |at| hops[at + 1 ..] else hops, " ");

            if (hop.len > 0 and hop.len <= 64) {
                return arena.dupe(u8, hop) catch "";
            }
        }
    }

    const text = std.fmt.allocPrint(arena, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });

    return text catch "";
}

test "a caller's minute: counted, refused past the limit, counted again next minute" {
    var limits: Limits = .{};

    for (0..3) |_| {
        try std.testing.expect(limits.take("ada", "", 3, 1000).allowed);
    }

    const refused = limits.take("ada", "", 3, 2000);

    try std.testing.expect(!refused.allowed);
    try std.testing.expectEqual(0, refused.remaining);
    try std.testing.expectEqual(59, refused.reset_s);
    try std.testing.expect(limits.take("grace", "", 3, 2000).allowed);
    try std.testing.expect(limits.take("ada", "guestbook.sign", 3, 2000).allowed);
    try std.testing.expect(limits.take("ada", "", 3, 61_000).allowed);
}

test "the address: the peer's, or the proxy's last forwarded hop on loopback" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("10.0.0.7", address_of(arena, .{ 10, 0, 0, 7 }, "1.2.3.4"));
    const proxied = address_of(arena, .{ 127, 0, 0, 1 }, "1.1.1.1, 5.6.7.8");

    try std.testing.expectEqualStrings("5.6.7.8", proxied);
    try std.testing.expectEqualStrings("127.0.0.1", address_of(arena, .{ 127, 0, 0, 1 }, null));
    try std.testing.expectEqualStrings("", address_of(arena, null, "1.2.3.4"));
}
