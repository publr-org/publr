//! A user's custom fields: every custom field group that applies to the account is one
//! namespaced group of one document (`<group handle>.<field>`), read from and written to
//! `user_values` through the record machinery.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const registry = @import("../../app/registry.zig");
const custom_fields = @import("../custom_fields.zig");
const document_module = @import("../document/document.zig");
const user_operations = @import("../user.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Role = sdk.caller.Role;
const Def = model.field.Def;
const Value = std.json.Value;
const Problem = model.field.Problem;

pub const document_bytes_max: u32 = 64 << 10;

/// The fields of an account with this role: one group per custom field group that
/// applies, named by its handle, labelled by its name, in the order the groups list.
pub fn definition(ctx: *Ctx, role: Role) Error![]const Def {
    std.debug.assert(ctx.caller != .anonymous);
    std.debug.assert(model.field.fields_max > 0);

    const listed = try registry.SDK.dispatch(ctx, custom_fields.List, .{});
    var groups: std.ArrayList(Def) = .empty;

    for (listed.groups) |item| {
        if (groups.items.len == model.field.fields_max) {
            break;
        }

        const got = try registry.SDK.dispatch(ctx, custom_fields.Get, .{ .group = item.handle });
        const applies = model.field_group.applies(got.definition.group, .{
            .destination = .user,
            .role = @tagName(role),
        });

        if (!applies or got.definition.fields.len == 0) {
            continue;
        }

        try groups.append(ctx.arena, .{
            .name = got.definition.handle,
            .label = got.definition.name,
            .kind = "group",
            .fields = got.definition.fields,
        });
    }

    return groups.items;
}

/// The account's document, assembled from its value rows.
pub fn read(ctx: *Ctx, user_id: []const u8, defs: []const Def) Error!Value {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(defs.len <= model.field.fields_max);

    const rows = try store.user_values.read(ctx.db, ctx.arena, user_id, store.user_values.live);

    return model.document.assemble(registry.Kinds.all, ctx.arena, defs, rows) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Invalid,
        };
    };
}

pub const Checked = struct { document: ?Value, problems: []const Problem };

/// The document as text, parsed and validated against the fields; the problems when it
/// is refused.
pub fn check(ctx: *Ctx, defs: []const Def, text: []const u8) Error!Checked {
    std.debug.assert(defs.len <= model.field.fields_max);
    std.debug.assert(ctx.now_ms >= 0);

    var problems: model.field.Problems = .{};

    if (text.len > document_bytes_max) {
        problems.add("", "document is too large");

        return .{ .document = null, .problems = try document_module.copy_problems(ctx, &problems) };
    }

    const parsed = @import("../../lib/json.zig").parse(Value, ctx.arena, text, .{}) catch {
        problems.add("", "document is not valid JSON");

        return .{ .document = null, .problems = try document_module.copy_problems(ctx, &problems) };
    };

    model.validate.validate_document(registry.Kinds.all, defs, parsed, ctx.now_ms, &problems);

    const copied = try document_module.copy_problems(ctx, &problems);

    return .{ .document = if (problems.is_empty()) parsed else null, .problems = copied };
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
        registry.Kinds.all,
        ctx.db,
        user_id,
        live,
        store.user_values.type_id,
        defs,
        document,
    );
}

pub const Get = struct {
    pub const name = "user.get";
    pub const description = "One account with its custom fields and their values";
    pub const details =
        \\Admins only. `fields` lists one group per custom field group that applies to the
        \\account (its destination is `user` and its role rules match); every field's path
        \\in `document` is `<group handle>.<field name>`.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { user: []const u8 };
    pub const Out = struct {
        user: user_operations.Summary,
        fields: []const Def,
        document: []const u8,
    };
    pub const example: In = .{ .user = "editor@example.com" };
    pub const example_out: Out = .{
        .user = .{
            .id = "9b1e7c3d5a2f4e6b8d0c1a3f",
            .email = "editor@example.com",
            .display_name = "Editor",
            .role = .editor,
            .created_at = 1789646400000,
            .active = true,
        },
        .fields = &.{},
        .document = "{}",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{ .user = "The user's id or email" };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .user = "The account",
        .fields = "The groups that apply, each with its fields",
        .document = "The values, as JSON, one object per group",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.caller != .anonymous);
        std.debug.assert(in.user.len <= 64 << 10);

        const found = try user_operations.find_user(ctx, in.user) orelse return error.NotFound;
        const defs = try definition(ctx, found.user.role);
        const document = try read(ctx, found.user.id, defs);
        const text = std.json.Stringify.valueAlloc(ctx.arena, document, .{}) catch {
            return error.OutOfMemory;
        };

        return .{
            .user = user_operations.summary_of(found.user),
            .fields = defs,
            .document = text,
        };
    }
};

pub const Validate = struct {
    pub const name = "user.validate";
    pub const description = "Check an account's custom field values without saving";
    pub const details = "Admins only. The same rules `user update --document` applies.";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { user: []const u8, document: []const u8 };
    pub const Out = struct { valid: bool, problems: []const Problem };
    pub const example: In = .{ .user = "editor@example.com", .document = "{}" };
    pub const example_out: Out = .{ .valid = true, .problems = &.{} };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .user = "The user's id or email",
        .document = "The values, as JSON, one object per group",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .valid = "Whether the document would be saved",
        .problems = "What was refused, by field path",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.caller != .anonymous);
        std.debug.assert(in.document.len <= 64 << 10);

        const found = try user_operations.find_user(ctx, in.user) orelse return error.NotFound;
        const defs = try definition(ctx, found.user.role);
        const checked = try check(ctx, defs, in.document);

        return .{ .valid = checked.document != null, .problems = checked.problems };
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
            "\"required\":true}}]}}",
        .{ handle, handle, role_rule },
    );

    _ = try TestSDK.dispatch(ctx, custom_fields.Create, .{ .group = handle, .definition = text });
}

test "get: one namespaced group per applicable custom field group; update writes values" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try user_operations.seed_admin(&system);
    const admin_id = (try user_operations.find_user(&system, "admin@example.com")).?.user.id;
    var admin = harness.ctx(.{ .user = .{ .id = admin_id, .role = .admin } });
    try seed_group(&admin, "basic", "");
    try seed_group(&admin, "staff", "editor");
    const Create = user_operations.Create;
    const created = try TestSDK.dispatch(&admin, Create, Create.example);

    const editor = try TestSDK.dispatch(&admin, Get, .{ .user = created.user_id });
    try std.testing.expectEqual(@as(usize, 2), editor.fields.len);
    try std.testing.expectEqualStrings("basic", editor.fields[0].name);
    try std.testing.expectEqualStrings("Group staff", editor.fields[1].label);
    try std.testing.expectEqualStrings("{}", editor.document);
    const own = try TestSDK.dispatch(&admin, Get, .{ .user = admin_id });
    try std.testing.expectEqual(@as(usize, 1), own.fields.len);

    const empty: Validate.In = .{ .user = created.user_id, .document = "{}" };
    try std.testing.expect((try TestSDK.dispatch(&admin, Validate, empty)).valid);
    const blank: Validate.In = .{ .user = created.user_id, .document = "{\"basic\":{}}" };
    const missing = try TestSDK.dispatch(&admin, Validate, blank);
    try std.testing.expect(!missing.valid);
    try std.testing.expectEqualStrings("basic.bio", missing.problems[0].path);

    const filled = "{\"basic\":{\"bio\":\"Writes\"},\"staff\":{\"bio\":\"Edits\"}}";
    const update: user_operations.Update.In = .{
        .user = created.user_id,
        .display_name = "Writer",
        .role = .editor,
        .document = filled,
    };
    _ = try TestSDK.dispatch(&admin, user_operations.Update, update);
    const after = try TestSDK.dispatch(&admin, Get, .{ .user = created.user_id });
    try std.testing.expect(std.mem.indexOf(u8, after.document, "\"bio\":\"Writes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after.document, "\"bio\":\"Edits\"") != null);

    var refused = update;
    refused.document = "{\"basic\":{}}";
    const refusal = TestSDK.dispatch(&admin, user_operations.Update, refused);
    try std.testing.expectError(error.Invalid, refusal);
    const kept = try TestSDK.dispatch(&admin, Get, .{ .user = created.user_id });
    try std.testing.expectEqualStrings(after.document, kept.document);

    var promoted = update;
    promoted.role = .admin;
    promoted.document = "{\"basic\":{\"bio\":\"Leads\"}}";
    _ = try TestSDK.dispatch(&admin, user_operations.Update, promoted);
    const as_admin = try TestSDK.dispatch(&admin, Get, .{ .user = created.user_id });
    try std.testing.expectEqual(@as(usize, 1), as_admin.fields.len);
    try std.testing.expect(std.mem.indexOf(u8, as_admin.document, "staff") == null);
}
