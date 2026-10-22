//! Keeps every structure change it hears, for the smoke.
//!
//! Keeps every structure change it hears, in its own table, and answers them back: what a
//! plugin recording deployments does, for the smoke to see each write heard `after` it ran.
//! Everything it brings takes the host's context, so its sandboxed build leaves it out.
//! Each as the write's name and what it changed (or the event's name and subject), oldest
//! first.
const std = @import("std");
const publr = @import("publr");

const sdk = publr.sdk;

const manifest: publr.Manifest = .{
    .name = "recorder",
    .version = "0.1.0",
};

const operations = [_]type{Seen};

pub const lines_max: u32 = 256;

/// Kept in the database, not in a state: its hook runs in the server's worker, its read in
/// the server.
const lines_table =
    \\CREATE TABLE IF NOT EXISTS recorder_lines (
    \\    id INTEGER PRIMARY KEY,
    \\    line TEXT NOT NULL
    \\) STRICT;
;

/// The writes that change the structure, each kept as `operation key` after it ran.
const changed_units = sdk.changed_units;
const structure = [_]changed_units.Kind{ .content_type, .taxonomy, .field_group, .plugin };
const hooks = changed_units.hooks(&structure, changed) ++ [_]type{Loaded};

fn changed(ctx: *sdk.Ctx, operation: []const u8, unit: changed_units.Unit) void {
    std.debug.assert(operation.len > 0);
    std.debug.assert(unit.key.len > 0);

    keep(ctx, operation, unit.key) catch |err| {
        std.log.warn("recorder: {s} not kept: {t}", .{ operation, err });
    };
}

/// The apps loaded from the folder: the server's own event, not a write.
pub const Loaded = struct {
    pub const stage: sdk.middleware.Stage = .on;
    pub const event = sdk.AppsLoaded.full_name;
    pub const Payload = sdk.AppsLoaded.Payload;
    pub const reason = "Keeps the apps loaded";

    pub fn run(ctx: *sdk.Ctx, loaded: Payload) void {
        std.debug.assert(ctx.now_ms >= 0);

        keep(ctx, event, loaded.app) catch |err| {
            std.log.warn("recorder: {s} not kept: {t}", .{ event, err });
        };
    }
};

fn keep(ctx: *sdk.Ctx, name: []const u8, subject: []const u8) !void {
    std.debug.assert(name.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const line = try std.fmt.allocPrint(ctx.arena, "{s} {s}", .{ name, subject });
    var insert = try ctx.db.prepare("INSERT INTO recorder_lines (line) VALUES (?1)");
    defer insert.finalize();

    try insert.bind_text(1, line);
    try insert.exec();
}

pub const Seen = struct {
    pub const name = "recorder.seen";
    pub const description = "The structure changes heard";
    pub const details = "Administrators only.";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        lines: []const []const u8,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .lines = &.{"content_type.create post"},
    };

    pub fn run(ctx: *sdk.Ctx, _: In, granted: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(granted.allows());

        var select = try ctx.db.prepare("SELECT line FROM recorder_lines ORDER BY id LIMIT ?1");
        defer select.finalize();

        try select.bind_int(1, lines_max);

        var lines: std.ArrayList([]const u8) = .empty;

        while (try select.step()) {
            std.debug.assert(lines.items.len < lines_max);
            const row = try select.read(struct {
                line: []const u8,
            }, ctx.arena);

            lines.append(ctx.arena, row.line) catch return error.OutOfMemory;
        }

        return .{
            .lines = lines.items,
        };
    }
};

pub const plugin = publr.plugin.define(manifest, .{
    .operations = operations,
    .hooks = hooks,
    .extend = extend,
});

fn extend(host: *publr.Host) publr.Error!void {
    try host.table(.{
        .name = "recorder_lines",
        .schema = lines_table,
    });
}
