//! One type's statuses and the transitions between them, as its definition keeps them: core's
//! vocabulary (`draft`, `published`, `archived`, `deleted`) plus the type's own statuses,
//! its listed transitions and where its records start. A type without a flow of its own has
//! core's. Data, so a type declared by an installed plugin carries it as one compiled in
//! does, and a site can change it.
const std = @import("std");
const status = @import("status.zig");
const caller_answer = @import("caller_answer.zig");

pub const transitions_max: u32 = status.transitions_max;

/// A status transition by its name (`publish`): from any of `from`, to `to`; `label` is its
/// button. `authorize`, when set, is who may make it besides administrators.
pub const Transition = struct {
    name: []const u8,
    from: []const []const u8,
    to: []const u8,
    label: []const u8,
    authorize: ?Who = null,
    /// Written `from = any`: it also leaves statuses other plugins add to the flow.
    from_any: bool = false,
};

/// A status another plugin adds to a type's flow (`.register_statuses`), stored under that
/// plugin's name, and the transitions into and out of it.
pub const Added = struct {
    /// The type whose flow it joins: `orders.order`.
    to: []const u8,
    /// The plugin that adds it.
    plugin: []const u8,
    status: status.Status,
    transitions: []const Transition,
};

/// The flow of `handle` with every status other plugins add to it, and their transitions;
/// the type's own transitions written `from = any` leave the added statuses too.
pub fn with_added(
    arena: std.mem.Allocator,
    handle: []const u8,
    flow: Flow,
    added: []const Added,
) error{OutOfMemory}!Flow {
    std.debug.assert(handle.len > 0);
    std.debug.assert(added.len <= transitions_max);

    var statuses: std.ArrayList(status.Status) = .empty;
    var transitions: std.ArrayList(Transition) = .empty;
    var joined: std.ArrayList([]const u8) = .empty;

    try statuses.appendSlice(arena, flow.statuses);

    for (added) |entry| {
        if (std.mem.eql(u8, entry.to, handle)) {
            try statuses.append(arena, entry.status);
            try joined.append(arena, entry.status.id);
        }
    }

    if (joined.items.len == 0) {
        return flow;
    }

    for (flow.listed()) |own| {
        var copy = own;

        if (own.from_any) {
            copy.from = try std.mem.concat(arena, []const u8, &.{ own.from, joined.items });
        }

        try transitions.append(arena, copy);
    }

    for (added) |entry| {
        if (std.mem.eql(u8, entry.to, handle)) {
            try transitions.appendSlice(arena, entry.transitions);
        }
    }

    return .{
        .statuses = statuses.items,
        .transitions = transitions.items,
        .start = if (flow.start.len > 0) flow.start else flow.initial().id,
    };
}

/// The transition records leave an added status by when it goes: the plugin's first one out
/// of it into a status the plugin does not add. Null for none, which a plugin may not declare.
pub fn way_out(added: Added) ?Transition {
    std.debug.assert(added.plugin.len > 0);
    std.debug.assert(added.status.id.len > added.plugin.len);

    for (added.transitions) |step| {
        const leaves = for (step.from) |from| {
            if (std.mem.eql(u8, from, added.status.id)) {
                break true;
            }
        } else false;
        const own = std.mem.startsWith(u8, step.to, added.plugin) and
            step.to.len > added.plugin.len and step.to[added.plugin.len] == '.';

        if (leaves and !own) {
            return step;
        }
    }

    return null;
}

/// Who may make a transition, kept as plain data: a ready answer of `publr.authorize`.
pub const Who = struct {
    answer: Kind,
    /// With `roles`: anyone holding one of them.
    roles: []const []const u8 = &.{},

    pub const Kind = enum { signed_in, roles, plugin_calls };

    pub fn of(given: caller_answer.Answer) Who {
        std.debug.assert(@intFromEnum(given) <= @intFromEnum(caller_answer.Answer.plugin_calls));

        return switch (given) {
            .visitor, .signed_in => .{
                .answer = .signed_in,
            },
            .roles => |names| .{
                .answer = .roles,
                .roles = names,
            },
            .plugin_calls => .{
                .answer = .plugin_calls,
            },
        };
    }

    pub fn answered(who: Who) caller_answer.Answer {
        std.debug.assert(who.roles.len <= 64);
        std.debug.assert(who.answer == .roles or who.roles.len == 0);

        return switch (who.answer) {
            .signed_in => .signed_in,
            .roles => .{
                .roles = who.roles,
            },
            .plugin_calls => .plugin_calls,
        };
    }
};

/// Names every flow has from core, which a type's own transitions never take.
pub const reserved_names = [_][]const u8{
    "trash",
    "restore",
    "destroy",
    "create",
    "save",
    "any_transition",
};

/// Core's flow, for a type without one of its own: each transition by name.
pub const core_transitions = [_]Transition{
    .{
        .name = "publish",
        .from = &.{"draft"},
        .to = "published",
        .label = "Publish",
    },
    .{
        .name = "unpublish",
        .from = &.{"published"},
        .to = "draft",
        .label = "Unpublish",
    },
    .{
        .name = "archive",
        .from = &.{ "draft", "published" },
        .to = "archived",
        .label = "Archive",
    },
    .{
        .name = "unarchive",
        .from = &.{"archived"},
        .to = "draft",
        .label = "Restore",
    },
};

pub const trashed = "trashed";

/// What a hook on every transition of a type hears (`Posts.any_transition`): the record,
/// the transition's name, and the statuses it left and reached.
pub const Transitioned = struct {
    record: []const u8,
    transition: []const u8,
    from: []const u8,
    to: []const u8,
};

/// The hook point for every transition on records of a type is named for it, as a event
/// is: `<plugin>.<type>_transitioned`, or `<type>.transitioned` for a type no plugin
/// declares; what `Posts.any_transition` hooks.
pub const any_suffix = "_transitioned";

pub fn any_name(arena: std.mem.Allocator, handle: []const u8) error{OutOfMemory}![]const u8 {
    std.debug.assert(handle.len > 0);
    std.debug.assert(handle.len <= 64);

    const plain = std.mem.indexOfScalar(u8, handle, '.') == null;
    const joint = if (plain) ".transitioned" else any_suffix;

    return std.fmt.allocPrint(arena, "{s}{s}", .{ handle, joint });
}

pub fn any_name_of(comptime handle: []const u8) []const u8 {
    comptime {
        std.debug.assert(handle.len > 0);

        const plain = std.mem.indexOfScalar(u8, handle, '.') == null;
        const joint = if (plain) ".transitioned" else any_suffix;

        return handle ++ joint;
    }
}

/// Where a named transition takes a record from where it is, and who may make it.
pub const Target = struct {
    name: []const u8,
    to: []const u8,
    label: []const u8,
    authorize: ?Who = null,
    /// Who may, changed on this site: for people, in place of `authorize`.
    people: ?Who = null,
    /// Turned off on this site: people can't make it; plugin code still can.
    off: bool = false,
};

/// What a site changes of a type's flow, kept beside it and laid over it as it is read,
/// never a copy of it: "Reset to plugin's" drops a change. Who may on any transition (core's
/// `trash`, `restore` and `destroy` too), the code's transitions turned off, and the site's
/// own transitions and statuses.
pub const Changes = struct {
    who: []const Changed = &.{},
    off: []const []const u8 = &.{},
    transitions: []const Transition = &.{},
    statuses: []const status.Status = &.{},

    pub fn empty(changes: Changes) bool {
        std.debug.assert(changes.transitions.len <= transitions_max);

        return changes.who.len == 0 and changes.off.len == 0 and
            changes.transitions.len == 0 and changes.statuses.len == 0;
    }
};

/// Who may make the transition `name`, as a site changed it.
pub const Changed = struct {
    name: []const u8,
    who: Who,
};

/// `flow` with a site's changes laid over it: its own statuses and transitions after the
/// code's (core's listed when the type has none of its own), who may and what is off as
/// lookups by name.
pub fn with_changes(
    arena: std.mem.Allocator,
    flow: Flow,
    changes: Changes,
) error{OutOfMemory}!Flow {
    std.debug.assert(changes.statuses.len <= status.statuses_max);
    std.debug.assert(changes.transitions.len <= transitions_max);

    var changed = flow;

    changed.who = changes.who;
    changed.off = changes.off;

    if (changes.statuses.len == 0 and changes.transitions.len == 0) {
        return changed;
    }

    changed.statuses = try std.mem.concat(arena, status.Status, &.{
        flow.statuses,
        changes.statuses,
    });
    changed.transitions = try std.mem.concat(arena, Transition, &.{
        flow.listed(),
        changes.transitions,
    });

    return changed;
}

pub fn reserved(name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(reserved_names.len == 6);

    for (reserved_names) |taken| {
        if (std.mem.eql(u8, taken, name)) {
            return true;
        }
    }

    return false;
}

pub const Flow = struct {
    /// The type's own statuses, namespaced (`guestbook.in_review`); core's are not listed.
    statuses: []const status.Status = &.{},
    transitions: []const Transition = &.{},
    /// Where every record of the type begins; empty: core's `draft`.
    start: []const u8 = "",
    /// Who may, as the site changed it (`Changes`); read as the type is, never stored in it.
    who: []const Changed = &.{},
    /// The transitions the site turned off.
    off: []const []const u8 = &.{},

    /// `target` with what the site changed of it: who may for people, and whether it is off.
    pub fn changed(flow: Flow, target: Target) Target {
        std.debug.assert(target.name.len > 0);
        std.debug.assert(flow.who.len <= transitions_max);

        var marked = target;

        for (flow.who) |change| {
            if (std.mem.eql(u8, change.name, target.name)) {
                marked.people = change.who;
            }
        }

        for (flow.off) |name| {
            if (std.mem.eql(u8, name, target.name)) {
                marked.off = true;
            }
        }

        return marked;
    }

    /// Whether the type has a flow of its own, rather than core's.
    pub fn own(flow: Flow) bool {
        std.debug.assert(flow.transitions.len <= transitions_max);
        std.debug.assert(flow.statuses.len <= status.statuses_max);

        return flow.transitions.len > 0 or flow.statuses.len > 0 or flow.start.len > 0;
    }

    pub fn find(flow: Flow, id: []const u8) ?status.Status {
        std.debug.assert(id.len > 0);
        std.debug.assert(flow.statuses.len <= status.statuses_max);

        if (status.Core.find(id)) |found| {
            return found;
        }

        for (flow.statuses) |declared| {
            if (std.mem.eql(u8, declared.id, id)) {
                return declared;
            }
        }

        return null;
    }

    pub fn is_live(flow: Flow, id: []const u8) bool {
        std.debug.assert(id.len > 0);

        const found = flow.find(id) orelse return false;

        std.debug.assert(std.mem.eql(u8, found.id, id));

        return found.live;
    }

    pub fn initial(flow: Flow) status.Status {
        std.debug.assert(flow.statuses.len <= status.statuses_max);

        if (flow.start.len > 0) {
            if (flow.find(flow.start)) |found| {
                return found;
            }
        }

        const first = status.Core.initial();

        std.debug.assert(first.initial);

        return first;
    }

    /// Whether a record of the type may go from `from` to `to`: one of its listed transitions,
    /// or core's trash transitions (into `deleted` from anywhere, back to where records start).
    pub fn allows(flow: Flow, from: []const u8, to: []const u8) bool {
        std.debug.assert(from.len > 0);
        std.debug.assert(to.len > 0);

        if (!flow.own()) {
            return status.Core.allows(from, to);
        }

        const in_trash = std.mem.eql(u8, from, trashed);

        if (std.mem.eql(u8, to, trashed)) {
            return !in_trash;
        }

        if (in_trash) {
            return flow.find(to) != null and !flow.is_live(to);
        }

        return flow.transition_between(from, to) != null;
    }

    /// Where `restore` takes a record that had `before` it went into the trash: back there,
    /// or where records start when it was live or its status is gone.
    pub fn restored_to(flow: Flow, before: []const u8) []const u8 {
        std.debug.assert(flow.statuses.len <= status.statuses_max);

        const kept = before.len > 0 and !std.mem.eql(u8, before, trashed) and
            flow.find(before) != null and !flow.is_live(before);

        return if (kept) before else flow.initial().id;
    }

    /// The transition named `name` out of `from`, where it leads; null when none of that
    /// name leaves `from`. Every flow has core's `trash` (from anywhere but the trash) and
    /// `restore` (out of it, to where records start).
    pub fn named(flow: Flow, name: []const u8, from: []const u8) ?Target {
        std.debug.assert(name.len > 0);
        std.debug.assert(from.len > 0);

        const in_trash = std.mem.eql(u8, from, trashed);

        if (std.mem.eql(u8, name, "trash")) {
            return if (in_trash) null else flow.changed(.{
                .name = "trash",
                .to = trashed,
                .label = "Delete",
            });
        }

        if (std.mem.eql(u8, name, "restore")) {
            return if (!in_trash) null else flow.changed(.{
                .name = "restore",
                .to = flow.initial().id,
                .label = "Restore",
            });
        }

        if (std.mem.eql(u8, name, "destroy")) {
            return if (!in_trash) null else flow.changed(.{
                .name = "destroy",
                .to = trashed,
                .label = "Destroy",
            });
        }

        for (flow.listed()) |transition| {
            if (!std.mem.eql(u8, transition.name, name)) {
                continue;
            }

            for (transition.from) |leaving| {
                if (std.mem.eql(u8, leaving, from)) {
                    return flow.changed(.{
                        .name = transition.name,
                        .to = transition.to,
                        .label = transition.label,
                        .authorize = transition.authorize,
                    });
                }
            }
        }

        return null;
    }

    /// The transitions out of `from` people may make, in the order listed, core's trash
    /// transition last; the ones the site turned off are left out.
    pub fn out_of(flow: Flow, from: []const u8, buffer: []Target) []const Target {
        std.debug.assert(from.len > 0);
        std.debug.assert(buffer.len > transitions_max);

        var count: u32 = 0;

        for (flow.listed()) |transition| {
            for (transition.from) |leaving| {
                if (std.mem.eql(u8, leaving, from)) {
                    buffer[count] = flow.changed(.{
                        .name = transition.name,
                        .to = transition.to,
                        .label = transition.label,
                        .authorize = transition.authorize,
                    });
                    count += @intFromBool(!buffer[count].off);
                    break;
                }
            }
        }

        const back = if (std.mem.eql(u8, from, trashed)) "restore" else "trash";

        buffer[count] = flow.named(back, from).?;
        count += 1;

        return buffer[0..count];
    }

    /// Whether the flow lists a transition named `name`, from anywhere.
    pub fn lists(flow: Flow, name: []const u8) bool {
        std.debug.assert(name.len > 0);
        std.debug.assert(flow.transitions.len <= transitions_max);

        for (flow.listed()) |transition| {
            if (std.mem.eql(u8, transition.name, name)) {
                return true;
            }
        }

        return false;
    }

    /// The type's own transitions, or core's for a type without a flow.
    pub fn listed(flow: Flow) []const Transition {
        std.debug.assert(flow.transitions.len <= transitions_max);

        return if (flow.own()) flow.transitions else &core_transitions;
    }

    /// The name of the transition from `from` to `to`: its own, core's, or the trash's;
    /// empty when none leads there.
    pub fn name_between(flow: Flow, from: []const u8, to: []const u8) []const u8 {
        std.debug.assert(from.len > 0);
        std.debug.assert(to.len > 0);

        if (std.mem.eql(u8, to, trashed)) {
            return "trash";
        }

        if (std.mem.eql(u8, from, trashed)) {
            return "restore";
        }

        for (flow.listed()) |transition| {
            if (!std.mem.eql(u8, transition.to, to)) {
                continue;
            }

            for (transition.from) |leaving| {
                if (std.mem.eql(u8, leaving, from)) {
                    return transition.name;
                }
            }
        }

        return "";
    }

    /// The listed transition from `from` to `to`; null when there is none.
    pub fn transition_between(flow: Flow, from: []const u8, to: []const u8) ?Transition {
        std.debug.assert(from.len > 0);
        std.debug.assert(to.len > 0);

        for (flow.transitions) |transition| {
            if (!std.mem.eql(u8, transition.to, to)) {
                continue;
            }

            for (transition.from) |leaving| {
                if (std.mem.eql(u8, leaving, from)) {
                    return transition;
                }
            }
        }

        return null;
    }
};

/// Core's flow: what every type without its own has.
pub const core: Flow = .{};

test "a type without a flow has core's" {
    try std.testing.expect(!core.own());
    try std.testing.expect(core.allows("draft", "published"));
    try std.testing.expect(core.is_live("published"));
    try std.testing.expectEqualStrings("draft", core.initial().id);
    try std.testing.expect(core.find("guestbook.in_review") == null);
}

test "a type's own flow allows only its transitions and the trash" {
    const flow: Flow = .{
        .statuses = &.{.{
            .id = "guestbook.in_review",
            .label = "Waiting for review",
        }},
        .transitions = &.{
            .{
                .name = "submit",
                .from = &.{"draft"},
                .to = "guestbook.in_review",
                .label = "Submit for review",
            },
            .{
                .name = "publish",
                .from = &.{"guestbook.in_review"},
                .to = "published",
                .label = "Publish",
            },
        },
        .start = "draft",
    };

    try std.testing.expect(flow.own());
    try std.testing.expect(flow.allows("draft", "guestbook.in_review"));
    try std.testing.expect(flow.allows("guestbook.in_review", "published"));
    try std.testing.expect(!flow.allows("draft", "published"));
    try std.testing.expect(flow.allows("published", "trashed"));
    try std.testing.expect(flow.allows("trashed", "draft"));
    try std.testing.expect(!flow.allows("trashed", "published"));
    const in_review = flow.find("guestbook.in_review").?;

    try std.testing.expectEqualStrings("Waiting for review", in_review.label);
    try std.testing.expect(!flow.is_live("guestbook.in_review"));
    const submit = flow.transition_between("draft", "guestbook.in_review").?;

    try std.testing.expectEqualStrings("submit", submit.name);
}

test "a transition is found by its name and only out of its own statuses" {
    const flow: Flow = .{
        .statuses = &.{.{
            .id = "guestbook.in_review",
            .label = "Waiting for review",
        }},
        .transitions = &.{
            .{
                .name = "publish",
                .from = &.{ "draft", "guestbook.in_review" },
                .to = "published",
                .label = "Publish",
                .authorize = .{
                    .answer = .roles,
                    .roles = &.{"editor"},
                },
            },
        },
        .start = "draft",
    };

    try std.testing.expectEqualStrings("published", flow.named("publish", "draft").?.to);
    try std.testing.expect(flow.named("publish", "published") == null);
    try std.testing.expect(flow.named("nope", "draft") == null);
    try std.testing.expect(flow.named("publish", "draft").?.authorize != null);
    try std.testing.expectEqualStrings("trashed", flow.named("trash", "draft").?.to);
    try std.testing.expect(flow.named("trash", "trashed") == null);
    try std.testing.expectEqualStrings("draft", flow.named("restore", "trashed").?.to);
    try std.testing.expectEqualStrings("archived", core.named("archive", "published").?.to);
    try std.testing.expect(core.named("unarchive", "draft") == null);

    var buffer: [transitions_max + 1]Target = undefined;
    const out = flow.out_of("draft", &buffer);

    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("trash", out[1].name);
    try std.testing.expect(reserved("destroy"));
    try std.testing.expect(!reserved("publish"));
}

test "statuses another plugin adds join the flow; the owner's `any` transitions reach them" {
    const orders: Flow = .{
        .statuses = &.{.{
            .id = "orders.paid",
            .label = "Paid",
        }},
        .transitions = &.{
            .{
                .name = "pay",
                .from = &.{"draft"},
                .to = "orders.paid",
                .label = "Mark paid",
            },
            .{
                .name = "ship",
                .from = &.{"orders.paid"},
                .to = "published",
                .label = "Ship",
            },
            .{
                .name = "cancel",
                .from = &.{ "draft", "orders.paid" },
                .to = "archived",
                .label = "Cancel",
                .from_any = true,
            },
        },
        .start = "draft",
    };
    const added = [_]Added{.{
        .to = "orders.order",
        .plugin = "inventory",
        .status = .{
            .id = "inventory.awaiting_stock",
            .label = "Awaiting stock",
        },
        .transitions = &.{
            .{
                .name = "await_stock",
                .from = &.{"orders.paid"},
                .to = "inventory.awaiting_stock",
                .label = "Wait for stock",
            },
            .{
                .name = "stock_arrived",
                .from = &.{"inventory.awaiting_stock"},
                .to = "orders.paid",
                .label = "Stock arrived",
            },
        },
    }};
    var buffer: [8192]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const joined = try with_added(fixed.allocator(), "orders.order", orders, &added);
    const untouched = try with_added(fixed.allocator(), "blog.post", orders, &added);

    try std.testing.expect(joined.find("inventory.awaiting_stock") != null);
    try std.testing.expect(joined.named("await_stock", "orders.paid") != null);
    // The owner's `ship` from paid does not ship an order waiting for stock; `cancel`, from
    // any status, still works from it.
    try std.testing.expect(joined.named("ship", "inventory.awaiting_stock") == null);
    try std.testing.expect(joined.named("cancel", "inventory.awaiting_stock") != null);
    try std.testing.expectEqual(orders.transitions.len, untouched.transitions.len);

    try std.testing.expectEqualStrings("stock_arrived", way_out(added[0]).?.name);

    var stuck = added[0];

    stuck.transitions = added[0].transitions[0..1];
    try std.testing.expect(way_out(stuck) == null);
}
