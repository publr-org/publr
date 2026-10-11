//! The manifest of an installed plugin, as it travels in the module's `publr` custom section:
//! generated at build time from the plugin's declarations, read by the host before anything
//! runs. One shape for both, so they cannot drift.
const std = @import("std");
const runtime = @import("sandboxed.zig");
const sdk_operation = @import("../operation.zig");
const sandboxed_plugin = @import("../../model/sandboxed_plugin.zig");
const help = @import("../help.zig");
const shapes = @import("../../model/contract.zig");

/// The name of the custom section the manifest travels in.
pub const section_name = "publr";
pub const format = sandboxed_plugin.format;
pub const bytes_max: u32 = 1 << 20;

pub const Manifest = sandboxed_plugin.Manifest;
pub const Operation = sandboxed_plugin.Operation;
pub const Field = sandboxed_plugin.Field;
pub const Hook = sandboxed_plugin.Hook;
pub const RemoteUse = sandboxed_plugin.RemoteUse;

pub fn of(comptime Plugin: type) Manifest {
    comptime {
        @setEvalBranchQuota(200_000);

        const contract = @import("../plugin.zig");

        runtime.assert_sandboxable(Plugin);

        return .{
            .name = Plugin.manifest.name,
            .version = Plugin.manifest.version,
            .summary = Plugin.manifest.summary,
            .namespaces = namespaces_of(Plugin),
            .operations = operations_of(Plugin),
            .hooks = hooks_of(Plugin),
            .permissions = runtime.permissions_of(Plugin),
            .allowed_domains = runtime.strings_of(Plugin, "allowed_domains"),
            .depends_on = @import("depends_on.zig").of(Plugin),
            .limits = if (@hasDecl(Plugin, "limits")) Plugin.limits else .{},
            .content_access = if (@hasDecl(Plugin, "content_access"))
                Plugin.content_access
            else
                .{},
            .content_types = contract.content_types_of(Plugin),
            .custom_fields = contract.custom_fields_of(Plugin),
            .roles = contract.roles_of(Plugin),
            .internal_records = contract.internal_records_of(Plugin),
            .remotes = remotes_of(Plugin),
            .compatible_with = contract.compatible_with_of(Plugin),
            .pages = pages_of(Plugin),
            .sections = sections_of(Plugin),
            .panels = panels_of(Plugin),
            .top_bar = items_of(Plugin, "top_bar"),
            .row_actions = row_actions_of(Plugin),
            .uninstall = uninstall_of(Plugin),
            .about = if (@hasDecl(Plugin, "about")) Plugin.about else "",
            .left_out = runtime.left_out(Plugin),
        };
    }
}

fn operations_of(comptime Plugin: type) []const Operation {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        var list: []const Operation = &.{};

        for (runtime.runtime_entries(Plugin)) |entry| {
            if (entry.stage != .operation) {
                continue;
            }

            const Declared = entry.declaration;

            list = list ++ &[_]Operation{.{
                .name = Declared.name,
                .kind = if (Declared.kind == .read) .read else .write,
                .description = Declared.description,
                .details = if (@hasDecl(Declared, "details")) Declared.details else "",
                .open = @hasDecl(Declared, "open") and Declared.open,
                .fields = fields_of(Declared),
                .input = sdk_operation.input_shape(Declared),
                .output = shapes.describe(Declared.Out),
                .secret = @import("../trail.zig").secret_of(Declared),
            }};
        }

        return list;
    }
}

/// The plugin's pages whose operation runs in the sandbox; one that takes the host's
/// context is left out with its operation.
fn pages_of(comptime Plugin: type) []const sandboxed_plugin.Page {
    comptime {
        const declared = @import("admin_slots.zig").pages_of(Plugin);
        var list: []const sandboxed_plugin.Page = &.{};

        std.debug.assert(declared.len <= @import("admin_slots.zig").pages_max);

        for (declared) |page| {
            const takes = @import("context.zig").takes_plugin_ctx;

            if (page.form) |form| {
                if (!takes(form.read.run) or !takes(form.save.run)) {
                    continue;
                }

                list = list ++ &[_]sandboxed_plugin.Page{.{
                    .path = page.path,
                    .label = page.label,
                    .icon = page.icon,
                    .read = form.read.name,
                    .save = form.save.name,
                    .multiline = form.multiline,
                }};
            } else if (takes(page.operation.?.run)) {
                list = list ++ &[_]sandboxed_plugin.Page{.{
                    .path = page.path,
                    .label = page.label,
                    .icon = page.icon,
                    .operation = page.operation.?.name,
                }};
            }
        }

        return list;
    }
}

/// The plugin's entries in `list` whose operations run in the sandbox.
fn items_of(comptime Plugin: type, comptime list: []const u8) []const sandboxed_plugin.Item {
    comptime {
        const declared = @import("admin_slots.zig").items_of(Plugin, list);
        const takes = @import("context.zig").takes_plugin_ctx;
        var items: []const sandboxed_plugin.Item = &.{};

        std.debug.assert(declared.len <= @import("admin_slots.zig").items_max);

        for (declared) |item| {
            const counted = if (item.count) |Count| takes(Count.run) else true;

            if (!takes(item.operation.run) or !counted) {
                continue;
            }

            items = items ++ &[_]sandboxed_plugin.Item{.{
                .label = item.label,
                .icon = item.icon,
                .page = item.page,
                .href = item.href,
                .operation = item.operation.name,
                .count = if (item.count) |Count| Count.name else "",
            }};
        }

        return items;
    }
}

fn panels_of(comptime Plugin: type) []const sandboxed_plugin.Panel {
    comptime {
        var panels: []const sandboxed_plugin.Panel = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        for (@import("admin_slots.zig").panels_of(Plugin)) |panel| {
            panels = panels ++ &[_]sandboxed_plugin.Panel{.{
                .type = panel.type,
                .label = panel.label,
                .operation = panel.operation.name,
            }};
        }

        return panels;
    }
}

fn sections_of(comptime Plugin: type) []const sandboxed_plugin.Section {
    comptime {
        var sections: []const sandboxed_plugin.Section = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        for (@import("admin_slots.zig").sections_of(Plugin)) |section| {
            var listed: []const sandboxed_plugin.SectionType = &.{};

            for (section.types) |one| {
                listed = listed ++ &[_]sandboxed_plugin.SectionType{.{
                    .handle = one.handle,
                    .columns = one.columns,
                }};
            }

            sections = sections ++ &[_]sandboxed_plugin.Section{.{
                .label = section.label,
                .icon = section.icon,
                .types = listed,
            }};
        }

        return sections;
    }
}

fn row_actions_of(comptime Plugin: type) []const sandboxed_plugin.RowAction {
    comptime {
        var actions: []const sandboxed_plugin.RowAction = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        for (@import("admin_slots.zig").row_actions_of(Plugin)) |action| {
            actions = actions ++ &[_]sandboxed_plugin.RowAction{.{
                .slot = action.slot,
                .label = action.label,
                .path = action.path,
                .kind = action.kind,
                .operation = action.operation.name,
            }};
        }

        return actions;
    }
}

fn remotes_of(comptime Plugin: type) []const RemoteUse {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        var list: []const RemoteUse = &.{};

        for (@import("../plugin.zig").remotes_of(Plugin)) |Used| {
            list = list ++ &[_]RemoteUse{.{
                .operation = Used.name,
                .input = shapes.describe(Used.In),
                .output = shapes.describe(Used.Out),
            }};
        }

        return list;
    }
}

fn hooks_of(comptime Plugin: type) []const Hook {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        var list: []const Hook = &.{};

        for (runtime.runtime_entries(Plugin)) |entry| {
            const Declared = entry.declaration;
            const stage: Hook.Stage = switch (entry.stage) {
                .operation => continue,
                .before => .before,
                .after => .after,
                .event => .event,
                .display => .display,
            };
            const target = switch (stage) {
                .event => Declared.event,
                .display => @import("../display.zig").target_of(Declared),
                .before, .after => Declared.operation,
            };

            list = list ++ &[_]Hook{.{
                .stage = stage,
                .target = target,
                .reason = Declared.reason,
            }};
        }

        return list;
    }
}

fn namespaces_of(comptime Plugin: type) []const sandboxed_plugin.Namespace {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        var list: []const sandboxed_plugin.Namespace = &.{};

        for (@import("../plugin.zig").namespaces_of(Plugin)) |namespace| {
            list = list ++ &[_]sandboxed_plugin.Namespace{.{
                .name = namespace.name,
                .summary = namespace.summary,
                .details = namespace.details,
            }};
        }

        return list;
    }
}

pub fn fields_of(comptime Declared: type) []const Field {
    comptime {
        std.debug.assert(Declared.name.len > 0);

        var list: []const Field = &.{};

        for (@typeInfo(Declared.In).@"struct".fields) |field| {
            list = list ++ &[_]Field{.{
                .name = field.name,
                .shape = shape_of(field.type),
                .required = field.defaultValue() == null,
                .doc = sdk_operation.field_doc(Declared, "field_docs", field.name),
                .label = help.type_label(field.type),
                .values = values_of(field.type),
            }};
        }

        return list;
    }
}

fn shape_of(comptime Type: type) Field.Shape {
    comptime {
        std.debug.assert(@typeInfo(Type) != .@"fn");

        return switch (@typeInfo(Type)) {
            .optional => |optional| shape_of(optional.child),
            .bool => .boolean,
            .int => .integer,
            .float => .number,
            .@"enum" => .string,
            .pointer => |pointer| if (pointer.child == u8)
                .string
            else if (help.listable(pointer.child) or is_reference(pointer.child))
                .strings
            else
                .json,
            .@"struct" => if (is_reference(Type)) .string else .json,
            else => .json,
        };
    }
}

fn is_reference(comptime Type: type) bool {
    comptime {
        return @typeInfo(Type) == .@"struct" and @hasDecl(Type, "reference");
    }
}

/// The names a value may take: an enum's, or a list of them's; none for anything else.
fn values_of(comptime Type: type) []const []const u8 {
    comptime {
        std.debug.assert(@typeInfo(Type) != .@"fn");

        const Named = switch (@typeInfo(Type)) {
            .optional => |optional| optional.child,
            .pointer => |pointer| if (pointer.child == u8) return &.{} else pointer.child,
            else => Type,
        };

        if (@typeInfo(Named) != .@"enum") {
            return &.{};
        }

        var names: []const []const u8 = &.{};

        for (std.meta.fieldNames(Named)) |name| {
            names = names ++ &[_][]const u8{name};
        }

        return names;
    }
}

/// Writes the manifest as JSON: what the build puts in the module's custom section, each
/// operation's `--help` rendered into it.
pub fn write(
    comptime Plugin: type,
    arena: std.mem.Allocator,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const manifest = comptime of(Plugin);
    const declared = comptime operation_types(Plugin);
    var operations: [declared.len]Operation = manifest.operations[0..declared.len].*;

    comptime std.debug.assert(manifest.operations.len == declared.len);
    std.debug.assert(manifest.format == format);

    inline for (declared, &operations) |Declared, *described| {
        var text: std.Io.Writer.Allocating = .init(arena);

        help.command(Declared, &text.writer) catch return error.WriteFailed;
        described.help = text.written();
    }

    var complete = manifest;

    complete.operations = &operations;

    try std.json.Stringify.value(complete, .{
        .emit_null_optional_fields = false,
    }, writer);
}

/// The operations' declarations, in the manifest's order.
fn operation_types(comptime Plugin: type) []const type {
    comptime {
        var list: []const type = &.{};

        for (runtime.runtime_entries(Plugin)) |entry| {
            if (entry.stage == .operation) {
                list = list ++ &[_]type{entry.declaration};
            }
        }

        std.debug.assert(list.len <= runtime.runtime_entries(Plugin).len);

        return list;
    }
}

test "the test plugin's manifest names its operation, fields and content type" {
    const Greeter = @import("../plugin.zig").testing.Greeter;
    const manifest = comptime of(Greeter);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write(Greeter, arena_state.allocator(), &writer);

    const text = writer.buffered();

    try std.testing.expectEqualStrings("greeter", manifest.name);
    try std.testing.expectEqual(@as(usize, 1), manifest.hooks.len);
    try std.testing.expectEqualStrings("greeter.greet", manifest.hooks[0].target);
    try std.testing.expectEqual(@as(usize, 1), manifest.operations.len);
    try std.testing.expectEqual(Field.Shape.string, manifest.operations[0].fields[0].shape);
    try std.testing.expect(manifest.operations[0].fields[0].required);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"content.write\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"greeting\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Usage: publr greeter") != null);
}

/// The write a plugin runs when it is removed with some of its data: one of its own, taking
/// `remove`, the keys of the pieces going (`type:<handle>`, `internal:<collection>`,
/// `fields:<group>`), to clear what core does not know is its.
pub fn uninstall_of(comptime Plugin: type) []const u8 {
    comptime {
        const contract = @import("../plugin.zig");
        const name = Plugin.manifest.name;

        if (!@hasDecl(Plugin, "uninstall")) {
            return "";
        }

        const Uninstall = Plugin.uninstall;

        if (!contract.owns_operation(Plugin, Uninstall) or Uninstall.kind != .write) {
            @compileError("plugin " ++ name ++ ": `uninstall` is one of its own writes");
        }

        if (!@hasField(Uninstall.In, "remove")) {
            @compileError("plugin " ++ name ++ ": `uninstall` takes `remove`, the keys of " ++
                "the pieces of its data going");
        }

        return Uninstall.name;
    }
}
