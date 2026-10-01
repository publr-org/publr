const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const operation = @import("operation.zig");

pub const list_len_max: u32 = 64;
pub const resolvers_max: u32 = 8;

pub const Decision = enum { allow, deny };

pub const Row = struct {
    record_id: []const u8,
    type_id: []const u8,
    status: []const u8,
    owner_id: ?[]const u8,
};

pub const Resolver = *const fn (ctx: *const Ctx, row: Row) bool;

pub const RecordFilter = struct {
    flags: Flags = .{},
    resolvers: [resolvers_max]Resolver = undefined,
    resolvers_len: u8 = 0,

    pub const Flags = packed struct(u8) {
        own_only: bool = false,
        live_only: bool = false,
        public_types_only: bool = false,
        _padding: u5 = 0,
    };

    pub fn add_resolver(filter: *RecordFilter, resolver: Resolver) void {
        std.debug.assert(filter.resolvers_len < resolvers_max);
        filter.resolvers[filter.resolvers_len] = resolver;
        filter.resolvers_len += 1;
    }

    pub fn accepts(filter: *const RecordFilter, ctx: *const Ctx, row: Row) bool {
        std.debug.assert(filter.resolvers_len <= resolvers_max);
        std.debug.assert(row.record_id.len > 0);

        if (filter.flags.own_only) {
            const owner = row.owner_id orelse return false;
            const me = ctx.caller.user_id() orelse return false;
            if (!std.mem.eql(u8, owner, me)) {
                return false;
            }
        }

        for (filter.resolvers[0..filter.resolvers_len]) |resolve| {
            if (!resolve(ctx, row)) {
                return false;
            }
        }

        return true;
    }

    fn merge(left: RecordFilter, right: RecordFilter) RecordFilter {
        std.debug.assert(left.resolvers_len <= resolvers_max);
        std.debug.assert(left.resolvers_len + right.resolvers_len <= resolvers_max);

        var out = left;

        out.flags = @bitCast(@as(u8, @bitCast(left.flags)) | @as(u8, @bitCast(right.flags)));

        for (right.resolvers[0..right.resolvers_len]) |resolver| out.add_resolver(resolver);

        return out;
    }
};

pub const Transition = struct { from: []const u8, to: []const u8 };

pub const Grant = struct {
    decision: Decision = .allow,
    read_only: bool = false,
    types: ?[]const []const u8 = null,
    /// The plugins whose content types are in reach: a type a plugin outside this list owns
    /// is not, one no plugin owns always is. Null: every plugin's.
    plugins: ?[]const []const u8 = null,
    statuses: ?[]const []const u8 = null,
    field_mask: []const []const u8 = &.{},
    transitions: ?[]const Transition = null,
    record_filter: RecordFilter = .{},

    pub const deny: Grant = .{ .decision = .deny };
    pub const allow_all: Grant = .{};

    pub fn allows(grant: *const Grant) bool {
        return grant.decision == .allow;
    }

    pub fn allows_type(grant: *const Grant, type_id: []const u8) bool {
        const list = grant.types orelse return true;
        return contains(list, type_id);
    }

    /// Whether a type owned by `owner` (empty: no plugin, the project's own) is in reach.
    pub fn allows_owner(grant: *const Grant, owner: []const u8) bool {
        std.debug.assert(owner.len <= 64);

        const list = grant.plugins orelse return true;

        if (owner.len == 0) {
            return true;
        }

        return contains(list, owner);
    }

    pub fn allows_status(grant: *const Grant, status: []const u8) bool {
        const list = grant.statuses orelse return true;
        return contains(list, status);
    }

    pub fn allows_transition(grant: *const Grant, from: []const u8, to: []const u8) bool {
        std.debug.assert(from.len > 0);
        std.debug.assert(to.len > 0);

        const list = grant.transitions orelse return true;

        for (list) |transition| {
            const from_any = std.mem.eql(u8, transition.from, "*");
            const from_ok = from_any or std.mem.eql(u8, transition.from, from);
            if (from_ok and std.mem.eql(u8, transition.to, to)) {
                return true;
            }
        }

        return false;
    }

    pub fn masks_field(grant: *const Grant, field: []const u8) bool {
        return contains(grant.field_mask, field);
    }

    pub fn intersect(left: Grant, right: Grant, arena: std.mem.Allocator) operation.Error!Grant {
        if (left.decision == .deny or right.decision == .deny) {
            return deny;
        }

        std.debug.assert(left.field_mask.len <= list_len_max);
        std.debug.assert(right.field_mask.len <= list_len_max);

        return .{
            .read_only = left.read_only or right.read_only,
            .types = try intersect_lists(left.types, right.types, arena),
            .plugins = try intersect_lists(left.plugins, right.plugins, arena),
            .statuses = try intersect_lists(left.statuses, right.statuses, arena),
            .field_mask = try union_lists(left.field_mask, right.field_mask, arena),
            .transitions = if (left.transitions != null) left.transitions else right.transitions,
            .record_filter = RecordFilter.merge(left.record_filter, right.record_filter),
        };
    }
};

fn contains(list: []const []const u8, item: []const u8) bool {
    std.debug.assert(list.len <= list_len_max);
    std.debug.assert(item.len > 0);

    for (list) |candidate| {
        if (std.mem.eql(u8, candidate, item)) {
            return true;
        }
    }

    return false;
}

fn intersect_lists(
    left_or_null: ?[]const []const u8,
    right_or_null: ?[]const []const u8,
    arena: std.mem.Allocator,
) operation.Error!?[]const []const u8 {
    const left = left_or_null orelse return right_or_null;
    const right = right_or_null orelse return left_or_null;

    std.debug.assert(left.len <= list_len_max);
    std.debug.assert(right.len <= list_len_max);

    var out = arena.alloc([]const u8, left.len) catch return error.OutOfMemory;
    var len: u32 = 0;

    for (left) |item| {
        if (contains(right, item)) {
            out[len] = item;
            len += 1;
        }
    }

    return out[0..len];
}

fn union_lists(
    left: []const []const u8,
    right: []const []const u8,
    arena: std.mem.Allocator,
) operation.Error![]const []const u8 {
    std.debug.assert(left.len <= list_len_max);
    std.debug.assert(right.len <= list_len_max);

    var out = arena.alloc([]const u8, left.len + right.len) catch return error.OutOfMemory;
    var len: u32 = 0;

    for (left) |item| {
        out[len] = item;
        len += 1;
    }

    for (right) |item| {
        if (!contains(left, item)) {
            out[len] = item;
            len += 1;
        }
    }

    return out[0..len];
}

test "intersect: deny wins, lists intersect, masks union, flags or" {
    var buffer: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const arena = fixed.allocator();

    const left: Grant = .{
        .types = &.{ "post", "page" },
        .field_mask = &.{"secret"},
        .record_filter = .{ .flags = .{ .own_only = true } },
    };
    const right: Grant = .{
        .types = &.{ "page", "tag" },
        .statuses = &.{"published"},
        .field_mask = &.{ "secret", "internal" },
        .record_filter = .{ .flags = .{ .live_only = true } },
    };

    const both = try Grant.intersect(left, right, arena);

    try std.testing.expect(both.allows());
    try std.testing.expect(both.allows_type("page"));
    try std.testing.expect(!both.allows_type("post"));
    try std.testing.expect(!both.allows_type("tag"));
    try std.testing.expect(both.allows_status("published"));
    try std.testing.expect(!both.allows_status("draft"));
    try std.testing.expect(both.masks_field("internal"));
    try std.testing.expectEqual(@as(u32, 2), @as(u32, @intCast(both.field_mask.len)));
    try std.testing.expect(both.record_filter.flags.own_only);
    try std.testing.expect(both.record_filter.flags.live_only);

    const denied = try Grant.intersect(left, Grant.deny, arena);
    try std.testing.expect(!denied.allows());
}

test "plugins: the project's own types always, a plugin's only when listed" {
    var buffer: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const arena = fixed.allocator();
    const every: Grant = .{};
    const site: Grant = .{ .plugins = &.{ "newsletter", "seo" } };

    try std.testing.expect(every.allows_owner("shop"));
    try std.testing.expect(site.allows_owner(""));
    try std.testing.expect(site.allows_owner("seo"));
    try std.testing.expect(!site.allows_owner("shop"));

    const narrowed = try Grant.intersect(site, .{ .plugins = &.{"seo"} }, arena);
    try std.testing.expect(narrowed.allows_owner("seo"));
    try std.testing.expect(!narrowed.allows_owner("newsletter"));
    try std.testing.expect((try Grant.intersect(every, site, arena)).allows_owner("newsletter"));
}

test "record filter: own_only and resolver chain" {
    var harness: @import("../sdk.zig").testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.{ .user = .{ .id = "u_1" } });

    var filter: RecordFilter = .{ .flags = .{ .own_only = true } };
    const mine: Row = .{
        .record_id = "e_1",
        .type_id = "post",
        .status = "draft",
        .owner_id = "u_1",
    };
    const theirs: Row = .{
        .record_id = "e_2",
        .type_id = "post",
        .status = "draft",
        .owner_id = "u_9",
    };

    try std.testing.expect(filter.accepts(&ctx, mine));
    try std.testing.expect(!filter.accepts(&ctx, theirs));

    filter.add_resolver(&reject_posts);
    try std.testing.expect(!filter.accepts(&ctx, mine));
}

fn reject_posts(_: *const Ctx, row: Row) bool {
    return !std.mem.eql(u8, row.type_id, "post");
}
