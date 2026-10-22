//! `publr.query.prepare(@embedFile("queries/recent.groq"), .{})`, then
//! `recent.execute(ctx, []const Post, .{ .category = "engineering" })`: GROQ, never a query
//! language of our own. Parameters are the query's `$names`, bound from a struct and never
//! written into the text; a `$name` the struct lacks, or a field the query never names,
//! fails the build.
const queue = @import("queue.zig");
const std = @import("std");
const sdk = @import("../../sdk.zig");
const record = @import("../../operations/record.zig");
const PluginCtx = @import("context.zig").PluginCtx;

pub const params_max: u32 = 32;

pub const Options = struct {
    /// Read trashed records too; every other query leaves them out.
    trashed: bool = false,
};

pub fn prepare(comptime text: []const u8, comptime options: Options) type {
    comptime {
        std.debug.assert(text.len > 0);

        const names = param_names(text);

        return struct {
            pub const query = text;
            pub const given = options;
            pub const parameters = names;

            /// Runs the query as the caller, its answer read into `Result`.
            pub fn execute(
                any_ctx: anytype,
                comptime Result: type,
                params: anytype,
            ) sdk.Error!Result {
                const ctx = queue.base_of(any_ctx);

                comptime check_params(text, names, @TypeOf(params));
                std.debug.assert(text.len > 0);

                const arena = ctx.arena();
                // `.{}` is an empty tuple, which JSON writes as `[]`: no parameters are `{}`.
                const bound = if (comptime std.meta.fields(@TypeOf(params)).len == 0)
                    "{}"
                else
                    std.json.Stringify.valueAlloc(arena, params, .{}) catch {
                        return error.OutOfMemory;
                    };
                const answer = try ctx.call(record.Query, .{
                    .query = text,
                    .params = bound,
                    .trashed = options.trashed,
                });

                return std.json.parseFromSliceLeaky(Result, arena, answer.result.text, .{
                    .ignore_unknown_fields = true,
                    .allocate = .alloc_always,
                }) catch error.Invalid;
            }
        };
    }
}

/// Every `$name` the query uses, each once, outside strings.
pub fn param_names(comptime text: []const u8) []const []const u8 {
    comptime {
        @setEvalBranchQuota(text.len * 40 + 2_000);

        var names: []const []const u8 = &.{};
        var index: u32 = 0;
        var quote: ?u8 = null;

        while (index < text.len) : (index += 1) {
            const char = text[index];

            if (quote) |open| {
                if (char == '\\') {
                    index += 1;
                } else if (char == open) {
                    quote = null;
                }

                continue;
            }

            if (char == '"' or char == '\'') {
                quote = char;
                continue;
            }

            if (char != '$') {
                continue;
            }

            const start = index + 1;
            var end = start;

            while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) {
                end += 1;
            }

            const name = text[start..end];

            if (name.len > 0 and !contains(names, name)) {
                names = names ++ [_][]const u8{name};
            }

            index = end - 1;
        }

        if (names.len > params_max) {
            @compileError("query: more than 32 parameters");
        }

        return names;
    }
}

fn check_params(
    comptime text: []const u8,
    comptime names: []const []const u8,
    comptime Params: type,
) void {
    comptime {
        std.debug.assert(text.len > 0);

        const fields = std.meta.fieldNames(Params);

        for (names) |name| {
            if (!contains(fields, name)) {
                @compileError("query uses `$" ++ name ++ "`, which the parameters lack");
            }
        }

        for (fields) |field| {
            if (!contains(names, field)) {
                @compileError("query never uses `$" ++ field ++ "`");
            }
        }
    }
}

fn contains(comptime list: []const []const u8, comptime name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (list) |candidate| {
        if (std.mem.eql(u8, candidate, name)) {
            return true;
        }
    }

    return false;
}

test "a query's parameters, outside its strings" {
    const names = comptime param_names(
        \\*[_type == "post" && category == $category && title != "$not" && date > $since]
        \\[$from...$to] { "c": $category }
    );

    try std.testing.expectEqual(4, names.len);
    try std.testing.expectEqualStrings("category", names[0]);
    try std.testing.expectEqualStrings("since", names[1]);
    try std.testing.expectEqualStrings("from", names[2]);
    try std.testing.expectEqualStrings("to", names[3]);

    comptime check_params("total == $total", &.{"total"}, struct {
        total: u32,
    });
}
