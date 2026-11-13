//! The clone's download: what it would bring down (`--size`) and the bundle, piece by piece.
const std = @import("std");
const report = @import("../../lib/report.zig");
const credentials = @import("../credentials.zig");
const site_side = @import("site.zig");
const progress = @import("progress.zig");

const piece_bytes_max = site_side.piece_bytes_max;
const pack_poll_ms: u32 = 300;

/// `--size`: what a clone would bring down, as JSON, for the agent to ask its person with.
pub fn say_size(init: std.process.Init, out: *std.Io.Writer, site: credentials.Site) !u8 {
    std.debug.assert(site.token.len > 0);

    const text = try size_text(init, site) orelse return 1;

    try out.print("{s}\n", .{text});

    return 0;
}

/// What a clone of `site` would bring down; null, having said why, when it does not say.
pub fn size_of(init: std.process.Init, site: credentials.Site) !?site_side.Size {
    std.debug.assert(site.token.len > 0);

    const text = try size_text(init, site) orelse return null;

    return try std.json.parseFromSliceLeaky(site_side.Size, init.arena.allocator(), text, .{
        .ignore_unknown_fields = true,
    });
}

fn size_text(init: std.process.Init, site: credentials.Site) !?[]const u8 {
    std.debug.assert(site.token.len > 0);

    const answer = try asked(init.io, init.arena.allocator(), site, site_side.size_route);

    if (answer.status != .ok) {
        report.err("publr clone: {s} answered {d} when asked its size", .{
            site.address,
            @intFromEnum(answer.status),
        });
        return null;
    }

    return answer.body;
}

const Answer = struct {
    status: std.http.Status,
    body: []const u8,
};

/// `GET <route>` on the site, as the device signed in there.
fn asked(io: std.Io, arena: std.mem.Allocator, site: credentials.Site, route: []const u8) !Answer {
    std.debug.assert(site.token.len > 0);
    std.debug.assert(route.len > 0 and route[0] == '/');

    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ site.address, route });
    var body: std.Io.Writer.Allocating = .init(arena);
    var client: std.http.Client = .{
        .allocator = arena,
        .io = io,
    };
    defer client.deinit();

    const result = try client.fetch(.{
        .location = .{
            .url = url,
        },
        .keep_alive = false,
        .extra_headers = &.{.{
            .name = "Authorization",
            .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{site.token}),
        }},
        .response_writer = &body.writer,
    });

    return .{
        .status = result.status,
        .body = body.written(),
    };
}

/// The pack the site started, followed until it is made, how far it is told to the page;
/// null when it failed, with why in `why`, for people.
pub fn wait_for_pack(
    init: std.process.Init,
    site: credentials.Site,
    shared: *progress.Shared,
    why: *[]const u8,
) !?site_side.Prepared {
    std.debug.assert(site.token.len > 0);
    std.debug.assert(shared.phase.load(.acquire) == @intFromEnum(progress.Phase.packing));

    while (true) {
        var state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer state.deinit();

        const arena = state.allocator();
        const answer = try asked(init.io, arena, site, site_side.pack_progress_route);

        if (answer.status != .ok) {
            why.* = "The site stopped saying how far the packing is.";
            return null;
        }

        const packing = try std.json.parseFromSliceLeaky(site_side.Packing, arena, answer.body, .{
            .ignore_unknown_fields = true,
        });

        shared.packed_through.store(packing.through, .release);

        if (packing.made) |made| {
            const kept = init.arena.allocator();

            return .{
                .bytes = made.bytes,
                .publr = try kept.dupe(u8, made.publr),
                .name = try kept.dupe(u8, made.name),
                .parts = made.parts,
            };
        }

        if (!std.mem.eql(u8, packing.state, "packing")) {
            why.* = "The site could not pack itself. Its own log says why.";
            return null;
        }

        try std.Io.sleep(init.io, .fromMilliseconds(pack_poll_ms), .awake);
    }
}

/// The bundle's pieces, in order, into `path`.
pub fn fetch_bundle(
    init: std.process.Init,
    site: credentials.Site,
    bytes: u64,
    path: []const u8,
    shared: *progress.Shared,
) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(site.address.len > 0);

    const clock = @import("../../sdk.zig").context;

    shared.total_bytes.store(bytes, .release);
    shared.started_ms.store(clock.wall_clock_ms(init.io), .release);
    shared.enter(.downloading);

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
        shared.done_bytes.store(offset, .release);
        shared.now_ms.store(clock.wall_clock_ms(init.io), .release);

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
        site_side.pack_route,
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
