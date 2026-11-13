//! The site's side of a clone: what it weighs (`GET /api/sites/size`), so the person is asked
//! knowing it, and the bundle made for the clone: started (`POST /api/sites/pack`), followed
//! (`GET /api/sites/pack/progress`) and sent in pieces (`GET /api/sites/pack?offset=`).
//! Administrators only, signed in or as a device.
const std = @import("std");
const http = @import("../../lib/http.zig");
const identity_module = @import("../../adapters/rest/identity.zig");
const role = @import("../../model/role.zig");
const backup = @import("../gate/backup.zig");
const bundle = @import("../bundle.zig");
const clone_rules = @import("../bundle/clone.zig");
const pack_process = @import("pack_process.zig");
const Project = @import("../project.zig").Project;

pub const pack_route = "/api/sites/pack";
pub const pack_progress_route = "/api/sites/pack/progress";
pub const size_route = "/api/sites/size";
pub const piece_bytes_max: u32 = 1 << 20;
const clones_dir = ".clones";
const walk_entries_max: u32 = 1 << 24;

/// What a clone would bring down. Media files are counted from the folder, without the
/// resized copies the site keeps (`media/.cache`), which a clone never takes.
pub const Size = struct {
    database_bytes: u64,
    media_files: u64,
    media_bytes: u64,
    apps_bytes: u64 = 0,
    plugins_bytes: u64 = 0,
};

/// What `POST /api/sites/pack` takes: `media` "none" for a bundle without media files.
const Asked = struct {
    media: []const u8 = "all",
};

/// The bundle made, as `GET /api/sites/pack/progress` answers once it is.
pub const Prepared = pack_process.Made;

/// Where the pack is: `packing` with `through` in ten-thousandths, `made` with `made`,
/// `failed` with `why`, or `none` when nothing was started.
pub const Packing = struct {
    state: []const u8,
    through: u32 = 0,
    made: ?Prepared = null,
    why: []const u8 = "",
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

/// `POST /api/sites/pack`: this site made into a bundle for a clone, in a process of its own;
/// answered at once, followed at `pack_progress_route`.
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
    const asked = std.json.parseFromSliceLeaky(Asked, arena, request.body, .{
        .ignore_unknown_fields = true,
    }) catch Asked{};

    pack_process.start(project.io, arena, .{
        .db_path = project.db_path,
        .folder = project.folder,
        .out = path,
        .keep_user = user,
        .media = !std.mem.eql(u8, asked.media, "none"),
    }) catch |err| {
        std.log.warn("clone: packing not started: {t}", .{err});
        return response.json(.internal_server_error, .{
            .@"error" = "pack_failed",
        });
    };

    try response.json(.accepted, .{
        .packing = true,
    });
}

/// `GET /api/sites/pack/progress`: where this person's pack is.
pub fn pack_progress(
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
    const found = pack_process.state(project.io, arena, path) catch |err| {
        std.log.warn("clone: reading the pack's progress: {t}", .{err});
        return response.json(.internal_server_error, .{
            .@"error" = "pack_failed",
        });
    };
    const answer: Packing = switch (found) {
        .none => .{
            .state = "none",
        },
        .packing => |through| .{
            .state = "packing",
            .through = through,
        },
        .made => |made| .{
            .state = "made",
            .through = 10_000,
            .made = made,
        },
        .failed => |why| failed: {
            std.log.warn("clone: packing failed: {s}", .{why});
            break :failed .{
                .state = "failed",
                .why = why,
            };
        },
    };

    try response.set_header("Cache-Control", "no-store");
    try response.json(.ok, answer);
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
        pack_process.forget(project.io, arena, path) catch |err| {
            std.log.warn("clone: removing what the pack left beside {s}: {t}", .{ path, err });
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

/// `GET /api/sites/size`: what a clone of this site would bring down.
pub fn size(request: *http.Request, response: *http.Response, ctx: *http.Context) http.Error!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.method() == .get or request.method() == .head);

    const project = Project.of(ctx);

    _ = try administrator(project, request, response, ctx.arena) orelse return;

    const weighed = weigh(project.io, ctx.arena, project.db_path, project.folder) catch |err| {
        std.log.warn("clone: weighing the site failed: {t}", .{err});
        return response.json(.internal_server_error, .{
            .@"error" = "size_failed",
        });
    };

    try response.json(.ok, weighed);
}

pub fn weigh(
    io: std.Io,
    arena: std.mem.Allocator,
    db_path: []const u8,
    project_dir: []const u8,
) !Size {
    std.debug.assert(db_path.len > 0);

    const data = std.fs.path.dirname(db_path) orelse ".";
    const media_dir = try std.fs.path.join(arena, &.{ data, clone_rules.media_dir });
    const media = try counted(io, arena, media_dir);
    const installed = try counted(io, arena, try std.fs.path.join(arena, &.{ data, "plugins" }));
    const project = if (project_dir.len > 0) project_dir else ".";
    const apps = try counted(io, arena, try std.fs.path.join(arena, &.{ project, "apps" }));
    const sources = try counted(io, arena, try std.fs.path.join(arena, &.{ project, "plugins" }));
    const weighed: Size = .{
        .database_bytes = (try std.Io.Dir.cwd().statFile(io, db_path, .{})).size,
        .media_files = media.files,
        .media_bytes = media.bytes,
        .apps_bytes = apps.bytes,
        .plugins_bytes = installed.bytes + sources.bytes,
    };

    std.debug.assert(weighed.media_bytes == 0 or weighed.media_files > 0);

    return weighed;
}

const Counted = struct {
    files: u64 = 0,
    bytes: u64 = 0,
};

/// The files under `root` and their bytes, without dot files and folders (caches, unfinished
/// uploads), which a clone never takes; nothing for a folder that is not there.
fn counted(io: std.Io, arena: std.mem.Allocator, root: []const u8) !Counted {
    std.debug.assert(root.len > 0);

    var dir = std.Io.Dir.cwd().openDir(io, root, .{
        .iterate = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(arena);
    defer walker.deinit();

    var found: Counted = .{};
    var entries: u32 = 0;

    while (try walker.next(io)) |entry| : (entries += 1) {
        if (entries == walk_entries_max) {
            return error.TooManyFiles;
        }

        if (entry.basename[0] == '.' or std.mem.eql(u8, entry.basename, "zig-out")) {
            if (entry.kind == .directory) {
                walker.leave(io);
            }

            continue;
        }

        if (entry.kind == .file) {
            const stat = try entry.dir.statFile(io, entry.basename, .{});

            found.files += 1;
            found.bytes += stat.size;
        }
    }

    return found;
}

test "a site weighs its database and its media, not the resized copies" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const io = std.testing.io;
    const root = try scratch.dir.realPathFileAlloc(io, ".", arena);
    const files = [_][2][]const u8{
        .{ "data/publr.db", "12345" },
        .{ "data/media/2026/11/cake-ab12.webp", "0123456789" },
        .{ "data/media/.cache/2026/11/cake-ab12-w400.webp", "01234" },
    };

    for (files) |file| {
        try scratch.dir.createDirPath(io, std.fs.path.dirname(file[0]).?);
        try scratch.dir.writeFile(io, .{
            .sub_path = file[0],
            .data = file[1],
        });
    }

    const database = try std.fs.path.join(arena, &.{ root, "data/publr.db" });
    const weighed = try weigh(io, arena, database, root);

    try std.testing.expectEqual(@as(u64, 5), weighed.database_bytes);
    try std.testing.expectEqual(@as(u64, 1), weighed.media_files);
    try std.testing.expectEqual(@as(u64, 10), weighed.media_bytes);
}
