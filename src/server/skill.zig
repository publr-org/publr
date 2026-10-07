//! `publr skill`: the build-on-publr skill this binary carries (`skills/build-on-publr/`), so
//! the one an agent reads matches the Publr it drives. `publr skill install` writes it into
//! a project, where agents that load skills from a folder find it.
const std = @import("std");

pub const install_dir_default = ".claude/skills/build-on-publr";

const files = [_]struct { path: []const u8, text: []const u8 }{
    .{ .path = "SKILL.md", .text = @embedFile("skill") },
    .{ .path = "references/core-changes.md", .text = @embedFile("skill_core_changes") },
};

pub fn run(init: std.process.Init, out: *std.Io.Writer, args: []const []const u8) !u8 {
    std.debug.assert(files.len > 0);

    if (args.len == 0) {
        try out.writeAll(files[0].text);
        return 0;
    }

    const install = std.mem.eql(u8, args[0], "install");
    const named = args.len == 3 and std.mem.eql(u8, args[1], "--dir") and args[2].len > 0;

    if (!install or (args.len != 1 and !named)) {
        std.debug.print("usage: publr skill\n       publr skill install [--dir <path>]\n", .{});
        return 2;
    }

    const dir = if (named) args[2] else install_dir_default;

    try write_files(init, dir);
    try out.print("build-on-publr written to {s}/\n", .{dir});

    return 0;
}

fn write_files(init: std.process.Init, dir: []const u8) !void {
    std.debug.assert(dir.len > 0);

    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(init.io, dir);

    var root = try cwd.openDir(init.io, dir, .{});
    defer root.close(init.io);

    for (files) |file| {
        if (std.fs.path.dirname(file.path)) |sub| {
            try root.createDirPath(init.io, sub);
        }

        try root.writeFile(init.io, .{ .sub_path = file.path, .data = file.text });
    }
}
