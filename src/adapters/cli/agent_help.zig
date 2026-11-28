//! What an agent reads first when it asks for help: a short block sending it to
//! `publr find` instead of walking every namespace's `--help`. Shown only when the process
//! runs inside an agent, known by the variables agent tools set in the shells they run
//! (`CLAUDECODE`, `AI_AGENT`, ...). Only the help text changes: what a command does and
//! answers never depends on who runs it.
const std = @import("std");

/// Variables an agent tool sets in the shells it runs, each naming that tool (after
/// Cloudflare's `cf`, `packages/cli/src/lib/agent-context.ts`). `AI_AGENT` is the marker
/// meant for every agent, which `gh` reads too.
pub const markers = [_][]const u8{
    "AI_AGENT",             "CLAUDECODE",        "CLAUDE_CODE_SESSION_ID",
    "CURSOR_AGENT",         "CODEX_THREAD_ID",   "GEMINI_CLI",
    "COPILOT_AGENT",        "COPILOT_CLI",       "OPENCODE",
    "CLINE_ACTIVE",         "AUGMENT_AGENT",     "AMP_CURRENT_THREAD_ID",
    "QWEN_CODE_SESSION_ID", "PI_CODING_AGENT",   "KIRO_SESSION_ID",
    "GOOSE_TERMINAL",       "ANTIGRAVITY_AGENT", "CRUSH",
};

pub const block =
    \\=== For agents: finding commands ===
    \\Don't explore by running `--help` on one namespace after another. First run:
    \\  publr find "<what you want to do>"
    \\It answers the five commands and guide entries that fit best, as JSON. Then run
    \\`publr <namespace> <verb> --help` on the one you pick. Describe the action and what
    \\it is on, never names, emails or ids. The guide is `publr agents`.
    \\=== End ===
    \\
    \\
;

/// Whether one of the markers is set to something other than an empty or false-like value.
pub fn running_in_agent(environment: anytype) bool {
    comptime std.debug.assert(markers.len > 0);

    for (markers) |name| {
        const value = environment.get(name) orelse continue;

        if (!false_like(value)) {
            return true;
        }
    }

    return false;
}

fn false_like(value: []const u8) bool {
    std.debug.assert(value.len < 1 << 20);

    const trimmed = std.mem.trim(u8, value, " ");
    const words = [_][]const u8{ "", "0", "false", "no", "off" };

    for (words) |word| {
        if (std.ascii.eqlIgnoreCase(trimmed, word)) {
            return true;
        }
    }

    return false;
}

/// Whether a command line asks for help: nothing at all, or a `--help` anywhere in it.
pub fn asks_for_help(args: []const []const u8) bool {
    std.debug.assert(args.len <= 1 << 16);

    if (args.len == 0) {
        return true;
    }

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return true;
        }
    }

    return false;
}

const Fake = struct {
    name: []const u8,
    value: []const u8,

    pub fn get(fake: Fake, name: []const u8) ?[]const u8 {
        return if (std.mem.eql(u8, fake.name, name)) fake.value else null;
    }
};

test "an agent is known by its tool's variable, set to something true" {
    try std.testing.expect(running_in_agent(Fake{
        .name = "CLAUDECODE",
        .value = "1",
    }));
    try std.testing.expect(running_in_agent(Fake{
        .name = "AI_AGENT",
        .value = "my_agent",
    }));
    try std.testing.expect(!running_in_agent(Fake{
        .name = "CLAUDECODE",
        .value = "0",
    }));
    try std.testing.expect(!running_in_agent(Fake{
        .name = "AI_AGENT",
        .value = " False ",
    }));
    try std.testing.expect(!running_in_agent(Fake{
        .name = "TERM",
        .value = "xterm",
    }));
}

test "help is asked for by no words or a --help anywhere" {
    try std.testing.expect(asks_for_help(&.{}));
    try std.testing.expect(asks_for_help(&.{ "taxonomy", "--help" }));
    try std.testing.expect(asks_for_help(&.{ "taxonomy", "create", "-h" }));
    try std.testing.expect(!asks_for_help(&.{ "taxonomy", "list" }));
}
