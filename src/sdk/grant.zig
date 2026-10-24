const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const operation = @import("operation.zig");
const content_type = @import("../model/content_type.zig");
const plugin_contracts = @import("../model/plugin_contracts.zig");

pub const list_len_max: u32 = 64;

pub const Decision = enum { allow, deny };

pub const RecordFilter = struct {
    flags: Flags = .{},

    pub const Flags = packed struct(u8) {
        own_only: bool = false,
        live_only: bool = false,
        public_types_only: bool = false,
        /// Internal taxonomies are out of reach unless named (a wide read without
        /// `.internal`).
        named_internal_only: bool = false,
        _padding: u4 = 0,
    };

    /// Whether a record made by `owner_id` is in reach: any, unless `own_only` keeps the
    /// caller to their own.
    pub fn accepts(filter: *const RecordFilter, ctx: *const Ctx, owner_id: ?[]const u8) bool {
        std.debug.assert(ctx.now_ms >= 0);

        if (!filter.flags.own_only) {
            return true;
        }

        const owner = owner_id orelse return false;
        const me = ctx.caller.user_id() orelse return false;

        return std.mem.eql(u8, owner, me);
    }

    fn merge(left: RecordFilter, right: RecordFilter) RecordFilter {
        return .{
            .flags = @bitCast(@as(u8, @bitCast(left.flags)) | @as(u8, @bitCast(right.flags))),
        };
    }
};

pub const Grant = struct {
    decision: Decision = .allow,
    read_only: bool = false,
    types: ?[]const []const u8 = null,
    /// The plugins whose content types are in reach: a type a plugin outside this list owns
    /// is not, one no plugin owns always is. Null: every plugin's.
    plugins: ?[]const []const u8 = null,
    /// The app the caller reads for: only types living in it or shared with it are in
    /// reach. Null: every type, wherever it lives (the admin across apps, the CLI).
    app: ?[]const u8 = null,
    record_filter: RecordFilter = .{},
    /// The roles of the account calling, an administrator's excepted: a Private type with a
    /// role list is in reach only when one is held. Null: every type, whatever its roles.
    roles: ?[]const []const u8 = null,
    /// With `public_types_only`: the types reached whatever their kind (named in a plugin's
    /// grant, or its own).
    any_kind_types: []const []const u8 = &.{},
    /// With `live_only`: the types whose drafts are read all the same, and whether every
    /// public type's are (a plugin's `records.write`, its own types).
    draft_types: []const []const u8 = &.{},
    drafts_public: bool = false,
    /// The plugin reading, and what it uses of others: a record type it describes with
    /// `publr.remote.record` answers only the fields listed, and `Unavailable` while off.
    remote_user: []const u8 = "",
    remotes: []const plugin_contracts.Used = &.{},

    pub const deny: Grant = .{
        .decision = .deny,
    };
    pub const allow_all: Grant = .{};

    pub fn allows(grant: *const Grant) bool {
        return grant.decision == .allow;
    }

    pub fn allows_type(grant: *const Grant, type_id: []const u8) bool {
        const list = grant.types orelse return true;
        return contains(list, type_id);
    }

    /// Whether a Private type that `type_roles` reach (empty: every role) is in reach.
    pub fn reaches_roles(grant: *const Grant, type_roles: []const []const u8) bool {
        std.debug.assert(type_roles.len <= list_len_max);

        const held = grant.roles orelse return true;

        if (type_roles.len == 0) {
            return true;
        }

        for (held) |name| {
            if (contains(type_roles, name)) {
                return true;
            }
        }

        return false;
    }

    /// Whether a type owned by `owner` (empty or core's: the project's own) is in reach.
    pub fn allows_owner(grant: *const Grant, owner: []const u8) bool {
        std.debug.assert(owner.len <= 64);

        const list = grant.plugins orelse return true;

        if (owner.len == 0 or std.mem.eql(u8, owner, content_type.core_owner)) {
            return true;
        }

        return contains(list, owner);
    }

    /// Whether a type living in `home` (empty: Global) and shared as `shared` is in reach.
    pub fn allows_placement(
        grant: *const Grant,
        home: []const u8,
        shared: content_type.Shared,
    ) bool {
        std.debug.assert(home.len <= 64);

        const app = grant.app orelse return true;

        return content_type.reaches(home, shared, app);
    }

    /// Whether only public types are in reach for the type `handle`.
    pub fn public_only_on(grant: *const Grant, handle: []const u8) bool {
        std.debug.assert(handle.len > 0);
        std.debug.assert(grant.any_kind_types.len <= list_len_max);

        return grant.record_filter.flags.public_types_only and
            !contains(grant.any_kind_types, handle);
    }

    /// Whether the internal taxonomy `handle` is in reach: always, but for a wide read
    /// without `.internal`, which reaches it only by naming it.
    pub fn internal_on(grant: *const Grant, handle: []const u8) bool {
        std.debug.assert(handle.len > 0);
        std.debug.assert(grant.any_kind_types.len <= list_len_max);

        return !grant.record_filter.flags.named_internal_only or
            contains(grant.any_kind_types, handle);
    }

    /// Whether only live records of the type `handle` (public or not) are in reach.
    pub fn live_only_on(grant: *const Grant, handle: []const u8, public: bool) bool {
        std.debug.assert(handle.len > 0);
        std.debug.assert(grant.draft_types.len <= list_len_max);

        if (!grant.record_filter.flags.live_only) {
            return false;
        }

        return !(grant.drafts_public and public) and !contains(grant.draft_types, handle);
    }

    pub fn intersect(left: Grant, right: Grant, arena: std.mem.Allocator) operation.Error!Grant {
        if (left.decision == .deny or right.decision == .deny) {
            return deny;
        }

        std.debug.assert(left.any_kind_types.len <= list_len_max);
        std.debug.assert(right.any_kind_types.len <= list_len_max);

        return .{
            .read_only = left.read_only or right.read_only,
            .types = try intersect_lists(left.types, right.types, arena),
            .plugins = try intersect_lists(left.plugins, right.plugins, arena),
            .app = left.app orelse right.app,
            .roles = left.roles orelse right.roles,
            .record_filter = RecordFilter.merge(left.record_filter, right.record_filter),
            .any_kind_types = try exempt(
                left.record_filter.flags.public_types_only,
                left.any_kind_types,
                right.record_filter.flags.public_types_only,
                right.any_kind_types,
                arena,
            ),
            .draft_types = try exempt(
                left.record_filter.flags.live_only,
                left.draft_types,
                right.record_filter.flags.live_only,
                right.draft_types,
                arena,
            ),
            .drafts_public = drafts_public_of(left, right),
            .remote_user = if (left.remote_user.len > 0) left.remote_user else right.remote_user,
            .remotes = if (left.remotes.len > 0) left.remotes else right.remotes,
        };
    }

    /// The fields a remote record of type `handle` is read with; null when the type is no
    /// remote record of the reading plugin.
    pub fn remote_fields(
        grant: *const Grant,
        handle: []const u8,
    ) ?[]const plugin_contracts.UsedField {
        std.debug.assert(handle.len > 0);
        std.debug.assert(grant.remotes.len <= plugin_contracts.findings_max);

        for (grant.remotes) |used| {
            if (used.kind == .record and std.mem.eql(u8, used.name, handle)) {
                return used.fields;
            }
        }

        return null;
    }

    fn drafts_public_of(left: Grant, right: Grant) bool {
        const left_live = left.record_filter.flags.live_only;
        const right_live = right.record_filter.flags.live_only;

        std.debug.assert(left.decision == .allow);
        std.debug.assert(right.decision == .allow);

        if (left_live and right_live) {
            return left.drafts_public and right.drafts_public;
        }

        return if (left_live) left.drafts_public else right.drafts_public;
    }
};

/// What stays exempt from a narrowing flag when two grants meet: where both set the flag,
/// what both exempt; where one does, its own exemptions.
fn exempt(
    left_flag: bool,
    left: []const []const u8,
    right_flag: bool,
    right: []const []const u8,
    arena: std.mem.Allocator,
) operation.Error![]const []const u8 {
    std.debug.assert(left.len <= list_len_max);
    std.debug.assert(right.len <= list_len_max);

    if (left_flag and right_flag) {
        return (try intersect_lists(left, right, arena)) orelse &.{};
    }

    if (left_flag) {
        return left;
    }

    return if (right_flag) right else &.{};
}

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

test "intersect: deny wins, lists intersect, flags or" {
    var buffer: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const arena = fixed.allocator();

    const left: Grant = .{
        .types = &.{ "post", "page" },
        .record_filter = .{
            .flags = .{
                .own_only = true,
            },
        },
    };
    const right: Grant = .{
        .types = &.{ "page", "tag" },
        .record_filter = .{
            .flags = .{
                .live_only = true,
            },
        },
    };

    const both = try Grant.intersect(left, right, arena);

    try std.testing.expect(both.allows());
    try std.testing.expect(both.allows_type("page"));
    try std.testing.expect(!both.allows_type("post"));
    try std.testing.expect(!both.allows_type("tag"));
    try std.testing.expect(both.record_filter.flags.own_only);
    try std.testing.expect(both.record_filter.flags.live_only);

    const denied = try Grant.intersect(left, Grant.deny, arena);
    try std.testing.expect(!denied.allows());
}

test "exemptions: what both grants exempt from a flag both set, else the setter's own" {
    var buffer: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const arena = fixed.allocator();
    const visitor: Grant = .{
        .record_filter = .{
            .flags = .{
                .live_only = true,
                .public_types_only = true,
            },
        },
    };
    const plugin: Grant = .{
        .any_kind_types = &.{"notes"},
        .draft_types = &.{"notes"},
        .drafts_public = true,
        .record_filter = .{
            .flags = .{
                .live_only = true,
                .public_types_only = true,
            },
        },
    };
    const person: Grant = .{};

    const alone = try Grant.intersect(person, plugin, arena);

    try std.testing.expect(!alone.public_only_on("notes"));
    try std.testing.expect(alone.public_only_on("post"));
    try std.testing.expect(!alone.live_only_on("notes", false));
    try std.testing.expect(!alone.live_only_on("post", true));
    try std.testing.expect(alone.live_only_on("secret", false));

    const both = try Grant.intersect(visitor, plugin, arena);

    try std.testing.expect(both.public_only_on("notes"));
    try std.testing.expect(both.live_only_on("post", true));
}

test "plugins: the project's own types always, a plugin's only when listed" {
    var buffer: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const arena = fixed.allocator();
    const every: Grant = .{};
    const site: Grant = .{
        .plugins = &.{ "newsletter", "seo" },
    };

    try std.testing.expect(every.allows_owner("shop"));
    try std.testing.expect(site.allows_owner(""));
    try std.testing.expect(site.allows_owner(content_type.core_owner));
    try std.testing.expect(site.allows_owner("seo"));
    try std.testing.expect(!site.allows_owner("shop"));

    const narrowed = try Grant.intersect(site, .{
        .plugins = &.{"seo"},
    }, arena);
    try std.testing.expect(narrowed.allows_owner("seo"));
    try std.testing.expect(!narrowed.allows_owner("newsletter"));
    try std.testing.expect((try Grant.intersect(every, site, arena)).allows_owner("newsletter"));
}

test "record filter: own_only keeps the caller to their own" {
    var harness: @import("../sdk.zig").testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.{
        .user = .{
            .id = "u_1",
        },
    });

    const filter: RecordFilter = .{
        .flags = .{
            .own_only = true,
        },
    };

    try std.testing.expect(filter.accepts(&ctx, "u_1"));
    try std.testing.expect(!filter.accepts(&ctx, "u_9"));
    try std.testing.expect(!filter.accepts(&ctx, null));
    try std.testing.expect((RecordFilter{}).accepts(&ctx, "u_9"));
}
