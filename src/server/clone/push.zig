//! `publr push`: the clone in this folder and its base packed and sent up; the plugin that keeps
//! copies makes a branch of them, reviewed and merged there. Nothing local writes to live.
const std = @import("std");
const report = @import("../../lib/report.zig");
const backup = @import("../gate/backup.zig");
const bundle = @import("../bundle.zig");
const credentials = @import("../credentials.zig");
const upload = @import("../cloud_deploy/upload.zig");
const clone = @import("../clone.zig");
const placeholders = @import("placeholders.zig");
const linking = @import("link.zig");
const changes = @import("changes.zig");
const pulling = @import("pull.zig");

const push_path = "/api/environments/push";
const push_dir = ".publr/push";
const upload_piece_bytes: u32 = 256 << 10;
const base_dir = clone.base_dir;
const db_path = clone.db_path;

pub fn push(init: std.process.Init, out: *std.Io.Writer) !u8 {
    std.debug.assert(upload_piece_bytes > 0);

    const arena = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();
    var link = try linking.read(init.io, arena, cwd) orelse {
        report.err("publr push: not a clone here; `publr clone <address>` makes one", .{});
        return 1;
    };
    const site = try credentials.find(init, link.site) orelse {
        report.err("publr push: not signed in to {s}; run \"publr login {s}\"", .{
            link.site,
            link.site,
        });
        return pulling.signed_out;
    };
    const folder_path = try cwd.realPathFileAlloc(init.io, ".", arena);

    if (!try pulling.ensure_base(init, site, &link, folder_path)) {
        return 1;
    }

    // What is sent, named before packing: work made while it goes up is not in it.
    const sent = try changes.mark(init.io, arena, folder_path, link.since);

    if (sent.len == 0) {
        try out.print("Nothing to push: this folder is as {s} is\n", .{link.site});
        return 0;
    }

    try cwd.createDirPath(init.io, push_dir);
    defer cwd.deleteTree(init.io, push_dir) catch |err| {
        std.log.debug("removing {s}: {t}", .{ push_dir, err });
    };

    const folder = try backup.Site.of(init.io, arena, db_path, null);
    const base_db = try std.fs.path.join(arena, &.{ base_dir, db_path });
    const base = try backup.Site.of(init.io, arena, base_db, base_dir);
    const packed_site = push_dir ++ "/site" ++ bundle.extension;
    const packed_base = push_dir ++ "/base" ++ bundle.extension;

    // A placeholder still there goes up as it came down: the branch takes the live file.
    const kept_out = try placeholders.still_there(init.io, arena, ".");

    _ = try bundle.pack_clone(folder, arena, packed_site, link.branch, .{
        .placeholders = kept_out,
    });
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

    link.branch = pushed.name;
    link.pushed = sent;
    try linking.write(init.io, arena, cwd, link);
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
