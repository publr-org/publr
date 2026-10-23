//! A type's flow as a site changes it: who may make each transition, the code's transitions
//! turned off and on, and the site's own transitions and statuses. The changes are kept
//! beside the type (`flow.<type>`, `model.flow.Changes`) and laid over its flow as it is
//! read, never a copy of it: resetting one drops it. A plugin's statuses and transitions
//! are never removed; turned off, people can't use a transition and the plugin's own code
//! still can.
const std = @import("std");
const sdk = @import("../sdk.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const definitions = @import("record.zig").domain.definition;

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const flow = model.flow;

pub const namespace: sdk.operation.Namespace = .{
    .name = "flow",
    .label = "Workflow",
    .area = .site,
    .summary = "A type's statuses and transitions as this site changes them",
    .details =
    \\A type's flow is what its code says (core's draft, published and archived when it
    \\says nothing). Administrators change who may make each transition, turn the code's
    \\transitions off and on, and add transitions and statuses of the site's own. The
    \\code's flow stays the default: a change resets to it, and a plugin's statuses and
    \\transitions are never removed. A transition turned off is refused to people; the
    \\plugin's own code still makes it.
    ,
};

/// One status of the type: core's, its code's (locked), or the site's own.
pub const Status = struct {
    id: []const u8,
    label: []const u8,
    live: bool,
    /// `core`, `plugin` (its code's), or `site`: only the site's own can be removed.
    source: []const u8,
};

/// One transition of the type and who may make it.
pub const Transition = struct {
    name: []const u8,
    label: []const u8,
    from: []const []const u8,
    to: []const u8,
    /// Who may, in effect for people: `signed_in`, `roles:editor,author`; empty for whoever
    /// may edit the record. Administrators always may.
    who: []const u8,
    /// What its code says, the same way.
    declared: []const u8,
    /// Who may was changed on this site: "Reset to plugin's" takes it back.
    changed: bool,
    /// `core`, `plugin` or `site`.
    source: []const u8,
    /// Turned off on this site.
    off: bool,
};

pub const Flow = struct {
    statuses: []const Status,
    transitions: []const Transition,
};

const example_flow: Flow = .{
    .statuses = &.{.{
        .id = "draft",
        .label = "Draft",
        .live = false,
        .source = "core",
    }},
    .transitions = &.{.{
        .name = "publish",
        .label = "Publish",
        .from = &.{"draft"},
        .to = "published",
        .who = "roles:editor",
        .declared = "",
        .changed = true,
        .source = "core",
        .off = false,
    }},
};

const type_doc = "The type's handle, as `content_type list` gives it";
const name_doc = "The transition's name, as `flow get` gives it";
const roles_doc = "Anyone holding one of these roles, and administrators";

pub const Get = struct {
    pub const name = "flow.get";
    pub const description = "A type's statuses and transitions, and what this site changed";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        type: []const u8,
    };
    pub const Out = Flow;
    pub const example: In = .{
        .type = "post",
    };
    pub const example_out: Out = example_flow;
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = type_doc,
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        return shown(ctx, (try find(ctx, in.type)).def.handle);
    }
};

pub const Authorize = struct {
    pub const name = "flow.authorize";
    pub const description = "Change who may make a transition on this site";
    pub const details =
        \\Administrators only, and they always may. Give `user_has_role` (the roles),
        \\`user_is_signed_in` (whoever may edit the record), or `default` to go back to what
        \\the code says. Any transition, core's `trash`, `restore` and `destroy` too. It holds
        \\for people; a plugin's own code is held to what its code says.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        type: []const u8,
        transition: []const u8,
        user_has_role: []const []const u8 = &.{},
        user_is_signed_in: bool = false,
        default: bool = false,
    };
    pub const Out = Flow;
    pub const example: In = .{
        .type = "post",
        .transition = "publish",
        .user_has_role = &.{"editor"},
    };
    pub const example_out: Out = example_flow;
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = type_doc,
        .transition = name_doc,
        .user_has_role = roles_doc,
        .user_is_signed_in = "Whoever may edit the record",
        .default = "Back to what its code says",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const given = @as(u32, @intFromBool(in.user_has_role.len > 0)) +
            @intFromBool(in.user_is_signed_in) + @intFromBool(in.default);
        const def = (try find(ctx, in.type)).def;
        var changes = try changes_of(ctx, def.handle);

        if (given != 1 or in.transition.len == 0 or in.transition.len > 64) {
            return error.Invalid;
        }

        if (!flow.reserved(in.transition) and !def.flow.lists(in.transition)) {
            return error.NotFound;
        }

        const who: ?flow.Who = if (in.default) null else try who_of(ctx, in.user_has_role);
        const transitions = try ctx.arena.dupe(flow.Transition, changes.transitions);
        var kept: std.ArrayList(flow.Changed) = .empty;

        // The site's own transition is changed in place: there is no code's to go back to.
        for (transitions) |*own| {
            if (std.mem.eql(u8, own.name, in.transition)) {
                own.authorize = who;
                changes.transitions = transitions;

                return save(ctx, def.handle, changes);
            }
        }

        for (changes.who) |change| {
            if (!std.mem.eql(u8, change.name, in.transition)) {
                try kept.append(ctx.arena, change);
            }
        }

        if (who) |answer| {
            try kept.append(ctx.arena, .{
                .name = in.transition,
                .who = answer,
            });
        }

        changes.who = kept.items;

        return save(ctx, def.handle, changes);
    }
};

pub const Add = struct {
    pub const name = "flow.add";
    pub const description = "Add a transition of this site's own to a type's flow";
    pub const details =
        \\Administrators only. From one or more of the type's statuses to another; its name
        \\is made from its label. `user_has_role` says who may make it besides
        \\administrators; none, whoever may edit the record. Never out of or into the trash:
        \\core's `trash` and `restore` do that. Fails as conflict for a name the flow has.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        type: []const u8,
        label: []const u8,
        from: []const []const u8,
        to: []const u8,
        user_has_role: []const []const u8 = &.{},
    };
    pub const Out = Flow;
    pub const example: In = .{
        .type = "post",
        .label = "Send back",
        .from = &.{"published"},
        .to = "draft",
    };
    pub const example_out: Out = example_flow;
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = type_doc,
        .label = "Its button, and its name made from it (`send_back`)",
        .from = "The statuses it leaves",
        .to = "The status it reaches",
        .user_has_role = roles_doc,
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const def = (try find(ctx, in.type)).def;
        var changes = try changes_of(ctx, def.handle);
        const transition_name = try name_of(ctx.arena, in.label, model.status.id_len_max);
        const room = changes.transitions.len < model.status.transitions_max;

        if (in.label.len > 64 or in.from.len == 0 or in.from.len > 16 or !room) {
            return error.Invalid;
        }

        if (flow.reserved(transition_name) or def.flow.lists(transition_name)) {
            return taken(ctx);
        }

        // Between statuses the type has, never the trash: `trash` and `restore` do that.
        for (try std.mem.concat(ctx.arena, []const u8, &.{ in.from, &.{in.to} })) |id| {
            if (def.flow.find(id) == null or std.mem.eql(u8, id, flow.trashed)) {
                return error.Invalid;
            }
        }

        for (in.from) |id| {
            if (std.mem.eql(u8, id, in.to)) {
                return error.Invalid;
            }
        }

        changes.transitions = try std.mem.concat(ctx.arena, flow.Transition, &.{
            changes.transitions,
            &.{.{
                .name = transition_name,
                .from = in.from,
                .to = in.to,
                .label = in.label,
                .authorize = if (in.user_has_role.len == 0)
                    null
                else
                    try who_of(ctx, in.user_has_role),
            }},
        });

        return save(ctx, def.handle, changes);
    }
};

pub const Remove = struct {
    pub const name = "flow.remove";
    pub const description = "Remove a transition this site added";
    pub const details =
        \\Administrators only. Only the site's own: the code's transitions are turned off
        \\(`flow set_on`), never removed. Records stay where they are.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        type: []const u8,
        transition: []const u8,
    };
    pub const Out = Flow;
    pub const example: In = .{
        .type = "post",
        .transition = "send_back",
    };
    pub const example_out: Out = example_flow;
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = type_doc,
        .transition = name_doc,
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const def = (try find(ctx, in.type)).def;
        var changes = try changes_of(ctx, def.handle);
        var kept: std.ArrayList(flow.Transition) = .empty;

        for (changes.transitions) |own| {
            if (!std.mem.eql(u8, own.name, in.transition)) {
                try kept.append(ctx.arena, own);
            }
        }

        if (kept.items.len == changes.transitions.len) {
            return if (def.flow.lists(in.transition)) locked(ctx) else error.NotFound;
        }

        changes.transitions = kept.items;

        return save(ctx, def.handle, changes);
    }
};

pub const SetOn = struct {
    pub const name = "flow.set_on";
    pub const description = "Turn one of the code's transitions off for people, or back on";
    pub const details =
        \\Administrators only. Off, people can't make it any more, administrators included;
        \\the plugin's own code still can, so the plugin keeps working. Core's `trash`,
        \\`restore` and `destroy` are never turned off, and the site's own are removed instead.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        type: []const u8,
        transition: []const u8,
        on: bool,
    };
    pub const Out = Flow;
    pub const example: In = .{
        .type = "post",
        .transition = "archive",
        .on = false,
    };
    pub const example_out: Out = example_flow;
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = type_doc,
        .transition = name_doc,
        .on = "On, as its code says; off, refused to people",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const def = (try find(ctx, in.type)).def;
        var changes = try changes_of(ctx, def.handle);
        var kept: std.ArrayList([]const u8) = .empty;

        if (flow.reserved(in.transition) or !def.flow.lists(in.transition)) {
            return error.NotFound;
        }

        for (changes.transitions) |own| {
            if (std.mem.eql(u8, own.name, in.transition)) {
                return error.Invalid;
            }
        }

        for (changes.off) |off| {
            if (!std.mem.eql(u8, off, in.transition)) {
                try kept.append(ctx.arena, off);
            }
        }

        if (!in.on) {
            try kept.append(ctx.arena, in.transition);
        }

        changes.off = kept.items;

        return save(ctx, def.handle, changes);
    }
};

pub const AddStatus = struct {
    pub const name = "flow.add_status";
    pub const description = "Add a status of this site's own to a type's flow";
    pub const details =
        \\Administrators only. Named under the type (`post.in_review`) from its label; not
        \\live: visitors don't see records in it. Add transitions into and out of it with
        \\`flow add`.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        type: []const u8,
        label: []const u8,
    };
    pub const Out = Flow;
    pub const example: In = .{
        .type = "post",
        .label = "In review",
    };
    pub const example_out: Out = example_flow;
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = type_doc,
        .label = "How it reads, and its id made from it",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const def = (try find(ctx, in.type)).def;
        var changes = try changes_of(ctx, def.handle);
        const room = model.status.id_len_max -| (def.handle.len + 1);
        const full = def.flow.statuses.len + model.status.core_statuses.len >=
            model.status.statuses_max;

        if (in.label.len > 64 or room < 3 or full) {
            return error.Invalid;
        }

        const id = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{
            def.handle,
            try name_of(ctx.arena, in.label, room),
        });

        if (def.flow.find(id) != null) {
            return taken(ctx);
        }

        changes.statuses = try std.mem.concat(ctx.arena, model.status.Status, &.{
            changes.statuses,
            &.{.{
                .id = id,
                .label = in.label,
            }},
        });

        return save(ctx, def.handle, changes);
    }
};

pub const RemoveStatus = struct {
    pub const name = "flow.remove_status";
    pub const description = "Remove a status this site added";
    pub const details =
        \\Administrators only. Only the site's own, and only while no record is in it and no
        \\transition leads into or out of it: remove those first. The code's statuses are
        \\never removed.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        type: []const u8,
        status: []const u8,
    };
    pub const Out = Flow;
    pub const example: In = .{
        .type = "post",
        .status = "post.in_review",
    };
    pub const example_out: Out = example_flow;
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = type_doc,
        .status = "The status's id, as `flow get` gives it",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const type_row = try find(ctx, in.type);
        const def = type_row.def;
        var changes = try changes_of(ctx, def.handle);
        var kept: std.ArrayList(model.status.Status) = .empty;

        for (changes.statuses) |own| {
            if (!std.mem.eql(u8, own.id, in.status)) {
                try kept.append(ctx.arena, own);
            }
        }

        if (kept.items.len == changes.statuses.len) {
            return if (def.flow.find(in.status) != null) locked(ctx) else error.NotFound;
        }

        // Only the site's own transitions can reach the site's own status.
        for (changes.transitions) |transition| {
            const leaves = for (transition.from) |from| {
                if (std.mem.eql(u8, from, in.status)) break true;
            } else false;

            if (leaves or std.mem.eql(u8, transition.to, in.status)) {
                return in_use(ctx, "a transition leads into or out of it");
            }
        }

        const held = try store.records.count(ctx.db, ctx.arena, .{
            .type_ids = &.{type_row.id},
            .statuses = &.{in.status},
        });

        if (held > 0) {
            return in_use(ctx, "records are in it");
        }

        changes.statuses = kept.items;

        return save(ctx, def.handle, changes);
    }
};

pub const operations = [_]type{
    Get,
    Authorize,
    Add,
    Remove,
    SetOn,
    AddStatus,
    RemoveStatus,
};

fn key_of(arena: std.mem.Allocator, handle: []const u8) Error![]const u8 {
    std.debug.assert(handle.len > 0 and handle.len <= 64);

    return std.fmt.allocPrint(arena, "flow.{s}", .{handle}) catch error.OutOfMemory;
}

fn parsed(arena: std.mem.Allocator, text: []const u8) flow.Changes {
    return std.json.parseFromSliceLeaky(flow.Changes, arena, text, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch .{};
}

/// What the site changed of the flow of the type `handle`; none when it changed nothing.
pub fn changes_of(ctx: *Ctx, handle: []const u8) Error!flow.Changes {
    std.debug.assert(handle.len > 0);

    if (handle.len > 64) {
        return .{};
    }

    const key = try key_of(ctx.arena, handle);
    const text = try store.settings.get(ctx.db, ctx.arena, key) orelse return .{};

    return parsed(ctx.arena, text);
}

/// Every status a site added to any type's flow.
pub fn site_statuses(ctx: *Ctx) Error![]const model.status.Status {
    std.debug.assert(ctx.now_ms >= 0);

    var found: std.ArrayList(model.status.Status) = .empty;

    for (try store.settings.values_under(ctx.db, ctx.arena, "flow.")) |text| {
        try found.appendSlice(ctx.arena, parsed(ctx.arena, text).statuses);
    }

    return found.items;
}

fn save(ctx: *Ctx, handle: []const u8, changes: flow.Changes) Error!Flow {
    std.debug.assert(handle.len > 0);

    const key = try key_of(ctx.arena, handle);
    const text = std.json.Stringify.valueAlloc(ctx.arena, changes, .{}) catch {
        return error.OutOfMemory;
    };

    if (changes.empty()) {
        try store.settings.delete(ctx.db, key);
    } else if (text.len > store.settings.value_len_max) {
        return error.Invalid;
    } else {
        try store.settings.set(ctx.db, key, text, ctx.now_ms);
    }

    ctx.forget_definitions();

    return shown(ctx, handle);
}

/// The type as read, the site's changes laid over its flow.
fn find(ctx: *Ctx, handle: []const u8) Error!store.content_types.Row {
    if (handle.len == 0 or handle.len > 64) {
        return error.Invalid;
    }

    return try definitions.find(ctx, handle) orelse error.NotFound;
}

/// The type's flow as its page shows it: core's statuses, its code's, the site's; every
/// transition, core's trash transitions last.
fn shown(ctx: *Ctx, handle: []const u8) Error!Flow {
    std.debug.assert(handle.len > 0);

    const def = (try find(ctx, handle)).def;
    const changes = try changes_of(ctx, handle);
    // The code's own flow, as stored; without one, core's.
    const stored = try definitions.find_raw(ctx, handle) orelse return error.NotFound;
    const code: []const u8 = if (def.owner.len > 0 and stored.def.flow.own()) "plugin" else "core";
    const site = flow.Flow{
        .statuses = changes.statuses,
        .transitions = changes.transitions,
    };
    var statuses: std.ArrayList(Status) = .empty;
    var transitions: std.ArrayList(Transition) = .empty;

    const all = try std.mem.concat(ctx.arena, model.status.Status, &.{
        &model.status.core_statuses,
        def.flow.statuses,
    });

    for (all) |one| {
        const core = model.status.Core.find(one.id) != null;
        const source = if (core) "core" else if (site.find(one.id) != null) "site" else "plugin";

        if (std.mem.eql(u8, one.id, flow.trashed)) {
            continue;
        }

        try statuses.append(ctx.arena, .{
            .id = one.id,
            .label = one.label,
            .live = one.live,
            .source = source,
        });
    }

    const trash = [_]flow.Transition{
        .{
            .name = "trash",
            .from = &.{},
            .to = flow.trashed,
            .label = "Delete",
        },
        .{
            .name = "restore",
            .from = &.{flow.trashed},
            .to = "",
            .label = "Restore",
        },
        .{
            .name = "destroy",
            .from = &.{flow.trashed},
            .to = "",
            .label = "Destroy",
        },
    };

    for (try std.mem.concat(ctx.arena, flow.Transition, &.{ def.flow.listed(), &trash })) |listed| {
        const marked = def.flow.changed(.{
            .name = listed.name,
            .to = listed.to,
            .label = listed.label,
            .authorize = listed.authorize,
        });
        const own = site.transitions.len > 0 and site.lists(listed.name);

        const reserved = flow.reserved(listed.name);
        const declared = try who_text(ctx.arena, listed.authorize);

        try transitions.append(ctx.arena, .{
            .name = listed.name,
            .label = listed.label,
            .from = listed.from,
            .to = listed.to,
            .who = if (marked.people) |people| try who_text(ctx.arena, people) else declared,
            .declared = declared,
            .changed = marked.people != null,
            .source = if (own) "site" else if (reserved) "core" else code,
            .off = marked.off,
        });
    }

    return .{
        .statuses = statuses.items,
        .transitions = transitions.items,
    };
}

fn who_text(arena: std.mem.Allocator, who: ?flow.Who) Error![]const u8 {
    std.debug.assert(who == null or who.?.roles.len <= model.operation_override.roles_max);

    const given = who orelse return "";

    return model.operation_override.answer_text(arena, given.answered());
}

/// Who may, from the roles given: anyone holding one of them; none, whoever may edit.
fn who_of(ctx: *Ctx, roles: []const []const u8) Error!flow.Who {
    std.debug.assert(ctx.now_ms >= 0);

    if (roles.len == 0) {
        return .{
            .answer = .signed_in,
        };
    }

    if (roles.len > model.operation_override.roles_max) {
        return error.Invalid;
    }

    for (roles) |role_name| {
        if (!model.role.valid_name(role_name)) {
            return error.Invalid;
        }
    }

    return .{
        .answer = .roles,
        .roles = try ctx.arena.dupe([]const u8, roles),
    };
}

/// `label` as a name: `send_back`, at most `len_max` long.
fn name_of(arena: std.mem.Allocator, label: []const u8, len_max: u64) Error![]const u8 {
    std.debug.assert(len_max > 0);

    const slug = @import("../lib/text.zig").slugify(arena, label) catch return error.Invalid;
    const name = std.mem.trim(u8, slug[0..@min(slug.len, len_max)], "-");
    const kept = try arena.dupe(u8, name);

    std.mem.replaceScalar(u8, kept, '-', '_');

    if (kept.len == 0 or !std.ascii.isLower(kept[0])) {
        return error.Invalid;
    }

    return kept;
}

fn taken(ctx: *Ctx) error{Failed} {
    return ctx.fail(.{
        .name = "Taken",
        .status = 409,
        .message = "the flow has one of that name",
    });
}

fn locked(ctx: *Ctx) error{Failed} {
    return ctx.fail(.{
        .name = "Locked",
        .status = 409,
        .message = "its code declares it: turn a transition off instead; a status stays",
    });
}

fn in_use(ctx: *Ctx, why: []const u8) error{Failed} {
    std.debug.assert(why.len > 0);

    return ctx.fail(.{
        .name = "InUse",
        .status = 409,
        .message = why,
    });
}

const testing_types = @import("content_type.zig");
const testing_record = @import("record.zig");

/// Entries wait for review; only a reviewer (or an administrator) publishes them.
const reviewed_type: model.content_type.Def = .{
    .handle = "guestbook.entry",
    .name = "Entry",
    .owner = "guestbook",
    .fields = &.{.{
        .name = "title",
        .label = "Title",
        .kind = "string",
    }},
    .flow = .{
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
                .authorize = .{
                    .answer = .roles,
                    .roles = &.{"reviewer"},
                },
            },
        },
        .start = "draft",
    },
};

const Testing = struct {
    harness: sdk.testing.Harness,

    fn person(site: *Testing, comptime role: []const u8) Ctx {
        comptime std.debug.assert(role.len > 0);

        return site.harness.ctx(.{
            .user = .{
                .id = role,
                .roles = &.{role},
            },
        });
    }

    fn created(site: *Testing) ![]const u8 {
        var by = site.person("editor");
        const made = try registry_sdk().dispatch(&by, testing_record.Create, .{
            .type = "guestbook.entry",
            .document = "{\"title\":\"Lovely\"}",
        });

        std.debug.assert(made.id.len > 0);

        return made.id;
    }

    fn moved(site: *Testing, ctx: *Ctx, id: []const u8, name: []const u8) ![]const u8 {
        std.debug.assert(site.harness.ctx(.system).now_ms >= 0);
        std.debug.assert(name.len > 0);

        const out = try registry_sdk().dispatch(ctx, testing_record.Transition, .{
            .id = id,
            .transition = name,
        });

        return out.status;
    }
};

fn registry_sdk() type {
    return @import("../server/registry.zig").SDK;
}

fn start(site: *Testing) !void {
    const SDK = registry_sdk();

    try site.harness.init();

    var system = site.harness.ctx(.system);

    try SDK.bootstrap(&system);
    _ = try SDK.dispatch(&system, testing_types.Create, .{
        .definition = try model.content_type.encode(system.arena, reviewed_type),
    });

    std.debug.assert(system.now_ms >= 0);
}

fn transition_named(listed: Flow, name: []const u8) ?Transition {
    std.debug.assert(name.len > 0);

    for (listed.transitions) |one| {
        if (std.mem.eql(u8, one.name, name)) {
            return one;
        }
    }

    return null;
}

test "who may, changed on the site, holds for people and resets to the code's" {
    const SDK = @import("../server/registry.zig").SDK;
    var site: Testing = undefined;
    try start(&site);
    defer site.harness.deinit();

    var admin = site.person("admin");
    var editor = site.person("editor");
    const id = try site.created();

    const submitted = try site.moved(&editor, id, "submit");

    try std.testing.expectEqualStrings("guestbook.in_review", submitted);
    try std.testing.expectError(error.Denied, site.moved(&editor, id, "publish"));

    const changed = try SDK.dispatch(&admin, Authorize, .{
        .type = "guestbook.entry",
        .transition = "publish",
        .user_has_role = &.{"editor"},
    });
    const publish = transition_named(changed, "publish").?;

    try std.testing.expect(publish.changed);
    try std.testing.expectEqualStrings("roles:editor", publish.who);
    try std.testing.expectEqualStrings("roles:reviewer", publish.declared);
    try std.testing.expectEqualStrings("plugin", publish.source);
    try std.testing.expectEqualStrings("published", try site.moved(&editor, id, "publish"));

    const reset = try SDK.dispatch(&admin, Authorize, .{
        .type = "guestbook.entry",
        .transition = "publish",
        .default = true,
    });

    try std.testing.expect(!transition_named(reset, "publish").?.changed);

    const system = site.harness.ctx(.system);
    const kept = store.settings.get;

    try std.testing.expect(try kept(system.db, system.arena, "flow.guestbook.entry") == null);

    // Core's trash takes who may too.
    _ = try SDK.dispatch(&admin, Authorize, .{
        .type = "guestbook.entry",
        .transition = "trash",
        .user_has_role = &.{"reviewer"},
    });
    try std.testing.expectError(error.Denied, site.moved(&editor, id, "trash"));
}

test "a site's own status and transition are used on records and removed" {
    const SDK = @import("../server/registry.zig").SDK;
    var site: Testing = undefined;
    try start(&site);
    defer site.harness.deinit();

    var admin = site.person("admin");
    var editor = site.person("editor");
    const id = try site.created();

    const with_status = try SDK.dispatch(&admin, AddStatus, .{
        .type = "guestbook.entry",
        .label = "On hold",
    });
    const last = with_status.statuses[with_status.statuses.len - 1];

    try std.testing.expectEqualStrings("guestbook.entry.on_hold", last.id);
    try std.testing.expectEqualStrings("site", last.source);

    const added = try SDK.dispatch(&admin, Add, .{
        .type = "guestbook.entry",
        .label = "Hold",
        .from = &.{"draft"},
        .to = "guestbook.entry.on_hold",
    });

    try std.testing.expectEqualStrings("site", transition_named(added, "hold").?.source);
    const held = try site.moved(&editor, id, "hold");

    try std.testing.expectEqualStrings("guestbook.entry.on_hold", held);

    // The status is in use: it stays until the records and transitions leave it.
    try std.testing.expectError(error.Failed, SDK.dispatch(&admin, RemoveStatus, .{
        .type = "guestbook.entry",
        .status = "guestbook.entry.on_hold",
    }));

    const named_again = SDK.dispatch(&admin, Add, .{
        .type = "guestbook.entry",
        .label = "Submit",
        .from = &.{"draft"},
        .to = "published",
    });

    try std.testing.expectError(error.Failed, named_again);

    // The code's transition is never removed.
    try std.testing.expectError(error.Failed, SDK.dispatch(&admin, Remove, .{
        .type = "guestbook.entry",
        .transition = "submit",
    }));

    const removed = try SDK.dispatch(&admin, Remove, .{
        .type = "guestbook.entry",
        .transition = "hold",
    });

    try std.testing.expect(transition_named(removed, "hold") == null);
    try std.testing.expectError(error.Invalid, site.moved(&editor, id, "hold"));
}

test "a code's transition turned off is refused to people; plugin code still makes it" {
    const SDK = @import("../server/registry.zig").SDK;
    var site: Testing = undefined;
    try start(&site);
    defer site.harness.deinit();

    var admin = site.person("admin");
    var editor = site.person("editor");
    const id = try site.created();
    const off = try SDK.dispatch(&admin, SetOn, .{
        .type = "guestbook.entry",
        .transition = "submit",
        .on = false,
    });

    try std.testing.expect(transition_named(off, "submit").?.off);
    try std.testing.expectError(error.Denied, site.moved(&editor, id, "submit"));
    try std.testing.expectError(error.Denied, site.moved(&admin, id, "submit"));

    var plugin = site.person("editor");

    plugin.plugin = "guestbook";
    plugin.plugin_code = true;
    const by_plugin = try site.moved(&plugin, id, "submit");

    try std.testing.expectEqualStrings("guestbook.in_review", by_plugin);

    try std.testing.expectError(error.NotFound, SDK.dispatch(&admin, SetOn, .{
        .type = "guestbook.entry",
        .transition = "trash",
        .on = false,
    }));

    const on = try SDK.dispatch(&admin, SetOn, .{
        .type = "guestbook.entry",
        .transition = "submit",
        .on = true,
    });

    try std.testing.expect(!transition_named(on, "submit").?.off);
}

test "a site type on core's flow takes a status and a transition of its own" {
    const SDK = @import("../server/registry.zig").SDK;
    var site: Testing = undefined;
    try start(&site);
    defer site.harness.deinit();

    var admin = site.person("admin");
    var system = site.harness.ctx(.system);

    _ = try SDK.dispatch(&system, testing_types.Create, .{
        .definition = try model.content_type.encode(system.arena, .{
            .handle = "post",
            .name = "Post",
            .fields = &.{.{
                .name = "title",
                .label = "Title",
                .kind = "string",
            }},
        }),
    });
    _ = try SDK.dispatch(&admin, AddStatus, .{
        .type = "post",
        .label = "In review",
    });

    const added = try SDK.dispatch(&admin, Add, .{
        .type = "post",
        .label = "Review",
        .from = &.{"draft"},
        .to = "post.in_review",
    });

    try std.testing.expectEqualStrings("core", transition_named(added, "publish").?.source);
    try std.testing.expectEqualStrings("site", transition_named(added, "review").?.source);

    const made = try SDK.dispatch(&admin, testing_record.Create, .{
        .type = "post",
        .document = "{\"title\":\"Hi\"}",
    });

    try std.testing.expectEqualStrings("post.in_review", try site.moved(&admin, made.id, "review"));
    try std.testing.expect(try @import("status.zig").find(&admin, "post.in_review") != null);
}
