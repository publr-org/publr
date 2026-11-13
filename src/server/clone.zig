//! A site brought down to work on and sent back up (`.agents/specs/clone-and-push.md`).
//! `publr clone <address>` signs in as a device, downloads the site as a bundle made for a
//! clone, and writes it to a folder, with a pristine copy at `.publr/base/` for the merge
//! later. `publr push` packs the folder and its base and uploads both; the plugin that keeps
//! copies makes a branch of them, reviewed and merged there. Nothing local writes to live.
const std = @import("std");
const report = @import("../lib/report.zig");
const bundle = @import("bundle.zig");
const credentials = @import("credentials.zig");
const login = @import("login.zig");
const remote = @import("remote.zig");
const site_side = @import("clone/site.zig");
const placeholders = @import("clone/placeholders.zig");
const downloads = @import("clone/download.zig");
const progress = @import("clone/progress.zig");
const entering = @import("clone/entry.zig");
const opening = @import("clone/opening.zig");
const writing = @import("clone/folder.zig");

const version = @import("../publr.zig").version;
pub const clone_path = ".publr/clone.json";
pub const base_dir = ".publr/base";
pub const db_path = "data/publr.db";

/// What `.publr/clone.json` keeps: where the folder came from and the branch it pushes to.
pub const Link = struct {
    site: []const u8,
    branch: []const u8,
};

pub fn handles(args: []const []const u8) bool {
    std.debug.assert(args.len > 0);

    return std.mem.eql(u8, args[0], "clone") or std.mem.eql(u8, args[0], "push");
}

const usage = "usage: publr clone <address or project> [<folder>] [--media all|none] " ++
    "[--size] [--port <n>] [--no-open] [--no-serve]\n       publr push";

/// What `publr clone` was asked: `--media none` brings no media files down (placeholders
/// stand in); `--size` only says what a clone would bring down.
const Asked = struct {
    given: []const u8 = "",
    folder: ?[]const u8 = null,
    media: bool = true,
    /// `--media` was given: nothing to ask on the page.
    media_given: bool = false,
    size_only: bool = false,
    /// `--no-open`: the progress page is not opened, only printed.
    open: bool = true,
    /// `--no-serve`: done once the folder is written, without serving it.
    serve: bool = true,
    /// `--port <n>`: the folder's address; a free one when 0.
    port: u16 = 0,
};

pub fn run(init: std.process.Init, out: *std.Io.Writer, args: []const []const u8) !u8 {
    std.debug.assert(args.len > 0);

    if (std.mem.eql(u8, args[0], "push")) {
        return @import("clone/push.zig").push(init, out);
    }

    const asked = parse(args[1..]) orelse {
        report.err("{s}", .{usage});
        return 2;
    };

    return clone(init, out, asked);
}

fn parse(args: []const []const u8) ?Asked {
    std.debug.assert(args.len <= 128);

    var asked: Asked = .{};
    var index: u32 = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--media") and index + 1 < args.len) {
            index += 1;

            const all = std.mem.eql(u8, args[index], "all");

            if (!all and !std.mem.eql(u8, args[index], "none")) {
                return null;
            }

            asked.media = all;
            asked.media_given = true;
        } else if (std.mem.eql(u8, arg, "--size")) {
            asked.size_only = true;
        } else if (std.mem.eql(u8, arg, "--no-open")) {
            asked.open = false;
        } else if (std.mem.eql(u8, arg, "--no-serve")) {
            asked.serve = false;
        } else if (std.mem.eql(u8, arg, "--port") and index + 1 < args.len) {
            index += 1;
            asked.port = std.fmt.parseInt(u16, args[index], 10) catch return null;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return null;
        } else if (asked.given.len == 0) {
            asked.given = arg;
        } else if (asked.folder == null) {
            asked.folder = arg;
        } else {
            return null;
        }
    }

    return if (asked.given.len > 0) asked else null;
}

/// A project's name is a Cloud project's address; anything else is an address already.
fn address_of(arena: std.mem.Allocator, given: []const u8) ![]const u8 {
    std.debug.assert(given.len > 0);

    const bare = std.mem.indexOfAny(u8, given, ".:/") == null;

    if (bare) {
        return std.fmt.allocPrint(arena, "https://{s}.publr.app", .{given});
    }

    return given;
}

/// This computer's device for the site `given` names, signing in first when it has none.
fn signed_in(init: std.process.Init, out: *std.Io.Writer, given: []const u8) !?credentials.Site {
    std.debug.assert(given.len > 0);

    const arena = init.arena.allocator();
    const typed = try address_of(arena, given);
    const address = try credentials.normalize(arena, typed) orelse {
        report.err("publr clone: {s} is not an address", .{given});
        return null;
    };

    if (try credentials.find(init, address) == null) {
        const words = [_][]const u8{ "login", address };

        if (try login.run(init, out, &words) != 0) {
            return null;
        }
    }

    return credentials.find(init, address);
}

fn clone(init: std.process.Init, out: *std.Io.Writer, asked: Asked) !u8 {
    std.debug.assert(asked.given.len > 0);

    const arena = init.arena.allocator();
    const site = try signed_in(init, out, asked.given) orelse return 1;

    if (asked.size_only) {
        return downloads.say_size(init, out, site);
    }

    const by_slug = std.mem.indexOfAny(u8, asked.given, ".:/") == null;
    const folder = asked.folder orelse if (by_slug) asked.given else name_of(site.address);

    if (exists(init.io, folder)) {
        report.err("publr clone: {s} is there already", .{folder});
        return 1;
    }

    try std.Io.Dir.cwd().createDirPath(init.io, folder);

    // Asked on the page what comes down, unless the command said (`--media`).
    const asking = !asked.media_given;
    // Weighed before the page is drawn: its choice and its bar's parts come from this.
    const size = try downloads.size_of(init, site);
    var shared: progress.Shared = .{
        .size = size orelse .{
            .database_bytes = 0,
            .media_files = 0,
            .media_bytes = 0,
        },
        .phase = .init(@intFromEnum(if (asking) progress.Phase.choosing else .packing)),
        .io = init.io,
        .site = site.address,
        .name = name_of(site.address),
        .folder = try std.Io.Dir.cwd().realPathFileAlloc(init.io, folder, arena),
        .media = asked.media,
        .began_ms = @import("../sdk.zig").context.wall_clock_ms(init.io),
    };
    const server = try arena.create(progress.Server);

    try server.start(init.gpa, &shared, asked.port);

    const admin_origin = try std.fmt.allocPrint(arena, "http://admin.localhost:{d}", .{
        server.port,
    });
    const page = try std.fmt.allocPrint(arena, "{s}{s}", .{ admin_origin, progress.page_path });

    try out.print("Bringing {s} into {s}. Follow it at {s}\n", .{ site.address, folder, page });
    try out.flush();

    if (asked.open) {
        opening.open(init, page);
    }

    var chosen = asked;

    if (asking) {
        chosen.media = try wait_for_choice(init, out, &shared);
    }

    const entered = bring_down(init, out, chosen, site, &shared) catch |err| {
        shared.fail(if (shared.problem.len > 0) shared.problem else stopped_because(err));
        report.err("publr clone: {t}", .{err});
        // The page says why before it stops answering.
        std.Io.sleep(init.io, .fromSeconds(3), .awake) catch |slept| {
            std.log.debug("clone: {t}", .{slept});
        };
        server.stop();
        return 1;
    };
    shared.session_cookie = entered.session_cookie;
    shared.hint_cookie = entered.hint_cookie;
    shared.enter(.starting);
    // The page asks every 400 ms: it hears where to go before this stops answering.
    try std.Io.sleep(init.io, .fromMilliseconds(1200), .awake);
    server.stop();

    try out.print("Cloned {s} into {s}. Send it up as a branch: publr push\n", .{
        site.address,
        folder,
    });

    if (!asked.serve) {
        return 0;
    }

    try out.print("Serving it at {s}\n", .{admin_origin});
    try out.flush();

    return serve_here(init, folder, server.port);
}

/// Why a clone stopped, for people.
fn stopped_because(err: anyerror) []const u8 {
    std.debug.assert(@errorName(err).len > 0);

    return switch (err) {
        error.ConnectionRefused => "The site did not answer. Is it running?",
        error.ShortDownload, error.DownloadRefused => "The download broke off. Try again.",
        error.SiteExists => "This folder holds a site already.",
        else => @errorName(err),
    };
}

/// What the person chose on the page: true for everything, false for no media files.
fn wait_for_choice(
    init: std.process.Init,
    out: *std.Io.Writer,
    shared: *progress.Shared,
) !bool {
    std.debug.assert(shared.phase.load(.acquire) == @intFromEnum(progress.Phase.choosing));

    try out.writeAll("Choose on that page what comes down (or run again with --media " ++
        "all|none).\n");
    try out.flush();

    while (shared.chosen.load(.acquire) == 0) {
        try std.Io.sleep(init.io, .fromMilliseconds(200), .awake);
    }

    const media = shared.chosen.load(.acquire) == 1;

    shared.media = media;
    shared.began_ms = @import("../sdk.zig").context.wall_clock_ms(init.io);
    shared.enter(.packing);

    return media;
}

/// The clone written to its folder, its media or placeholders for it, and a session there
/// for the account that cloned it.
fn bring_down(
    init: std.process.Init,
    out: *std.Io.Writer,
    asked: Asked,
    site: credentials.Site,
    shared: *progress.Shared,
) !entering.Entered {
    std.debug.assert(shared.folder.len > 0);

    const arena = init.arena.allocator();
    var why: []const u8 = "";
    const made = try prepared(init, site, asked.media, shared, &why) orelse {
        shared.problem = why;
        return error.NotPrepared;
    };
    const download_path = try std.fmt.allocPrint(arena, "{s}{s}", .{
        shared.folder,
        bundle.extension,
    });

    defer std.Io.Dir.cwd().deleteFile(init.io, download_path) catch |err| {
        std.log.debug("removing {s}: {t}", .{ download_path, err });
    };

    shared.parts = made.parts;
    try downloads.fetch_bundle(init, site, made.bytes, download_path, shared);
    shared.enter(.unpacking);
    const unpacked = &shared.unpacked_bytes;

    try writing.write_folder(init, arena, shared.folder, download_path, site.address, unpacked);

    if (!asked.media) {
        shared.enter(.placeholders);

        const written = try placeholders.write_all(init.io, arena, shared.folder);

        shared.placeholders.store(written.files, .release);
        try out.print("Placeholders stand in for {d} media files; push never sends them.\n", .{
            written.files,
        });
    }

    const now_ms = @import("../sdk.zig").context.wall_clock_ms(init.io);

    return entering.session_for(init.io, arena, shared.folder, site.email, now_ms);
}

/// This process becomes the folder's `publr serve`, on the address its page was opened at.
fn serve_here(init: std.process.Init, folder: []const u8, port: u16) !u8 {
    std.debug.assert(folder.len > 0);
    std.debug.assert(port > 0);

    const arena = init.arena.allocator();
    var dir = try std.Io.Dir.cwd().openDir(init.io, folder, .{});
    defer dir.close(init.io);

    try std.process.setCurrentDir(init.io, dir);

    const port_text = try std.fmt.allocPrint(arena, "{d}", .{port});
    const site_url = try std.fmt.allocPrint(arena, "http://localhost:{d}", .{port});

    return @import("serve.zig").run(init, db_path, &.{ "--port", port_text, "--url", site_url });
}

/// A folder's name for a site given by its address: its first name, without the admin's
/// part (`test-m964yr--admin.publr.app` is `test-m964yr`, `admin.example.com` `example`).
fn name_of(address: []const u8) []const u8 {
    std.debug.assert(address.len > 0);

    const scheme_end = if (std.mem.indexOf(u8, address, "://")) |at| at + 3 else 0;
    const after_scheme = address[scheme_end..];
    const host_end = std.mem.indexOfAny(u8, after_scheme, ":/") orelse after_scheme.len;
    const host = after_scheme[0..host_end];
    const bare = if (std.mem.startsWith(u8, host, "admin.")) host["admin.".len..] else host;
    const first = bare[0 .. std.mem.indexOfScalar(u8, bare, '.') orelse bare.len];
    const cut = std.mem.indexOf(u8, first, "--") orelse first.len;

    return if (cut > 0) first[0..cut] else "site";
}

/// The site packed for this clone, followed while it packs; null when it was not, with why
/// in `why`, for people.
fn prepared(
    init: std.process.Init,
    site: credentials.Site,
    media: bool,
    shared: *progress.Shared,
    why: *[]const u8,
) !?site_side.Prepared {
    std.debug.assert(site.token.len > 0);

    const arena = init.arena.allocator();
    const reply = try remote.post(init.io, arena, .{
        .url = try std.fmt.allocPrint(arena, "{s}{s}", .{ site.address, site_side.pack_route }),
        .payload = if (media) "{}" else "{\"media\":\"none\"}",
        .token = site.token,
    });

    if (reply.status != .accepted) {
        const refused = reply.status == .unauthorized or reply.status == .forbidden;

        why.* = if (refused)
            "Only the site's administrators can bring it down. Sign in as one: publr login."
        else if (reply.status == .internal_server_error)
            "The site could not pack itself. Its own log says why."
        else
            try std.fmt.allocPrint(arena, "The site answered {d}.", .{@intFromEnum(reply.status)});
        report.err("publr clone: {s}: {s}", .{ site.address, why.* });
        return null;
    }

    const made = try downloads.wait_for_pack(init, site, shared, why) orelse {
        report.err("publr clone: {s}: {s}", .{ site.address, why.* });
        return null;
    };

    if (!std.mem.eql(u8, made.publr, version)) {
        why.* = try std.fmt.allocPrint(arena, "The site runs Publr {s}; this computer has " ++
            "{s}. Install that one first.", .{ made.publr, version });
        report.err("publr clone: {s} runs Publr {s}, this is {s}. Get that one first:\n" ++
            "  curl -fsSL https://publr.dev/install.sh | PUBLR_HOME=. PUBLR_VERSION=v{s} sh", .{
            site.address,
            made.publr,
            version,
            made.publr,
        });
        return null;
    }

    return made;
}

fn exists(io: std.Io, path: []const u8) bool {
    std.debug.assert(path.len > 0);

    std.Io.Dir.cwd().access(io, path, .{}) catch return false;

    return true;
}

test {
    _ = @import("clone/site.zig");
    _ = @import("clone/pack_process.zig");
    _ = @import("clone/placeholders.zig");
    _ = @import("clone/download.zig");
    _ = @import("clone/push.zig");
    _ = @import("clone/progress.zig");
    _ = @import("clone/entry.zig");
    _ = @import("clone/opening.zig");
    _ = @import("clone/folder.zig");
}

test "a folder is named after the site's first name" {
    const cloud = "https://test-m964yr--admin.publr.app";

    try std.testing.expectEqualStrings("test-m964yr", name_of(cloud));
    try std.testing.expectEqualStrings("example", name_of("https://admin.example.com"));
    try std.testing.expectEqualStrings("shop", name_of("http://shop.localhost:8080/"));
}
