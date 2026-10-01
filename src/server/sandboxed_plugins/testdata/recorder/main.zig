//! Keeps every structure change it hears, in its state, and answers them back: what a
//! plugin recording deployments does, for the smoke to see each change raise its notice.
//! Everything it brings takes the host's context, so its sandboxed build leaves it out.
const std = @import("std");
const publr = @import("publr");

const sdk = publr.sdk;
const Recorder = @This();

pub const manifest: publr.plugin.Manifest = .{
    .name = "recorder",
    .version = "0.1.0",
    .summary = "Keeps every structure change it hears, for the smoke",
};

pub const namespaces = [_]sdk.operation.Namespace{.{
    .name = "recorder",
    .summary = "The structure changes heard since the server started",
    .details = "Each as the notice's name and its subject, oldest first.",
}};

pub const operations = [_]type{Seen};
pub const middleware = [_]type{Heard};

pub const lines_max: u32 = 256;

pub const State = struct {
    arena: std.mem.Allocator = undefined,
    lines: [lines_max][]const u8 = undefined,
    count: u32 = 0,

    pub fn init(state: *State, process: publr.plugin.Process) anyerror!void {
        std.debug.assert(process.db_path.len > 0);

        state.* = .{ .arena = process.arena };
    }

    fn keep(state: *State, name: []const u8, subject: []const u8) void {
        std.debug.assert(state.count <= lines_max);

        if (state.count == lines_max) {
            return;
        }

        const line = std.fmt.allocPrint(state.arena, "{s} {s}", .{ name, subject }) catch {
            return;
        };

        state.lines[state.count] = line;
        state.count += 1;
    }
};

/// Every notice that changes the structure, kept as `name subject`.
pub const Heard = struct {
    pub const stage: sdk.middleware.Stage = .on;
    pub const reason = "Keeps the structure changes";

    pub fn run(ctx: *sdk.Ctx, event: sdk.middleware.Event) void {
        std.debug.assert(ctx.now_ms >= 0);

        const notice = switch (event) {
            .notice => |notice| notice,
            else => return,
        };
        const states = ctx.plugin_states orelse return;

        if (sdk.structure.is_change(notice.name)) {
            publr.plugin_states.from(states, Recorder).keep(notice.name, notice.subject);
        }
    }
};

pub const Seen = struct {
    pub const name = "recorder.seen";
    pub const description = "The structure changes heard since the server started";
    pub const details = "Administrators only.";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct { lines: []const []const u8 };
    pub const example: In = .{};
    pub const example_out: Out = .{ .lines = &.{"content_type.created post"} };

    pub fn run(ctx: *sdk.Ctx, _: In, granted: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(granted.allows());

        const states = ctx.plugin_states orelse return .{ .lines = &.{} };
        const state = publr.plugin_states.from(states, Recorder);

        return .{ .lines = state.lines[0..state.count] };
    }
};
