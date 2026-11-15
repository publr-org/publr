//! Transient plugins: sandboxed plugins a server is started with (`serve --plugin <file>`),
//! for that server alone. Never installed: no row, no file in the data folder. Each asks for
//! what it needs and holds it, as the person who started the server chose it. What it keeps
//! lives in a database in memory, made for the server and gone with it: its types are
//! defined there, and its record calls on its own types are answered there.
const std = @import("std");
const wasm = @import("publr_wasm");
const db = @import("../../lib/db.zig");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const json = @import("../../lib/json.zig");
const registry = @import("../registry.zig");
const lifecycle = @import("../../operations/plugin/lifecycle.zig");
const plugin_manifest = @import("../../sdk/plugin/manifest.zig");
const AuthState = @import("../../lib/auth.zig").State;

const sandboxed_plugin = model.sandboxed_plugin;

pub const transients_max: u32 = 8;
const module_bytes_max: u32 = 64 << 20;

/// One transient plugin: its module as read, and the row it loads from as an installed one
/// does.
pub const Plugin = struct {
    bytes: []const u8,
    row: store.sandboxed_plugins.Row,
};

pub const Transient = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arena_state: std.heap.ArenaAllocator,
    runtime: db.Runtime,
    connection: db.Db,
    /// The server's own: sessions and secrets are the site's.
    auth: *AuthState,
    plugins: []const Plugin,

    /// Every module at `paths` read and checked, and the memory database made, each plugin's
    /// types defined in it.
    pub fn open(
        transient: *Transient,
        gpa: std.mem.Allocator,
        io: std.Io,
        auth: *AuthState,
        paths: []const []const u8,
    ) !void {
        std.debug.assert(paths.len > 0);
        std.debug.assert(paths.len <= transients_max);

        transient.* = .{
            .gpa = gpa,
            .io = io,
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .runtime = try db.Runtime.init(.{}),
            .connection = undefined,
            .auth = auth,
            .plugins = &.{},
        };
        errdefer transient.arena_state.deinit();
        errdefer transient.runtime.deinit();

        transient.connection = try db.open(&transient.runtime, ":memory:");
        errdefer transient.connection.close();

        try db.schema.apply(&transient.connection);

        const arena = transient.arena_state.allocator();
        var plugins: std.ArrayList(Plugin) = .empty;

        for (paths) |path| {
            try plugins.append(arena, try read(arena, io, path));
        }

        transient.plugins = plugins.items;
        try transient.define();
    }

    pub fn close(transient: *Transient) void {
        std.debug.assert(transient.connection.transaction_depth == 0);
        std.debug.assert(transient.plugins.len <= transients_max);

        transient.connection.close();
        transient.runtime.deinit();
        transient.arena_state.deinit();
    }

    /// The core's own declared types and roles, then each plugin's, in the memory database.
    fn define(transient: *Transient) !void {
        std.debug.assert(transient.connection.transaction_depth == 0);

        var arena_state = std.heap.ArenaAllocator.init(transient.gpa);
        defer arena_state.deinit();

        const arena = arena_state.allocator();
        const now_ms = sdk.context.wall_clock_ms(transient.io);
        const connection = &transient.connection;
        var ctx = sdk.Ctx.init(connection, transient.io, arena, transient.auth, .system, .{
            .now_ms = now_ms,
        });

        try registry.SDK.bootstrap(&ctx);

        for (transient.plugins) |plugin| {
            const text = plugin.row.manifest;
            const manifest = try json.parse(sandboxed_plugin.Manifest, arena, text, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            });

            var transaction = try transient.connection.transaction();
            errdefer transaction.rollback();

            try lifecycle.apply_types(&ctx, &manifest);
            try transaction.commit();
        }
    }

    /// `ctx` answering from the memory database, for a transient plugin's record call on its
    /// own types: nothing it does reaches the site's database, its logs or its hooks.
    pub fn context_of(transient: *Transient, ctx: *const sdk.Ctx) sdk.Ctx {
        std.debug.assert(ctx.plugin.len > 0);

        var held = ctx.*;

        held.db = &transient.connection;
        held.trail = null;
        held.kept_events = null;
        held.notify = null;
        held.parent = null;

        return held;
    }
};

/// The module at `path`, its manifest read from it and everything it asks for granted.
fn read(arena: std.mem.Allocator, io: std.Io, path: []const u8) !Plugin {
    std.debug.assert(path.len > 0);

    const limit: std.Io.Limit = .limited(module_bytes_max);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit) catch |err| {
        std.log.err("--plugin {s}: {t}", .{ path, err });
        return err;
    };
    const text = wasm.section.find(bytes, plugin_manifest.section_name) catch {
        std.log.err("--plugin {s}: not a plugin built for Publr", .{path});
        return error.NotAPlugin;
    } orelse {
        std.log.err("--plugin {s}: not a plugin built for Publr", .{path});
        return error.NotAPlugin;
    };
    const manifest = try json.parse(sandboxed_plugin.Manifest, arena, text, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });

    if (!sandboxed_plugin.valid_name(manifest.name)) {
        return error.NotAPlugin;
    }

    return .{
        .bytes = bytes,
        .row = try row_of(arena, &manifest, text),
    };
}

/// The row an installed plugin would have once every request was granted, never stored.
fn row_of(
    arena: std.mem.Allocator,
    manifest: *const sandboxed_plugin.Manifest,
    text: []const u8,
) !store.sandboxed_plugins.Row {
    std.debug.assert(manifest.name.len > 0);

    const asked = try sandboxed_plugin.requests(manifest, arena);
    var keys: std.ArrayList([]const u8) = .empty;
    var grants: std.ArrayList(model.permission.Held) = .empty;

    for (asked) |request| {
        try keys.append(arena, request.key);
    }

    for (manifest.permissions) |*ask| {
        try grants.append(arena, ask.held());
    }

    return .{
        .name = manifest.name,
        .version = manifest.version,
        .hash = "",
        .manifest = text,
        .enabled = true,
        .granted = try std.json.Stringify.valueAlloc(arena, keys.items, .{}),
        .denied = "[]",
        .grants = try std.json.Stringify.valueAlloc(arena, grants.items, .{}),
        .next_version = null,
        .next_hash = null,
        .next_manifest = null,
        .previous_version = null,
        .previous_hash = null,
        .previous_manifest = null,
        .installed_at = 0,
        .updated_at = 0,
    };
}

/// Whether a transient plugin's call `name` with `input` is a record call on its own types
/// (or names no type: by id, only its own records are there to reach).
pub fn own_record_call(own_types: []const []const u8, name: []const u8, input: []const u8) bool {
    std.debug.assert(name.len > 0);

    if (!std.mem.startsWith(u8, name, "record.")) {
        return false;
    }

    const type_at = std.mem.indexOf(u8, input, "\"type\":\"") orelse return true;
    const start = type_at + "\"type\":\"".len;
    const end = std.mem.indexOfScalarPos(u8, input, start, '"') orelse return false;
    const named = input[start..end];

    for (own_types) |own| {
        if (std.mem.eql(u8, own, named)) {
            return true;
        }
    }

    return false;
}

test "a transient plugin's record calls on its own types are its own" {
    const own = [_][]const u8{"clone_progress.run"};

    const listed = "{\"type\":\"clone_progress.run\"}";

    try std.testing.expect(own_record_call(&own, "record.list", listed));
    try std.testing.expect(own_record_call(&own, "record.get", "{\"id\":\"abc\"}"));
    try std.testing.expect(!own_record_call(&own, "record.list", "{\"type\":\"post\"}"));
    try std.testing.expect(!own_record_call(&own, "user.list", "{}"));
}
