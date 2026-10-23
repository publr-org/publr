//! The manifest of an installed plugin, as it travels in the module's `publr` custom section:
//! generated at build time from the plugin's declarations, read by the host before anything
//! runs. One shape for both, so they cannot drift.
const std = @import("std");
const plugin_define = @import("define.zig");
const runtime = @import("sandboxed.zig");
const sdk_operation = @import("../operation.zig");
const sandboxed_plugin = @import("../../model/sandboxed_plugin.zig");
const help = @import("../help.zig");
const shapes = @import("../../model/contract.zig");

/// The name of the custom section the manifest travels in.
pub const section_name = "publr";
pub const format = sandboxed_plugin.format;

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
            .jobs = jobs_of(Plugin),
            .permissions = runtime.permissions_of(Plugin),
            .secrets = @import("secret_define.zig").declared_of(Plugin),
            .depends_on = @import("depends_on.zig").of(Plugin),
            .limits = if (plugin_define.has(Plugin, "limits"))
                plugin_define.get(Plugin, "limits")
            else
                .{},
            .content_types = contract.content_types_of(Plugin),
            .custom_fields = contract.custom_fields_of(Plugin),
            .roles = contract.roles_of(Plugin),
            .statuses = @import("record_flow.zig").registered_of(Plugin),
            .internal_records = contract.internal_records_of(Plugin),
            .remotes = @import("remote_contract.zig").uses_of(Plugin),
            .events = @import("remote_contract.zig").events_of(Plugin),
            .compatible_with = contract.compatible_with_of(Plugin),
            .providers = @import("../contract.zig").registered_of(Plugin),
            .pages = pages_of(Plugin),
            .menu = @import("menu_define.zig").entries_of(Plugin),
            .icons = @import("menu_define.zig").icons_of(Plugin),
            .panels = panels_of(Plugin),
            .top_bar = items_of(Plugin),
            .row_actions = row_actions_of(Plugin),
            // The rest of `main.zig`'s `//!`, past its first line: shown on its page.
            .about = if (@hasDecl(Plugin, "settings_text")) Plugin.settings_text else "",
            .left_out = runtime.left_out(Plugin),
        };
    }
}

fn operations_of(comptime Plugin: type) []const Operation {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        var list: []const Operation = &.{};

        for (operation_types(Plugin)) |Declared| {
            list = list ++ &[_]Operation{.{
                .name = Declared.name,
                .kind = if (Declared.kind == .read) .read else .write,
                .description = Declared.description,
                .details = if (@hasDecl(Declared, "details")) Declared.details else "",
                .open = @hasDecl(Declared, "open") and Declared.open,
                .public_api = @hasDecl(Declared, "public_api") and Declared.public_api,
                .example = if (@hasDecl(Declared, "example_json")) Declared.example_json else "",
                .example_out = if (@hasDecl(Declared, "example_out_json"))
                    Declared.example_out_json
                else
                    "",
                .untrusted_callers = if (@hasDecl(Declared, "untrusted_callers"))
                    Declared.untrusted_callers
                else
                    null,
                .answer = if (@hasDecl(Declared, "answer")) Declared.answer else null,
                .limit = if (@hasDecl(Declared, "limit") and Declared.limit != null)
                    Declared.limit.?.per_minute
                else
                    0,
                .fields = fields_of(Declared),
                .input = shapes.describe(Declared.In),
                .output = shapes.describe(Declared.Out),
                .secret = @import("../trail.zig").secret_of(Declared),
                .checked = if (@hasDecl(Declared, "checked")) Declared.checked else "",
                .who_may_call = if (@hasDecl(Declared, "who_may_call"))
                    Declared.who_may_call
                else
                    "",
                .deprecated = sdk_operation.deprecation_text(Declared),
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

            if (page.tabs) {
                list = list ++ &[_]sandboxed_plugin.Page{.{
                    .path = page.path,
                    .label = page.label,
                    .icon = page.icon,
                    .hidden = page.menu != null,
                    .tabs = true,
                }};
            } else if (page.form) |form| {
                if (!takes(form.read.run) or !takes(form.save.run)) {
                    continue;
                }

                list = list ++ &[_]sandboxed_plugin.Page{.{
                    .path = page.path,
                    .label = page.label,
                    .icon = page.icon,
                    .read = form.read.name,
                    .save = form.save.name,
                    .hidden = page.menu != null,
                    .parent = page.parent,
                }};
            } else if (takes(page.operation.?.run)) {
                list = list ++ &[_]sandboxed_plugin.Page{.{
                    .path = page.path,
                    .label = page.label,
                    .icon = page.icon,
                    .operation = page.operation.?.name,
                    .hidden = page.menu != null,
                }};
            }
        }

        return list;
    }
}

/// The plugin's top bar entries whose operations run in the sandbox.
fn items_of(comptime Plugin: type) []const sandboxed_plugin.Item {
    comptime {
        const declared = @import("admin_slots.zig").items_of(Plugin);
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

fn hooks_of(comptime Plugin: type) []const Hook {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        var list: []const Hook = &.{};

        for (runtime.runtime_entries(Plugin)) |entry| {
            const Declared = entry.declaration;
            const stage: Hook.Stage = switch (entry.stage) {
                .operation, .job => continue,
                .before => .before,
                .after => .after,
                .event => .event,
                .modify => .modify,
            };
            const target = switch (stage) {
                .event => Declared.event,
                .modify => Declared.pattern,
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

fn jobs_of(comptime Plugin: type) []const sandboxed_plugin.Job {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        var list: []const sandboxed_plugin.Job = &.{};

        for (runtime.runtime_entries(Plugin)) |entry| {
            if (entry.stage != .job) {
                continue;
            }

            const Job = entry.declaration;
            const every = Job.every;

            list = list ++ &[_]sandboxed_plugin.Job{.{
                .name = Job.verb,
                .every = if (every) |given| @tagName(given) else "",
                .minutes = if (every) |given| switch (given) {
                    .minutes => |count| count,
                    else => 0,
                } else 0,
                .hour = Job.at.hour,
                .minute = Job.at.minute,
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
                .fields = item_fields_of(field.type),
            }};
        }

        return list;
    }
}

/// A list of structs' item fields, when each is plain; none for anything else.
fn item_fields_of(comptime Type: type) []const Field {
    comptime {
        std.debug.assert(@typeInfo(Type) != .@"fn");

        const info = @typeInfo(Type);

        if (info != .pointer or info.pointer.size != .slice) {
            return &.{};
        }

        const Item = info.pointer.child;

        if (@typeInfo(Item) != .@"struct" or is_reference(Item)) {
            return &.{};
        }

        var list: []const Field = &.{};

        for (@typeInfo(Item).@"struct".fields) |field| {
            const shape = shape_of(field.type);

            if (shape == .strings or shape == .json) {
                return &.{};
            }

            list = list ++ &[_]Field{.{
                .name = field.name,
                .shape = shape,
                .required = field.defaultValue() == null,
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

const is_reference = @import("remote_fields.zig").is_reference;

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

test "a plugin's manifest names its operation, fields, hook and record" {
    const sdk = @import("../../sdk.zig");
    const PluginCtx = @import("context.zig").PluginCtx;
    const hook_define = @import("hook_define.zig");
    const Greeting = struct {
        note: []const u8,
    };
    const In = struct {
        who: []const u8,
        times: u32 = 1,
    };
    const Out = struct {
        text: []const u8,
    };
    const Docs = plugin_define.Words(.{
        .{ "main", "Test plugin: greets, and keeps the greetings as records" },
        .{ "operation:greet", "Greet someone\n\nExample:\n  in: { \"who\": \"world\" }\n" ++
            "  out: { \"text\": \"hello, world\" }" },
        .{ @typeName(In) ++ ".who", "Whom to greet" },
        .{ @typeName(In) ++ ".times", "How many times" },
        .{ @typeName(Out) ++ ".text", "The greeting" },
        .{ @typeName(Greeting), "Greeting" },
        .{ @typeName(Greeting) ++ ".note", "Note" },
        .{ "hook:0", "Says when someone was greeted" },
    });
    const Greet = @import("operation_define.zig").define(In, Out, .{
        .name = "greet",
        .kind = .write,
        .deprecated = .{
            .since = "0.1.0",
        },
        .run = struct {
            fn run(_: *PluginCtx, in: In) sdk.Error!Out {
                return .{
                    .text = in.who,
                };
            }
        }.run,
    });
    const Module = struct {
        pub const plugin = plugin_define.define(.{
            .name = "greeter",
            .version = "0.1.0",
        }, .{
            .records = &.{@import("record_define.zig").define(Greeting, .{
                .name = "greeter.greeting",
            })},
            .permissions = &.{.{
                .key = "records.write",
                .reason = "Keeps every greeting as a record",
            }},
            .operations = &.{Greet},
            .hooks = &.{hook_define.after(Greet, struct {
                fn run(_: *PluginCtx, _: *In, _: *const Out) sdk.Error!void {}
            }.run)},
        });
    };
    const Greeter = plugin_define.Bind(Module, Docs);
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
    try std.testing.expect(std.mem.indexOf(u8, text, "\"records.write\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"greeter.greeting\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Usage: publr greeter") != null);
    // An installed plugin's callers are told it is on its way out, as a compiled-in one's.
    try std.testing.expectEqualStrings(
        "greeter.greet is deprecated since 0.1.0",
        manifest.operations[0].deprecated,
    );
}
