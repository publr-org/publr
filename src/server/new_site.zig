//! `publr new <name>`: a new site in the folder beside you, run by this binary. A site is a
//! folder `publr` runs in: `publr.zon` (its name, and which binary is its own when that is
//! not where agents look first), `apps/`, `plugins/`, and `data/` once it first runs.
//!
//! ```
//! sites/
//!   publr          the binary every site here runs
//!   blog/          publr.zon, apps/, plugins/, data/
//!   shop/
//! ```
const std = @import("std");

pub const name_len_max: u32 = 64;

/// Where an agent looks for a site's binary, from the site's folder, before `publr.zon`'s
/// `.binary` is needed: beside the site's files, or one folder up, built or downloaded.
pub const standard_places = [_][]const u8{
    "publr",
    "../publr",
    "zig-out/bin/publr",
    "../zig-out/bin/publr",
};

pub fn run(init: std.process.Init, out: *std.Io.Writer, args: []const []const u8) !u8 {
    std.debug.assert(standard_places.len > 0);

    if (args.len != 1 or !valid_name(args[0])) {
        std.debug.print("usage: publr new <name>   (letters, digits and dashes)\n", .{});
        return 2;
    }

    const name = args[0];
    const arena = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();

    if (cwd.access(init.io, name, .{})) |_| {
        std.debug.print("publr new: {s} is there already\n", .{name});
        return 1;
    } else |_| {}

    try cwd.createDirPath(init.io, try std.fs.path.join(arena, &.{ name, "apps" }));
    try cwd.createDirPath(init.io, try std.fs.path.join(arena, &.{ name, "plugins" }));

    const binary = try binary_entry(init, name);
    const zon = if (binary) |path|
        try std.fmt.allocPrint(arena, ".{{\n    .name = \"{s}\",\n    .binary = \"{s}\",\n}}\n", .{
            name,
            path,
        })
    else
        try std.fmt.allocPrint(arena, ".{{\n    .name = \"{s}\",\n}}\n", .{name});

    try cwd.writeFile(init.io, .{
        .sub_path = try std.fs.path.join(arena, &.{ name, "publr.zon" }),
        .data = zon,
    });
    try print_next(out, name, binary);

    return 0;
}

/// `[a-z0-9][a-z0-9-]*`, up to 64 characters: a folder name on every system.
pub fn valid_name(name: []const u8) bool {
    std.debug.assert(name_len_max > 0);

    if (name.len == 0 or name.len > name_len_max or name[0] == '-') {
        return false;
    }

    for (name) |char| {
        if (!std.ascii.isLower(char) and !std.ascii.isDigit(char) and char != '-') {
            return false;
        }
    }

    return true;
}

/// This binary's path for `publr.zon`, from the new site's folder; null when it sits in one
/// of the standard places, where nothing needs saying.
fn binary_entry(init: std.process.Init, name: []const u8) !?[]const u8 {
    std.debug.assert(name.len > 0);

    const arena = init.arena.allocator();
    const executable = try std.process.executablePathAlloc(init.io, arena);
    const site = try std.Io.Dir.cwd().realPathFileAlloc(init.io, name, arena);
    const relative = try std.fs.path.relative(arena, "/", null, site, executable);

    for (standard_places) |place| {
        if (std.mem.eql(u8, relative, place)) {
            return null;
        }
    }

    std.debug.assert(relative.len > 0);

    // Near, the site and its binary move together; far, the absolute path says it plainly.
    const hops = std.mem.count(u8, relative, "../");

    return if (hops > 2) executable else relative;
}

fn print_next(out: *std.Io.Writer, name: []const u8, binary: ?[]const u8) !void {
    std.debug.assert(name.len > 0);

    const command = binary orelse "../publr";

    try out.print(
        \\Made {s}/: publr.zon, apps/, plugins/.
        \\
        \\Next:
        \\  cd {s}
        \\  {s} serve        # prints its address; open it to create the first admin
        \\
    , .{ name, name, command });
}

test "site names are plain folder names" {
    try std.testing.expect(valid_name("blog"));
    try std.testing.expect(valid_name("shop-2"));
    try std.testing.expect(!valid_name("-x"));
    try std.testing.expect(!valid_name("Blog"));
    try std.testing.expect(!valid_name("a/b"));
    try std.testing.expect(!valid_name(""));
}
