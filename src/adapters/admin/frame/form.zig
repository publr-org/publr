//! A plugin's page by declaration: the admin draws the form itself, the fields of the
//! plugin's save operation filled from its read. No markup of the plugin's reaches the
//! page, so it is an admin page like any other, the same for an installed plugin.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const pages = @import("pages.zig");
const model = @import("../../../model/sandboxed_plugin.zig");
const manifest_module = @import("../../../sdk/plugin/manifest.zig");

const Session = admin.Session;
const Error = admin.Error;
const Item = admin.views.PluginFormPage.FieldsItem;

pub fn show(session: *Session, page: pages.Page) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(page.declared());

    const described = try described_of(session, page);
    const read = registry.SDK.call_json(&session.ctx, page.read, "{}") catch |err| {
        return admin.fail(session, err, "/admin/settings");
    };
    const values = std.json.parseFromSliceLeaky(std.json.Value, session.arena, read, .{}) catch {
        return admin.fail(session, error.Invalid, "/admin/settings");
    };
    const options: admin.chrome.Options = .{ .settings_path = session.request.path() };

    try admin.screen_with(session, options, .ok, admin.views.PluginFormPage, .{
        .title = page.label,
        .operation = page.save,
        .fields = try items_of(session.arena, described, values, page.multiline),
    });
}

/// The save operation's input as its plugin describes it: from the build for a compiled-in
/// plugin, from the manifest for an installed one.
fn described_of(session: *const Session, page: pages.Page) Error![]const model.Field {
    std.debug.assert(page.save.len > 0);

    inline for (registry.pages) |owned| {
        if (owned.page.form) |declared| {
            const same = std.mem.eql(u8, owned.plugin, page.plugin) and
                std.mem.eql(u8, owned.page.path, page.path);

            if (same) {
                return comptime manifest_module.fields_of(declared.save);
            }
        }
    }

    const sandboxed = session.ctx.sandboxed_plugins orelse return &.{};

    for (sandboxed.manifests()) |manifest| {
        if (!std.mem.eql(u8, manifest.name, page.plugin)) {
            continue;
        }

        for (manifest.operations) |operation| {
            if (std.mem.eql(u8, operation.name, page.save)) {
                return operation.fields;
            }
        }
    }

    return &.{};
}

fn items_of(
    arena: std.mem.Allocator,
    described: []const model.Field,
    values: std.json.Value,
    multiline: []const []const u8,
) Error![]const Item {
    std.debug.assert(described.len <= 256);

    var items: std.ArrayList(Item) = .empty;

    for (described) |field| {
        const kind = kind_of(field, multiline) orelse continue;

        try items.append(arena, .{
            .name = field.name,
            .label = try label_of(arena, field.name),
            .kind = kind,
            .required = field.required,
            .help = field.doc,
            .value = try text_of(arena, field, values),
        });
    }

    return items.items;
}

/// How a field is drawn; null for one a form does not draw (a list, an object).
fn kind_of(field: model.Field, multiline: []const []const u8) ?[]const u8 {
    std.debug.assert(field.name.len > 0);

    return switch (field.shape) {
        .boolean => "boolean",
        .integer, .number => "number",
        .string => for (multiline) |name| {
            if (std.mem.eql(u8, name, field.name)) {
                break "text";
            }
        } else "string",
        .strings, .json => null,
    };
}

/// `site_title` as `Site title`.
fn label_of(arena: std.mem.Allocator, name: []const u8) Error![]const u8 {
    std.debug.assert(name.len > 0);

    const label = try arena.dupe(u8, name);

    std.mem.replaceScalar(u8, label, '_', ' ');
    label[0] = std.ascii.toUpper(label[0]);

    return label;
}

/// What the read answered for `field`, as the form shows it; empty when it answered none.
fn text_of(arena: std.mem.Allocator, field: model.Field, values: std.json.Value) Error![]const u8 {
    std.debug.assert(field.name.len > 0);

    if (values != .object) {
        return "";
    }

    const present = values.object.get(field.name) orelse return "";

    return switch (present) {
        .string => |text| text,
        .bool => |flag| if (flag) "true" else "false",
        .integer => |number| try std.fmt.allocPrint(arena, "{d}", .{number}),
        .float => |number| try std.fmt.allocPrint(arena, "{d}", .{number}),
        else => "",
    };
}

test "a declared form's fields: kinds, labels and values from what the read answers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const described = [_]model.Field{
        .{ .name = "site_title", .shape = .string, .required = true },
        .{ .name = "description", .shape = .string, .required = false, .doc = "Under the title" },
        .{ .name = "visits", .shape = .integer, .required = false },
        .{ .name = "tags", .shape = .strings, .required = false },
    };
    const values = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"site_title":"Acme","description":"Anvils","visits":3}
    , .{});
    const items = try items_of(arena, &described, values, &.{"description"});

    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("Site title", items[0].label);
    try std.testing.expectEqualStrings("text", items[1].kind);
    try std.testing.expectEqualStrings("Under the title", items[1].help);
    try std.testing.expectEqualStrings("3", items[2].value);
}
