//! The admin parts that name an operation by type (a page's top bar count, panels, row
//! actions, Settings pages): the `publr.operation.define` named there is given its words and
//! its plugin's name, as in `.operations`.
const std = @import("std");
const operation_define = @import("operation_define.zig");

/// `Operation` as the core runs it: the definition with its words.
pub fn described(comptime Plugin: type, comptime Operation: type) type {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        if (!operation_define.is_definition(Operation)) {
            @compileError("plugin " ++ Plugin.manifest.name ++ ": an admin part names an " ++
                "operation made with `publr.operation.define`");
        }

        return operation_define.Described(Operation, Plugin.manifest.name, Plugin.docs);
    }
}

/// Each of `list`'s items with its `.operation` described.
pub fn each(comptime Plugin: type, comptime Item: type, comptime list: []const Item) []const Item {
    comptime {
        var out: []const Item = &.{};

        std.debug.assert(@hasField(Item, "operation"));
        std.debug.assert(list.len <= 64);

        for (list) |item| {
            var made = item;

            made.operation = described(Plugin, item.operation);
            out = out ++ [_]Item{made};
        }

        const done = out;

        return done;
    }
}

test "a definition named by an admin part is described" {
    const Words = @import("define.zig").Words(.{
        .{ "operation:tick", "Does nothing\n\nExample:\n  in: {}\n  out: {}" },
    });
    const Empty = struct {};
    const Tick = operation_define.define(Empty, Empty, .{
        .name = "tick",
        .kind = .read,
        .run = struct {
            fn run(_: anytype, _: Empty) !Empty {
                return .{};
            }
        }.run,
    });
    const Plugin = struct {
        pub const manifest = .{
            .name = "sampler",
        };
        pub const docs = Words;
    };

    try std.testing.expectEqualStrings("sampler.tick", described(Plugin, Tick).name);
    try std.testing.expectEqual(.read, described(Plugin, Tick).kind);
}
