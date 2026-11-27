//! A user's custom fields: every custom field group that applies to the account is one
//! namespaced group of one document (`<group handle>.<field>`), read from and written to
//! `user_values` through the record machinery.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/user/fields.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");
const custom_fields = @import("../custom_fields.zig");
const document_module = @import("../document/document.zig");
const user_operations = @import("../user.zig");
const members = @import("members.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Def = model.field.Def;
const Value = std.json.Value;
const Problem = model.field.Problem;

pub const document_bytes_max: u32 = 64 << 10;

/// The fields of an account holding these roles: one group per custom field group that
/// applies to it (by any of its roles, or a rule naming the account, `user_id` when it has
/// one), named by its handle, labelled by its name, in the order the groups list.
pub fn definition(ctx: *Ctx, user_id: []const u8, roles: []const []const u8) Error![]const Def {
    std.debug.assert(ctx.caller != .anonymous);
    std.debug.assert(model.field.fields_max > 0);

    const listed = try registry.SDK.dispatch(ctx, custom_fields.List, .{});
    var groups: std.ArrayList(Def) = .empty;

    for (listed.groups) |item| {
        if (groups.items.len == model.field.fields_max) {
            break;
        }

        const group = try registry.SDK.dispatch(ctx, custom_fields.Get, .{
            .group = item.handle,
        });
        const applies = try applies_to_any(ctx, group.definition.group, user_id, roles);

        if (!applies or group.definition.fields.len == 0) {
            continue;
        }

        try groups.append(ctx.arena, .{
            .name = group.definition.handle,
            .label = group.definition.name,
            .kind = "group",
            .fields = group.definition.fields,
        });
    }

    return groups.items;
}

fn applies_to_any(
    ctx: *Ctx,
    group: model.field_group.Options,
    user_id: []const u8,
    roles: []const []const u8,
) Error!bool {
    std.debug.assert(roles.len <= model.role.user_roles_max);
    std.debug.assert(model.role.user_roles_max > 0);

    const rules = try registry.all_location_rules(ctx);

    for (roles) |name| {
        const context: model.field_group.Context = .{
            .destination = .user,
            .role = name,
            .id = user_id,
            .reader = ctx,
            .rules = rules,
        };

        if (model.field_group.applies(group, context)) {
            return true;
        }
    }

    return false;
}

/// The account's document, assembled from its value rows.
pub fn read(ctx: *Ctx, user_id: []const u8, defs: []const Def) Error!Value {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(defs.len <= model.field.fields_max);

    const rows = try store.user_values.read(ctx.db, ctx.arena, user_id, store.user_values.live);

    return model.document.assemble(registry.kinds(ctx), ctx.arena, defs, rows) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Invalid,
        };
    };
}

pub const Checked = struct {
    document: ?Value,
    problems: []const Problem,
};

/// The document as text, parsed and validated against the fields; the problems when it
/// is refused.
pub fn check(ctx: *Ctx, defs: []const Def, text: []const u8) Error!Checked {
    std.debug.assert(defs.len <= model.field.fields_max);
    std.debug.assert(ctx.now_ms >= 0);

    var problems: model.field.Problems = .{
        .reader = ctx,
    };

    if (text.len > document_bytes_max) {
        problems.add("", "document is too large");

        return .{
            .document = null,
            .problems = try document_module.copy_problems(ctx, &problems),
        };
    }

    const parsed = @import("../../lib/json.zig").parse(Value, ctx.arena, text, .{}) catch {
        problems.add("", "document is not valid JSON");

        return .{
            .document = null,
            .problems = try document_module.copy_problems(ctx, &problems),
        };
    };

    model.validate.validate_document(registry.kinds(ctx), defs, parsed, ctx.now_ms, &problems);

    const copied = try document_module.copy_problems(ctx, &problems);

    return .{
        .document = if (problems.is_empty()) parsed else null,
        .problems = copied,
    };
}

/// Replace the account's document; `error.Invalid` when the fields refuse it.
pub fn write(ctx: *Ctx, user_id: []const u8, defs: []const Def, text: []const u8) Error!void {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    const checked = try check(ctx, defs, text);
    const document = checked.document orelse return error.Invalid;
    const live = store.user_values.live;

    try store.user_values.clear(ctx.db, user_id, live);
    try store.user_values.write(
        registry.kinds(ctx),
        ctx,
        ctx.db,
        user_id,
        live,
        store.user_values.type_id,
        defs,
        document,
    );
}

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

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.caller != .anonymous);
        std.debug.assert(in.user.len <= 64 << 10);

        const found = try user_operations.find_user(ctx, in.user) orelse return error.NotFound;

        // Through `users.own` alone, another type's account is as if it were not there.
        members.refuse_unread_account(ctx, found.user) catch return error.NotFound;

        // A caller who may not read the custom field groups (a plugin through `users.own`)
        // gets the account without them.
        const defs = definition(ctx, found.user.id, found.user.roles) catch |err| switch (err) {
            error.Denied => &.{},
            else => return err,
        };
        const document = try read(ctx, found.user.id, defs);
        const text = std.json.Stringify.valueAlloc(ctx.arena, document, .{}) catch {
            return error.OutOfMemory;
        };

        return .{
            .user = user_operations.summary_of(found.user),
            .fields = defs,
            .document = .{
                .text = text,
            },
        };
    }
};

pub const Validate = struct {
    pub const shape = public.Validate;
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

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.caller != .anonymous);
        std.debug.assert(in.document.text.len <= 64 << 10);

        const found = try user_operations.find_user(ctx, in.user) orelse return error.NotFound;
        const defs = try definition(ctx, found.user.id, found.user.roles);
        const checked = try check(ctx, defs, in.document.text);

        return .{
            .valid = checked.document != null,
            .problems = checked.problems,
        };
    }
};

const TestSDK = sdk.SDK(.{
    .operations = &(user_operations.operations ++ custom_fields.operations ++
        @import("../content_type.zig").operations),
});

fn seed_group(ctx: *Ctx, handle: []const u8, role: []const u8) Error!void {
    std.debug.assert(handle.len > 0);
    std.debug.assert(ctx.caller == .user);

    const role_rule = if (role.len > 0)
        try std.fmt.allocPrint(ctx.arena, ",{{\"field\":\"role\",\"value\":\"{s}\"}}", .{role})
    else
        "";
    const text = try std.fmt.allocPrint(
        ctx.arena,
        "{{\"handle\":\"{s}\",\"name\":\"Group {s}\",\"kind\":\"component\"," ++
            "\"title_field\":\"\",\"group\":{{\"location\":[{{\"rules\":" ++
            "[{{\"field\":\"destination\",\"value\":\"user\"}}{s}]}}]}}," ++
            "\"fields\":[{{\"name\":\"bio\",\"label\":\"Bio\",\"kind\":\"string\"," ++
            "\"validation\":{{\"required\":true}}}}]}}",
        .{ handle, handle, role_rule },
    );

    _ = try TestSDK.dispatch(ctx, custom_fields.Create, .{
        .group = handle,
        .definition = try model.content_type.read(ctx.arena, text),
    });
}

test "get: one namespaced group per applicable custom field group; update writes values" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try user_operations.seed_admin(&system);
    const admin_id = (try user_operations.find_user(&system, "admin@example.com")).?.user.id;
    var admin = harness.ctx(.{
        .user = .{
            .id = admin_id,
            .roles = &.{"admin"},
        },
    });
    try seed_group(&admin, "basic", "");
    try seed_group(&admin, "staff", "editor");
    const Create = user_operations.Create;
    const created = try TestSDK.dispatch(&admin, Create, Create.example);

    const editor = try TestSDK.dispatch(&admin, Get, .{
        .user = created.user_id,
    });
    try std.testing.expectEqual(@as(usize, 2), editor.fields.len);
    try std.testing.expectEqualStrings("basic", editor.fields[0].name);
    try std.testing.expectEqualStrings("Group staff", editor.fields[1].label);
    try std.testing.expectEqualStrings("{}", editor.document.text);
    const own = try TestSDK.dispatch(&admin, Get, .{
        .user = admin_id,
    });
    try std.testing.expectEqual(@as(usize, 1), own.fields.len);

    const empty: Validate.In = .{
        .user = created.user_id,
        .document = .{
            .text = "{}",
        },
    };
    try std.testing.expect((try TestSDK.dispatch(&admin, Validate, empty)).valid);
    const blank: Validate.In = .{
        .user = created.user_id,
        .document = .{
            .text = "{\"basic\":{}}",
        },
    };
    const missing = try TestSDK.dispatch(&admin, Validate, blank);
    try std.testing.expect(!missing.valid);
    try std.testing.expectEqualStrings("basic.bio", missing.problems[0].path);

    const filled = "{\"basic\":{\"bio\":\"Writes\"},\"staff\":{\"bio\":\"Edits\"}}";
    const update: user_operations.Update.In = .{
        .user = created.user_id,
        .display_name = "Writer",
        .roles = &.{"editor"},
        .document = .{
            .text = filled,
        },
    };
    _ = try TestSDK.dispatch(&admin, user_operations.Update, update);
    const after = try TestSDK.dispatch(&admin, Get, .{
        .user = created.user_id,
    });
    try std.testing.expect(std.mem.indexOf(u8, after.document.text, "\"bio\":\"Writes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after.document.text, "\"bio\":\"Edits\"") != null);

    var refused = update;
    refused.document = .{
        .text = "{\"basic\":{}}",
    };
    const refusal = TestSDK.dispatch(&admin, user_operations.Update, refused);
    try std.testing.expectError(error.Invalid, refusal);
    const kept = try TestSDK.dispatch(&admin, Get, .{
        .user = created.user_id,
    });
    try std.testing.expectEqualStrings(after.document.text, kept.document.text);

    var promoted = update;
    promoted.roles = &.{"admin"};
    promoted.document = .{
        .text = "{\"basic\":{\"bio\":\"Leads\"}}",
    };
    _ = try TestSDK.dispatch(&admin, user_operations.Update, promoted);
    const as_admin = try TestSDK.dispatch(&admin, Get, .{
        .user = created.user_id,
    });
    try std.testing.expectEqual(@as(usize, 1), as_admin.fields.len);
    try std.testing.expect(std.mem.indexOf(u8, as_admin.document.text, "staff") == null);
}
