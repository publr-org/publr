//! A record's statuses and the transitions between them, as plugins write them:
//! `[_]publr.record.Transition(Status){ .{ .name = .submit, .from = &.{.draft}, .to =
//! .in_review, .label = "Submit for review" } }`, `.from = publr.record.any` for every status
//! but the target and the trash. Turned into the flow the type keeps as data, its own statuses
//! stored under the plugin's name.
const std = @import("std");
const content_type = @import("../../model/content_type.zig");
const flow_model = @import("../../model/flow.zig");
const status_module = @import("../../model/status.zig");
const caller_answer = @import("../../model/caller_answer.zig");

/// Core's statuses: any record lists them by name and they keep core's meaning.
pub const core_status_ids = [_][]const u8{ "draft", "published", "archived", "trashed" };

/// Every status of the list but the transition's target, never the trash.
pub const any = &.{.any};

/// The statuses a transition may leave: the record's own, and `any`.
pub fn Leaving(comptime Status: type) type {
    comptime {
        std.debug.assert(@typeInfo(Status) == .@"enum");

        if (@hasField(Status, "any")) {
            @compileError(@typeName(Status) ++ ": `any` is every status, not one of them");
        }

        return Widened(Status, "any");
    }
}

/// `Status` with one more value, `extra`, after its own.
fn Widened(comptime Status: type, comptime extra: []const u8) type {
    comptime {
        const statuses = std.meta.fieldNames(Status);
        var names: [statuses.len + 1][]const u8 = undefined;
        var values: [statuses.len + 1]u8 = undefined;

        std.debug.assert(statuses.len < 255);

        for (statuses, 0..) |status, index| {
            names[index] = status;
            values[index] = index;
        }

        names[statuses.len] = extra;
        values[statuses.len] = statuses.len;

        const done_names = names;
        const done_values = values;

        return @Enum(u8, .exhaustive, &done_names, &done_values);
    }
}

/// One transition of a record's flow: its name (`.publish`, what code and hooks call it), the
/// statuses it leaves, the one it reaches, its button's label, and who may make it besides
/// administrators (an answer of `publr.authorize`; none: whoever may write the record).
pub fn Transition(comptime Status: type) type {
    return struct {
        name: @TypeOf(.enum_literal),
        from: []const Leaving(Status),
        to: Status,
        label: []const u8,
        authorize: ?caller_answer.Answer = null,
    };
}

/// A record's status as its code reads it: one of its list, or `other` for a status an
/// administrator added (or another plugin's step in its flow).
pub fn Held(comptime Status: type) type {
    comptime {
        if (@hasField(Status, "other")) {
            return Status;
        }

        return Widened(Status, "other");
    }
}

/// The hook point for every transition on records of `handle`, trash and restore included:
/// `publr.before(Posts.any_transition, run)`, its run given
/// `.{ .record, .transition, .from, .to }`.
pub fn AnyTransition(comptime handle: []const u8) type {
    comptime std.debug.assert(handle.len > 0);

    return struct {
        pub const publr_event_definition = true;
        pub const Payload = flow_model.Transitioned;
        pub const verb = flow_model.any_name_of(handle);
        pub const full_name = verb;
        pub const refusable = true;
    };
}

/// One transition's hook point: `publr.before(Posts.transitions.publish, run)`,
/// heard for that transition alone, its run given what `any_transition` gets.
pub fn NamedTransition(comptime handle: []const u8, comptime name: []const u8) type {
    comptime std.debug.assert(name.len > 0);

    return struct {
        pub const publr_event_definition = true;
        pub const Payload = flow_model.Transitioned;
        pub const verb = handle ++ "_" ++ name;
        pub const full_name = verb;
        pub const refusable = true;
    };
}

/// `Posts.transitions`: a field per transition of the record's flow (its own, or core's
/// without one) and core's `trash`, `restore`, `destroy`, each its hook point. A misspelt
/// name fails the build.
pub fn TransitionHooks(comptime options: anytype) type {
    comptime {
        const handle = options.name;
        const own = @hasField(@TypeOf(options), "status");
        const steps = if (own) transitions_of(options) else &flow_model.core_transitions;
        var names: []const []const u8 = &.{};

        std.debug.assert(handle.len > 0);

        for (steps) |step| {
            if (!listed(names, step.name)) {
                names = names ++ [_][]const u8{step.name};
            }
        }

        names = names ++ [_][]const u8{ "trash", "restore", "destroy" };

        var types: [names.len]type = undefined;
        var attributes: [names.len]std.builtin.Type.StructField.Attributes = undefined;

        for (names, &types, &attributes) |name, *field_type, *attribute| {
            const Hook = NamedTransition(handle, name);

            field_type.* = type;
            attribute.* = .{
                .@"comptime" = true,
                .default_value_ptr = &Hook,
            };
        }

        const done_names = names[0..names.len].*;
        const done_types = types;
        const done_attributes = attributes;

        return @Struct(.auto, null, &done_names, &done_types, &done_attributes);
    }
}

/// Core's statuses, for a record without a `.status` of its own.
pub const CoreStatus = enum { draft, published, archived, trashed };

/// The list a record's statuses come from: its own, or core's.
pub fn List(comptime options: anytype) type {
    if (!@hasField(@TypeOf(options), "status")) {
        return CoreStatus;
    }

    return options.status.list;
}

/// A stored status read back as the record's own: `guestbook.in_review` is `.in_review`,
/// anything else not in the list `.other`.
pub fn held_status(
    comptime Status: type,
    comptime handle: []const u8,
    stored: []const u8,
) Held(Status) {
    std.debug.assert(handle.len > 0);
    std.debug.assert(stored.len > 0);

    inline for (std.meta.fields(Status)) |field| {
        if (std.mem.eql(u8, stored, comptime status_id(handle, field.name))) {
            return @field(Held(Status), field.name);
        }
    }

    return .other;
}

/// A status's stored id: core's by their names, the record's own under its plugin's name.
pub fn status_id(comptime handle: []const u8, comptime value: []const u8) []const u8 {
    comptime {
        std.debug.assert(value.len > 0);

        if (listed(&core_status_ids, value)) {
            return value;
        }

        const id = content_type.namespace_of(handle) ++ "." ++ value;

        if (id.len > status_module.id_len_max) {
            @compileError("status " ++ id ++ ": a plugin's name and status come to at most 32");
        }

        return id;
    }
}

/// Where every record of the type begins: `.status.start`, required with a `.status`.
pub fn start_status(comptime options: anytype) []const u8 {
    comptime {
        std.debug.assert(options.name.len > 0);

        if (!@hasField(@TypeOf(options), "status")) {
            return "draft";
        }

        if (!@hasField(@TypeOf(options.status), "start")) {
            @compileError("record " ++ options.name ++ ": `.status` needs `.start`, where " ++
                "every record begins");
        }

        return status_id(options.name, @tagName(options.status.start));
    }
}

/// The record's flow as written, checked: a slice of `Transition(Status)` with names of its
/// own; empty without one.
pub fn flow_given(comptime options: anytype) []const Transition(List(options)) {
    comptime {
        std.debug.assert(options.name.len > 0);

        const Status = List(options);
        const has_flow = @hasField(@TypeOf(options), "status") and
            @hasField(@TypeOf(options.status), "flow");

        if (!has_flow or options.status.flow.len == 0) {
            return &.{};
        }

        const Given = @TypeOf(options.status.flow);
        const typed = Given == []const Transition(Status) or
            Given == *const [options.status.flow.len]Transition(Status);

        if (!typed) {
            @compileError("record " ++ options.name ++ ": `.flow` is a list of " ++
                "`publr.record.Transition(" ++ @typeName(Status) ++ ")`: " ++
                "`.flow = &flow`, `const flow = [_]publr.record.Transition(Status){ ... }`");
        }

        const flow: []const Transition(Status) = options.status.flow;

        for (flow, 0..) |step, index| {
            const name = @tagName(step.name);

            if (flow_model.reserved(name)) {
                @compileError("record " ++ options.name ++ ": `" ++ name ++ "` is core's, " ++
                    "every flow has it");
            }

            for (flow[0..index]) |earlier| {
                if (std.mem.eql(u8, @tagName(earlier.name), name)) {
                    @compileError("record " ++ options.name ++ ": two transitions are named `" ++
                        name ++ "`");
                }
            }
        }

        return flow;
    }
}

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

/// The other plugin's status one of the record's own stands in for, from `.status.alias`
/// (`.alias = .{ .paid = "orders.paid" }`); empty for none.
pub fn alias_of(comptime options: anytype, comptime value: []const u8) []const u8 {
    comptime {
        std.debug.assert(value.len > 0);

        const Status = List(options);
        const has = @hasField(@TypeOf(options), "status") and
            @hasField(@TypeOf(options.status), "alias");

        if (!has) {
            return "";
        }

        const aliases = options.status.alias;

        for (std.meta.fieldNames(@TypeOf(aliases))) |own| {
            if (!@hasField(Status, own) or listed(&core_status_ids, own)) {
                @compileError("record " ++ options.name ++ ": `.alias` names one of its own " ++
                    "statuses, not `" ++ own ++ "`");
            }

            const target: []const u8 = @field(aliases, own);

            if (std.mem.indexOfScalar(u8, target, '.') == null) {
                @compileError("record " ++ options.name ++ ": `." ++ own ++ "` stands in " ++
                    "for another plugin's status, `<plugin>.<status>`");
            }
        }

        if (!@hasField(@TypeOf(aliases), value)) {
            return "";
        }

        return @field(aliases, value);
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

        if (listed(&core_status_ids, name)) {
            return name;
        }

        return content_type.namespace_of(entry.to) ++ "." ++ name;
    }
}

/// The statuses visitors see: core's `published`, and those `.published` lists.
pub fn published_of(comptime options: anytype) []const List(options) {
    comptime {
        const Status = List(options);
        const has = @hasField(@TypeOf(options), "status") and
            @hasField(@TypeOf(options.status), "published");

        std.debug.assert(options.name.len > 0);

        if (!has) {
            return &.{};
        }

        const published: []const Status = options.status.published;

        return published;
    }
}

/// The transition `name` of the record's flow, checked at build time: its own, or core's.
pub fn check_named(comptime options: anytype, comptime name: []const u8) void {
    comptime {
        std.debug.assert(name.len > 0);

        if (flow_model.reserved(name)) {
            return;
        }

        const own = @hasField(@TypeOf(options), "status");
        const steps = if (own) transitions_of(options) else &flow_model.core_transitions;

        for (steps) |step| {
            if (std.mem.eql(u8, step.name, name)) {
                return;
            }
        }

        @compileError("record " ++ options.name ++ ": its flow has no transition `" ++
            name ++ "`");
    }
}

pub fn listed(comptime names: []const []const u8, comptime name: []const u8) bool {
    comptime {
        std.debug.assert(name.len > 0);

        for (names) |candidate| {
            if (std.mem.eql(u8, candidate, name)) {
                return true;
            }
        }

        return false;
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
