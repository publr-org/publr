const std = @import("std");
const db = @import("lib/db.zig");
const auth = @import("lib/auth.zig");
const deps = @import("lib/deps.zig");
const registry = @import("server/registry.zig");
const sdk = @import("sdk.zig");
const builtin = @import("builtin");

/// The sandbox runs plugins natively; the browser build has none yet.
pub const sandboxed_plugins = if (builtin.os.tag == .wasi)
    void
else
    @import("server/sandboxed_plugins.zig");
const SandboxHost = if (builtin.os.tag == .wasi) void else sandboxed_plugins.Host;
const PluginStates = @import("server/plugin_states.zig").States;

pub const db_heap_bytes: u32 = 64 << 20;
pub const request_arena_bytes: u32 = 4 << 20;

pub const Server = struct {
    gpa: std.mem.Allocator,
    heap: []align(8) u8,
    runtime: db.Runtime,
    connection: db.Db,
    auth: auth.State,
    index: deps.Index,
    sandboxed_plugins: SandboxHost,
    /// Every compiled-in plugin's `State`.
    plugin_states: PluginStates,

    pub fn init(server: *Server, process: std.process.Init, db_path: [:0]const u8) !void {
        std.debug.assert(db_path.len > 0);
        std.debug.assert(db_heap_bytes >= db.heap_bytes_min);

        try ensure_parent_dir(process.io, db_path);

        server.gpa = process.gpa;
        server.heap = try reserve_heap(process.gpa);
        errdefer release_heap(process.gpa, server.heap);

        server.runtime = try db.Runtime.init(.{ .heap = server.heap });
        errdefer server.runtime.deinit();

        server.connection = try db.open(&server.runtime, db_path);
        errdefer server.connection.close();

        try db.schema.apply(&server.connection);
        try registry.SDK.apply_schemas(&server.connection);
        server.index = try deps.Index.open(&server.connection, .{ .quiet_ms = deps.quiet_ms });
        try server.auth.init(process.gpa, process.io, .{});
        errdefer server.auth.deinit();

        try server.apply_declared_types(process);

        if (SandboxHost != void) {
            const dir = try sandboxed_plugins_dir(process.arena.allocator(), db_path);

            try server.sandboxed_plugins.init(process.gpa, process.io, dir);
            errdefer server.sandboxed_plugins.deinit();

            try server.sandboxed_plugins.load_all(&server.connection);
        }

        try server.plugin_states.init(.{
            .io = process.io,
            .gpa = process.gpa,
            .arena = process.arena.allocator(),
            .db_path = db_path,
            .runtime = &server.runtime,
        });

        std.debug.assert(server.runtime.open_count == 1);
    }

    /// What every context this server makes carries: the installed plugins, or none.
    pub fn sandboxed(server: *Server) ?*const sdk.sandboxed_plugins.SandboxedPlugins {
        std.debug.assert(server.runtime.open_count == 1);

        if (SandboxHost == void) {
            return null;
        }

        return server.sandboxed_plugins.sandboxed_plugins();
    }

    fn apply_declared_types(server: *Server, process: std.process.Init) !void {
        std.debug.assert(server.connection.transaction_depth == 0);
        std.debug.assert(request_arena_bytes > 0);

        var arena_state = std.heap.ArenaAllocator.init(process.gpa);
        defer arena_state.deinit();

        var ctx = sdk.Ctx.init(.{
            .caller = .system,
            .db = &server.connection,
            .io = process.io,
            .arena = arena_state.allocator(),
            .auth = &server.auth,
            .now_ms = sdk.context.wall_clock_ms(process.io),
        });

        try registry.SDK.bootstrap(&ctx);
    }

    pub fn deinit(server: *Server) void {
        std.debug.assert(server.runtime.open_count == 1);
        std.debug.assert(server.connection.transaction_depth == 0);

        server.plugin_states.deinit();

        if (SandboxHost != void) {
            server.sandboxed_plugins.deinit();
        }

        server.auth.deinit();
        server.connection.close();
        server.runtime.deinit();
        release_heap(server.gpa, server.heap);
        server.* = undefined;
    }
};

/// SQLite's heap, reserved but not written: the generic `alloc` fills new memory with
/// `undefined`, which safe builds write out, and 64 MiB would be resident from the first
/// second whatever the database needs. The raw path commits pages as SQLite touches them.
fn reserve_heap(gpa: std.mem.Allocator) error{OutOfMemory}![]align(8) u8 {
    std.debug.assert(db_heap_bytes >= db.heap_bytes_min);
    std.debug.assert(std.math.isPowerOfTwo(db_heap_bytes));

    const ptr = gpa.rawAlloc(db_heap_bytes, heap_alignment, @returnAddress()) orelse
        return error.OutOfMemory;

    return @alignCast(ptr[0..db_heap_bytes]);
}

fn release_heap(gpa: std.mem.Allocator, heap: []align(8) u8) void {
    std.debug.assert(heap.len == db_heap_bytes);
    std.debug.assert(db_heap_bytes > 0);

    gpa.rawFree(heap, heap_alignment, @returnAddress());
}

const heap_alignment: std.mem.Alignment = .@"8";

/// `plugins/` beside the database file.
fn sandboxed_plugins_dir(arena: std.mem.Allocator, db_path: []const u8) ![]const u8 {
    std.debug.assert(db_path.len > 0);

    const parent = std.fs.path.dirname(db_path) orelse ".";

    return std.fs.path.join(arena, &.{ if (parent.len == 0) "." else parent, "plugins" });
}

fn ensure_parent_dir(io: std.Io, path: []const u8) !void {
    std.debug.assert(path.len > 0);

    const parent = std.fs.path.dirname(path) orelse return;

    if (parent.len == 0) {
        return;
    }

    std.debug.assert(parent.len < path.len);

    try std.Io.Dir.cwd().createDirPath(io, parent);
}

test {
    if (SandboxHost != void) {
        _ = sandboxed_plugins;
    }
}
