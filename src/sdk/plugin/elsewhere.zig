//! A built-in plugin's reads on another database than the call's own
//! (`publr.Host.as_plugin_on`): another copy of the site, or this one as last committed. Each
//! call made through it runs as the plugin itself, held to its grants, on that database for
//! the length of the call: what this site's request read and cached is set aside meanwhile,
//! a write is refused, and nothing it raises is this site's (no event, no activity entry).
const std = @import("std");
const sdk = @import("../../sdk.zig");
const db = @import("../../lib/db.zig");
const registry = @import("../../server/registry.zig");
const context = @import("context.zig");

const HostApi = context.HostApi;
const Error = sdk.Error;

/// What the call's context holds of its own database while a call runs on another.
pub const Saved = struct {
    db: *db.Db,
    definitions: @FieldType(sdk.Ctx, "definitions"),
    site_currencies: @FieldType(sdk.Ctx, "site_currencies"),
    media_base: @FieldType(sdk.Ctx, "media_base"),
    sandboxed_plugins: @FieldType(sdk.Ctx, "sandboxed_plugins"),
    reads: @FieldType(sdk.Ctx, "reads"),
    prepared: @FieldType(sdk.Ctx, "prepared"),
    job_write: @FieldType(sdk.Ctx, "job_write"),
    reads_only: bool,
    elsewhere: bool,
};

/// The plugin's ctx making its calls on `database`, as itself with its grants.
pub fn as_plugin_on(api: *HostApi, database: *db.Db) Error!*context.PluginCtx {
    const inner = api.inner;

    std.debug.assert(inner.now_ms >= 0);

    // Core's own code is no plugin: it has no grants to act with.
    if (inner.plugin.len == 0) {
        return error.Denied;
    }

    if (database == inner.db) {
        return error.Invalid;
    }

    const made = inner.arena.create(HostApi) catch return error.OutOfMemory;

    made.* = .{
        .inner = inner,
        .reads = api.reads,
        .person = sdk.plugin_caller.alone(inner.plugin, registry.SDK.compiled_access(inner.plugin)),
        .elsewhere = database,
    };

    return made.ctx();
}

/// The call's context turned to `database` for one call; `put_back` undoes it.
pub fn turn(inner: *sdk.Ctx, database: *db.Db) Saved {
    std.debug.assert(database != inner.db);
    std.debug.assert(!inner.elsewhere);

    const saved: Saved = .{
        .db = inner.db,
        .definitions = inner.definitions,
        .site_currencies = inner.site_currencies,
        .media_base = inner.media_base,
        .sandboxed_plugins = inner.sandboxed_plugins,
        .reads = inner.reads,
        .prepared = inner.prepared,
        .job_write = inner.job_write,
        .reads_only = inner.reads_only,
        .elsewhere = inner.elsewhere,
    };

    inner.db = database;
    inner.definitions = null;
    inner.site_currencies = null;
    inner.media_base = null;
    inner.sandboxed_plugins = null;
    inner.reads = null;
    inner.prepared = null;
    inner.job_write = null;
    inner.reads_only = true;
    inner.elsewhere = true;

    return saved;
}

pub fn put_back(inner: *sdk.Ctx, saved: Saved) void {
    std.debug.assert(inner.elsewhere);
    std.debug.assert(saved.db != inner.db);

    inner.db = saved.db;
    inner.definitions = saved.definitions;
    inner.site_currencies = saved.site_currencies;
    inner.media_base = saved.media_base;
    inner.sandboxed_plugins = saved.sandboxed_plugins;
    inner.reads = saved.reads;
    inner.prepared = saved.prepared;
    inner.job_write = saved.job_write;
    inner.reads_only = saved.reads_only;
    inner.elsewhere = saved.elsewhere;
}

test "a plugin reads another database as itself, writes refused, its own put back after" {
    const project = @import("../../publr/operations/project.zig");
    const role = @import("../../publr/operations/role.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var other: db.testing.Fixture = undefined;
    try other.init();
    defer other.deinit();

    try other.connection.exec("INSERT INTO settings VALUES ('project.initialised_at', '1', 1)");

    var inner = harness.ctx(.{
        .user = .{
            .id = "u_1",
            .roles = &.{"admin"},
        },
    });
    var api: HostApi = .{
        .inner = &inner,
    };

    try std.testing.expectError(error.Denied, as_plugin_on(&api, &other.connection));

    inner.plugin = "hello";

    try std.testing.expectError(error.Invalid, as_plugin_on(&api, inner.db));

    const there = context.host_of(try as_plugin_on(&api, &other.connection));
    const seen = there.caller();

    try std.testing.expect(seen.user_id() == null);
    try std.testing.expect(!seen.system);
    try std.testing.expect((try there.call(project.Status, .{})).initialised);
    try std.testing.expect(!(try api.call(project.Status, .{})).initialised);
    // A write anyone may make is refused there all the same.
    try std.testing.expectError(error.Denied, there.call(project.Init, project.Init.example));
    try std.testing.expect(!there.may(role.Create));
    try std.testing.expect(inner.db == &harness.fixture.connection);
    try std.testing.expect(!inner.elsewhere and !inner.reads_only);
    try std.testing.expect(inner.caller == .user);
}
