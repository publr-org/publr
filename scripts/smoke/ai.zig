//! A whole conversation against the running server, answered by a script: asked from the
//! CLI, its agent started beside the server as a drafts device, a command run as that
//! device, a destroying one listed for the person instead, the steps recorded, the turn
//! paused for them and the device revoked; the person keeps everything and the agent
//! carries on. Then the Overview signed in shows it.
const std = @import("std");
const smoke = @import("../smoke.zig");

const email = "ai@example.com";
const password = "ai smoke pass";
const prompt = "List the content types";
/// What the model answers, turn by turn: a command, then a destroying one, which pauses
/// the turn (its last words are never asked for).
const script =
    \\[{"parts":[{"kind":"text","text":"Looking at the types."},
    \\  {"kind":"tool_call","id":"c1","name":"run","input":{"args":["content_type","list"]}}],
    \\  "stop":"tool_calls","usage":{"input_tokens":10,"output_tokens":5}},
    \\ {"parts":[{"kind":"tool_call","id":"c2","name":"run",
    \\  "input":{"args":["record","purge","--id","0190a1b2c3d40001a1b2c3d4"]}}],
    \\  "stop":"tool_calls"},
    \\ {"parts":[{"kind":"text","text":"There are two content types."}],"stop":"end",
    \\  "usage":{"input_tokens":20,"output_tokens":6}}]
;

const Listed = struct {
    conversations: []const struct {
        id: []const u8,
        state: []const u8,
    },
};

pub fn expect_ai(init: std.process.Init, binary: []const u8, work_dir: []const u8) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(work_dir.len > 0);

    const arena = init.arena.allocator();
    const dir = try std.fmt.allocPrint(arena, "{s}/ai", .{work_dir});
    const script_path = try std.fmt.allocPrint(arena, "{s}/script.json", .{dir});
    const setup = [_][]const u8{
        "init", "--email", email, "--display_name", "Ai", "--password", password,
    };
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(init.io, dir);
    try cwd.writeFile(init.io, .{
        .sub_path = script_path,
        .data = script,
    });
    try smoke.expect_contains(init, binary, dir, &setup, "\"roles\": [");

    var environ = try init.environ_map.clone(arena);
    try environ.put("PUBLR_AI_SCRIPT", script_path);

    var child = try std.process.spawn(init.io, .{
        .argv = &.{ binary, "serve", "--port", "8094" },
        .cwd = .{
            .path = dir,
        },
        .environ_map = &environ,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    defer child.kill(init.io);

    _ = try smoke.read_port(init, child.stderr.?);

    const ask = [_][]const u8{ "--as", email, "ai", "ask", "--prompt", prompt };

    try smoke.expect_contains(init, binary, dir, &ask, "\"state\": \"running\"");

    const id = try finished(init, binary, dir);
    const read = [_][]const u8{ "--as", email, "ai", "conversation", "--id", id };

    const looked = "\"summary\": \"Looked at the content types\"";

    try smoke.expect_contains(init, binary, dir, &read, looked);
    try smoke.expect_contains(init, binary, dir, &read, "\"summary\": \"To remove: ");
    try smoke.expect_contains(init, binary, dir, &read, "\"state\": \"waiting\"");
    try smoke.expect_contains(init, binary, dir, &.{ "--as", email, "device", "list" }, "[]");

    const list_id = try waiting_list(init, binary, dir);
    const keep = [_][]const u8{ "--as", email, "removal", "decline", "--id", list_id };

    try smoke.expect_contains(init, binary, dir, &keep, "\"state\": \"kept\"");
    try smoke.expect_contains(init, binary, dir, &read, "\"state\": \"running\"");
}

/// The removal list waiting for the person: the one the agent made.
fn waiting_list(init: std.process.Init, binary: []const u8, dir: []const u8) ![]const u8 {
    std.debug.assert(binary.len > 0);

    const arena = init.arena.allocator();
    const result = try smoke.run_publr(init, binary, dir, &.{ "--as", email, "removal", "list" });
    const Lists = struct {
        lists: []const struct {
            id: []const u8,
        },
    };
    const listed = try std.json.parseFromSliceLeaky(Lists, arena, result.stdout, .{
        .ignore_unknown_fields = true,
    });

    if (listed.lists.len != 1) {
        std.debug.print("smoke: ai: no removal list waits\n", .{});
        return error.SmokeFailed;
    }

    return listed.lists[0].id;
}

/// The conversation's id once its turn waits for the person; within ten seconds.
fn finished(init: std.process.Init, binary: []const u8, dir: []const u8) ![]const u8 {
    std.debug.assert(binary.len > 0);
    std.debug.assert(dir.len > 0);

    const arena = init.arena.allocator();
    const list = [_][]const u8{ "--as", email, "ai", "conversations" };
    var attempts: u32 = 0;

    while (attempts < 50) : (attempts += 1) {
        const result = try smoke.run_publr(init, binary, dir, &list);
        const listed = try std.json.parseFromSliceLeaky(Listed, arena, result.stdout, .{
            .ignore_unknown_fields = true,
        });

        const over = listed.conversations.len == 1 and
            std.mem.eql(u8, listed.conversations[0].state, "waiting");

        if (over) {
            return listed.conversations[0].id;
        }

        try std.Io.sleep(init.io, .fromMilliseconds(200), .awake);
    }

    std.debug.print("smoke: ai: the conversation did not finish\n", .{});

    return error.SmokeFailed;
}
