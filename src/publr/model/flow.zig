/// What a hook on every transition of a type hears (`Posts.any_transition`): the record,
/// the transition's name, and the statuses it left and reached.
pub const Transitioned = struct {
    record: []const u8,
    transition: []const u8,
    from: []const u8,
    to: []const u8,
};

const Status = @import("status.zig").Status;

/// One type's statuses and the transitions between them, as its definition keeps them:
/// Publr's vocabulary (`draft`, `published`, `archived`, `deleted`) plus the type's own
/// statuses, its listed transitions and where its records start. A type without a flow of
/// its own has Publr's.
pub const Flow = struct {
    /// The type's own statuses, namespaced (`guestbook.in_review`); Publr's are not listed.
    statuses: []const Status = &.{},
    transitions: []const Transition = &.{},
    /// Where every record of the type begins; empty: Publr's `draft`.
    start: []const u8 = "",
    /// Who may, as the site changed it; read as the type is, never stored in it.
    who: []const Changed = &.{},
    /// The transitions the site turned off.
    off: []const []const u8 = &.{},
};

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

/// Who may make a transition, kept as plain data: a ready answer of `publr.authorize`.
pub const Who = struct {
    answer: Kind,
    /// With `roles`: anyone holding one of them.
    roles: []const []const u8 = &.{},

    pub const Kind = enum { signed_in, roles, plugin_calls };
};

/// Who may make the transition `name`, as a site changed it.
pub const Changed = struct {
    name: []const u8,
    who: Who,
};
