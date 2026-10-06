//! Files the module cannot reach itself: in the browser they live in OPFS, which only the
//! service worker can open, and only asynchronously. A read of a file the worker has not
//! handed over fails with `Needed` and names it; the worker attaches it and runs the request
//! again (a failed request rolls back, so a second run is safe). Writes and removals are
//! kept as effects, which the worker carries out once it has the response. Resized copies
//! are not kept.

const std = @import("std");
const files = @import("../files.zig");

const Area = files.Area;
const Error = files.Error;

pub const attachments_max: u32 = 8;
pub const effects_max: u32 = 64;

pub const Kind = enum(u8) { write, append, remove };

pub const Effect = struct {
    kind: Kind,
    area: Area,
    key: []u8,
    offset: u64 = 0,
    bytes: []u8 = &.{},
};

const Attachment = struct { area: Area, key: []u8, bytes: []u8 };

pub const Wanted = struct {
    area: Area,
    key_buffer: [files.key_len_max]u8 = undefined,
    key_len: u32 = 0,

    pub fn key(wanted: *const Wanted) []const u8 {
        std.debug.assert(wanted.key_len > 0);
        std.debug.assert(wanted.key_len <= files.key_len_max);

        return wanted.key_buffer[0..wanted.key_len];
    }
};

pub const Deferred = struct {
    gpa: std.mem.Allocator,
    attachments: [attachments_max]?Attachment = @splat(null),
    effects: [effects_max]Effect = undefined,
    effects_len: u32 = 0,
    /// The file the last request lacked, if it lacked one.
    needed: ?Wanted = null,

    pub fn init(gpa: std.mem.Allocator) Deferred {
        std.debug.assert(attachments_max > 0);
        std.debug.assert(effects_max > 0);

        return .{ .gpa = gpa };
    }

    pub fn deinit(deferred: *Deferred) void {
        std.debug.assert(deferred.effects_len <= effects_max);

        deferred.settle();
        deferred.* = undefined;
    }

    /// Before each run of a request: what the last run asked for and wrote is forgotten; the
    /// files handed over stay for the run again.
    pub fn begin(deferred: *Deferred) void {
        std.debug.assert(deferred.effects_len <= effects_max);

        deferred.drop_effects();
        deferred.needed = null;

        std.debug.assert(deferred.effects_len == 0);
    }

    /// Once the worker has the response and its effects: everything goes.
    pub fn settle(deferred: *Deferred) void {
        std.debug.assert(deferred.effects_len <= effects_max);

        deferred.begin();

        for (&deferred.attachments) |*slot| {
            const attachment = slot.* orelse continue;

            deferred.gpa.free(attachment.key);
            deferred.gpa.free(attachment.bytes);
            slot.* = null;
        }
    }

    /// Hands over a file's bytes, which the deferred store now owns (from its `gpa`).
    pub fn attach(deferred: *Deferred, area: Area, key: []const u8, bytes: []u8) Error!void {
        std.debug.assert(bytes.len <= files.bytes_max);

        if (!files.valid_key(key)) {
            return error.InvalidKey;
        }

        for (&deferred.attachments) |*slot| {
            if (slot.* != null) {
                continue;
            }

            slot.* = .{ .area = area, .key = try deferred.gpa.dupe(u8, key), .bytes = bytes };

            return;
        }

        return error.TooLarge;
    }

    pub fn done(deferred: *const Deferred) []const Effect {
        std.debug.assert(deferred.effects_len <= effects_max);

        return deferred.effects[0..deferred.effects_len];
    }

    pub fn read(
        deferred: *Deferred,
        allocator: std.mem.Allocator,
        area: Area,
        key: []const u8,
        limit: u32,
    ) Error![]u8 {
        std.debug.assert(files.valid_key(key));
        std.debug.assert(limit > 0);

        if (area == .cache) {
            return error.NotFound;
        }

        for (deferred.attachments) |slot| {
            const attachment = slot orelse continue;

            if (attachment.area != area or !std.mem.eql(u8, attachment.key, key)) {
                continue;
            }

            if (attachment.bytes.len > limit) {
                return error.TooLarge;
            }

            return allocator.dupe(u8, attachment.bytes);
        }

        if (try deferred.written(allocator, area, key, limit)) |bytes| {
            return bytes;
        }

        var wanted: Wanted = .{ .area = area, .key_len = @intCast(key.len) };

        @memcpy(wanted.key_buffer[0..key.len], key);

        if (deferred.needed == null) {
            deferred.needed = wanted;
        }

        return error.Needed;
    }

    /// The file as this run wrote it, when it did from its start: its effects, in order.
    fn written(
        deferred: *const Deferred,
        allocator: std.mem.Allocator,
        area: Area,
        key: []const u8,
        limit: u32,
    ) Error!?[]u8 {
        std.debug.assert(files.valid_key(key));
        std.debug.assert(deferred.effects_len <= effects_max);

        var start: ?u32 = null;

        for (deferred.done(), 0..) |effect, index| {
            const same = effect.area == area and std.mem.eql(u8, effect.key, key);

            const begins = effect.kind == .write or (effect.kind == .append and effect.offset == 0);

            if (same and begins) {
                start = @intCast(index);
            } else if (same and effect.kind == .remove) {
                start = null;
            }
        }

        const first = start orelse return null;
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(allocator);

        for (deferred.done()[first..]) |effect| {
            const same = effect.area == area and std.mem.eql(u8, effect.key, key);

            if (!same) {
                continue;
            }

            if (bytes.items.len + effect.bytes.len > limit) {
                return error.TooLarge;
            }

            try bytes.appendSlice(allocator, effect.bytes);
        }

        return try bytes.toOwnedSlice(allocator);
    }

    pub fn read_range(
        deferred: *Deferred,
        area: Area,
        key: []const u8,
        offset: u64,
        buffer: []u8,
    ) Error![]u8 {
        std.debug.assert(files.valid_key(key));
        std.debug.assert(buffer.len > 0);

        const whole = try deferred.read(deferred.gpa, area, key, files.bytes_max);
        defer deferred.gpa.free(whole);

        const start: u32 = @intCast(@min(offset, whole.len));
        const len = @min(buffer.len, whole.len - start);

        @memcpy(buffer[0..len], whole[start..][0..len]);

        return buffer[0..len];
    }

    pub fn write(deferred: *Deferred, area: Area, key: []const u8, bytes: []const u8) Error!void {
        std.debug.assert(files.valid_key(key));
        std.debug.assert(bytes.len <= files.bytes_max);

        if (area == .cache) {
            return;
        }

        try deferred.add(.write, area, key, 0, bytes);
    }

    pub fn append(
        deferred: *Deferred,
        area: Area,
        key: []const u8,
        offset: u64,
        bytes: []const u8,
    ) Error!u64 {
        std.debug.assert(files.valid_key(key));
        std.debug.assert(offset + bytes.len <= files.bytes_max);

        try deferred.add(.append, area, key, offset, bytes);

        return offset + bytes.len;
    }

    pub fn remove(deferred: *Deferred, area: Area, key: []const u8) void {
        std.debug.assert(files.valid_key(key));
        std.debug.assert(deferred.effects_len <= effects_max);

        deferred.add(.remove, area, key, 0, "") catch |err| {
            std.log.warn("media: could not remove {s}: {t}", .{ key, err });
        };
    }

    fn add(
        deferred: *Deferred,
        kind: Kind,
        area: Area,
        key: []const u8,
        offset: u64,
        bytes: []const u8,
    ) Error!void {
        std.debug.assert(files.valid_key(key));
        std.debug.assert(kind != .remove or bytes.len == 0);

        if (deferred.effects_len == effects_max) {
            return error.TooLarge;
        }

        const owned_key = try deferred.gpa.dupe(u8, key);
        errdefer deferred.gpa.free(owned_key);

        const owned_bytes = try deferred.gpa.dupe(u8, bytes);

        deferred.effects[deferred.effects_len] = .{
            .kind = kind,
            .area = area,
            .key = owned_key,
            .offset = offset,
            .bytes = owned_bytes,
        };
        deferred.effects_len += 1;
    }

    fn drop_effects(deferred: *Deferred) void {
        std.debug.assert(deferred.effects_len <= effects_max);

        for (deferred.effects[0..deferred.effects_len]) |effect| {
            deferred.gpa.free(effect.key);
            deferred.gpa.free(effect.bytes);
        }

        deferred.effects_len = 0;
    }
};

test "deferred: a missing file is named, an attached one read, writes kept as effects" {
    const gpa = std.testing.allocator;
    var deferred = Deferred.init(gpa);
    defer deferred.deinit();

    const stored: files.Files = .{ .deferred = &deferred };

    deferred.begin();
    try std.testing.expectError(error.Needed, stored.read(gpa, .files, "2026/10/cat.jpg", 64));
    try std.testing.expectEqualStrings("2026/10/cat.jpg", deferred.needed.?.key());
    try std.testing.expectEqual(Area.files, deferred.needed.?.area);

    try deferred.attach(.files, "2026/10/cat.jpg", try gpa.dupe(u8, "meow"));
    deferred.begin();
    try std.testing.expect(deferred.needed == null);

    const read = try stored.read(gpa, .files, "2026/10/cat.jpg", 64);
    defer gpa.free(read);

    try std.testing.expectEqualStrings("meow", read);
    try std.testing.expectError(error.TooLarge, stored.read(gpa, .files, "2026/10/cat.jpg", 2));
    try std.testing.expectError(error.NotFound, stored.read(gpa, .cache, "2026/10/cat.jpg", 64));

    try stored.write(.files, "2026/10/dog.jpg", "woof");
    try stored.write(.cache, "2026/10/dog_w2.jpg", "wo");
    try std.testing.expectEqual(@as(u64, 6), try stored.append(.incoming, "up1", 4, "ab"));
    stored.remove(.files, "2026/10/cat.jpg");

    const done = deferred.done();

    try std.testing.expectEqual(@as(usize, 3), done.len);
    try std.testing.expectEqual(Kind.write, done[0].kind);
    try std.testing.expectEqualStrings("woof", done[0].bytes);
    try std.testing.expectEqual(@as(u64, 4), done[1].offset);
    try std.testing.expectEqual(Kind.remove, done[2].kind);

    // A piece written after the start is not the file: the rest is in OPFS.
    try std.testing.expectError(error.Needed, stored.read(gpa, .incoming, "up1", 64));
    try std.testing.expectError(error.Needed, stored.read(gpa, .incoming, "up2", 64));

    try std.testing.expectEqual(@as(u64, 2), try stored.append(.incoming, "up2", 0, "ab"));
    try std.testing.expectEqual(@as(u64, 4), try stored.append(.incoming, "up2", 2, "cd"));

    const whole = try stored.read(gpa, .incoming, "up2", 64);
    defer gpa.free(whole);

    try std.testing.expectEqualStrings("abcd", whole);
    deferred.settle();
    try std.testing.expectEqual(@as(usize, 0), deferred.done().len);
    try std.testing.expectError(error.Needed, stored.read(gpa, .files, "2026/10/cat.jpg", 64));
}
