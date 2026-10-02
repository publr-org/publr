//! The manifest of an installed plugin, as it travels in the module's `publr` custom section:
//! generated at build time from the plugin's declarations, read by the host before anything
//! runs. One shape for both, so they cannot drift.
const std = @import("std");
const runtime = @import("sandboxed.zig");
const sdk_operation = @import("../operation.zig");
const sandboxed_plugin = @import("../../model/sandboxed_plugin.zig");
const help = @import("../help.zig");

/// The name of the custom section the manifest travels in.
pub const section_name = "publr";
pub const format = sandboxed_plugin.format;
pub const bytes_max: u32 = 1 << 20;

pub const Manifest = sandboxed_plugin.Manifest;
pub const Operation = sandboxed_plugin.Operation;
pub const Field = sandboxed_plugin.Field;
pub const Hook = sandboxed_plugin.Hook;

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
            };
            const target = if (stage == .event) Declared.event else Declared.operation;

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

fn fields_of(comptime Declared: type) []const Field {
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
            else if (help.listable(pointer.child))
                .strings
            else
                .json,
            else => .json,
        };
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

    try std.json.Stringify.value(complete, .{ .emit_null_optional_fields = false }, writer);
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
