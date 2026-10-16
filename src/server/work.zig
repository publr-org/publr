//! The work a folder has open on a Publr elsewhere: a copy of the project (on Publr Cloud, a
//! branch) that commands from the folder go to instead of the project, until `publr work
//! done`. `work start` is the server's own command, where a hosting service brings it; what
//! it answers is kept in `.publr/work.json` in the folder.
const std = @import("std");

pub const path = ".publr/work.json";
const file_bytes_max: u32 = 16 << 10;

/// The open work. `site` is the address signed in to; `address` where commands go now.
pub const Work = struct {
    site: []const u8,
    name: []const u8,
    address: []const u8,
    preview: []const u8 = "",
    merge: []const u8 = "",
};

/// What `work start` answers, as the server prints it.
const Started = struct {
    name: []const u8,
    address: []const u8,
    preview: []const u8 = "",
    merge: []const u8 = "",
};

/// Said when the Publr there has no `work start`: a self-hosted one.
pub const not_hosted = "Branches are a Publr Cloud feature: changes here go straight to the site.";

/// The work open in this folder; null when there is none, or it is for another site.
pub fn open(init: std.process.Init, site: ?[]const u8) !?Work {
    std.debug.assert(file_bytes_max > 0);

    const arena = init.arena.allocator();
    const limit: std.Io.Limit = .limited(file_bytes_max);
    const text = std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, limit) catch |err| {
        return switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    };
    const work = std.json.parseFromSliceLeaky(Work, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;

    if (work.address.len == 0) {
        return null;
    }

    if (site) |wanted| {
        if (!std.mem.eql(u8, wanted, work.site)) {
            return null;
        }
    }

    return work;
}

/// The work `work start` answered for `site` with `text`; null when it is not one.
pub fn started(arena: std.mem.Allocator, site: []const u8, text: []const u8) ?Work {
    std.debug.assert(site.len > 0);

    const answer = std.json.parseFromSliceLeaky(Started, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;

    if (answer.address.len == 0 or answer.name.len == 0) {
        return null;
    }

    return .{
        .site = site,
        .name = answer.name,
        .address = answer.address,
        .preview = answer.preview,
        .merge = answer.merge,
    };
}

/// Keeps `work` as the folder's open work, replacing any other, and says where commands go.
pub fn keep(init: std.process.Init, work: Work) !void {
    std.debug.assert(work.address.len > 0);
    std.debug.assert(work.site.len > 0);

    const arena = init.arena.allocator();
    const text = try std.json.Stringify.valueAlloc(arena, work, .{
        .whitespace = .indent_2,
    });
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(init.io, std.fs.path.dirname(path).?);

    var file = try cwd.createFile(init.io, path, .{});
    defer file.close(init.io);

    try file.writeStreamingAll(init.io, text);
    var said: std.Io.Writer.Allocating = .init(arena);

    try said.writer.print("publr: working in the branch {s}; commands from this folder go " ++
        "there\n", .{work.name});
    try describe(&said.writer, work);
    std.debug.print("{s}", .{said.written()});
}

/// `publr work`, `publr work done`: the folder's open work, and forgetting it.
pub fn run(init: std.process.Init, out: *std.Io.Writer, args: []const []const u8) !u8 {
    std.debug.assert(args.len > 0);
    std.debug.assert(std.mem.eql(u8, args[0], "work"));

    const done = args.len == 2 and std.mem.eql(u8, args[1], "done");

    if (args.len > 1 and !done) {
        std.debug.print("usage: publr work | publr work done | publr --site <address> " ++
            "work start --name <what>\n", .{});
        return 2;
    }

    const work = try open(init, null) orelse {
        try out.print("No work open in this folder: commands go to the site itself.\n", .{});
        return 0;
    };

    if (done) {
        try std.Io.Dir.cwd().deleteFile(init.io, path);
        try out.print("Done with {s}; commands from this folder go to {s} again.\n", .{
            work.name,
            work.site,
        });
    } else {
        try out.print("Working in the branch {s} of {s}\n", .{ work.name, work.site });
    }

    try describe(out, work);

    return 0;
}

fn describe(out: *std.Io.Writer, work: Work) !void {
    std.debug.assert(work.name.len > 0);

    if (work.preview.len > 0) {
        try out.print("  Preview  {s}\n", .{work.preview});
    }

    if (work.merge.len > 0) {
        try out.print("  Merge    {s}  (a person reviews it)\n", .{work.merge});
    }

    try out.flush();
}

/// The name of work started for a write sent without one: when it was sent.
pub fn name_now(arena: std.mem.Allocator, now_s: u64) ![]const u8 {
    std.debug.assert(now_s > 0);

    const epoch: std.time.epoch.EpochSeconds = .{
        .secs = now_s,
    };
    const day = epoch.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const time = epoch.getDaySeconds();

    return std.fmt.allocPrint(arena, "Agent work {d}-{d:0>2}-{d:0>2} {d:0>2}{d:0>2}", .{
        day.year,
        month.month.numeric(),
        month.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
    });
}

test "work start's answer becomes the folder's work" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\{"name":"recipes","address":"https://ada--recipes.publr.app","merge":"m"}
    ;

    const work = started(arena, "https://ada.publr.app", text).?;
    try std.testing.expectEqualStrings("recipes", work.name);
    try std.testing.expectEqualStrings("https://ada.publr.app", work.site);
    try std.testing.expect(started(arena, "https://ada.publr.app", "{}") == null);
    try std.testing.expect(started(arena, "https://ada.publr.app", "not json") == null);
}

test "work started for a write is named after when it was sent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const name = try name_now(arena_state.allocator(), 1_792_160_700);
    try std.testing.expectEqualStrings("Agent work 2026-10-16 1425", name);
}
