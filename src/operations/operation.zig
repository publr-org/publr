//! What code declares about each operation, as data a site reads and overrides: who may
//! call it and its rate limit. `operation.list`, `operation.get`, `operation.authorize`,
//! `operation.limit`; the overrides are settings (`model/operation_override.zig`), read
//! where each is checked.
const std = @import("std");
const sdk = @import("../sdk.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const registry = @import("../server/registry.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const override = model.operation_override;
const Answer = @import("../model/caller_answer.zig").Answer;

pub const namespace: sdk.operation.Namespace = .{
    .name = "operation",
    .label = "Operations",
    .area = .system,
    .summary = "Every operation, as its code declares it and as this site overrides it",
    .details =
    \\What each operation is, who may call it and how often, core's, built-in plugins' and
    \\installed plugins' alike, as declared, overridden and in effect. A site overrides who
    \\may call an operation a plugin made with `publr.operation.define` (`operation
    \\authorize`) and the calls a minute any operation takes from one caller (`operation
    \\limit`). Administrators only.
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

pub const Described = struct {
    name: []const u8,
    kind: []const u8,
    /// The plugin that brings it; empty for core's.
    plugin: []const u8 = "",
    description: []const u8,
    untrusted_callers: bool = false,
    public_api: bool = false,
    /// Whether `operation authorize` reaches it: made with `publr.operation.define`.
    overridable: bool = false,
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

pub const Failure = struct {
    name: []const u8,
    status: u16,
    message: []const u8,
};

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
    /// Where an app's pages call it (`/_actions/app.<name>`); empty when they cannot.
    app_address: []const u8 = "",
};

/// One operation as its code declares it, before overrides.
const Declared = struct {
    described: Described,
    details: []const u8 = "",
    destructive: bool = false,
    failures: []const Failure = &.{},
    validate: []const u8 = "",
    who_may_call: []const u8 = "",
};

pub const List = struct {
    pub const name = "operation.list";
    pub const description = "Every operation, with who may call it and its limit";
    pub const details =
        \\Administrators only. Core's operations, built-in plugins' and installed plugins',
        \\by name: each one's kind, plugin, words, whether callers without credentials may
        \\call it, whether it destroys what cannot be had back, and who may call it and its
        \\limit, as declared, overridden and in effect. Then each built-in namespace with what
        \\people call it and the area roles list it under.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        operations: []const Described,
        namespaces: []const Grouped,
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
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .operations = "Each operation: name, kind, plugin, description, untrusted_callers, " ++
            "public_api, overridable, destructive, authorize and limit (declared, override, " ++
            "in_effect)",
        .namespaces = "Each built-in namespace: name, label, summary and area (content, " ++
            "site, people, system, background)",
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(registry.SDK.operations.len > 0);

        var listed: std.ArrayList(Described) = .empty;

        inline for (registry.SDK.operations, 0..) |Operation, index| {
            const found = declared_native(Operation, index);

            listed.append(ctx.arena, try in_effect(ctx, found.described)) catch {
                return error.OutOfMemory;
            };
        }

        for (installed(ctx)) |manifest| {
            for (manifest.operations) |declared| {
                const found = declared_installed(manifest.name, declared);

                listed.append(ctx.arena, try in_effect(ctx, found.described)) catch {
                    return error.OutOfMemory;
                };
            }
        }

        return .{
            .operations = listed.items,
            .namespaces = &grouped,
        };
    }
};

const grouped = grouped: {
    var all: [registry.SDK.namespaces.len]Grouped = undefined;

    for (registry.SDK.namespaces, &all) |declared, *out| {
        out.* = .{
            .name = declared.name,
            .label = if (declared.label.len > 0) declared.label else declared.name,
            .summary = declared.summary,
            .area = @tagName(declared.area),
        };
    }

    const done = all;

    break :grouped done;
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
    pub const kind: sdk.operation.Kind = .read;
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
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The operation's name, as `operation list` gives it",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .operation = "As `operation list` describes it",
        .details = "Who may call it, what it changes, how it fails, in its words",
        .destructive = "Whether it destroys what cannot be had back",
        .failures = "How it can refuse: name, HTTP status, meaning",
        .validate = "What its `.validate` checks, in its plugin's words; empty for none",
        .who_may_call = "Who may call it, as its code says it",
        .hooks = "Each hook on it: plugin, stage (before, after, on), reason and " ++
            "last_failure (its last failed run kept to run again)",
        .app_address = "Where an app's pages call it; empty when only callers with " ++
            "credentials may",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(in.name.len <= 4096);

        const found = try declared_named(ctx, in.name) orelse return error.NotFound;
        const named = found.described.name;

        return .{
            .operation = try in_effect(ctx, found.described),
            .details = found.details,
            .destructive = found.destructive,
            .failures = found.failures,
            .validate = found.validate,
            .who_may_call = found.who_may_call,
            .hooks = try hooks_on(ctx, named),
            .app_address = if (found.described.untrusted_callers)
                try std.fmt.allocPrint(ctx.arena, "/_actions/app.{s}", .{named})
            else
                "",
        };
    }
};

/// The hooks on the operation `name` and on its event, compiled in and installed.
fn hooks_on(ctx: *Ctx, name: []const u8) Error![]const Hook {
    std.debug.assert(name.len > 0);
    const declared = registry.registry;

    std.debug.assert(declared.middleware.len == declared.middleware_owners.len);

    var found: std.ArrayList(Hook) = .empty;

    inline for (declared.middleware, declared.middleware_owners) |Middleware, owner| {
        const stage = comptime Middleware.stage;
        const target: []const u8 = comptime switch (stage) {
            .before, .after => Middleware.operation,
            .on => if (@hasDecl(Middleware, "event")) Middleware.event else "",
            .pre, .modify => "",
        };

        if (target.len > 0 and std.mem.eql(u8, target, name)) {
            try found.append(ctx.arena, .{
                .plugin = owner,
                .stage = @tagName(stage),
                .reason = if (@hasDecl(Middleware, "reason")) Middleware.reason else "",
            });
        }
    }

    for (installed(ctx)) |manifest| {
        for (manifest.hooks) |hook| {
            if (hook.stage == .modify or !std.mem.eql(u8, hook.target, name)) {
                continue;
            }

            try found.append(ctx.arena, .{
                .plugin = manifest.name,
                .stage = if (hook.stage == .event) "on" else @tagName(hook.stage),
                .reason = hook.reason,
            });
        }
    }

    for (found.items) |*hook| {
        if (std.mem.eql(u8, hook.stage, "on")) {
            hook.last_failure = try last_failure(ctx, hook.plugin, name);
        }
    }

    return found.items;
}

/// The problem of a plugin's latest failed `on` run on the event `name` still kept.
fn last_failure(ctx: *Ctx, plugin: []const u8, name: []const u8) Error![]const u8 {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(name.len > 0);

    const run_name = try @import("../sdk/hook_runs.zig").name_of(ctx.arena, name, 0);

    return store.job_queue.last_problem(ctx.db, ctx.arena, plugin, run_name);
}

pub const Authorize = struct {
    pub const name = "operation.authorize";
    pub const description = "Override who may call a plugin's operation on this site";
    pub const details =
        \\Administrators only. `answer` is `plugin_calls`, `roles:<role>,<role>`, `signed_in`
        \\(only where the operation takes untrusted callers), or `default` to go back to what
        \\its code says. Reaches operations a plugin made with
        \\`publr.operation.define`; core's keep their grants and roles. Where the code checks
        \\callers with a function of its own, that check still runs: the override can only
        \\narrow, and `warning` says so. Fails as not found for a name no operation has, and
        \\as invalid for an answer it cannot take.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
        answer: []const u8,
    };
    pub const Out = struct {
        authorize: Who,
        warning: []const u8 = "",
    };
    pub const example: In = .{
        .name = "hello.record",
        .answer = "signed_in",
    };
    pub const example_out: Out = .{
        .authorize = .{
            .declared = "default",
            .override = "signed_in",
            .in_effect = "signed_in",
        },
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The operation's name, as `operation list` gives it",
        .answer = "signed_in, plugin_calls, roles:<role>,<role>, or default",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .authorize = "Who may call it now: declared, override, in_effect",
        .warning = "Said when the code's own check still runs beside the override",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(in.name.len <= 4096);

        const found = try declared_named(ctx, in.name) orelse return error.NotFound;
        const key = try override.authorize_key(ctx.arena, found.described.name);

        if (!found.described.overridable) {
            return error.Invalid;
        }

        if (std.mem.eql(u8, in.answer, "default")) {
            try store.settings.delete(ctx.db, key);
        } else {
            const answer = try override.parse_answer(ctx.arena, in.answer) orelse {
                return error.Invalid;
            };

            if (answer == .signed_in and !found.described.untrusted_callers) {
                return error.Invalid;
            }

            const text = try override.answer_text(ctx.arena, answer);

            try store.settings.set(ctx.db, key, text, ctx.now_ms);
        }

        const custom = std.mem.eql(u8, found.described.authorize.declared, "custom");
        const now = try in_effect(ctx, found.described);

        return .{
            .authorize = now.authorize,
            .warning = if (custom and now.authorize.override.len > 0)
                "Its code checks callers with a function of its own, which still runs: " ++
                    "this can only narrow who may call it"
            else
                "",
        };
    }
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
    pub const kind: sdk.operation.Kind = .write;
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
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The operation's name, as `operation list` gives it",
        .per_minute = "Calls a minute per caller; 0 for what its code says",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .limit = "Its limit now: declared, override, in_effect",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(in.name.len <= 4096);

        const found = try declared_named(ctx, in.name) orelse return error.NotFound;
        const key = try override.limit_key(ctx.arena, found.described.name);

        if (in.per_minute == 0) {
            try store.settings.delete(ctx.db, key);
        } else {
            const text = std.fmt.allocPrint(ctx.arena, "{d}", .{in.per_minute}) catch {
                return error.OutOfMemory;
            };

            try store.settings.set(ctx.db, key, text, ctx.now_ms);
        }

        const now = try in_effect(ctx, found.described);

        return .{
            .limit = now.limit,
        };
    }
};

pub const operations = [_]type{ List, Get, Authorize, Limit };

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

/// The operation `name`, compiled in or installed; null for a name none has.
fn declared_named(ctx: *Ctx, name: []const u8) Error!?Declared {
    std.debug.assert(name.len <= 4096);
    std.debug.assert(registry.SDK.operations.len > 0);

    if (name.len == 0 or name.len > override.name_len_max) {
        return null;
    }

    inline for (registry.SDK.operations, 0..) |Operation, index| {
        if (std.mem.eql(u8, Operation.name, name)) {
            return declared_native(Operation, index);
        }
    }

    for (installed(ctx)) |manifest| {
        for (manifest.operations) |declared| {
            if (std.mem.eql(u8, declared.name, name)) {
                return declared_installed(manifest.name, declared);
            }
        }
    }

    return null;
}

fn installed(ctx: *const Ctx) []const model.sandboxed_plugin.Manifest {
    std.debug.assert(ctx.now_ms >= 0);

    const sandboxed = ctx.sandboxed_plugins orelse return &.{};

    return sandboxed.manifests();
}

fn declared_native(comptime Operation: type, comptime index: u32) Declared {
    comptime std.debug.assert(Operation.name.len > 0);
    comptime std.debug.assert(index < registry.SDK.operations.len);

    const defined = comptime @hasDecl(Operation, "untrusted_callers");
    const answer: ?Answer = comptime if (@hasDecl(Operation, "answer"))
        Operation.answer
    else
        null;
    const custom = defined and Operation.open and answer == null;
    const limit = comptime if (@hasDecl(Operation, "limit") and Operation.limit != null)
        Operation.limit.?.per_minute
    else
        0;
    const failures = comptime if (@hasDecl(Operation, "failures")) failures_of(Operation) else &.{};

    return .{
        .described = .{
            .name = Operation.name,
            .kind = @tagName(Operation.kind),
            .plugin = registry.registry.operation_owners[index],
            .description = Operation.description,
            .untrusted_callers = defined and Operation.untrusted_callers,
            .public_api = @hasDecl(Operation, "public_api") and Operation.public_api,
            .overridable = defined,
            .destructive = comptime sdk.operation.destroys(Operation),
            .authorize = declared_who(answer, custom),
            .limit = .{
                .declared = limit,
            },
        },
        .details = if (@hasDecl(Operation, "details")) Operation.details else "",
        .destructive = comptime sdk.operation.destroys(Operation),
        .failures = failures,
        .validate = if (@hasDecl(Operation, "checked")) Operation.checked else "",
        .who_may_call = if (@hasDecl(Operation, "who_may_call")) Operation.who_may_call else "",
    };
}

fn failures_of(comptime Operation: type) []const Failure {
    comptime {
        std.debug.assert(Operation.name.len > 0);

        var list: []const Failure = &.{};

        for (Operation.failures) |failure| {
            list = list ++ [_]Failure{.{
                .name = failure.name,
                .status = failure.status,
                .message = failure.message,
            }};
        }

        const done = list;

        return done;
    }
}

fn declared_installed(plugin: []const u8, found: model.sandboxed_plugin.Operation) Declared {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(found.name.len > 0);

    const defined = found.untrusted_callers != null;
    const custom = defined and found.open and found.answer == null;

    return .{
        .described = .{
            .name = found.name,
            .kind = @tagName(found.kind),
            .plugin = plugin,
            .description = found.description,
            .untrusted_callers = found.untrusted_callers orelse false,
            .overridable = defined,
            .authorize = declared_who(found.answer, custom),
            .limit = .{
                .declared = found.limit,
            },
        },
        .details = found.details,
        .validate = found.checked,
        .who_may_call = found.who_may_call,
    };
}

fn declared_who(answer: ?Answer, custom: bool) Who {
    std.debug.assert(!(custom and answer != null));

    const text = if (answer) |ready| switch (ready) {
        .visitor => "anyone",
        .signed_in => "signed_in",
        .plugin_calls => "plugin_calls",
        .roles => "roles",
    } else if (custom) "custom" else "default";

    std.debug.assert(text.len > 0);

    return .{
        .declared = text,
        .in_effect = text,
    };
}

/// The declared description with this site's overrides read in.
fn in_effect(ctx: *Ctx, declared: Described) Error!Described {
    std.debug.assert(declared.name.len > 0);
    std.debug.assert(declared.authorize.declared.len > 0);

    var now = declared;
    const answer_key = try override.authorize_key(ctx.arena, declared.name);
    const limit_key = try override.limit_key(ctx.arena, declared.name);

    if (declared.overridable) {
        if (try store.settings.get(ctx.db, ctx.arena, answer_key)) |text| {
            now.authorize.override = text;
            now.authorize.in_effect = text;
        }
    }

    if (try store.settings.get(ctx.db, ctx.arena, limit_key)) |text| {
        now.limit.override = std.fmt.parseInt(u32, text, 10) catch 0;
    }

    now.limit.in_effect = if (now.limit.override > 0) now.limit.override else now.limit.declared;

    return now;
}

test "a site's limit and answer read in, and back to the code's" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_1",
        },
    });

    const listed = try registry.SDK.dispatch(&admin, List, .{});

    try std.testing.expect(listed.operations.len >= registry.SDK.operations.len);

    const limited = try registry.SDK.dispatch(&admin, Limit, .{
        .name = "operation.list",
        .per_minute = 5,
    });

    try std.testing.expectEqual(5, limited.limit.in_effect);

    const cleared = try registry.SDK.dispatch(&admin, Limit, .{
        .name = "operation.list",
        .per_minute = 0,
    });

    try std.testing.expectEqual(0, cleared.limit.in_effect);
    try std.testing.expectError(error.Invalid, registry.SDK.dispatch(&admin, Authorize, .{
        .name = "operation.list",
        .answer = "signed_in",
    }));
    try std.testing.expectError(error.NotFound, registry.SDK.dispatch(&admin, Get, .{
        .name = "nothing.here",
    }));
}

test "an operation's own limit counts untrusted callers only" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const table = try std.testing.allocator.create(sdk.limits.Limits);
    defer std.testing.allocator.destroy(table);

    table.* = .{};

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_1",
        },
    });

    _ = try registry.SDK.dispatch(&admin, Limit, .{
        .name = "operation.list",
        .per_minute = 1,
    });

    admin.limits = table;
    admin.address = "203.0.113.7";

    _ = try registry.SDK.dispatch(&admin, List, .{});
    _ = try registry.SDK.dispatch(&admin, List, .{});

    var anonymous = harness.ctx(.anonymous);

    anonymous.limits = table;
    anonymous.address = "203.0.113.8";

    try std.testing.expectError(error.Denied, registry.SDK.dispatch(&anonymous, List, .{}));
    try std.testing.expectError(error.Throttled, registry.SDK.dispatch(&anonymous, List, .{}));
}
