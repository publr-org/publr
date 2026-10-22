//! `publr cloud deploy`: the site in this folder made a Publr Cloud project. The site is
//! packed (`bundle.zig`), uploaded to the account's dashboard, and made a project at the
//! address asked for; then the folder carries the link to it (`cloud.json`), and the Cloud
//! project is the site. Publr Studio calls the same endpoints itself. Nothing local
//! overwrites a live site: a linked folder is refused.
const std = @import("std");
const report = @import("../lib/report.zig");
const backup = @import("gate/backup.zig");
const bundle = @import("bundle.zig");

pub const link_name = "cloud.json";
pub const token_variable = "PUBLR_CLOUD_TOKEN";
pub const dashboard_variable = "PUBLR_CLOUD";
pub const dashboard_default = "https://cloud.publr.app";
/// Where the dashboard takes a packed site, and the operations around it.
pub const upload_path = "/api/cloud/bundles";
const answer_bytes_max: u32 = 64 << 10;
const upload_piece_bytes: u32 = 256 << 10;

pub const help =
    \\  cloud deploy --space <space> --slug <address> [--name <name>] [--cloud <dashboard>]
    \\                    This site made a Publr Cloud project at <address>, with the
    \\                    account token in PUBLR_CLOUD_TOKEN; the folder is linked to it
    \\
;

/// What the folder keeps about the project it was deployed as.
pub const Link = struct {
    dashboard: []const u8,
    space: []const u8,
    /// The project's record on the dashboard, and the id the host knows it by.
    project: []const u8,
    project_id: []const u8,
    slug: []const u8,
    address: []const u8,
    admin: []const u8,
    deployed_at_ms: i64,
};

const Options = struct {
    space: []const u8 = "",
    slug: []const u8 = "",
    name: []const u8 = "",
    dashboard: []const u8 = "",
};

const Deployed = struct {
    id: []const u8,
    slug: []const u8,
    project_id: []const u8,
    address: []const u8,
    admin: []const u8,
    state: []const u8,
};

/// Whether `args` is this command.
pub fn handles(args: []const []const u8) bool {
    std.debug.assert(args.len > 0);
    std.debug.assert(args.len <= 128);

    return args.len >= 2 and std.mem.eql(u8, args[0], "cloud") and
        std.mem.eql(u8, args[1], "deploy");
}

pub fn run(
    init: std.process.Init,
    out: *std.Io.Writer,
    db_path: [:0]const u8,
    args: []const []const u8,
) !u8 {
    std.debug.assert(handles(args));
    std.debug.assert(db_path.len > 0);

    const arena = init.arena.allocator();
    var options = parse(args[2..]) orelse {
        try out.print("usage:\n{s}", .{help});
        return 2;
    };
    const token = init.environ_map.get(token_variable) orelse {
        report.err("publr cloud deploy: set {s} to your account's token", .{token_variable});
        return 1;
    };

    if (options.dashboard.len == 0) {
        options.dashboard = init.environ_map.get(dashboard_variable) orelse dashboard_default;
    }

    if (try read_link(init.io, arena)) |link| {
        report.err("publr cloud deploy: this folder is {s}'s; its changes go up as a branch " ++
            "(not built yet), never over the live site", .{link.address});
        return 1;
    }

    const site = backup.Site.of(init.io, arena, db_path, null) catch |err| {
        report.err("publr cloud deploy: no site here ({s}: {t})", .{ db_path, err });
        return 1;
    };

    if (options.name.len == 0) {
        options.name = std.fs.path.basename(site.project_dir);
    }

    return deploy(init, out, site, token, options);
}

fn deploy(
    init: std.process.Init,
    out: *std.Io.Writer,
    site: backup.Site,
    token: []const u8,
    options: Options,
) !u8 {
    std.debug.assert(token.len > 0);
    std.debug.assert(options.slug.len > 0);

    const arena = init.arena.allocator();
    const client: Client = .{
        .io = init.io,
        .arena = arena,
        .dashboard = options.dashboard,
        .token = token,
    };

    if (!try address_free(client, out, options.slug)) {
        return 1;
    }

    const file = try std.fmt.allocPrint(arena, ".deploy{s}", .{bundle.extension});
    defer std.Io.Dir.cwd().deleteFile(init.io, file) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.log.warn("removing {s}: {t}", .{ file, err }),
    };

    try progress(out, "Packing the site", .{});

    const made = bundle.pack(site, arena, file, options.name) catch |err| {
        report.err("\npublr cloud deploy: packing the site failed: {t}", .{err});
        return 1;
    };

    try out.print("{d} files\n", .{made.files});

    const upload = try client.upload(out, file) orelse return 1;

    try progress(out, "Starting it on Cloud", .{});

    const sent = try std.json.Stringify.valueAlloc(arena, .{
        .space = options.space,
        .name = options.name,
        .slug = options.slug,
        .upload = upload,
    }, .{});
    const answer = try client.call("cloud/deploy_site", sent);
    const deployed = try client.answered(Deployed, answer) orelse return 1;

    try write_link(init, deployed, options);
    try out.print("done\n{s} is live at {s}\nAdmin: {s}\n" ++
        "This folder is linked to it ({s}).\n", .{
        options.name,
        deployed.address,
        deployed.admin,
        link_name,
    });

    return 0;
}

fn address_free(client: Client, out: *std.Io.Writer, slug: []const u8) !bool {
    std.debug.assert(slug.len > 0);
    std.debug.assert(client.token.len > 0);

    const Checked = struct {
        available: bool,
        reason: ?[]const u8 = null,
    };
    const sent = try std.json.Stringify.valueAlloc(client.arena, .{
        .slug = slug,
    }, .{});

    try progress(out, "Checking the address {s}", .{slug});

    const answer = try client.call("cloud/check_address", sent);
    const checked = try client.answered(Checked, answer) orelse return false;

    if (!checked.available) {
        try out.print("{s}\n", .{checked.reason orelse "not available"});
    } else {
        try out.print("available\n", .{});
    }

    return checked.available;
}

fn progress(out: *std.Io.Writer, comptime step: []const u8, values: anytype) !void {
    std.debug.assert(step.len > 0);
    std.debug.assert(!std.mem.endsWith(u8, step, "\n"));

    try out.print(step ++ "... ", values);
    try out.flush();
}

fn parse(args: []const []const u8) ?Options {
    std.debug.assert(args.len <= 128);

    var options: Options = .{};
    var index: u32 = 0;

    while (index + 1 < args.len) : (index += 2) {
        const flag = args[index];
        const value = args[index + 1];

        if (std.mem.eql(u8, flag, "--space")) {
            options.space = value;
        } else if (std.mem.eql(u8, flag, "--slug")) {
            options.slug = value;
        } else if (std.mem.eql(u8, flag, "--name")) {
            options.name = value;
        } else if (std.mem.eql(u8, flag, "--cloud")) {
            options.dashboard = std.mem.trimEnd(u8, value, "/");
        } else {
            return null;
        }
    }

    if (index != args.len or options.space.len == 0 or options.slug.len == 0) {
        return null;
    }

    return options;
}

/// The link the folder carries, or null when it has none.
pub fn read_link(io: std.Io, arena: std.mem.Allocator) !?Link {
    std.debug.assert(link_name.len > 0);
    std.debug.assert(answer_bytes_max > 0);

    const limit: std.Io.Limit = .limited(answer_bytes_max);
    const found = std.Io.Dir.cwd().readFileAlloc(io, link_name, arena, limit);
    const text = found catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    return try std.json.parseFromSliceLeaky(Link, arena, text, .{
        .ignore_unknown_fields = true,
    });
}

fn write_link(init: std.process.Init, deployed: Deployed, options: Options) !void {
    std.debug.assert(deployed.address.len > 0);
    std.debug.assert(options.space.len > 0);

    const arena = init.arena.allocator();
    const link: Link = .{
        .dashboard = options.dashboard,
        .space = options.space,
        .project = deployed.id,
        .project_id = deployed.project_id,
        .slug = deployed.slug,
        .address = deployed.address,
        .admin = deployed.admin,
        .deployed_at_ms = @import("../sdk.zig").context.wall_clock_ms(init.io),
    };
    const text = try std.json.Stringify.valueAlloc(arena, link, .{
        .whitespace = .indent_2,
    });

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = link_name,
        .data = text,
    });
}

const Reply = struct {
    status: std.http.Status,
    body: []const u8,
};

/// The account's dashboard, called with its token.
const Client = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    dashboard: []const u8,
    token: []const u8,

    /// `POST /api/<namespace>/<verb>` with a JSON body.
    fn call(client: Client, operation: []const u8, payload: []const u8) !Reply {
        std.debug.assert(operation.len > 0);
        std.debug.assert(payload.len > 0);

        const reply = try @import("remote.zig").post(client.io, client.arena, .{
            .url = try std.fmt.allocPrint(client.arena, "{s}/api/{s}", .{
                client.dashboard,
                operation,
            }),
            .payload = payload,
            .token = client.token,
        });

        return .{
            .status = reply.status,
            .body = reply.body,
        };
    }

    /// The answer as `Answer`; null, having said why, for a refusal.
    fn answered(client: Client, comptime Answer: type, reply: Reply) !?Answer {
        std.debug.assert(@typeInfo(Answer) == .@"struct");
        std.debug.assert(client.dashboard.len > 0);

        const ok = reply.status == .ok or reply.status == .created;

        if (ok) {
            return try std.json.parseFromSliceLeaky(Answer, client.arena, reply.body, .{
                .ignore_unknown_fields = true,
            });
        }

        const Refusal = struct {
            @"error": []const u8 = "",
            message: []const u8 = "",
        };
        const refusal = std.json.parseFromSliceLeaky(Refusal, client.arena, reply.body, .{
            .ignore_unknown_fields = true,
        }) catch Refusal{};
        const why = if (refusal.message.len > 0) refusal.message else refusal.@"error";

        report.err("\npublr cloud deploy: {s} answered {d}: {s}", .{
            client.dashboard,
            @intFromEnum(reply.status),
            why,
        });

        return null;
    }

    /// The packed site sent to the dashboard as it is read; the upload's name there.
    fn upload(client: Client, out: *std.Io.Writer, path: []const u8) !?[]const u8 {
        std.debug.assert(path.len > 0);
        std.debug.assert(upload_piece_bytes > 0);

        const reply = try @import("cloud_deploy/upload.zig").send(.{
            .io = client.io,
            .arena = client.arena,
            .url = try std.fmt.allocPrint(client.arena, "{s}{s}", .{
                client.dashboard,
                upload_path,
            }),
            .token = client.token,
            .path = path,
            .piece_bytes = upload_piece_bytes,
            .out = out,
        });
        const Uploaded = struct {
            upload: []const u8,
            bytes: u64,
        };
        const uploaded = try client.answered(Uploaded, .{
            .status = reply.status,
            .body = reply.body,
        }) orelse return null;

        return uploaded.upload;
    }
};
