//! A type's flow as a site changes it: who may make each transition, the code's transitions
//! turned off and on, and the site's own transitions and statuses. Changes are laid over the
//! type's flow as it is read; resetting one drops it.
const operation = @import("../operation.zig");

pub const namespace: operation.Namespace = .{
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
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        type: []const u8,
    };
    pub const Out = Flow;
    pub const example: In = .{
        .type = "post",
    };
    pub const example_out: Out = example_flow;
    pub const field_docs: operation.Docs(In) = .{
        .type = type_doc,
    };
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
    pub const kind: operation.Kind = .write;
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
    pub const field_docs: operation.Docs(In) = .{
        .type = type_doc,
        .transition = name_doc,
        .user_has_role = roles_doc,
        .user_is_signed_in = "Whoever may edit the record",
        .default = "Back to what its code says",
    };
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
    pub const kind: operation.Kind = .write;
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
        .label = "Return",
        .from = &.{"archived"},
        .to = "draft",
    };
    pub const example_out: Out = example_flow;
    pub const field_docs: operation.Docs(In) = .{
        .type = type_doc,
        .label = "Its button, and its name made from it (`Send back` is `send_back`)",
        .from = "The statuses it leaves",
        .to = "The status it reaches",
        .user_has_role = roles_doc,
    };
};

pub const Remove = struct {
    pub const name = "flow.remove";
    pub const description = "Remove a transition this site added";
    pub const details =
        \\Administrators only. Only the site's own: the code's transitions are turned off
        \\(`flow set_on`), never removed. Records stay where they are.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        type: []const u8,
        transition: []const u8,
    };
    pub const Out = Flow;
    pub const example: In = .{
        .type = "page",
        .transition = "send_back",
    };
    pub const example_out: Out = example_flow;
    pub const field_docs: operation.Docs(In) = .{
        .type = type_doc,
        .transition = name_doc,
    };
};

pub const SetOn = struct {
    pub const name = "flow.set_on";
    pub const description = "Turn one of the code's transitions off for people, or back on";
    pub const details =
        \\Administrators only. Off, people can't make it any more, administrators included;
        \\the plugin's own code still can, so the plugin keeps working. Core's `trash`,
        \\`restore` and `destroy` are never turned off, and the site's own are removed instead.
    ;
    pub const kind: operation.Kind = .write;
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
    pub const field_docs: operation.Docs(In) = .{
        .type = type_doc,
        .transition = name_doc,
        .on = "On, as its code says; off, refused to people",
    };
};

pub const AddStatus = struct {
    pub const name = "flow.add_status";
    pub const description = "Add a status of this site's own to a type's flow";
    pub const details =
        \\Administrators only. Named under the type (`post.in_review`) from its label; not
        \\live: visitors don't see records in it. Add transitions into and out of it with
        \\`flow add`.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        type: []const u8,
        label: []const u8,
    };
    pub const Out = Flow;
    pub const example: In = .{
        .type = "post",
        .label = "On hold",
    };
    pub const example_out: Out = example_flow;
    pub const field_docs: operation.Docs(In) = .{
        .type = type_doc,
        .label = "How it reads, and its id made from it",
    };
};

pub const RemoveStatus = struct {
    pub const name = "flow.remove_status";
    pub const description = "Remove a status this site added";
    pub const details =
        \\Administrators only. Only the site's own, and only while no record is in it and no
        \\transition leads into or out of it: remove those first. The code's statuses are
        \\never removed.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        type: []const u8,
        status: []const u8,
    };
    pub const Out = Flow;
    pub const example: In = .{
        .type = "page",
        .status = "page.in_review",
    };
    pub const example_out: Out = example_flow;
    pub const field_docs: operation.Docs(In) = .{
        .type = type_doc,
        .status = "The status's id, as `flow get` gives it",
    };
};
