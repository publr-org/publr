//! `publr skill`: the build-on-publr skill this binary carries (`skills/build-on-publr/`), so
//! the one an agent reads matches the Publr it drives. `publr skill install` writes it into
//! the folder, where agents that load skills find it: the Agent Skills folder most read
//! (`.agents/skills`) and Claude Code's, or the one agent named.
const std = @import("std");

const skill_name = "build-on-publr";

/// Where each agent reads a folder's skills from.
const agents = [_]struct {
    name: []const u8,
    dir: []const u8,
}{
    .{
        .name = "claude",
        .dir = ".claude/skills/" ++ skill_name,
    },
    .{
        .name = "codex",
        .dir = ".agents/skills/" ++ skill_name,
    },
    .{
        .name = "cursor",
        .dir = ".cursor/skills/" ++ skill_name,
    },
    .{
        .name = "pi",
        .dir = ".pi/skills/" ++ skill_name,
    },
};

/// With no agent named: the shared Agent Skills folder (Codex, Cursor, Pi and others read
/// it) and Claude Code's, which reads only its own.
const dirs_default = [_][]const u8{ ".agents/skills/" ++ skill_name, agents[0].dir };

const usage =
    \\usage: publr skill
    \\       publr skill install [--agent claude|codex|cursor|pi | --dir <path>]
    \\
;

const files = [_]struct {
    path: []const u8,
    text: []const u8,
}{
    .{
        .path = "SKILL.md",
        .text = @embedFile("skill"),
    },
    .{
        .path = "references/core-changes.md",
        .text = @embedFile("skill_core_changes"),
    },
};

pub fn run(init: std.process.Init, out: *std.Io.Writer, args: []const []const u8) !u8 {
    std.debug.assert(files.len > 0);

    if (args.len == 0) {
        try out.writeAll(files[0].text);
        return 0;
    }

    if (!std.mem.eql(u8, args[0], "install") or (args.len != 1 and args.len != 3)) {
        std.debug.print(usage, .{});
        return 2;
    }

    const named = if (args.len == 3) dirs_of(args[1..]) else &dirs_default;
    const dirs = named orelse {
        std.debug.print(usage, .{});
        return 2;
    };

    for (dirs) |dir| {
        try write_files(init, dir);
        try out.print("{s} written to {s}/\n", .{ skill_name, dir });
    }

    return 0;
}

/// The one folder `--agent <name>` or `--dir <path>` names; null for anything else.
fn dirs_of(flag: []const []const u8) ?[]const []const u8 {
    std.debug.assert(flag.len == 2);
    std.debug.assert(agents.len > 0);

    if (flag[1].len == 0) {
        return null;
    }

    if (std.mem.eql(u8, flag[0], "--dir")) {
        return flag[1..2];
    }

    if (!std.mem.eql(u8, flag[0], "--agent")) {
        return null;
    }

    inline for (agents) |agent| {
        if (std.mem.eql(u8, flag[1], agent.name)) {
            return &.{agent.dir};
        }
    }

    return null;
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

        try root.writeFile(init.io, .{
            .sub_path = file.path,
            .data = file.text,
        });
    }
}

test "an agent named gets its own folder, and nothing else is taken" {
    const claude = dirs_of(&.{ "--agent", "claude" }).?;
    const cursor = dirs_of(&.{ "--agent", "cursor" }).?;

    try std.testing.expectEqualStrings(".claude/skills/build-on-publr", claude[0]);
    try std.testing.expectEqualStrings(".cursor/skills/build-on-publr", cursor[0]);
    try std.testing.expectEqualStrings("here", dirs_of(&.{ "--dir", "here" }).?[0]);
    try std.testing.expect(dirs_of(&.{ "--agent", "copilot" }) == null);
    try std.testing.expect(dirs_of(&.{ "--dir", "" }) == null);
    try std.testing.expect(dirs_of(&.{ "--force", "x" }) == null);
}
