const std = @import("std");
const db = @import("../../lib/db.zig");
const report = @import("../../lib/report.zig");
const settings = @import("../../store/settings.zig");
const gate = @import("../gate.zig");
const operator = @import("../operator.zig");

const version = @import("../../publr.zig").version;
const conform = gate.conform;

/// `publr db conform [--dry-run]`: 0 when it is done or there is nothing to do, 2 when the
/// database is not one to conform (nothing changed), 1 when the result would still be refused.
pub fn run(
    init: std.process.Init,
    out: *std.Io.Writer,
    db_path: [:0]const u8,
    dry_run: bool,
) !u8 {
    std.debug.assert(db_path.len > 0);
    std.debug.assert(version.len > 0);

    const arena = init.arena.allocator();

    if (!dry_run) {
        if (try operator.find(init.io, arena, db_path)) |running| {
            report.err("publr db conform: a server runs for {s} on port {d}; stop it first", .{
                db_path,
                running.port,
            });
            return 2;
        }
    }

    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();
    var connection = try db.open(&runtime, db_path);
    defer connection.close();

    const conforming: conform.Conforming = .{
        .io = init.io,
        .runtime = &runtime,
        .release = version,
        .now_ms = @import("../../sdk.zig").context.wall_clock_ms(init.io),
    };
    const planned = conform.run(&connection, arena, conforming, .{
        .dry_run = true,
    }) catch |err| return failed(out, err);

    if (planned.refusal) |why| {
        try out.print("conform: refused: {s}; nothing was changed\n", .{why});
        return 2;
    }

    if (planned.nothing()) {
        try out.writeAll("conform: nothing to do\n");
        return 0;
    }

    if (dry_run) {
        try print(out, planned, null);
        return 0;
    }

    const site = try gate.backup.Site.of(init.io, arena, db_path, null);
    const before = try settings.get(&connection, arena, gate.release_key);
    const made = try gate.backup.make(site, &connection, arena, .{
        .from = before orelse "",
        .to = "conform",
        .at_ms = conforming.now_ms,
        .database = site.database,
    }, .{});
    const done = conform.run(&connection, arena, conforming, .{
        .left_out_path = try std.fs.path.join(arena, &.{ made, conform.left_out_name }),
    }) catch |err| return failed(out, err);

    std.debug.assert(done.refusal == null);
    try print(out, done, std.fs.path.basename(made));

    return 0;
}

fn failed(out: *std.Io.Writer, err: anyerror) !u8 {
    std.debug.assert(@errorName(err).len > 0);

    if (err != error.DatabaseRefused) {
        return err;
    }

    try out.writeAll("conform: the result would still be refused (above); nothing was changed\n");

    return 1;
}

/// One line per change and per thing left out, each with its kind first, then `backup` on
/// a real run, then the count.
fn print(out: *std.Io.Writer, outcome: conform.Outcome, backup: ?[]const u8) !void {
    std.debug.assert(outcome.refusal == null);
    std.debug.assert(!outcome.nothing());

    for (std.enums.values(conform.Change.Kind)) |kind| {
        for (outcome.changes) |change| {
            if (change.kind != kind) {
                continue;
            }

            switch (kind) {
                .rebuild => try out.print("rebuild {s} ({s})\n", .{ change.name, change.why }),
                .drop => try out.print("drop {s}\n", .{change.name}),
                .create => try out.print("create {s}\n", .{change.name}),
                .nulled => try out.print("null {s} ({s})\n", .{ change.name, change.why }),
                .forget => try out.print("forget migration {s}\n", .{change.name}),
            }
        }
    }

    var left_out: u64 = 0;

    for (outcome.left_out) |entry| {
        left_out += entry.count;

        if (entry.column) |column| {
            try out.print("leave-out {s}.{s} {d} values\n", .{ entry.table, column, entry.count });
        } else {
            try out.print("leave-out {s} {d} rows\n", .{ entry.table, entry.count });
        }
    }

    if (backup) |name| {
        try out.print("backup {s}\n", .{name});
    }

    try out.print("conform: {d} change(s), {d} left out\n", .{ outcome.changes.len, left_out });
}
