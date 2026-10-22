//! A plugin's own log (`plugin.log`): the lines it logged with `ctx.log`, newest first, for
//! its Log tab. Read only; the lines are kept for good (`store/plugin_log.zig`).

const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{Log};

pub const Line = struct {
    id: i64,
    at: i64,
    /// `info`, `warn` or `err`.
    level: []const u8,
    line: []const u8,
    /// The operation, `job:<plugin>.<name>`, `event:<name>` or `sign_in:<provider>` it was
    /// logged in.
    call: []const u8,
};

pub const Log = struct {
    pub const name = "plugin.log";
    pub const description = "What a plugin logged, newest first";
    pub const details =
        \\Administrators only. The lines the plugin's code logged (`ctx.log`), each with
        \\its time, level and the call it ran in: an operation, a queued job's run
        \\(`job:<plugin>.<name>`) or a event's hooks (`event:<name>`). At most 100 lines a
        \\call. Page back with `before`, the id of the oldest line shown.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        name: []const u8,
        before: ?i64 = null,
        limit: u32 = 50,
    };
    pub const Out = struct {
        lines: []const Line,
    };
    pub const rules: sdk.operation.Rules(In) = .{
        .limit = .{
            .min = 1,
            .max = store.plugin_log.list_max,
        },
    };
    pub const example: In = .{
        .name = "greeter",
    };
    pub const example_out: Out = .{
        .lines = &.{.{
            .id = 1,
            .at = 1_790_000_000_000,
            .level = "info",
            .line = "Greeted with hi",
            .call = "greeter.greet",
        }},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The plugin, `greeter`",
        .before = "Only lines older than this id: the next page",
        .limit = "Page size",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .lines = "Newest first: id, time, level, the line, the call it ran in",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(in.limit <= store.plugin_log.list_max);

        if (in.name.len == 0) {
            return error.Invalid;
        }

        const rows = try store.plugin_log.of_plugin(
            ctx.db,
            ctx.arena,
            in.name,
            in.before,
            in.limit,
        );
        const lines = ctx.arena.alloc(Line, rows.len) catch return error.OutOfMemory;

        for (rows, lines) |row, *line| {
            line.* = .{
                .id = row.id,
                .at = row.at,
                .level = row.level,
                .line = row.line,
                .call = row.call,
            };
        }

        return .{
            .lines = lines,
        };
    }
};
