//! `publr build [--full] [--out <dir>] [--url <base>]`: every app as files, one folder
//! each, brought up to date with the least work (nothing, the changed pages, or under
//! `--full` everything). `serve` prefers the files afterwards, and every publish keeps them
//! current.

const std = @import("std");
const server = @import("../server.zig");
const report = @import("../lib/report.zig");
const routes = @import("routes.zig");
const apps_adapter = @import("../adapters/apps.zig");
const sdk = @import("../sdk.zig");

const Flags = struct {
    options: apps_adapter.Options = .{},
    /// Build everything again, whatever the marker and the queue say.
    full: bool = false,
    exit: ?u8 = null,
};

const Refreshed = apps_adapter.rebuild.Refreshed;

pub fn run(init: std.process.Init, db_path: [:0]const u8, args: []const []const u8) !u8 {
    std.debug.assert(db_path.len > 0);

    var flags = parse_flags(args);
    var reason: report.Reason = .{};
    flags.options.diagnostic = &reason;

    if (flags.exit) |code| {
        return code;
    }

    if (apps_adapter.spec.all.len == 0) {
        std.debug.print("publr build: this project has no apps to build\n", .{});

        return 0;
    }

    var application: server.Server = undefined;
    try application.init(init, db_path);
    defer application.deinit();

    var project: routes.Project = .{
        .connection = &application.connection,
        .auth = &application.auth,
        .io = init.io,
        .sandboxed_plugins = application.sandboxed(),
    };
    const apps = try init.gpa.alloc(apps_adapter.App, apps_adapter.spec.all.len);
    defer init.gpa.free(apps);
    const now_ms = sdk.context.wall_clock_ms(init.io);

    const index = &application.index;

    apps_adapter.load.open(&project, apps, init.gpa, index, flags.options, now_ms) catch |err| {
        report.err_reason(reason.text(), "publr build: the apps do not load: {s}", .{
            @errorName(err),
        });

        return 1;
    };
    defer apps_adapter.load.close(&project);

    const refreshed = bring_up_to_date(&project, flags.full) catch |err| {
        report.err_reason(reason.text(), "publr build: {s}", .{@errorName(err)});

        return 1;
    };

    announce(refreshed, flags.options.output_dir);

    return if (refreshed.full.failed > 0) 1 else 0;
}

/// Every app whole under `full`; otherwise only what the last build does not cover.
pub fn bring_up_to_date(project: *const routes.Project, full: bool) !Refreshed {
    std.debug.assert(project.apps.len > 0);
    std.debug.assert(project.connection.transaction_depth == 0);

    if (full) {
        return .{ .outcome = .built, .full = try apps_adapter.build.build_all(project) };
    }

    return apps_adapter.rebuild.refresh(project);
}

/// One line on stderr saying what the build did.
pub fn announce(refreshed: Refreshed, output_dir: []const u8) void {
    std.debug.assert(output_dir.len > 0);

    switch (refreshed.outcome) {
        .built => std.debug.print("publr: built {d} pages, {d} static islands and {d} assets " ++
            "({d} bytes) into {s}/\n", .{
            refreshed.full.pages,
            refreshed.full.islands,
            refreshed.full.assets,
            refreshed.full.bytes,
            output_dir,
        }),
        .refreshed => std.debug.print("publr: {s}/ brought up to date: {d} pages and islands " ++
            "rewritten, {d} removed, the rest unchanged\n", .{
            output_dir,
            refreshed.written,
            refreshed.removed,
        }),
        .current => std.debug.print(
            "publr: {s}/ is current: nothing changed in generated pages; " ++
                "{d} public files copied unchanged\n",
            .{ output_dir, refreshed.copied },
        ),
    }
}

const help =
    \\Usage: publr [--db <path>] build [--full] [--out <dir>] [--url <base>] [--apps <dir>]
    \\
    \\  --full        Build every page again; without it only what changed since the last
    \\                build is rendered, and nothing when nothing did
    \\  --out <dir>   Where the apps are written, one folder each (default: output)
    \\  --url <base>  The project's public address, for the sitemaps
    \\                (default: http://127.0.0.1:8080)
    \\  --apps <dir> Where each app's public files are read from, <dir>/<app>/public
    \\                (default: apps)
    \\  -h, --help    Print this help
    \\
;

pub fn parse_flags(args: []const []const u8) Flags {
    if (args.len >= 64) {
        return .{ .exit = usage("too many arguments") };
    }

    std.debug.assert(help.len > 0);

    var flags: Flags = .{};
    var index: u32 = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--full")) {
            flags.full = true;
        } else if (std.mem.eql(u8, arg, "--out")) {
            index += 1;

            if (index == args.len) {
                return .{ .exit = usage("--out needs a directory") };
            }

            flags.options.output_dir = args[index];
        } else if (std.mem.eql(u8, arg, "--url")) {
            index += 1;

            if (index == args.len) {
                return .{ .exit = usage("--url needs an address") };
            }

            flags.options.base_url = std.mem.trimEnd(u8, args[index], "/");
        } else if (std.mem.eql(u8, arg, "--apps")) {
            index += 1;

            if (index == args.len) {
                return .{ .exit = usage("--apps needs a directory") };
            }

            flags.options.apps_dir = args[index];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{help});

            return .{ .exit = 0 };
        } else {
            report.err("publr build: unknown flag \"{s}\"", .{arg});
            std.debug.print("{s}", .{help});

            return .{ .exit = 2 };
        }
    }

    if (!apps_adapter.valid_options(flags.options)) {
        return .{ .exit = usage("--out and --apps need a directory, --url an absolute HTTP(S) " ++
            "address") };
    }

    return flags;
}

fn usage(message: []const u8) u8 {
    std.debug.assert(message.len > 0);
    std.debug.assert(message.len < 200);

    report.err("publr build: {s}", .{message});
    std.debug.print("{s}", .{help});

    return 2;
}

test "build flags: an output folder and a base address without its trailing slash" {
    const parsed = parse_flags(&.{ "--out", "site", "--url", "https://example.com/" });
    try std.testing.expectEqualStrings("site", parsed.options.output_dir);
    try std.testing.expectEqualStrings("https://example.com", parsed.options.base_url);
    try std.testing.expect(parsed.exit == null);

    const defaults = parse_flags(&.{});
    try std.testing.expectEqualStrings("output", defaults.options.output_dir);
    try std.testing.expect(!defaults.full);
    try std.testing.expect(defaults.exit == null);
    try std.testing.expect(parse_flags(&.{"--full"}).full);
}
