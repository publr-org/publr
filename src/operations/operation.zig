const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/operation.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const registry = @import("../server/registry.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const override = model.operation_override;
const Answer = @import("../model/caller_answer.zig").Answer;
const key_page = @import("../model/key_page.zig");

pub const namespace = public.namespace;

pub const Who = public.Who;
pub const Rate = public.Rate;
pub const Described = public.Described;
pub const Grouped = public.Grouped;
pub const Failure = public.Failure;
pub const Hook = public.Hook;
pub const Detailed = public.Detailed;

/// One operation as its code declares it, before overrides.
const Declared = struct {
    described: Described,
    /// Made with `publr.operation.define`: an app's pages may call it.
    defined: bool = false,
    details: []const u8 = "",
    destructive: bool = false,
    failures: []const Failure = &.{},
    validate: []const u8 = "",
    who_may_call: []const u8 = "",
};

pub const List = struct {
    pub const shape = public.List;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(registry.SDK.operations.len > 0);

        const named = try names_of(ctx, in.public);
        const page = key_page.window(named.keys, in.after, sdk.operation.page_limit_max);
        const listed = ctx.arena.alloc(Described, page.end - page.start) catch {
            return error.OutOfMemory;
        };

        // Only the page's operations are read in full, each from where its name came.
        for (named.places[page.start..page.end], listed) |place, *out| {
            out.* = try in_effect(ctx, described_at(ctx, place));
        }

        return .{
            .operations = listed,
            .namespaces = &grouped,
            .next = page.next,
        };
    }
};

/// Where a listed operation's declaration is: a compiled-in one by its place in the
/// registry, an installed one by its manifest and its place there.
const Place = struct {
    native: ?u32,
    manifest: u32 = 0,
    declared: u32 = 0,
};

/// The listed operations' names, sorted, and where each one's declaration is.
const Named = struct {
    keys: []const []const u8,
    places: []const Place,
};

const Entry = struct {
    key: []const u8,
    place: Place,

    fn less(_: void, left: Entry, right: Entry) bool {
        return key_page.before(left.key, right.key);
    }
};

fn names_of(ctx: *Ctx, public_only: bool) Error!Named {
    const manifests = installed(ctx);
    var count: u64 = registry.SDK.operations.len;

    for (manifests) |manifest| {
        count += manifest.operations.len;
    }

    var entries = std.ArrayList(Entry).initCapacity(ctx.arena, @intCast(count)) catch {
        return error.OutOfMemory;
    };

    inline for (registry.SDK.operations, 0..) |Operation, index| {
        if (!public_only or declared_native(Operation, index).described.public_api) {
            entries.appendAssumeCapacity(.{
                .key = Operation.name,
                .place = .{
                    .native = index,
                },
            });
        }
    }

    for (manifests, 0..) |manifest, manifest_index| {
        for (manifest.operations, 0..) |declared, declared_index| {
            const shown = declared_installed(manifest.name, declared).described;

            if (!public_only or shown.public_api) {
                entries.appendAssumeCapacity(.{
                    .key = shown.name,
                    .place = .{
                        .native = null,
                        .manifest = @intCast(manifest_index),
                        .declared = @intCast(declared_index),
                    },
                });
            }
        }
    }

    std.mem.sort(Entry, entries.items, {}, Entry.less);

    const keys = ctx.arena.alloc([]const u8, entries.items.len) catch return error.OutOfMemory;
    const places = ctx.arena.alloc(Place, entries.items.len) catch return error.OutOfMemory;

    for (entries.items, keys, places) |entry, *key, *place| {
        key.* = entry.key;
        place.* = entry.place;
    }

    std.debug.assert(keys.len <= count);

    return .{
        .keys = keys,
        .places = places,
    };
}

fn described_at(ctx: *const Ctx, place: Place) Described {
    const native = place.native orelse {
        const manifest = installed(ctx)[place.manifest];

        return declared_installed(manifest.name, manifest.operations[place.declared]).described;
    };

    std.debug.assert(native < registry.SDK.operations.len);

    inline for (registry.SDK.operations, 0..) |Operation, index| {
        if (index == native) {
            return declared_native(Operation, index).described;
        }
    }

    unreachable;
}

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
    pub const shape = public.Get;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
            .app_address = if (found.defined)
                try std.fmt.allocPrint(ctx.arena, "/_actions/app.{s}", .{named})
            else
                "",
        };
    }
};

/// The hooks on the operation `name` and on its event, compiled in and installed.
pub fn hooks_on(ctx: *Ctx, name: []const u8) Error![]const Hook {
    std.debug.assert(name.len > 0);
    const declared = registry.registry;

    std.debug.assert(declared.hooks.len == declared.hook_owners.len);

    var found: std.ArrayList(Hook) = .empty;

    inline for (declared.hooks, declared.hook_owners) |Middleware, owner| {
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
    pub const shape = public.Authorize;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(in.name.len <= 4096);

        const found = try declared_named(ctx, in.name) orelse return error.NotFound;
        const key = try override.authorize_key(ctx.arena, found.described.name);
        const given = @as(u32, @intFromBool(in.user_has_role.len > 0)) +
            @intFromBool(in.user_is_signed_in) + @intFromBool(in.plugin_calls) +
            @intFromBool(in.default);

        if (given != 1 or in.user_has_role.len > override.roles_max) {
            return error.Invalid;
        }

        if (in.user_is_signed_in and !found.described.untrusted_callers) {
            return error.Invalid;
        }

        if (in.default) {
            try store.settings.delete(ctx.db, key);
        } else {
            for (in.user_has_role) |role_name| {
                if (role_name.len == 0 or std.mem.indexOfScalar(u8, role_name, ',') != null) {
                    return error.Invalid;
                }
            }

            const answer: Answer = if (in.user_is_signed_in)
                .signed_in
            else if (in.plugin_calls)
                .plugin_calls
            else
                .{
                    .roles = in.user_has_role,
                };
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
    pub const shape = public.Limit;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
    const custom = defined and @hasDecl(Operation, "open") and Operation.open and answer == null;
    const limit = comptime if (@hasDecl(Operation, "limit") and Operation.limit != null)
        Operation.limit.?.per_minute
    else
        0;
    const failures = comptime @import("../publr/plugin/words.zig").failures_of(Operation);

    return .{
        .described = .{
            .name = Operation.name,
            .kind = @tagName(Operation.kind),
            .plugin = registry.registry.operation_owners[index],
            .description = Operation.description,
            .untrusted_callers = defined and Operation.untrusted_callers,
            .public_api = @hasDecl(Operation, "public_api") and Operation.public_api,
            .destructive = comptime sdk.operation.destroys(Operation),
            .authorize = declared_who(answer, custom),
            .limit = .{
                .declared = limit,
            },
        },
        .defined = defined,
        .details = if (@hasDecl(Operation, "details")) Operation.details else "",
        .destructive = comptime sdk.operation.destroys(Operation),
        .failures = failures,
        .validate = if (@hasDecl(Operation, "checked")) Operation.checked else "",
        .who_may_call = if (@hasDecl(Operation, "who_may_call")) Operation.who_may_call else "",
    };
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
            .public_api = found.public_api,
            .destructive = found.destructive,
            .authorize = declared_who(found.answer, custom),
            .limit = .{
                .declared = found.limit,
            },
        },
        .defined = defined,
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

    if (try store.settings.get(ctx.db, ctx.arena, answer_key)) |text| {
        now.authorize.override = text;
        now.authorize.in_effect = text;
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

    // A page at a time, in the order of names, each name once.
    var after: []const u8 = "";
    var seen: u64 = 0;
    var last: []const u8 = "";

    for (0..registry.SDK.operations.len) |_| {
        const page = try registry.SDK.dispatch(&admin, List, .{
            .after = after,
        });

        try std.testing.expect(page.operations.len <= sdk.operation.page_limit_max);

        for (page.operations) |listed| {
            try std.testing.expect(std.mem.order(u8, last, listed.name) == .lt);
            last = listed.name;
        }

        seen += page.operations.len;
        after = page.next;

        if (after.len == 0) {
            break;
        }
    }

    try std.testing.expect(seen >= registry.SDK.operations.len);
    try std.testing.expectEqual(@as(usize, 0), after.len);

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
        .user_is_signed_in = true,
    }));
    try std.testing.expectError(error.Invalid, registry.SDK.dispatch(&admin, Authorize, .{
        .name = "operation.list",
        .plugin_calls = true,
        .default = true,
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

test "a site's answer reaches core's operations too; through an app the default is the roles" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_1",
        },
    });
    const set = try registry.SDK.dispatch(&admin, Authorize, .{
        .name = "device.offer",
        .user_has_role = &.{"customer"},
    });

    try std.testing.expectEqualStrings("roles:customer", set.authorize.in_effect);

    const core: registry.SDK.Declared = .{
        .untrusted_callers = null,
        .open = false,
    };
    var customer = harness.ctx(.{
        .user = .{
            .id = "u_2",
            .roles = &.{"customer"},
        },
    });
    var editor = harness.ctx(.{
        .user = .{
            .id = "u_3",
            .roles = &.{"editor"},
        },
    });

    try std.testing.expect(try registry.SDK.admit_answer(&customer, "device.offer", core));
    try std.testing.expectError(
        error.Denied,
        registry.SDK.admit_answer(&editor, "device.offer", core),
    );

    _ = try registry.SDK.dispatch(&admin, Authorize, .{
        .name = "device.offer",
        .default = true,
    });
    try std.testing.expect(!try registry.SDK.admit_answer(&editor, "device.offer", core));

    // Through an app an administrator is a signed-in person: the default lets in only the
    // roles granted the operation.
    const defined: registry.SDK.Declared = .{
        .untrusted_callers = false,
        .open = false,
    };
    var admin_in_app = harness.ctx(.{
        .user = .{
            .id = "u_1",
            .roles = &.{"admin"},
        },
    });
    admin_in_app.app_plugins = &.{};
    editor.app_plugins = &.{};

    try std.testing.expectError(
        error.Denied,
        registry.SDK.admit_answer(&admin_in_app, "record.list", defined),
    );
    try std.testing.expect(!try registry.SDK.admit_answer(&editor, "record.list", defined));

    var nobody = harness.ctx(.anonymous);
    nobody.app_plugins = &.{};

    try std.testing.expectError(
        error.Denied,
        registry.SDK.admit_answer(&nobody, "record.list", defined),
    );

    const listed = try registry.SDK.dispatch(&admin, List, .{
        .public = true,
    });

    for (listed.operations) |each| {
        try std.testing.expect(each.public_api);
    }
}
