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
            .webhooks = webhooks_of(Plugin),
            .location_rules = location_rules_of(Plugin),
            .field_kinds = field_kinds_of(Plugin),
            .permissions = runtime.permissions_of(Plugin),
            .secrets = @import("secret_define.zig").declared_of(Plugin),
            .depends_on = plugin_define.get(Plugin, "depends_on"),
            .limits = if (plugin_define.has(Plugin, "limits"))
                plugin_define.get(Plugin, "limits")
            else
                .{},
            .content_types = plugin_define.get(Plugin, "content_types"),
            .custom_fields = contract.custom_fields_of(Plugin),
            .roles = contract.roles_of(Plugin),
            .statuses = @import("record_flow.zig").registered_of(Plugin),
            .internal_records = plugin_define.get(Plugin, "internal_records"),
            .remotes = @import("remote_contract.zig").uses_of(Plugin),
            .events = @import("remote_contract.zig").events_of(Plugin),
            .compatible_with = plugin_define.get(Plugin, "compatible_with"),
            .providers = @import("../contract.zig").registered_of(Plugin),
            .pages = pages_of(Plugin),
            .menu = @import("menu_define.zig").entries_of(Plugin),
            .icons = @import("menu_define.zig").icons_of(Plugin),
            .panels = panels_of(Plugin),
            .columns = columns_of(Plugin),
            .row_actions = row_actions_of(Plugin),
            // The rest of `main.zig`'s `//!`, past its first line: shown on its page.
            .about = Plugin.settings_text,
            .left_out = runtime.left_out(Plugin),
        };
    }
}

/// Its field kinds made with `publr.field.kind`: the host runs their `validate` and `text`.
fn field_kinds_of(comptime Plugin: type) []const sandboxed_plugin.FieldKind {
    comptime {
        const field_kind_define = @import("field_kind_define.zig");
        var list: []const sandboxed_plugin.FieldKind = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        for (field_kind_define.definitions_of(Plugin)) |Definition| {
            list = list ++ &[_]sandboxed_plugin.FieldKind{
                field_kind_define.manifested(Definition, Plugin.docs),
            };
        }

        const done = list;

        return done;
    }
}

/// Its location rules, by name and label: the host runs their `values` and `matches`.
fn location_rules_of(comptime Plugin: type) []const sandboxed_plugin.LocationRule {
    comptime {
        var list: []const sandboxed_plugin.LocationRule = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        for (@import("location_rule_define.zig").given_of(Plugin)) |given| {
            list = list ++ &[_]sandboxed_plugin.LocationRule{.{
                .name = given.name,
                .label = given.label,
            }};
        }

        const done = list;

        return done;
    }
}

/// Its columns on lists it doesn't own, as the host draws them.
fn columns_of(comptime Plugin: type) []const sandboxed_plugin.Column {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        var list: []const sandboxed_plugin.Column = &.{};

        for (@import("column_define.zig").columns_of(Plugin)) |column| {
            list = list ++ &[_]sandboxed_plugin.Column{.{
                .list = column.list,
                .field = column.field,
                .label = column.label,
                .kind = column.kind,
                .stored = column.stored,
            }};
        }

        const done = list;

        return done;
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
                .details = Declared.details,
                .open = Declared.open,
                .public_api = Declared.public_api,
                .example = Declared.example_json,
                .example_out = Declared.example_out_json,
                .untrusted_callers = Declared.untrusted_callers,
                .answer = Declared.answer,
                .limit = if (Declared.limit) |limit| limit.per_minute else 0,
                .destructive = sdk_operation.destroys(Declared),
                .fields = fields_of(Declared, docs_of(Plugin)),
                .input = shapes.describe(Declared.In),
                .output = shapes.describe(Declared.Out),
                .secret = @import("../trail.zig").secret_of(Declared),
                .checked = Declared.checked,
                .who_may_call = Declared.who_may_call,
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
                const suggests = if (form.suggest) |Suggest| takes(Suggest.run) else true;
                const previews = if (form.preview) |Preview| takes(Preview.run) else true;

                if (!takes(form.read.run) or !takes(form.save.run) or !suggests or !previews) {
                    continue;
                }

                list = list ++ &[_]sandboxed_plugin.Page{.{
                    .path = page.path,
                    .label = page.label,
                    .icon = page.icon,
                    .read = form.read.name,
                    .save = form.save.name,
                    .only_one = form.only_one,
                    .blank_in_one = form.blank_in_one,
                    .suggest = if (form.suggest) |Suggest| Suggest.name else "",
                    .preview = if (form.preview) |Preview| Preview.name else "",
                    .hidden = page.menu != null,
                    .parent = page.parent,
                    .action_label = if (page.action) |action| action.label else "",
                    .action_href = if (page.action) |action| action.href else "",
                    .top_bar = top_bar_of(page),
                }};
            } else if (takes(page.operation.?.run)) {
                list = list ++ &[_]sandboxed_plugin.Page{.{
                    .path = page.path,
                    .label = page.label,
                    .icon = page.icon,
                    .operation = page.operation.?.name,
                    .hidden = page.menu != null,
                    .parent = page.parent,
                    .action_label = if (page.action) |action| action.label else "",
                    .action_href = if (page.action) |action| action.href else "",
                    .top_bar = top_bar_of(page),
                }};
            }
        }

        return list;
    }
}

/// A page's place in the top bar, its count named; none when its count takes the host's
/// context.
fn top_bar_of(comptime page: @import("admin_slots.zig").Page) ?sandboxed_plugin.TopBar {
    comptime {
        std.debug.assert(page.path.len > 0);

        const shown = page.top_bar orelse return null;
        const Count = shown.count orelse return .{};
        const takes = @import("context.zig").takes_plugin_ctx;

        return if (takes(Count.run)) .{
            .count = Count.name,
        } else null;
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
                .rule_values, .rule_matches, .kind_validate, .kind_text => continue,
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
                .due = Job.due_on,
            }};
        }

        return list;
    }
}

fn webhooks_of(comptime Plugin: type) []const sandboxed_plugin.Webhook {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        var list: []const sandboxed_plugin.Webhook = &.{};

        for (@import("../plugin.zig").webhooks_of(Plugin)) |Webhook| {
            list = list ++ &[_]sandboxed_plugin.Webhook{.{
                .name = Webhook.name,
                .secret = Webhook.secret,
                .signature = Webhook.signature,
                .body = Webhook.body,
                .delivery_id = Webhook.delivery_id,
            }};
        }

        return list;
    }
}

fn namespaces_of(comptime Plugin: type) []const sandboxed_plugin.Namespace {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        var list: []const sandboxed_plugin.Namespace = &.{};

        for (plugin_define.get(Plugin, "namespaces")) |namespace| {
            list = list ++ &[_]sandboxed_plugin.Namespace{.{
                .name = namespace.name,
                .summary = namespace.summary,
                .details = namespace.details,
            }};
        }

        return list;
    }
}

/// `Docs`: the plugin's words, where a value of a set finds its own (`///` on it).
pub fn fields_of(comptime Declared: type, comptime Docs: type) []const Field {
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
                .words = words_of(field.type, Docs),
                .fields = item_fields_of(field.type, Docs),
            }};
        }

        return list;
    }
}

/// A list of structs' item fields, when each is plain; none for anything else.
fn item_fields_of(comptime Type: type, comptime Docs: type) []const Field {
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
                .words = words_of(field.type, Docs),
                .default = default_text(field),
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

        const Named = enum_of(Type) orelse return &.{};
        var names: []const []const u8 = &.{};

        for (std.meta.fieldNames(Named)) |name| {
            names = names ++ &[_][]const u8{name};
        }

        return names;
    }
}

/// The plugin's words; none for one bound without them (a test's).
pub fn docs_of(comptime Plugin: type) type {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        return if (@hasDecl(Plugin, "docs")) Plugin.docs else plugin_define.Words(.{});
    }
}

/// A field's default as a form writes it (`{symbol}{amount}`, `period`, `true`); empty for
/// none or one of another shape.
fn default_text(comptime field: std.builtin.Type.StructField) []const u8 {
    comptime {
        std.debug.assert(field.name.len > 0);

        const value = field.defaultValue() orelse return "";

        return switch (@typeInfo(field.type)) {
            .bool => if (value) "true" else "false",
            .@"enum" => @tagName(value),
            .int, .float => std.fmt.comptimePrint("{d}", .{value}),
            .pointer => if (field.type == []const u8) value else "",
            else => "",
        };
    }
}

/// Each value's words, the first line of the `///` on it; none when no value has any.
fn words_of(comptime Type: type, comptime Docs: type) []const []const u8 {
    comptime {
        std.debug.assert(@typeInfo(Type) != .@"fn");

        const Named = enum_of(Type) orelse return &.{};
        var words: []const []const u8 = &.{};
        var any = false;

        for (std.meta.fieldNames(Named)) |name| {
            const said = Docs.first(@typeName(Named) ++ "." ++ name) orelse "";

            any = any or said.len > 0;
            words = words ++ &[_][]const u8{said};
        }

        return if (any) words else &.{};
    }
}

fn enum_of(comptime Type: type) ?type {
    comptime {
        std.debug.assert(@typeInfo(Type) != .@"fn");

        const Named = switch (@typeInfo(Type)) {
            .optional => |optional| optional.child,
            .pointer => |pointer| if (pointer.child == u8) return null else pointer.child,
            else => Type,
        };

        return if (@typeInfo(Named) == .@"enum") Named else null;
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
