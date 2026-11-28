//! What code declares about each operation, as data a site reads and overrides: who may
//! call it and its rate limit. `operation.list`, `operation.get`, `operation.authorize`,
//! `operation.limit`; the overrides are settings, read where each is checked.
const operation = @import("../operation.zig");

pub const namespace: operation.Namespace = .{
    .name = "operation",
    .label = "Operations",
    .area = .system,
    .summary = "Every operation, as its code declares it and as this site overrides it",
    .details =
    \\What each operation is, who may call it and how often, core's, built-in plugins' and
    \\installed plugins' alike, as declared, overridden and in effect. A site overrides who
    \\may call any operation (`operation authorize`) and the calls a minute it takes from one
    \\caller (`operation limit`). Administrators only.
    ,
};

/// Who may call: `default` (administrators, and roles an administrator granted it),
/// `custom` (the plugin's own check), or a ready answer (`signed_in`, `roles:editor`).
pub const Who = struct {
    declared: []const u8,
    override: []const u8 = "",
    in_effect: []const u8,
};

/// Calls a minute one caller makes, on top of the general limit; 0 for none.
pub const Rate = struct {
    declared: u32 = 0,
    override: u32 = 0,
    in_effect: u32 = 0,
};

/// An operation as `operation.list` answers it.
pub const Described = struct {
    name: []const u8,
    kind: []const u8,
    /// The plugin that brings it; empty for core's.
    plugin: []const u8 = "",
    description: []const u8,
    untrusted_callers: bool = false,
    public_api: bool = false,
    /// Whether it destroys what cannot be had back.
    destructive: bool = false,
    authorize: Who,
    limit: Rate,
};

/// A namespace as people see it: what it is called and where roles list it.
pub const Grouped = struct {
    name: []const u8,
    label: []const u8,
    summary: []const u8,
    /// content, site, people, system or background.
    area: []const u8,
};

pub const Failure = operation.Failure;

/// A hook on an operation: a plugin's `before` or `after` on the call, or `on` its event.
pub const Hook = struct {
    plugin: []const u8,
    /// before, after or on.
    stage: []const u8,
    /// Why, in the plugin's words.
    reason: []const u8 = "",
    /// Its last failed `on` run still kept to run again; empty when none is.
    last_failure: []const u8 = "",
};

/// Everything an operation says of itself, as `operation.get` answers it.
pub const Detailed = struct {
    operation: Described,
    details: []const u8 = "",
    destructive: bool = false,
    failures: []const Failure = &.{},
    /// What its `.validate` checks, in the plugin's words; empty for none.
    validate: []const u8 = "",
    /// Who may call it, as its code says it.
    who_may_call: []const u8 = "",
    hooks: []const Hook = &.{},
    /// Where an app's pages call it (`/_actions/app.<name>`); empty for core's own.
    app_address: []const u8 = "",
};

const example_described: Described = .{
    .name = "operation.list",
    .kind = "read",
    .description = List.description,
    .authorize = .{
        .declared = "default",
        .in_effect = "default",
    },
    .limit = .{},
};

pub const List = struct {
    pub const name = "operation.list";
    pub const description = "Every operation, with who may call it and its limit";
    pub const details =
        \\Administrators only. Core's operations, built-in plugins' and installed plugins',
        \\by name: each one's kind, plugin, words, whether callers without credentials may
        \\call it, whether it destroys what cannot be had back, and who may call it and its
        \\limit, as declared, overridden and in effect. Then each built-in namespace with what
        \\people call it and the area roles list it under. `public` lists only the operations
        \\their plugins publish for outside developers (`.public_api`): the API reference. A
        \\page at a time, in the order of their names: `next` continues it.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        public: bool = false,
        after: []const u8 = "",
    };
    pub const Out = struct {
        operations: []const Described,
        namespaces: []const Grouped,
        next: []const u8 = "",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .operations = &.{example_described},
        .namespaces = &.{.{
            .name = "operation",
            .label = "Operations",
            .summary = namespace.summary,
            .area = "system",
        }},
        .next = "provider.answers",
    };
    pub const field_docs: operation.Docs(In) = .{
        .public = "Only those published for outside developers (`.public_api`)",
        .after = "The page after this name: the `next` the last page answered",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .operations = "Each operation: name, kind, plugin, description, untrusted_callers, " ++
            "public_api, destructive, authorize and limit (declared, override, " ++
            "in_effect)",
        .namespaces = "Each built-in namespace: name, label, summary and area (content, " ++
            "site, people, system, background)",
        .next = "The next page's `after`; empty after the last",
    };
};

pub const Get = struct {
    pub const name = "operation.get";
    pub const description = "Everything an operation says of itself, and this site's overrides";
    pub const details =
        \\Administrators only. Its words and kind, the plugin that brings it, how it fails,
        \\whether it destroys what cannot be had back, what it checks, who may call it and its
        \\limit, as declared, overridden and in effect, the hooks on it with each one's last
        \\failure, and where an app's pages call it. Fails as not found for a name no
        \\operation has.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        name: []const u8,
    };
    pub const Out = Detailed;
    pub const example: In = .{
        .name = "operation.list",
    };
    pub const example_out: Out = .{
        .operation = example_described,
        .details = List.details,
    };
    pub const field_docs: operation.Docs(In) = .{
        .name = "The operation's name, as `operation list` gives it",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .operation = "As `operation list` describes it",
        .details = "Who may call it, what it changes, how it fails, in its words",
        .destructive = "Whether it destroys what cannot be had back",
        .failures = "How it can refuse: name, HTTP status, meaning",
        .validate = "What its `.validate` checks, in its plugin's words; empty for none",
        .who_may_call = "Who may call it, as its code says it",
        .hooks = "Each hook on it: plugin, stage (before, after, on), reason and " ++
            "last_failure (its last failed run kept to run again)",
        .app_address = "Where an app's pages call it; empty for core's own",
    };
};

pub const Authorize = struct {
    pub const name = "operation.authorize";
    pub const description = "Override who may call an operation on this site";
    pub const find_words = "permissions, who may call, restrict access, roles, lock down";
    pub const details =
        \\Administrators only. Give one of `user_has_role` (the roles, administrators
        \\always), `user_is_signed_in` (only where the operation takes untrusted callers),
        \\`plugin_calls` (other plugins' code only), or `default` to go back to what its code
        \\says. Any operation, core's too: the override decides who gets in, and the policies
        \\still narrow what they reach. Where the code checks callers with a function of its
        \\own, that check still runs: the override can only narrow, and `warning` says so.
        \\Fails as not found for a name no operation has, and as invalid for none or more
        \\than one answer, or one it cannot take.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
        user_has_role: []const []const u8 = &.{},
        user_is_signed_in: bool = false,
        plugin_calls: bool = false,
        default: bool = false,
    };
    pub const Out = struct {
        authorize: Who,
        warning: []const u8 = "",
    };
    pub const example: In = .{
        .name = "hello.record",
        .user_has_role = &.{ "moderator", "editor" },
    };
    pub const example_out: Out = .{
        .authorize = .{
            .declared = "default",
            .override = "roles:moderator,editor",
            .in_effect = "roles:moderator,editor",
        },
    };
    pub const field_docs: operation.Docs(In) = .{
        .name = "The operation's name, as `operation list` gives it",
        .user_has_role = "Anyone holding one of these roles, and administrators",
        .user_is_signed_in = "Anyone signed in; only where it takes untrusted callers",
        .plugin_calls = "Other plugins' code only",
        .default = "Back to what its code says",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .authorize = "Who may call it now: declared, override, in_effect",
        .warning = "Said when the code's own check still runs beside the override",
    };
};

pub const Limit = struct {
    pub const name = "operation.limit";
    pub const description = "Override how many calls a minute an operation takes from one caller";
    pub const details =
        \\Administrators only. `per_minute` is the calls a minute one untrusted caller (a
        \\site's pages, or anyone without credentials: an account, else a visitor, else an
        \\address) may make to it, on top of the general limit; 0 goes back to what its code
        \\says. Any operation, core's too. Fails as not found for a name no operation has.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
        per_minute: u32,
    };
    pub const Out = struct {
        limit: Rate,
    };
    pub const example: In = .{
        .name = "operation.list",
        .per_minute = 10,
    };
    pub const example_out: Out = .{
        .limit = .{
            .override = 10,
            .in_effect = 10,
        },
    };
    pub const field_docs: operation.Docs(In) = .{
        .name = "The operation's name, as `operation list` gives it",
        .per_minute = "Calls a minute per caller; 0 for what its code says",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .limit = "Its limit now: declared, override, in_effect",
    };
};
