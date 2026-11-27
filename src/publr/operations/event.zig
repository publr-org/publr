//! The events plugins declare (`publr.event.define`, listed in `.events`), compiled in and
//! installed, each with its payload's fields: what a plugin hooking one (`publr.on`,
//! `publr.after`, `publr.remote.event`) writes its own words against. `event.list`,
//! `event.get`. Every operation also emits an event under its own name carrying its answer;
//! `operation get` describes those.
const operation = @import("../operation.zig");
const Hook = @import("operation.zig").Hook;

pub const namespace: operation.Namespace = .{
    .name = "event",
    .label = "Events",
    .area = .system,
    .summary = "The events plugins declare, with their payloads",
    .details =
    \\What each plugin's events carry, compiled in and installed: the payload's fields, each
    \\with its kind, for a plugin hooking one to write its own words against. Every
    \\operation also emits an event under its own name, carrying its answer (`operation
    \\get`). Administrators only.
    ,
};

/// One field of a payload: its path (`lines[].sku`), its kind, whether it may be null or
/// left out, an enumeration's values.
pub const Field = struct {
    path: []const u8,
    kind: []const u8,
    optional: bool = false,
    required: bool = true,
    values: []const []const u8 = &.{},
};

pub const Described = struct {
    name: []const u8,
    /// The plugin that emits it.
    plugin: []const u8,
    installed: bool = false,
    payload: []const Field,
};
pub const example_described: Described = .{
    .name = "hello.recorded",
    .plugin = "hello",
    .payload = &.{.{
        .path = "note",
        .kind = "string",
    }},
};

pub const List = struct {
    pub const name = "event.list";
    pub const description = "Every event plugins declare, with its payload";
    pub const details =
        \\Administrators only. Each event a plugin declares, compiled in and installed: its
        \\name (`orders.paid`), the plugin emitting it, and its payload's fields with their
        \\kinds. `plugin` keeps one plugin's. Operations' own events (one per operation,
        \\carrying its answer) are not listed: `operation get` describes them. A page at a
        \\time, in the order of their names: `next` continues it.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        plugin: []const u8 = "",
        after: []const u8 = "",
    };
    pub const Out = struct {
        events: []const Described,
        next: []const u8 = "",
    };
    pub const example: In = .{
        .plugin = "hello",
    };
    pub const example_out: Out = .{
        .events = &.{example_described},
    };
    pub const field_docs: operation.Docs(In) = .{
        .plugin = "Only this plugin's events; every plugin's when left out",
        .after = "The page after this name: the `next` the last page answered",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .events = "Each event: name, plugin, installed, payload (path, kind, optional, " ++
            "required, values)",
        .next = "The next page's `after`; empty after the last",
    };
};

pub const Get = struct {
    pub const name = "event.get";
    pub const description = "One event: its payload, and the hooks that hear it";
    pub const details =
        \\Administrators only. The event as `event list` describes it, and each hook on it
        \\(plugin, stage `after` or `on`, its reason, its last failed run). Fails as not
        \\found for a name no plugin declares.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        name: []const u8,
    };
    pub const Out = struct {
        event: Described,
        hooks: []const Hook = &.{},
    };
    pub const example: In = .{
        .name = "hello.recorded",
    };
    pub const example_out: Out = .{
        .event = example_described,
    };
    pub const field_docs: operation.Docs(In) = .{
        .name = "The event's name, as `event list` gives it",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .event = "As `event list` describes it",
        .hooks = "Each hook on it: plugin, stage, reason and last_failure",
    };
};
