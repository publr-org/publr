//! The Overview's setup for an agent on another computer: one command, run in the folder the
//! agent works in, carrying a sign-in offered to the person looking (`device offer`), and
//! a longer prompt saying the same for an agent to run itself.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const offer = @import("../../operations/device/offer.zig");
const agent_script = @import("../../server/agent_script.zig");

/// The command and the prompt for the site at `site`, with a sign-in made now; empty
/// when none can be offered (a caller that is not a person).
pub const Setup = struct {
    command: []const u8,
    prompt: []const u8,
};

pub fn of(session: *admin.Session, site: []const u8) admin.Error!Setup {
    std.debug.assert(session.signed_in());
    std.debug.assert(site.len > 0);

    const offered = registry.SDK.dispatch(&session.ctx, offer.Offer, .{}) catch {
        session.ctx.failure = null;
        return .{
            .command = "",
            .prompt = "",
        };
    };
    const arena = session.arena;
    const command = try print(arena, "curl -fsSL {s}{s}{s} | sh", .{
        site,
        agent_script.prefix,
        offered.code,
    });
    const working = if (registry.work_start != null)
        try print(arena, branch_work, .{ site, site })
    else
        try print(arena, live_work, .{});

    return .{
        .command = command,
        .prompt = try print(arena, prompt, .{ site, command, site, site, working }),
    };
}

fn print(arena: std.mem.Allocator, comptime format: []const u8, args: anytype) admin.Error![]u8 {
    return std.fmt.allocPrint(arena, format, args) catch error.OutOfMemory;
}

const prompt =
    \\Set up Publr in this folder so you can build my site at {s}, then wait for what I ask.
    \\
    \\1. Run this in a terminal in this folder. It works once, within ten minutes:
    \\
    \\   {s}
    \\
    \\   It installs the publr command in ~/.local/bin, signs this computer in to my site and
    \\   puts the Publr skill in .agents/skills and .claude/skills. If it says it was used or
    \\   is too old, ask me for a new prompt from my site's Overview.
    \\2. Read the skill (.claude/skills/build-on-publr/SKILL.md, the same in .agents/skills)
    \\   and run `publr agents` for the whole guide. If `publr` is not found yet, use
    \\   ~/.local/bin/publr.
    \\3. My site runs elsewhere: send it every command with `publr --site {s} <command>`.
    \\   `publr --site {s} --help` lists what it can do, its plugins included.
    \\4. {s}
    \\5. Never ask me for a password or a token.
    \\
;

const branch_work =
    \\Your changes go to a branch of my site, never the live site. Start one for each task
    \\   with `publr --site {s} work start --name "<the task>"`; your later commands from
    \\   this folder go there. When you are done, give me its Preview and Merge links. Change
    \\   the live site only when I ask, adding `--production` to that call (`publr --site
    \\   {s} --production <command>`).
;

const live_work =
    \\Your changes go to the live site straight away: say what you will change before you
    \\   do, and tell me what you changed.
;
