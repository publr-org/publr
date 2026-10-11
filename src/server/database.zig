const std = @import("std");
const db = @import("../lib/db.zig");
const report = @import("../lib/report.zig");
const gate = @import("gate.zig");
const operator = @import("operator.zig");

const version = @import("../publr.zig").version;

pub const help =
    \\  db check                What this release would find opening the database: the
    \\                          release that last opened it, migrations to run, and every
    \\                          way its shape differs; exits 1 when the gate would refuse it
    \\  db tables               Every table, its rows, and whether it is core's
    \\  db draft <schema.sql>   The next migration, drafted from what this build's schema
    \\                          adds to that one (the last release's)
    \\  backups                 The backups taken before each update, newest first
    \\  restore <name>          Put the site back as a backup holds it (stop `serve` first)
    \\
;

/// `publr db check`, `publr backups`, `publr restore <name>`: the commands that look at the
/// database and its backups without going through the gate, so they work on a database the
/// gate refuses.
pub fn run(
    init: std.process.Init,
    out: *std.Io.Writer,
    db_path: [:0]const u8,
    args: []const []const u8,
) !u8 {
    std.debug.assert(args.len > 0);
    std.debug.assert(db_path.len > 0);

    const arena = init.arena.allocator();
    const command = args[0];

    if (std.mem.eql(u8, command, "db") and args.len == 2 and std.mem.eql(u8, args[1], "check")) {
        return check(init, out, db_path);
    }

    if (std.mem.eql(u8, command, "db") and args.len == 2 and std.mem.eql(u8, args[1], "tables")) {
        return tables(init, out, db_path);
    }

    if (std.mem.eql(u8, command, "db") and args.len == 3 and std.mem.eql(u8, args[1], "draft")) {
        return draft(init, out, args[2]);
    }

    if (std.mem.eql(u8, command, "backups") and args.len == 1) {
        return list(init, out, db_path);
    }

    if (std.mem.eql(u8, command, "restore") and args.len == 2) {
        return restore(init, out, db_path, args[1]);
    }

    try out.print("publr {s}: unknown arguments\n\n{s}", .{
        try std.mem.join(arena, " ", args),
        help,
    });

    return 2;
}

/// Whether `args` is one of these commands.
pub fn handles(args: []const []const u8) bool {
    std.debug.assert(args.len > 0);

    return std.mem.eql(u8, args[0], "db") or std.mem.eql(u8, args[0], "backups") or
        std.mem.eql(u8, args[0], "restore");
}

fn check(init: std.process.Init, out: *std.Io.Writer, db_path: [:0]const u8) !u8 {
    std.debug.assert(db_path.len > 0);
    std.debug.assert(version.len > 0);

    const arena = init.arena.allocator();
    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();
    var connection = try db.open(&runtime, db_path);
    defer connection.close();

    const status = try gate.status(&connection, &runtime, arena);

    try out.print("database   {s}\nlast opened by {s}; this is {s}\n", .{
        db_path,
        status.release orelse "no recorded release (made before 0.3.0)",
        version,
    });

    for (status.plan.pending) |migration| {
        try out.print("to run     {s} {s}{s}\n", .{
            migration.source,
            migration.name,
            if (migration.one_way) " (one-way)" else "",
        });
    }

    for (status.plan.unknown) |row| {
        try out.print("newer      {s} {s}{s}: a newer release ran it\n", .{
            row.source,
            row.name,
            if (row.one_way) " (one-way)" else "",
        });
    }

    for (status.differences) |difference| {
        try out.print("{s} {s}: expects {s}, has {s}\n", .{
            if (difference.compatible) "fine      " else "refused   ",
            difference.subject,
            difference.expected,
            difference.live,
        });
    }

    const refused = status.refused();

    try out.print("{s}\n", .{if (refused)
        "This release would refuse it."
    else
        "This release would open it."});

    return @intFromBool(refused);
}

fn tables(init: std.process.Init, out: *std.Io.Writer, db_path: [:0]const u8) !u8 {
    std.debug.assert(db_path.len > 0);

    const arena = init.arena.allocator();
    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();
    var connection = try db.open(&runtime, db_path);
    defer connection.close();

    for ((try db.shape.read(&connection, arena)).tables) |table| {
        // The name is one SQLite reported, never data from outside.
        const sql = try std.fmt.allocPrint(arena, "SELECT count(*) FROM \"{s}\"", .{table.name});
        var count = try connection.prepare_dynamic(sql);
        defer count.finalize();

        _ = try count.step();
        try out.print("{s} {d} {s}\n", .{ table.name, count.read_int(), owner_of(table.name) });
    }

    return 0;
}

/// `core` for a table `schema.sql` makes, `other` for a plugin's or an index's own.
fn owner_of(table: []const u8) []const u8 {
    std.debug.assert(table.len > 0);

    for (db.schema.tables) |core| {
        if (std.mem.eql(u8, core, table)) {
            return "core";
        }
    }

    return "other";
}

/// `publr db draft <schema.sql of the last release>`: the next migration's start.
fn draft(init: std.process.Init, out: *std.Io.Writer, released_path: []const u8) !u8 {
    std.debug.assert(released_path.len > 0);

    const arena = init.arena.allocator();
    const limit: std.Io.Limit = .limited(16 << 20);
    const released = try std.Io.Dir.cwd().readFileAllocOptions(
        init.io,
        released_path,
        arena,
        limit,
        .of(u8),
        0,
    );
    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();

    try @import("database/draft.zig").write(&runtime, arena, released, out);

    return 0;
}

fn list(init: std.process.Init, out: *std.Io.Writer, db_path: [:0]const u8) !u8 {
    std.debug.assert(db_path.len > 0);

    const arena = init.arena.allocator();
    const site = try gate.backup.Site.of(init.io, arena, db_path, null);
    const entries = try gate.backup.list(site, arena);

    if (entries.len == 0) {
        try out.print("No backups yet. One is taken before each update.\n", .{});
        return 0;
    }

    for (entries) |entry| {
        try out.print("{s}  {s} -> {s}\n", .{
            entry.name,
            if (entry.about.from.len == 0) "(new)" else entry.about.from,
            entry.about.to,
        });
    }

    return 0;
}

/// The site as it is now, backed up before a restore replaces it: a restore loses what was
/// written since the backup, so that is kept too.
fn keep_current(init: std.process.Init, site: gate.backup.Site, db_path: [:0]const u8) !void {
    std.debug.assert(db_path.len > 0);
    std.debug.assert(site.database.len > 0);

    const arena = init.arena.allocator();
    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();
    var connection = try db.open(&runtime, db_path);
    defer connection.close();

    const has_settings = try db.schema.has_table(&connection, "settings");
    const release = if (has_settings)
        try @import("../store/settings.zig").get(&connection, arena, gate.release_key)
    else
        null;
    const made = try gate.backup.make(site, &connection, arena, .{
        .from = release orelse "",
        .to = "restore",
        .at_ms = @import("../sdk.zig").context.wall_clock_ms(init.io),
        .database = site.database,
    }, .{
        .prune = false,
    });

    report.info("publr restore: kept the site as it was in {s}\n", .{made});
}

fn restore(
    init: std.process.Init,
    out: *std.Io.Writer,
    db_path: [:0]const u8,
    name: []const u8,
) !u8 {
    std.debug.assert(db_path.len > 0);
    std.debug.assert(name.len > 0);

    const arena = init.arena.allocator();

    if (try operator.find(init.io, arena, db_path)) |running| {
        report.err("publr restore: a server runs for {s} on port {d}; stop it first", .{
            db_path,
            running.port,
        });
        return 1;
    }

    const site = try gate.backup.Site.of(init.io, arena, db_path, null);

    for (try gate.backup.list(site, arena)) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            try keep_current(init, site, db_path);
            try gate.backup.restore(site, arena, entry);
            try out.print("Restored {s}: the site as it was before {s} opened it.\n", .{
                entry.name,
                entry.about.to,
            });
            return 0;
        }
    }

    report.err("publr restore: no backup named {s}; `publr backups` lists them", .{name});

    return 1;
}
