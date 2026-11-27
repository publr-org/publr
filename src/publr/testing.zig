//! A site for a plugin's tests: an empty Publr in memory with every plugin of the build,
//! called as visitors, people and plugins call it. Only for `test` blocks.
//!
//! ```zig
//! var site: publr.testing.Site = undefined;
//! try site.init();
//! defer site.deinit();
//!
//! const placed = try site.call(Orders.Place, .admin, .{});
//! const listed = try site.json(.{ .visitor = "v_1" }, "orders.list", "{}");
//! _ = try site.drain();
//! ```
const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const HostApi = @import("../sdk/plugin/context.zig").HostApi;
const Ctx = @import("ctx.zig").Ctx;
const messaging = @import("messaging.zig");
const database = @import("extend/database.zig");

const SDK = registry.SDK;
const Error = @import("operation.zig").Error;
const public_of = @import("../sdk/operation.zig").public_of;

/// Who makes a call.
pub const Who = union(enum) {
    /// Publr itself, between requests.
    system,
    /// The site's administrator, `u_admin`.
    admin,
    /// A visitor with no account, by the stable id their browser carries (empty: none).
    visitor: []const u8,
    /// A signed-in account.
    user: User,
    /// A built-in plugin's own code, calling as itself.
    plugin: Plugin,
};

pub const User = struct {
    id: []const u8,
    roles: []const []const u8 = &.{},
    /// The visitor id their browser carries, on a site's pages.
    visitor: []const u8 = "",
};

pub const Plugin = struct {
    name: []const u8,
    /// The visitor its call came from, on a site's pages.
    visitor: []const u8 = "",
    /// The person its call came from; a visitor with no account when null.
    user: ?User = null,
};

/// How many queued jobs `drain` runs at most in one pass.
const drained_max: u32 = 64;

pub const Site = struct {
    harness: sdk.testing.Harness,
    /// What `json` answers lives here, until `deinit`.
    keep: std.heap.ArenaAllocator,
    /// The site's time for every call: set it to move the clock.
    now_ms: i64 = 1_800_000_000_000,
    /// A development site, whose clock its operations may move (`clock.*`).
    development: bool = false,
    /// The refusal the last call came back with as `error.Failed`, by its `Fails:` name.
    failure: []const u8 = "",

    /// An empty site with every plugin of the build: its tables and what each sets up.
    pub fn init(site: *Site) !void {
        try site.harness.init();
        errdefer site.harness.deinit();

        site.keep = .init(std.testing.allocator);
        site.now_ms = 1_800_000_000_000;
        site.development = false;
        site.failure = "";

        var system = site.harness.ctx(.system);

        try SDK.apply_schemas(system.db);
        try SDK.bootstrap(&system);
        site.harness.fixed.reset();

        std.debug.assert(site.harness.fixture.connection.transaction_depth == 0);
    }

    pub fn deinit(site: *Site) void {
        std.debug.assert(site.harness.fixture.connection.transaction_depth == 0);

        site.keep.deinit();
        site.harness.deinit();
    }

    /// Whether the build has an operation by this name: a test of a plugin that hooks
    /// another skips without it.
    pub fn has(site: *const Site, comptime name: []const u8) bool {
        std.debug.assert(name.len > 0);
        _ = site;

        inline for (registry.registry.operations) |Operation| {
            if (comptime std.mem.eql(u8, Operation.name, name)) {
                return true;
            }
        }

        return false;
    }

    /// Runs `Operation` as `who`; its answer lives until the next call.
    pub fn call(
        site: *Site,
        comptime Operation: type,
        who: Who,
        in: Operation.In,
    ) Error!Operation.Out {
        var inner = site.context(who);

        return SDK.dispatch(&inner, Operation, in) catch |err| {
            site.note(&inner, err);
            return public_of(err);
        };
    }

    /// Runs any operation by name as `who`, JSON in and out; the answer lives until `deinit`.
    pub fn json(site: *Site, who: Who, name: []const u8, input: []const u8) Error![]const u8 {
        std.debug.assert(name.len > 0);

        var inner = site.context(who);
        const out = SDK.call_json(&inner, name, input) catch |err| {
            site.note(&inner, err);
            return public_of(err);
        };

        return site.keep.allocator().dupe(u8, out);
    }

    /// Runs the jobs queued so far that are due (events' `on` hooks, `ctx.enqueue`), as the
    /// queue's worker does between requests: how many ran.
    pub fn drain(site: *Site) Error!u32 {
        var inner = site.context(.system);
        const ran = SDK.jobs.drain(&inner, drained_max) catch |err| return public_of(err);

        std.debug.assert(ran <= drained_max);

        return ran;
    }

    /// Hands `message` to the providers as core does from the queue: the provider's id for
    /// it, or null when none covered it. The id lives until `deinit`.
    pub fn deliver(site: *Site, message: messaging.Message) Error!?[]const u8 {
        std.debug.assert(message.channel.len > 0);

        return site.delivered(message) catch |err| return public_of(err);
    }

    fn delivered(site: *Site, message: messaging.Message) sdk.Error!?[]const u8 {
        std.debug.assert(message.channel.len > 0);

        var inner = site.context(.system);
        var transaction = try inner.db.transaction();
        errdefer transaction.rollback();

        inner.parent = inner.allocate_operation_id();

        const id = try @import("../sdk/messaging.zig").deliver(&inner, message);
        const kept = if (id) |one| try site.keep.allocator().dupe(u8, one) else null;

        try transaction.commit();

        return kept;
    }

    /// A `publr.Ctx` calling as `who`, for a plugin's own functions; it lives until the next
    /// call.
    pub fn ctx(site: *Site, who: Who) !*Ctx {
        const memory = site.keep.allocator();
        const inner = try memory.create(sdk.Ctx);
        const api = try memory.create(HostApi);

        inner.* = site.context(who);
        api.* = .{
            .inner = inner,
        };

        std.debug.assert(inner.now_ms == site.now_ms);

        return api.ctx();
    }

    /// Databases besides the site's own, by path, opened as a built-in plugin's `State`
    /// opens them (`process.databases()`).
    pub fn databases(site: *Site) database.Databases {
        std.debug.assert(site.harness.buffer.len > 0);

        return .{
            .runtime = @ptrCast(&site.harness.fixture.runtime),
        };
    }

    /// A new database at `path` with Publr's tables, empty, as a new site's: open in
    /// `memory` until its `close`.
    pub fn new_database(
        site: *Site,
        memory: std.mem.Allocator,
        path: [:0]const u8,
    ) Error!database.Database {
        std.debug.assert(path.len > 0);

        const opened = try site.databases().open(memory, path);
        errdefer opened.close(memory);

        try opened.apply_schema();

        return opened;
    }

    fn context(site: *Site, who: Who) sdk.Ctx {
        site.harness.fixed.reset();
        site.failure = "";

        var made = site.harness.ctx(caller_of(who));

        switch (who) {
            .visitor => |id| made.visitor = id,
            .user => |user| made.visitor = user.visitor,
            .plugin => |plugin| {
                made.visitor = plugin.visitor;
                made.plugin = plugin.name;
                made.plugin_code = true;
            },
            .system, .admin => {},
        }

        made.now_ms = site.now_ms;
        made.test_clock = site.development;

        std.debug.assert(made.now_ms > 0);

        return made;
    }

    fn note(site: *Site, inner: *const sdk.Ctx, err: anyerror) void {
        std.debug.assert(site.failure.len == 0);

        if (err != error.Failed) {
            return;
        }

        const failure = inner.failure orelse return;

        site.failure = site.keep.allocator().dupe(u8, failure.name) catch "";
    }
};

fn caller_of(who: Who) sdk.Caller {
    const user: ?User = switch (who) {
        .user => |user| user,
        .plugin => |plugin| plugin.user,
        .system, .admin, .visitor => null,
    };

    std.debug.assert(user == null or user.?.id.len > 0);

    return switch (who) {
        .system => .system,
        .admin => .{
            .user = .{
                .id = "u_admin",
            },
        },
        .visitor => .anonymous,
        .user, .plugin => if (user) |person| .{
            .user = .{
                .id = person.id,
                .roles = person.roles,
            },
        } else .anonymous,
    };
}

test "a site answers each caller as it would, runs its queue and opens other databases" {
    const roles = @import("operations/role.zig");

    var site: Site = undefined;
    try site.init();
    defer site.deinit();

    try std.testing.expect(site.has("role.list"));
    try std.testing.expect(!site.has("nobody.nothing"));

    const listed = try site.call(roles.List, .admin, .{});

    try std.testing.expect(listed.roles.len > 0);
    try std.testing.expectError(error.Denied, site.call(roles.List, .{
        .visitor = "v_1",
    }, .{}));
    try std.testing.expectError(error.Denied, site.call(roles.List, .{
        .plugin = .{
            .name = "nobody",
        },
    }, .{}));
    try std.testing.expectEqualStrings("", site.failure);

    const text = try site.json(.admin, "role.list", "{}");

    try std.testing.expect(std.mem.indexOf(u8, text, "\"admin\"") != null);
    try std.testing.expectError(error.Denied, site.json(.{
        .user = .{
            .id = "u_1",
        },
    }, "role.list", "{}"));

    site.now_ms = 1_900_000_000_000;

    const as_admin = try site.ctx(.admin);

    try std.testing.expectEqual(@as(i64, 1_900_000_000_000), as_admin.now().ms);
    try std.testing.expectEqualStrings("u_admin", as_admin.caller().user_id().?);
    _ = try site.drain();
    _ = try site.deliver(.{
        .channel = "email",
        .to = "ada@example.com",
        .subject = "Hello",
        .text = "Hello, Ada",
    });

    var folder = std.testing.tmpDir(.{});
    defer folder.cleanup();

    const memory = site.keep.allocator();
    const root = try folder.dir.realPathFileAlloc(std.testing.io, ".", memory);
    const path = try std.fmt.allocPrintSentinel(memory, "{s}/copy.db", .{root}, 0);
    const made = try site.new_database(memory, path);

    made.close(memory);

    const opened = try site.databases().open(memory, path);
    defer opened.close(memory);

    try opened.run("SELECT 1 FROM users LIMIT 0");

    const copied = try std.fmt.allocPrint(memory, "{s}/copied.db", .{root});

    try opened.copy_to(copied);

    const Any = @import("extend/database_any.zig").Any;
    var one = try opened.prepare("SELECT 1, 'a', NULL", .{});
    defer one.finalize();

    try std.testing.expect(try one.step());

    const read = try one.read(struct {
        number: Any,
        text: Any,
        nothing: Any,
    }, memory);

    try std.testing.expectEqual(@as(i64, 1), read.number.integer);
    try std.testing.expectEqualStrings("a", read.text.text);
    try std.testing.expect(read.nothing == .null);
    try std.testing.expect(!opened.in_transaction());
}
