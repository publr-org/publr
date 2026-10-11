//! The agent's browser against the running server: a scripted model asks for a browser
//! call, this script plays the workspace page (reads the call, says the extension is
//! there, answers it) and the turn goes on with the answer as a step.
const std = @import("std");
const smoke = @import("../smoke.zig");

const email = "browser@example.com";
const password = "browser smoke pass";
const script =
    \\[{"parts":[{"kind":"tool_call","id":"b1","name":"browser",
    \\  "input":{"action":"navigate","url":"https://example.com/"}}],"stop":"tool_calls"},
    \\ {"parts":[{"kind":"text","text":"It says Example Domain."}],"stop":"end"}]
;

const Read = struct {
    conversation: struct {
        state: []const u8,
    },
    browser_call: struct {
        number: u32 = 0,
        call: []const u8 = "",
    } = .{},
};

pub fn expect_browser(init: std.process.Init, binary: []const u8, work_dir: []const u8) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(work_dir.len > 0);

    const arena = init.arena.allocator();
    const dir = try std.fmt.allocPrint(arena, "{s}/browser", .{work_dir});
    const script_path = try std.fmt.allocPrint(arena, "{s}/script.json", .{dir});
    const setup = [_][]const u8{
        "init", "--email", email, "--display_name", "Browser", "--password", password,
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
        .argv = &.{ binary, "serve", "--port", "8097" },
        .cwd = .{
            .path = dir,
        },
        .environ_map = &environ,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    defer child.kill(init.io);

    _ = try smoke.read_port(init, child.stderr.?);

    const ask = [_][]const u8{ "--as", email, "ai", "ask", "--prompt", "Look at example.com" };
    const asked = try smoke.run_publr(init, binary, dir, &ask);
    const Asked = struct {
        id: []const u8,
    };
    const id = (try std.json.parseFromSliceLeaky(Asked, arena, asked.stdout, .{
        .ignore_unknown_fields = true,
    })).id;

    try answer_call(init, binary, dir, id);

    const read = [_][]const u8{ "--as", email, "ai", "conversation", "--id", id };

    try until_state(init, binary, dir, id, "finished");
    try smoke.expect_contains(init, binary, dir, &read, "\"summary\": \"Opened example.com\"");
    try smoke.expect_contains(init, binary, dir, &read, "Example Domain");
}

/// Waits for the agent's call, as the workspace page does, and answers it.
fn answer_call(init: std.process.Init, binary: []const u8, dir: []const u8, id: []const u8) !void {
    std.debug.assert(id.len > 0);
    std.debug.assert(dir.len > 0);

    const arena = init.arena.allocator();
    const read = [_][]const u8{ "--as", email, "ai", "conversation", "--id", id };
    var attempts: u32 = 0;

    while (attempts < 50) : (attempts += 1) {
        const result = try smoke.run_publr(init, binary, dir, &read);
        const parsed = try std.json.parseFromSliceLeaky(Read, arena, result.stdout, .{
            .ignore_unknown_fields = true,
        });

        if (parsed.browser_call.number == 1) {
            if (std.mem.indexOf(u8, parsed.browser_call.call, "navigate") == null) {
                std.debug.print("smoke: browser: the call is not the agent's\n", .{});
                return error.SmokeFailed;
            }

            const ready = [_][]const u8{ "--as", email, "ai", "browser_ready", "--id", id };
            const answered = "Opened https://example.com/: Example Domain";
            const answer = [_][]const u8{
                "--as",     email, "ai",       "browser_answer", "--id", id,
                "--number", "1",   "--answer", answered,
            };

            try smoke.expect_contains(init, binary, dir, &ready, "{");
            try smoke.expect_contains(init, binary, dir, &answer, "{");
            return;
        }

        try std.Io.sleep(init.io, .fromMilliseconds(200), .awake);
    }

    std.debug.print("smoke: browser: no call came\n", .{});

    return error.SmokeFailed;
}

fn until_state(
    init: std.process.Init,
    binary: []const u8,
    dir: []const u8,
    id: []const u8,
    state: []const u8,
) !void {
    std.debug.assert(id.len > 0);
    std.debug.assert(state.len > 0);

    const arena = init.arena.allocator();
    const read = [_][]const u8{ "--as", email, "ai", "conversation", "--id", id };
    var attempts: u32 = 0;

    while (attempts < 50) : (attempts += 1) {
        const result = try smoke.run_publr(init, binary, dir, &read);
        const parsed = try std.json.parseFromSliceLeaky(Read, arena, result.stdout, .{
            .ignore_unknown_fields = true,
        });

        if (std.mem.eql(u8, parsed.conversation.state, state)) {
            return;
        }

        try std.Io.sleep(init.io, .fromMilliseconds(200), .awake);
    }

    std.debug.print("smoke: browser: the conversation did not finish\n", .{});

    return error.SmokeFailed;
}
