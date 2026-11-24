//! The types of user plugins register (customers, members, students), and which apps each
//! may sign in to: a setting on the type that administrators and agents change.
const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");
const model = @import("../model/user_type.zig");
const user_types = @import("../sdk/user_types.zig");
const operation_define = @import("../sdk/plugin/operation_define.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace: sdk.operation.Namespace = .{
    .name = "user_type",
    .label = "User types",
    .area = .people,
    .summary = "Types of user plugins register, and the apps each may sign in to",
    .details =
    \\A plugin registers a type of user (`customers` registers `customer`): people with an
    \\account on the site, on the one identity system (passwords, set-password links,
    \\sessions, sign-in providers), who are never staff. An account of a type signs in to
    \\the apps its type opens and nowhere else, as nobody elsewhere; it reaches the admin
    \\only if its roles grant it, and never holds `admin`. Settings › Users lists staff
    \\only; a type's plugin draws its own list (`user list --user_type customer`).
    ,
};

pub const operations = [_]type{ List, Set };

pub const Listed = struct {
    name: []const u8,
    label: []const u8,
    plugin: []const u8,
    /// The apps its people may sign in to now.
    apps: []const []const u8,
    /// A role it names that is staff now, so it gives nothing (no sign-up, no `user.add_type`)
    /// until the role is a visitor's again; empty when its roles are visitors'.
    refused_role: []const u8 = "",
};

pub const List = struct {
    pub const name = "user_type.list";
    pub const description = "List the types of user plugins register, each with its apps";
    pub const details =
        \\Every type a compiled-in or installed plugin registers, and the apps (`app.zon`'s
        \\`.name`) its people may sign in to: the administrator's choice when made
        \\(`user_type set`), else what the plugin declared. Administrators, and plugins.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const untrusted_callers = false;
    /// `.authorize`: administrators and plugin calls, never anyone else.
    pub const answer: ?operation_define.Answer = .plugin_calls;
    pub const example_signed_in = true;
    pub const In = struct {};
    pub const Out = struct {
        types: []const Listed,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .types = &.{.{
            .name = "customer",
            .label = "Customer",
            .plugin = "customers",
            .apps = &.{"shop"},
        }},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{};
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .types = "Each type: its name, label, plugin and the apps its people may sign in to",
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const declared = try user_types.all(ctx);
        const listed = try ctx.arena.alloc(Listed, declared.len);

        for (declared, listed) |one, *each| {
            each.* = .{
                .name = one.name,
                .label = one.label,
                .plugin = one.plugin,
                .apps = try user_types.apps_of(ctx, one),
                .refused_role = try user_types.staff_role_given(ctx, one) orelse "",
            };
        }

        std.debug.assert(listed.len == declared.len);

        return .{
            .types = listed,
        };
    }
};

pub const Set = struct {
    pub const name = "user_type.set";
    pub const description = "Choose the apps a type of user may sign in to";
    pub const details =
        \\Replaces the type's apps (`app.zon`'s `.name`, one or more, or none to let its
        \\people sign in nowhere). Counts from the next request: someone signed in to an app
        \\the type no longer opens is nobody there. Administrators only. Fails as not found
        \\for a type no plugin registers.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        user_type: []const u8,
        apps: []const []const u8 = &.{},
    };
    pub const Out = struct {
        user_type: []const u8,
        apps: []const []const u8,
    };
    pub const example: In = .{
        .user_type = "customer",
        .apps = &.{ "shop", "account" },
    };
    pub const example_out: Out = .{
        .user_type = "customer",
        .apps = &.{ "shop", "account" },
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .user_type = "The type's name: `customer`",
        .apps = "The apps its people may sign in to; none: nowhere",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .user_type = "The type changed",
        .apps = "The apps its people may sign in to now",
    };

    pub fn run(ctx: *Ctx, in: Set.In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (!model.valid_name(in.user_type) or model.apps_problem(in.apps) != null) {
            return error.Invalid;
        }

        if (try user_types.find(ctx, in.user_type) == null) {
            return error.NotFound;
        }

        const setting: model.Setting = .{
            .apps = in.apps,
        };
        const text = try sdk.stringify(ctx.arena, setting);
        const key = try user_types.setting_key(ctx.arena, in.user_type);

        try store.settings.set(ctx.db, key, text, ctx.now_ms);

        return .{
            .user_type = in.user_type,
            .apps = in.apps,
        };
    }
};
