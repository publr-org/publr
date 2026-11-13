//! What `publr mcp` tells the agent when it cannot reach the site yet: each says what to ask
//! the person or what to do next.
const std = @import("std");
const credentials = @import("../credentials.zig");

pub const is_a_site = "This folder is a Publr site itself: it works on itself, and is never " ++
    "linked to another.";

pub fn not_linked(init: std.process.Init, start: []const u8) ![]const u8 {
    std.debug.assert(start.len > 0);

    const arena = init.arena.allocator();

    if (!linkable(init, start)) {
        return no_project(arena, start);
    }

    const sites = try credentials.load(init);
    var text: std.Io.Writer.Allocating = .init(arena);

    try text.writer.print("This folder ({s}) is not linked to a Publr site yet. Ask your " ++
        "person which site it is for, then call `link` with its admin address.", .{start});

    if (sites.len == 0) {
        try text.writer.writeAll(" They find it on their site's Settings › Devices.");
    } else {
        try text.writer.writeAll("\n\nSites this computer is signed in to:");

        for (sites) |site| {
            try text.writer.print("\n- {s}", .{site.address});
        }
    }

    std.debug.assert(text.written().len > 0);

    return text.written();
}

/// A folder may be linked unless it is the home folder or the root: a link there would
/// reach every folder under it.
pub fn linkable(init: std.process.Init, start: []const u8) bool {
    std.debug.assert(start.len > 0);

    const trimmed = std.mem.trimEnd(u8, start, "/");
    const home = std.mem.trimEnd(u8, init.environ_map.get("HOME") orelse "", "/");

    return trimmed.len > 0 and !std.mem.eql(u8, trimmed, home);
}

pub fn no_project(arena: std.mem.Allocator, start: []const u8) ![]const u8 {
    std.debug.assert(start.len > 0);

    return std.fmt.allocPrint(arena, "No project folder is open (this runs in {s}). Ask " ++
        "your person to open their project's folder in this tool, then ask again.", .{start});
}

pub fn stopped(arena: std.mem.Allocator, folder: []const u8) ![]const u8 {
    std.debug.assert(folder.len > 0);

    return std.fmt.allocPrint(arena, "This folder is the Publr site in {s}, and nothing " ++
        "serves it. Start it there with `publr serve` (in the background; restart it if it " ++
        "runs from an older Publr), then ask again.", .{folder});
}

pub fn bad_link(arena: std.mem.Allocator, address: []const u8) ![]const u8 {
    std.debug.assert(address.len <= 64 << 10);

    return std.fmt.allocPrint(arena, "\"{s}\" is not an address this computer can sign in " ++
        "to. A site's admin address looks like https://shop--admin.publr.app.", .{address});
}

pub fn waiting(arena: std.mem.Allocator, approve: []const u8) ![]const u8 {
    std.debug.assert(approve.len > 0);

    return std.fmt.allocPrint(arena, "Your person approves this computer for the site in " ++
        "the browser that opened ({s}), and chooses what it may do. Tell them, and ask " ++
        "again once they have.", .{approve});
}

pub fn refused(arena: std.mem.Allocator, state: []const u8) ![]const u8 {
    std.debug.assert(state.len > 0);

    return std.fmt.allocPrint(arena, "The sign-in was {s}. Ask again to start over.", .{state});
}

test "the texts name what to do" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const waiting_text = try waiting(arena, "https://shop--admin.publr.app/admin/approve/x");

    try std.testing.expect(std.mem.indexOf(u8, waiting_text, "/admin/approve/x") != null);
    try std.testing.expect(std.mem.indexOf(u8, try stopped(arena, "/s"), "publr serve") != null);
    try std.testing.expect(std.mem.indexOf(u8, try refused(arena, "denied"), "denied") != null);
}
