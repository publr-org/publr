//! Core's reading of the dimensions a plugin declares (`publr/plugin/dimensions.zig` is what
//! a plugin writes): each list resolved to the plugin's own operation, and each dimension as
//! data, its wrapper's words from the plugin's doc comments.
const std = @import("std");
const public = @import("../../publr/plugin/dimensions.zig");
const model_dimension = @import("../../publr/model/dimension.zig");
const operation_define = @import("../../publr/plugin/operation_define.zig");
const plugin_define = @import("bound.zig");

const Dimension = public.Dimension;
const Holds = public.Holds;

/// A compiled-in plugin's dimension: as data, and its wrapper, whose `.options` the core
/// draws on the field panel.
pub const Native = struct {
    setting: model_dimension.Declared,
    api: type,
};

/// `dimension` as data, its wrapper's words from the doc comments of `plugin`: the field
/// option's `///` its label, its enum's its help, each value's its choice (a first line,
/// then what it means), the read option's the picker's word.
pub fn declared(
    comptime dimension: Dimension,
    comptime Docs: type,
    comptime plugin: []const u8,
) model_dimension.Declared {
    comptime {
        const api = dimension.api;
        const Takes = api.field.Value;
        const where = "dimension `" ++ dimension.name ++ "`: ";
        const field_key = @typeName(api) ++ ".field";
        const label = plugin_define.first(Docs, field_key) orelse @compileError(where ++
            field_key ++ " needs a `///` comment: the setting's name on the field panel");
        const help = plugin_define.words(Docs, @typeName(Takes)) orelse @compileError(where ++
            @typeName(Takes) ++ " needs a `///` comment: what the setting means");
        var choices: []const model_dimension.Choice = &.{};

        for (std.meta.fieldNames(Takes)) |value| {
            const key = @typeName(Takes) ++ "." ++ value;
            const title = plugin_define.first(Docs, key) orelse @compileError(where ++ key ++
                " needs a `///` comment: what a field holding it does");

            choices = choices ++ &[_]model_dimension.Choice{.{
                .value = value,
                .holds = api.field.holds(@field(Takes, value)),
                .title = std.mem.trimEnd(u8, title, "."),
                .description = plugin_define.rest(Docs, key).?,
            }};
        }

        const read: model_dimension.ReadOption = if (@hasDecl(api, "read")) .{
            .name = api.read.name,
            .label = plugin_define.first(Docs, @typeName(api) ++ ".read") orelse
                @compileError(where ++ @typeName(api) ++ ".read needs a `///` comment: " ++
                    "the word on the editor's picker"),
        } else .{};

        return .{
            .name = dimension.name,
            .param = if (dimension.param.len > 0) dimension.param else dimension.name,
            .priority = dimension.priority,
            .addresses = dimension.addresses,
            .list = dimension.list.name,
            .each = @hasField(dimension.list.Out, "dimensions"),
            .shown = if (dimension.shown) |shown| shown.name else "",
            .default = api.field.default_holds,
            .plugin = plugin,
            .field = .{
                .name = api.field.name,
                .label = std.mem.trimEnd(u8, label, "."),
                .help = help,
                .choices = choices,
                .drawn = api.field.drawn,
            },
            .read = read,
        };
    }
}

/// The dimensions a plugin declares, each list resolved to the plugin's own operation.
pub fn of(comptime Plugin: type) []const Dimension {
    comptime {
        const name = Plugin.manifest.name;

        if (!plugin_define.has(Plugin, "dimensions")) {
            return &.{};
        }

        const given: []const Dimension = plugin_define.get(Plugin, "dimensions");
        var resolved: []const Dimension = &.{};

        if (given.len > model_dimension.dimensions_max) {
            @compileError("plugin " ++ name ++ ": at most 64 dimensions");
        }

        for (given) |listed| {
            const checked = public.define(listed);
            const List = operation_define.Described(checked.list, name, Plugin.docs);
            const kind = if (@hasDecl(List, "given")) List.given.kind else List.kind;

            const answers = @hasField(List.Out, "values") or @hasField(List.Out, "dimensions");

            if (kind != .read or !answers) {
                @compileError("plugin " ++ name ++ ": dimension `" ++ checked.name ++
                    "`'s list is a read answering `values`, or `dimensions` for a family");
            }

            var one = checked;

            one.list = List;

            if (checked.shown) |given_shown| {
                const Read = operation_define.Described(given_shown, name, Plugin.docs);
                const read_kind = if (@hasDecl(Read, "given")) Read.given.kind else Read.kind;

                if (read_kind != .read or !@hasField(Read.Out, "shown")) {
                    @compileError("plugin " ++ name ++ ": dimension `" ++ checked.name ++
                        "`'s `.shown` is a read answering `shown`");
                }

                if (!@hasField(List.Out, "dimensions")) {
                    @compileError("plugin " ++ name ++ ": dimension `" ++ checked.name ++
                        "`: only a family (its list answering `dimensions`) has `.shown`");
                }

                one.shown = Read;
            }
            resolved = resolved ++ &[_]Dimension{one};
        }

        const done = resolved;

        return done;
    }
}

/// The dimensions `Plugin` declares, as its manifest carries them.
pub fn declared_of(comptime Plugin: type) []const model_dimension.Declared {
    comptime {
        var out: []const model_dimension.Declared = &.{};

        std.debug.assert(of(Plugin).len <= model_dimension.dimensions_max);

        for (of(Plugin)) |dimension| {
            out = out ++ &[_]model_dimension.Declared{
                declared(dimension, Plugin.docs, Plugin.manifest.name),
            };
        }

        const done = out;

        return done;
    }
}

test "a wrapper as data: the setting, its help, each choice and the picker from its words" {
    const core_dimension = @import("../../model/dimension.zig");
    const Api = struct {
        pub const Translatable = enum { none, required, optional };

        fn holds(translatable: Translatable) Holds {
            std.debug.assert(@backingInt(translatable) < 3);

            return switch (translatable) {
                .none => .one,
                .required => .required,
                .optional => .fallback,
            };
        }

        pub const field = public.field_option(.{
            .name = "translatable",
            .takes = Translatable,
            .holds = holds,
        });

        pub const read = public.read_option(.{
            .name = "language",
        });
    };
    const List = struct {
        pub const name = "languages.list";
        pub const Out = struct {
            values: []const public.Value,
        };
    };
    const Taken = @typeName(Api.Translatable);
    const Docs = plugin_define.Words(.{
        .{ @typeName(Api) ++ ".field", "Translate" },
        .{ Taken, "Whether the field holds a value in each language." },
        .{ Taken ++ ".none", "No translations\nOne value in every language." },
        .{ Taken ++ ".required", "All required\nEach language filled." },
        .{ Taken ++ ".optional", "Optional." },
        .{ @typeName(Api) ++ ".read", "Content language" },
    });
    const setting = comptime declared(public.define(.{
        .name = "language",
        .param = "lang",
        .api = Api,
        .list = List,
    }), Docs, "languages");
    const option = setting.field;

    try std.testing.expectEqualStrings("languages", setting.plugin);
    try std.testing.expectEqualStrings("lang", setting.param);
    try std.testing.expectEqualStrings("translatable", option.name);
    try std.testing.expectEqualStrings("Translate", option.label);
    try std.testing.expect(!option.drawn);
    try std.testing.expectEqual(3, option.choices.len);
    try std.testing.expectEqualStrings("No translations", option.choices[0].title);
    try std.testing.expectEqualStrings(
        "One value in every language.",
        option.choices[0].description,
    );
    try std.testing.expectEqualStrings("Optional", option.choices[2].title);
    try std.testing.expectEqual(Holds.required, core_dimension.holds_named(option, "required").?);
    try std.testing.expect(core_dimension.holds_named(option, "sometimes") == null);
    try std.testing.expectEqualStrings(
        "optional",
        core_dimension.choice_holding(option, .fallback).?.value,
    );
    try std.testing.expect(core_dimension.choice_holding(option, .empty) == null);
    try std.testing.expectEqualStrings("language", setting.read.name);
    try std.testing.expectEqualStrings("Content language", setting.read.label);
}
