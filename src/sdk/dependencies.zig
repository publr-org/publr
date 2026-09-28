const std = @import("std");

/// Explicit operation-owned read collection. Copies of Ctx carry it through nested SDK reads.
pub const Collector = struct {
    arena: std.mem.Allocator,
    parent: ?*Collector = null,
    keys: std.ArrayList([]const u8) = .empty,
    complete: bool = true,
    limit: u32 = 1024,

    pub fn add(self: *Collector, key: []const u8) void {
        std.debug.assert(key.len > 0);
        std.debug.assert(self.parent != self);

        if (self.parent) |parent| {
            parent.add(key);
        }

        for (self.keys.items) |known| {
            if (std.mem.eql(u8, known, key)) {
                return;
            }
        }

        if (self.keys.items.len >= self.limit) {
            self.complete = false;
            return;
        }

        const copy = self.arena.dupe(u8, key) catch {
            self.complete = false;
            return;
        };

        self.keys.append(self.arena, copy) catch {
            self.complete = false;
        };
    }

    pub fn depend(self: *Collector, prefix: []const u8, id: []const u8) void {
        std.debug.assert(prefix.len + id.len > 0);
        std.debug.assert(self.parent != self);

        var buffer: [1024]u8 = undefined;
        const key = std.fmt.bufPrint(&buffer, "{s}{s}", .{ prefix, id }) catch {
            self.complete = false;

            if (self.parent) |parent| {
                parent.complete = false;
            }

            return;
        };

        self.add(key);
    }
};

pub const Scope = struct { project: []const u8, authority: []const u8 };

/// Opaque tokens never expose record ids or permit reuse across sites/authorities.
pub fn token(
    arena: std.mem.Allocator,
    secret: []const u8,
    scope: Scope,
    key: []const u8,
) ![]const u8 {
    std.debug.assert(key.len > 0);

    if (secret.len < 32 or scope.project.len == 0 or scope.authority.len == 0) {
        return error.InvalidDependencyScope;
    }

    var mac = std.crypto.auth.hmac.sha2.HmacSha256.init(secret);

    for ([_][]const u8{ scope.project, scope.authority, key }) |part| {
        var length: [8]u8 = undefined;

        std.mem.writeInt(u64, &length, @intCast(part.len), .big);
        mac.update(&length);
        mac.update(part);
    }

    var digest: [32]u8 = undefined;

    mac.final(&digest);

    const hex = try std.fmt.allocPrint(arena, "{x}", .{digest});

    std.debug.assert(hex.len == digest.len * 2);

    return hex;
}

test "nested collection remains complete or explicitly fails closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parent: Collector = .{ .arena = arena.allocator() };
    var child: Collector = .{ .arena = arena.allocator(), .parent = &parent, .limit = 1 };

    child.depend("record:", "one");
    child.depend("record:", "two");
    try std.testing.expect(!child.complete);
    try std.testing.expect(parent.complete);
    try std.testing.expectEqual(@as(usize, 2), parent.keys.items.len);

    const secret = "s" ** 32;
    const first = try token(arena.allocator(), secret, .{
        .project = "one",
        .authority = "public",
    }, "record:one");
    const second = try token(arena.allocator(), secret, .{
        .project = "two",
        .authority = "public",
    }, "record:one");

    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expectError(error.InvalidDependencyScope, token(arena.allocator(), "short", .{
        .project = "one",
        .authority = "public",
    }, "record:one"));
}
