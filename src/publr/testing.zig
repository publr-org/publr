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
const Problem = @import("operation.zig").Problem;
const PluginStates = @import("../server/plugin_states.zig").States;
const Error = @import("operation.zig").Error;
const public_of = @import("../sdk/operation.zig").public_of;
const callers = @import("testing/who.zig");

pub const Who = callers.Who;
pub const Device = callers.Device;
pub const User = callers.User;
pub const Plugin = callers.Plugin;

/// How many queued jobs `drain` runs at most in one pass.
const drained_max: u32 = 64;

/// What a site runs on, Publr's own: held apart from `Site`, whose fields a test sees.
const Held = struct {
    harness: sdk.testing.Harness,
    /// Every built-in plugin's `State`, made as `serve` makes them, for the calls made here.
    states: PluginStates,
};

pub const Site = struct {
    /// Publr's own site behind the test's, made by `init`.
    held: *anyopaque,
    /// What `json` answers lives here, until `deinit`.
    keep: std.heap.ArenaAllocator,
    /// The site's time for every call: set it to move the clock.
    now_ms: i64 = 1_800_000_000_000,
    /// A development site, whose clock its operations may move (`clock.*`).
    development: bool = false,
    /// The refusal the last call came back with as `error.Failed`, by its `Fails:` name.
    failure: []const u8 = "",
    /// What the last call's `error.Invalid` found wrong (`problems`).
    refused: []const Problem = &.{},
    /// An empty site with every plugin of the build: its tables and what each sets up.
    pub fn init(site: *Site) Error!void {
        const held = try std.testing.allocator.create(Held);
        errdefer std.testing.allocator.destroy(held);

        site.held = held;

        // A site that cannot be made in memory is one the test cannot run on.
        site.backing().harness.init() catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Unavailable,
        };
        errdefer site.backing().harness.deinit();

        site.keep = .init(std.testing.allocator);
        errdefer site.keep.deinit();

        site.now_ms = 1_800_000_000_000;
        site.development = false;
        site.failure = "";
        site.refused = &.{};

        var system = site.backing().harness.ctx(.system);

        SDK.apply_schemas(system.db) catch |err| return public_of(err);
        SDK.bootstrap(&system) catch |err| return public_of(err);
        site.backing().harness.fixed.reset();

        // A state that cannot be made here is one the test cannot run with.
        site.backing().states.init(.{
            .io = std.testing.io,
            .gpa = std.testing.allocator,
            .arena = site.keep.allocator(),
            .db_path = ":memory:",
            .runtime = @ptrCast(&site.backing().harness.fixture.runtime),
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Unavailable,
        };

        std.debug.assert(site.backing().harness.fixture.connection.transaction_depth == 0);
    }

    pub fn deinit(site: *Site) void {
        std.debug.assert(site.backing().harness.fixture.connection.transaction_depth == 0);

        site.backing().states.deinit();
        site.keep.deinit();
        site.backing().harness.deinit();
        std.testing.allocator.destroy(site.backing());
    }

    fn backing(site: *const Site) *Held {
        return @ptrCast(@alignCast(site.held));
    }

    /// Whether the build has an operation by this name: a test of a plugin that hooks
    /// another skips without it.
    pub fn has(site: *const Site, comptime name: []const u8) bool {
        std.debug.assert(name.len > 0);
        _ = site;

        return comptime SDK.find(name) != null;
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
    pub fn ctx(site: *Site, who: Who) Error!*Ctx {
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
        std.debug.assert(site.backing().harness.buffer.len > 0);

        return .{
            .runtime = @ptrCast(&site.backing().harness.fixture.runtime),
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
        site.backing().harness.fixed.reset();
        site.failure = "";
        site.refused = &.{};

        var made = site.backing().harness.ctx(callers.caller_of(who));

        switch (who) {
            .visitor => |id| made.visitor = id,
            .user => |user| made.visitor = user.visitor,
            .device => |device| made.visitor = device.user.visitor,
            .plugin => |plugin| {
                made.visitor = plugin.visitor;
                made.plugin = plugin.name;
                made.plugin_code = true;
            },
            .system, .admin => {},
        }

        made.plugin_states = &site.backing().states;
        made.now_ms = site.now_ms;
        made.test_clock = site.development;

        std.debug.assert(made.now_ms > 0);

        return made;
    }

    /// What was wrong with the input when the last call came back with `error.Invalid`,
    /// beside each field (a record's `validate`, a field's limits); empty for any other end.
    /// It lives until `deinit`.
    pub fn problems(site: *const Site) []const Problem {
        std.debug.assert(site.refused.len <= sdk.operation.problems_max);

        return site.refused;
    }

    fn note(site: *Site, inner: *const sdk.Ctx, err: anyerror) void {
        std.debug.assert(site.failure.len == 0);
        std.debug.assert(site.refused.len == 0);

        if (err == error.Invalid) {
            site.refused = site.kept_problems(inner.problems) catch &.{};

            return;
        }

        if (err != error.Failed) {
            return;
        }

        const failure = inner.failure orelse return;

        site.failure = site.keep.allocator().dupe(u8, failure.name) catch "";
    }

    fn kept_problems(site: *Site, given: []const Problem) error{OutOfMemory}![]const Problem {
        std.debug.assert(given.len <= sdk.operation.problems_max);

        const memory = site.keep.allocator();
        const kept = try memory.alloc(Problem, given.len);

        for (given, kept) |problem, *one| {
            one.* = .{
                .field = try memory.dupe(u8, problem.field),
                .message = try memory.dupe(u8, problem.message),
            };
        }

        return kept;
    }
};

test {
    _ = @import("testing/tests.zig");
}
