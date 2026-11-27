//! A record's flow as core keeps it: each transition with its statuses as stored ids, and the
//! statuses a plugin adds to other plugins' flows (`publr/plugin/record_flow.zig` is what a
//! plugin writes).
const std = @import("std");
const flow_model = @import("../../model/flow.zig");
const content_type = @import("../../model/content_type.zig");
const status_module = @import("../../model/status.zig");
const record_flow = @import("../../publr/plugin/record_flow.zig");
const listed_in = @import("../../publr/plugin/define.zig").listed_in;

const List = record_flow.List;
const flow_given = record_flow.flow_given;
const status_id = record_flow.status_id;
const Transition = record_flow.Transition;
const Held = record_flow.Held;
const held_status = record_flow.held_status;
const any = record_flow.any;

/// Every transition by name, its `from` as stored ids: `any` is every status of the list
/// but the target and the trash.
pub fn transitions_of(comptime options: anytype) []const flow_model.Transition {
    comptime {
        std.debug.assert(options.name.len > 0);

        const Status = List(options);
        var list: []const flow_model.Transition = &.{};

        for (flow_given(options)) |step| {
            const to = @tagName(step.to);
            const every = step.from.len == 1 and step.from[0] == .any;
            var from: []const []const u8 = &.{};

            for (step.from) |leaving| {
                if (leaving == .any and !every) {
                    @compileError("record " ++ options.name ++ ": `publr.record.any` " ++
                        "stands alone in `.from`");
                }
            }

            const names = if (every) std.meta.fieldNames(Status) else names_of(step.from);

            for (names) |name| {
                const trash = std.mem.eql(u8, name, flow_model.trashed);

                if (!std.mem.eql(u8, name, to) and !trash) {
                    from = from ++ [_][]const u8{status_id(options.name, name)};
                }
            }

            const leaving_from = from;

            list = list ++ [_]flow_model.Transition{.{
                .name = @tagName(step.name),
                .from = leaving_from,
                .to = status_id(options.name, to),
                .label = step.label,
                .authorize = if (step.authorize) |answer| flow_model.Who.of(answer) else null,
                .from_any = every,
            }};
        }

        const done = list;

        return done;
    }
}

fn names_of(comptime from: anytype) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};

        std.debug.assert(from.len > 0);

        for (from) |leaving| {
            names = names ++ [_][]const u8{@tagName(leaving)};
        }

        const done = names;

        return done;
    }
}

/// The statuses and transitions a plugin adds to other plugins' flows
/// (`.register_statuses`): each status stored under the plugin's name, a transition's
/// statuses read as the added one, core's, or the owner's own.
pub fn registered_of(comptime Plugin: type) []const flow_model.Added {
    comptime {
        const plugin = Plugin.manifest.name;
        var list: []const flow_model.Added = &.{};

        std.debug.assert(plugin.len > 0);

        const adds = @hasDecl(Plugin, "options") and
            @hasField(@TypeOf(Plugin.options), "register_statuses");

        if (!adds) {
            return &.{};
        }

        for (Plugin.options.register_statuses) |entry| {
            if (std.mem.indexOfScalar(u8, entry.to, '.') == null) {
                @compileError("plugin " ++ plugin ++ ": `.register_statuses` adds to a type " ++
                    "named `<plugin>.<type>`, not `" ++ entry.to ++ "`");
            }

            const id = plugin ++ "." ++ entry.status;

            if (id.len > status_module.id_len_max) {
                @compileError("status " ++ id ++ ": a plugin's name and status come to at most 32");
            }

            var transitions: []const flow_model.Transition = &.{};

            for (entry.transitions) |step| {
                if (flow_model.reserved(step.name)) {
                    @compileError("plugin " ++ plugin ++ ": `" ++ step.name ++ "` is core's");
                }

                var from: []const []const u8 = &.{};

                for (step.from) |leaving| {
                    from = from ++ [_][]const u8{added_id(entry, plugin, leaving)};
                }

                const leaving_from = from;

                transitions = transitions ++ [_]flow_model.Transition{.{
                    .name = step.name,
                    .from = leaving_from,
                    .to = added_id(entry, plugin, step.to),
                    .label = step.label,
                }};
            }

            const done_transitions = transitions;
            const added: flow_model.Added = .{
                .to = entry.to,
                .plugin = plugin,
                .status = .{
                    .id = id,
                    .label = entry.label,
                },
                .transitions = done_transitions,
            };

            if (flow_model.way_out(added) == null) {
                @compileError("status " ++ id ++ ": needs a transition out of it into a " ++
                    "status the plugin does not add, for its records when it goes");
            }

            list = list ++ [_]flow_model.Added{added};
        }

        const done = list;

        return done;
    }
}

/// A status a registered transition names: the one the plugin adds, core's, or the owner's
/// own under the owner's plugin.
fn added_id(
    comptime entry: anytype,
    comptime plugin: []const u8,
    comptime name: []const u8,
) []const u8 {
    comptime {
        std.debug.assert(name.len > 0);

        if (std.mem.eql(u8, name, entry.status)) {
            return plugin ++ "." ++ name;
        }

        if (listed_in(record_flow.core_status_ids, name)) {
            return name;
        }

        return content_type.namespace_of(entry.to) ++ "." ++ name;
    }
}

test "a typed flow: lists, any, authorize, statuses under the plugin" {
    const Status = enum {
        draft,
        in_review,
        published,
    };
    const flow = [_]Transition(Status){
        .{
            .name = .submit,
            .from = &.{.draft},
            .to = .in_review,
            .label = "Submit for review",
        },
        .{
            .name = .withdraw,
            .from = any,
            .to = .draft,
            .label = "Withdraw",
            .authorize = .{
                .roles = &.{"editor"},
            },
        },
    };
    const options = .{
        .name = "guestbook.entry",
        .status = .{
            .list = Status,
            .start = .draft,
            .flow = &flow,
        },
    };
    const steps = comptime transitions_of(options);

    try std.testing.expectEqualStrings("guestbook.in_review", steps[0].to);
    try std.testing.expectEqualStrings("draft", steps[0].from[0]);
    try std.testing.expectEqual(@as(usize, 2), steps[1].from.len);
    try std.testing.expectEqualStrings("guestbook.in_review", steps[1].from[0]);
    try std.testing.expect(steps[1].authorize != null);
    const name = options.name;
    const in_review = held_status(Status, name, "guestbook.in_review");

    try std.testing.expectEqual(Held(Status).in_review, in_review);
    try std.testing.expectEqual(Held(Status).draft, held_status(Status, name, "draft"));
    try std.testing.expectEqual(Held(Status).other, held_status(Status, name, "shop.paid"));
}

test "a plugin's statuses on another plugin's flow: stored under its name, names resolved" {
    const Plugin = struct {
        pub const manifest = .{
            .name = "inventory",
        };
        pub const options = .{
            .register_statuses = .{.{
                .to = "orders.order",
                .status = "awaiting_stock",
                .label = "Awaiting stock",
                .transitions = .{
                    .{
                        .name = "await_stock",
                        .from = .{"paid"},
                        .to = "awaiting_stock",
                        .label = "Wait for stock",
                    },
                    .{
                        .name = "give_up",
                        .from = .{"awaiting_stock"},
                        .to = "archived",
                        .label = "Give up",
                    },
                },
            }},
        };
    };
    const added = comptime registered_of(Plugin);

    try std.testing.expectEqualStrings("inventory.awaiting_stock", added[0].status.id);
    try std.testing.expectEqualStrings("orders.paid", added[0].transitions[0].from[0]);
    try std.testing.expectEqualStrings("inventory.awaiting_stock", added[0].transitions[0].to);
    try std.testing.expectEqualStrings("archived", added[0].transitions[1].to);
}
