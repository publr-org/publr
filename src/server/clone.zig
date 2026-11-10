//! A site brought down to work on and sent back up (`.agents/specs/clone-and-push.md`).
//! `publr clone <address>` signs in as a device, downloads the site as a bundle made for a
//! clone, and writes it to a folder, with a pristine copy at `.publr/base/` for the merge
//! later. `publr push` packs the folder and its base and uploads both; the plugin that keeps
//! copies makes a branch of them, reviewed and merged there. Nothing local writes to live.
const std = @import("std");
const http = @import("../lib/http.zig");
const report = @import("../lib/report.zig");
const identity_module = @import("../adapters/rest/identity.zig");
const role = @import("../model/role.zig");
const backup = @import("gate/backup.zig");
const bundle = @import("bundle.zig");
const credentials = @import("credentials.zig");
const login = @import("login.zig");
const remote = @import("remote.zig");
const upload = @import("cloud_deploy/upload.zig");
const Project = @import("project.zig").Project;

pub const pack_route = "/api/sites/pack";
const push_path = "/api/environments/push";
const version = @import("../publr.zig").version;
const clone_path = ".publr/clone.json";
const base_dir = ".publr/base";
const push_dir = ".publr/push";
const clones_dir = ".clones";
const db_path = "data/publr.db";
const piece_bytes_max: u32 = 1 << 20;
const upload_piece_bytes: u32 = 256 << 10;
const link_bytes_max: u32 = 4 << 10;
const branch_suffix_len: u32 = 6;

/// What `.publr/clone.json` keeps: where the folder came from and the branch it pushes to.
const Link = struct {
    site: []const u8,
    branch: []const u8,
};

/// What making the download answers.
const Prepared = struct {
    bytes: u64,
    publr: []const u8,
    name: []const u8,
};

/// The administrator asking, signed in or as a device; null, answered 401, for anyone else.
fn administrator(
    project: *const Project,
    request: *const http.Request,
    response: *http.Response,
    arena: std.mem.Allocator,
) http.Error!?[]const u8 {
    std.debug.assert(project.connection.transaction_depth == 0);

    const caller = identity_module.identify(request, arena, project).caller;
    const allowed = caller.holds(role.admin) and project.db_path.len > 0;

    if (!allowed) {
        try response.json(.unauthorized, .{
            .@"error" = "administrator_required",
        });
        return null;
    }

    return caller.user_id();
}

fn bundle_path(
    project: *const Project,
    arena: std.mem.Allocator,
    user: []const u8,
) error{OutOfMemory}![]const u8 {
    std.debug.assert(user.len > 0);

    const data = std.fs.path.dirname(project.db_path) orelse ".";

    return std.fmt.allocPrint(arena, "{s}/{s}/{s}{s}", .{
        data,
        clones_dir,
        user,
        bundle.extension,
    });
}

/// `POST /api/sites/pack`: this site made into a bundle for a clone, waiting for its pieces.
pub fn prepare(
    request: *http.Request,
    response: *http.Response,
    ctx: *http.Context,
) http.Error!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.method() == .post);

    const project = Project.of(ctx);
    const arena = ctx.arena;
    const user = try administrator(project, request, response, arena) orelse return;
    const path = try bundle_path(project, arena, user);
    const made = make_bundle(project, arena, path, user) catch |err| {
        std.log.warn("clone: packing failed: {t}", .{err});
        return response.json(.internal_server_error, .{
            .@"error" = "pack_failed",
        });
    };

    try response.json(.ok, made);
}

fn make_bundle(
    project: *const Project,
    arena: std.mem.Allocator,
    path: []const u8,
    user: []const u8,
) !Prepared {
    std.debug.assert(path.len > 0);

    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(project.io, std.fs.path.dirname(path).?);

    const site = try backup.Site.of(project.io, arena, project.db_path, project.folder);
    const name = std.fs.path.basename(site.project_dir);
    const made = try bundle.pack_clone(site, arena, path, name, .{
        .keep_user = user,
    });
    const stat = try cwd.statFile(project.io, path, .{});

    return .{
        .bytes = stat.size,
        .publr = made.manifest.publr,
        .name = name,
    };
}

/// `GET /api/sites/pack?offset=<n>`: one piece of the bundle made for this person. The last
/// one removes it.
pub fn piece(
    request: *http.Request,
    response: *http.Response,
    ctx: *http.Context,
) http.Error!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.method() == .get or request.method() == .head);

    const project = Project.of(ctx);
    const arena = ctx.arena;
    const user = try administrator(project, request, response, arena) orelse return;
    const path = try bundle_path(project, arena, user);
    const asked = http.Form.query_param(arena, request.query(), "offset") orelse "0";
    const offset = std.fmt.parseInt(u64, asked, 10) catch 0;
    const bytes = read_piece(project.io, arena, path, offset) catch {
        return response.json(.not_found, .{
            .@"error" = "not_packed",
        });
    };

    if (bytes.len < piece_bytes_max) {
        std.Io.Dir.cwd().deleteFile(project.io, path) catch |err| {
            std.log.warn("clone: removing {s}: {t}", .{ path, err });
        };
    }

    try response.set_body(.ok, "application/gzip", bytes);
}

fn read_piece(io: std.Io, arena: std.mem.Allocator, path: []const u8, offset: u64) ![]const u8 {
    std.debug.assert(path.len > 0);
    std.debug.assert(piece_bytes_max > 0);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const buffer = try arena.alloc(u8, piece_bytes_max);
    var through: [4 << 10]u8 = undefined;
    var reader = file.reader(io, &through);

    try reader.seekTo(offset);

    const count = try reader.interface.readSliceShort(buffer);

    return buffer[0..count];
}

pub fn handles(args: []const []const u8) bool {
    std.debug.assert(args.len > 0);

    return std.mem.eql(u8, args[0], "clone") or std.mem.eql(u8, args[0], "push");
}

pub fn run(init: std.process.Init, out: *std.Io.Writer, args: []const []const u8) !u8 {
    std.debug.assert(args.len > 0);

    if (std.mem.eql(u8, args[0], "push")) {
        return push(init, out);
    }

    if (args.len < 2 or args.len > 3) {
        report.err("usage: publr clone <address or project> [<folder>]", .{});
        return 2;
    }

    return clone(init, out, args[1], if (args.len == 3) args[2] else null);
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

fn clone(
    init: std.process.Init,
    out: *std.Io.Writer,
    given: []const u8,
    named: ?[]const u8,
) !u8 {
    std.debug.assert(given.len > 0);

    const arena = init.arena.allocator();
    const typed = try address_of(arena, given);
    const address = try credentials.normalize(arena, typed) orelse {
        report.err("publr clone: {s} is not an address", .{given});
        return 2;
    };

    if (try credentials.find(init, address) == null) {
        const words = [_][]const u8{ "login", address };

        if (try login.run(init, out, &words) != 0) {
            return 1;
        }
    }

    const site = try credentials.find(init, address) orelse return 1;
    const reply = try remote.post(init.io, arena, .{
        .url = try std.fmt.allocPrint(arena, "{s}{s}", .{ site.address, pack_route }),
        .payload = "{}",
        .token = site.token,
    });

    if (reply.status != .ok) {
        report.err("publr clone: {s} answered {d}: only its administrators can clone it", .{
            site.address,
            @intFromEnum(reply.status),
        });
        return 1;
    }

    const made = try std.json.parseFromSliceLeaky(Prepared, arena, reply.body, .{
        .ignore_unknown_fields = true,
    });

    if (!std.mem.eql(u8, made.publr, version)) {
        report.err("publr clone: {s} runs Publr {s}, this is {s}. Get that one first:\n" ++
            "  curl -fsSL https://publr.dev/install.sh | PUBLR_HOME=. PUBLR_VERSION=v{s} sh", .{
            site.address,
            made.publr,
            version,
            made.publr,
        });
        return 1;
    }

    const by_slug = std.mem.indexOfAny(u8, given, ".:/") == null;
    const folder = named orelse if (by_slug) given else made.name;

    if (exists(init.io, folder)) {
        report.err("publr clone: {s} is there already", .{folder});
        return 1;
    }

    const download = try std.fmt.allocPrint(arena, "{s}{s}", .{ folder, bundle.extension });

    defer std.Io.Dir.cwd().deleteFile(init.io, download) catch |err| {
        std.log.debug("removing {s}: {t}", .{ download, err });
    };

    try fetch_bundle(init, site, made.bytes, download);
    try write_folder(init, arena, folder, download, site.address);
    try out.print("Cloned {s} into {s}\n  Work there: cd {s} && publr serve\n" ++
        "  Send it up as a branch: publr push\n", .{ site.address, folder, folder });

    return 0;
}

fn exists(io: std.Io, path: []const u8) bool {
    std.debug.assert(path.len > 0);

    std.Io.Dir.cwd().access(io, path, .{}) catch return false;

    return true;
}

/// The bundle's pieces, in order, into `path`.
fn fetch_bundle(
    init: std.process.Init,
    site: credentials.Site,
    bytes: u64,
    path: []const u8,
) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(site.address.len > 0);

    var file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
    defer file.close(init.io);

    var buffer: [64 << 10]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    var offset: u64 = 0;

    while (true) {
        var state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer state.deinit();

        const taken = try fetch_piece(init.io, state.allocator(), site, offset, &writer.interface);

        offset += taken;

        if (taken < piece_bytes_max) {
            break;
        }
    }

    try writer.interface.flush();

    if (offset != bytes) {
        return error.ShortDownload;
    }
}

fn fetch_piece(
    io: std.Io,
    arena: std.mem.Allocator,
    site: credentials.Site,
    offset: u64,
    into: *std.Io.Writer,
) !u64 {
    std.debug.assert(site.token.len > 0);
    std.debug.assert(piece_bytes_max > 0);

    var client: std.http.Client = .{
        .allocator = arena,
        .io = io,
    };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(arena);
    const url = try std.fmt.allocPrint(arena, "{s}{s}?offset={d}", .{
        site.address,
        pack_route,
        offset,
    });
    const bearer = try std.fmt.allocPrint(arena, "Bearer {s}", .{site.token});
    const result = try client.fetch(.{
        .location = .{
            .url = url,
        },
        .keep_alive = false,
        .extra_headers = &.{.{
            .name = "Authorization",
            .value = bearer,
        }},
        .response_writer = &body.writer,
    });

    if (result.status != .ok) {
        return error.DownloadRefused;
    }

    try into.writeAll(body.written());

    return body.written().len;
}

/// `folder` the site, `.publr/base/` the same site as it was (database and structure, no
/// media), and the link back.
fn write_folder(
    init: std.process.Init,
    arena: std.mem.Allocator,
    folder: []const u8,
    download: []const u8,
    address: []const u8,
) !void {
    std.debug.assert(folder.len > 0);

    const base = try std.fs.path.join(arena, &.{ folder, base_dir });

    try unpack_into(init, arena, folder, download);
    try unpack_into(init, arena, base, download);
    try keep_only_database(init.io, arena, base);

    var random: [branch_suffix_len]u8 = undefined;

    init.io.random(&random);

    for (&random) |*byte| {
        byte.* = "abcdefghijkmnpqrstuvwxyz23456789"[byte.* & 31];
    }

    const text = try std.json.Stringify.valueAlloc(arena, Link{
        .site = address,
        .branch = try std.fmt.allocPrint(arena, "work-{s}", .{&random}),
    }, .{
        .whitespace = .indent_2,
    });
    const link = try std.fs.path.join(arena, &.{ folder, clone_path });

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = link,
        .data = text,
    });
}

fn unpack_into(
    init: std.process.Init,
    arena: std.mem.Allocator,
    folder: []const u8,
    download: []const u8,
) !void {
    std.debug.assert(folder.len > 0);

    const database = try std.fs.path.join(arena, &.{ folder, db_path });

    try std.Io.Dir.cwd().createDirPath(init.io, std.fs.path.dirname(database).?);

    const site = try backup.Site.of(init.io, arena, database, folder);

    _ = try bundle.unpack(site, arena, download, .{});
}

/// Everything in the base's data folder but its database: media stays once, in the site.
fn keep_only_database(io: std.Io, arena: std.mem.Allocator, base: []const u8) !void {
    std.debug.assert(base.len > 0);

    const data = try std.fs.path.join(arena, &.{ base, "data" });
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, data, .{
        .iterate = true,
    });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();

    while (try iterator.next(io)) |entry| {
        if (!std.mem.eql(u8, entry.name, std.fs.path.basename(db_path))) {
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
    }

    for (names.items) |name| {
        try dir.deleteTree(io, name);
    }
}

fn push(init: std.process.Init, out: *std.Io.Writer) !u8 {
    std.debug.assert(link_bytes_max > 0);

    const arena = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();
    const text = cwd.readFileAlloc(init.io, clone_path, arena, .limited(link_bytes_max)) catch {
        report.err("publr push: not a clone here; `publr clone <address>` makes one", .{});
        return 1;
    };
    const link = try std.json.parseFromSliceLeaky(Link, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    const site = try credentials.find(init, link.site) orelse {
        report.err("publr push: not signed in to {s}; run \"publr login {s}\"", .{
            link.site,
            link.site,
        });
        return 1;
    };

    try cwd.createDirPath(init.io, push_dir);
    defer cwd.deleteTree(init.io, push_dir) catch |err| {
        std.log.debug("removing {s}: {t}", .{ push_dir, err });
    };

    const folder = try backup.Site.of(init.io, arena, db_path, null);
    const base_db = try std.fs.path.join(arena, &.{ base_dir, db_path });
    const base = try backup.Site.of(init.io, arena, base_db, base_dir);
    const packed_site = push_dir ++ "/site" ++ bundle.extension;
    const packed_base = push_dir ++ "/base" ++ bundle.extension;

    _ = try bundle.pack_clone(folder, arena, packed_site, link.branch, .{});
    _ = try bundle.pack_clone(base, arena, packed_base, link.branch, .{});

    if (try send_part(init, out, site, link.branch, "base", packed_base) == null) {
        return 1;
    }

    const answer = try send_part(init, out, site, link.branch, "site", packed_site) orelse return 1;
    const Pushed = struct {
        name: []const u8,
        address: []const u8 = "",
        merge: []const u8 = "",
    };
    const pushed = try std.json.parseFromSliceLeaky(Pushed, arena, answer, .{
        .ignore_unknown_fields = true,
    });

    // A site that does not know its admin's address names only the path.
    const merge = if (std.mem.startsWith(u8, pushed.merge, "/"))
        try std.fmt.allocPrint(arena, "{s}{s}", .{ site.address, pushed.merge })
    else
        pushed.merge;

    try out.print("Pushed as the branch {s}\n  Preview  {s}\n" ++
        "  Merge    {s}  (a person reviews it)\n", .{
        pushed.name,
        pushed.address,
        merge,
    });

    return 0;
}

/// One bundle uploaded; its answer, or null having said why it was refused.
fn send_part(
    init: std.process.Init,
    out: *std.Io.Writer,
    site: credentials.Site,
    branch: []const u8,
    part: []const u8,
    path: []const u8,
) !?[]const u8 {
    std.debug.assert(branch.len > 0);
    std.debug.assert(path.len > 0);

    const arena = init.arena.allocator();
    const reply = try upload.send(.{
        .io = init.io,
        .arena = arena,
        .url = try std.fmt.allocPrint(arena, "{s}{s}?name={s}&part={s}", .{
            site.address,
            push_path,
            branch,
            part,
        }),
        .token = site.token,
        .path = path,
        .piece_bytes = upload_piece_bytes,
        .out = out,
    });

    if (reply.status != .ok and reply.status != .created) {
        report.err("publr push: {s} answered {d}: {s}", .{
            site.address,
            @intFromEnum(reply.status),
            reply.body,
        });
        return null;
    }

    return reply.body;
}
