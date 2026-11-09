//! Dimensions: what makes a field hold a value per combination (`name@language=pl`, see
//! `model/dimension.zig`). Plugins declare them (`.dimensions`, each made with
//! `publr.dimension.define`): the languages plugin a `language`, an A/B test a `variation`.
//! The owner says how others use it through its wrapper (`.api`): a field option, drawn on
//! the field panel by the owner's own view or as the core's cards, and a read option. The
//! core stores, reads and picks values, and knows nothing else about what a dimension is.
const std = @import("std");
const plugin_define = @import("define.zig");
const model_dimension = @import("../../model/dimension.zig");
const field_model = @import("../../model/field.zig");

/// What `publr.dimension.define` takes, and `.dimensions` lists.
pub const Dimension = struct {
    /// What it is called where values are stored and asked for: `language`.
    name: []const u8,
    /// Its key in an address's query, where the admin keeps what a page shows (`?lang=pl`);
    /// empty: its name.
    param: []const u8 = "",
    /// Higher keeps its value longer when a read falls back across dimensions.
    priority: i32 = 0,
    /// How others use it, in the owner's words: a file (`@import("api.zig")`) with a
    /// `field`, made with `field_option`, and maybe a `read`, made with `read_option`.
    api: type,
    /// A read of the plugin's own (`publr.operation.define`) taking nothing and answering
    /// `values`: every `Value` in the order people see them, the main one first. Or a family:
    /// answering `dimensions`, each a `Member` with values of its own (each A/B test), kept
    /// under `<name>-<member>`; a field holding the family holds each.
    list: type,
    /// A family's read taking `type` and `id` (a record) and answering `shown`: each field of
    /// it a member shows on (`Shown`). Without it, every field holding the family shows each.
    shown: ?type = null,
    /// Its values have pages of their own, under each one's `address` (`/pl`). At most one
    /// dimension on a site does; the others are chosen per request.
    addresses: bool = false,
};

pub const Holds = model_dimension.Holds;

const field_option_names = [_][]const u8{ "name", "takes", "holds", "default", "options" };

/// `publr.dimension.field_option(.{ .name, .takes, .holds, .default, .options })`: what a
/// field of any plugin says to hold values per the dimension (`.translatable = .required`).
/// `.takes` is an enum, each value's `///` its words; `.holds` maps each value to a `Holds`,
/// no two the same and one `.one`; `.default` the value of a field that says nothing (the
/// one holding `.one` when left out); `.options` a view drawing the setting on the field
/// panel, its `ctx.value` the value the field holds and `ctx.change(value)` handing another
/// to the form.
pub fn field_option(comptime options: anytype) type {
    comptime {
        const Options = @TypeOf(options);

        for (std.meta.fieldNames(Options)) |given| {
            if (!plugin_define.listed_in(&field_option_names, given)) {
                @compileError("field option: no option `" ++ given ++ "`");
            }
        }

        if (!@hasField(Options, "name") or !model_dimension.valid_name(options.name)) {
            @compileError("a field option needs `.name`: lowercase letters, digits and _, a " ++
                "letter first");
        }

        if (!@hasField(Options, "takes") or @typeInfo(options.takes) != .@"enum") {
            @compileError("field option `" ++ options.name ++ "` needs `.takes`, an enum");
        }

        if (!@hasField(Options, "holds")) {
            @compileError("field option `" ++ options.name ++ "` needs `.holds`, " ++
                "`fn (" ++ @typeName(options.takes) ++ ") publr.dimension.Holds`");
        }

        const Takes = options.takes;
        const values = std.meta.fieldNames(Takes);
        var seen: [4]bool = @splat(false);

        if (values.len > model_dimension.choices_max) {
            @compileError("field option `" ++ options.name ++ "`: at most 16 values");
        }

        for (values) |value| {
            const holds: Holds = options.holds(@field(Takes, value));

            if (seen[@intFromEnum(holds)]) {
                @compileError("field option `" ++ options.name ++ "`: two values hold `." ++
                    @tagName(holds) ++ "`; the field panel could not tell which a field has");
            }

            seen[@intFromEnum(holds)] = true;
        }

        if (!seen[@intFromEnum(Holds.one)]) {
            @compileError("field option `" ++ options.name ++ "`: one value holds `.one`, " ++
                "a field that does not vary");
        }

        const default: Holds = if (@hasField(Options, "default"))
            options.holds(@as(Takes, options.default))
        else
            .one;

        return struct {
            pub const publr_dimension_field_option = true;
            pub const name = options.name;
            pub const Value = Takes;
            pub const default_holds = default;
            pub const drawn = @hasField(Options, "options");
            pub const view = if (drawn) options.options else void;

            pub fn holds(value: Takes) Holds {
                return options.holds(value);
            }
        };
    }
}

/// `publr.dimension.read_option(.{ .name })`: what a read of any plugin names the dimension
/// by (`.language = "pl"`), its `///` the word on the editor's picker.
pub fn read_option(comptime options: anytype) type {
    comptime {
        const Options = @TypeOf(options);

        for (std.meta.fieldNames(Options)) |given| {
            if (!std.mem.eql(u8, given, "name")) {
                @compileError("read option: no option `" ++ given ++ "`");
            }
        }

        if (!@hasField(Options, "name") or !model_dimension.valid_name(options.name)) {
            @compileError("a read option needs `.name`: lowercase letters, digits and _, a " ++
                "letter first");
        }

        return struct {
            pub const publr_dimension_read_option = true;
            pub const name = options.name;
        };
    }
}

fn is_field_option(comptime Type: type) bool {
    return @typeInfo(Type) == .@"struct" and @hasDecl(Type, "publr_dimension_field_option");
}

fn is_read_option(comptime Type: type) bool {
    return @typeInfo(Type) == .@"struct" and @hasDecl(Type, "publr_dimension_read_option");
}

/// A compiled-in plugin's dimension: as data, and its wrapper, whose `.options` the core
/// draws on the field panel.
pub const Native = struct {
    setting: model_dimension.Declared,
    api: type,
};

/// One value of a dimension as the core shows and serves it.
pub const Value = struct {
    /// `pl`, `en-gb`: the code its values are stored under. The main value is stored under
    /// the plain name; its code still names it (`<html lang>`).
    code: []const u8,
    /// What people call it: `Polski`.
    label: []const u8,
    /// Where its pages are, under the site: `/pl`; empty for the main value, and for a
    /// dimension without pages of its own.
    address: []const u8 = "",
    main: bool = false,
};

pub const values_max: u32 = 64;

/// One dimension of a family, as its list answers it: `hero`, kept as `variation-hero`.
pub const Member = struct {
    /// Lowercase letters, digits and _, a letter first.
    name: []const u8,
    /// What people call it: `Hero headline`.
    label: []const u8,
    /// Its values, the main one first.
    values: []const Value,
};

/// A field of one record a family's member shows on, as `.shown` answers it.
pub const Shown = struct {
    /// The member: `hero`.
    member: []const u8,
    /// A top-level field of the record's type.
    field: []const u8,
};

/// `publr.dimension.define(.{ .name, .api, .list, ... })`: the dimension, its name and
/// wrapper checked.
pub fn define(comptime dimension: Dimension) Dimension {
    comptime {
        if (!model_dimension.valid_name(dimension.name)) {
            @compileError("dimension `" ++ dimension.name ++ "`: a name is lowercase letters, " ++
                "digits and _, a letter first");
        }

        if (dimension.param.len > 0 and !model_dimension.valid_name(dimension.param)) {
            @compileError("dimension `" ++ dimension.name ++ "`: `param` is lowercase letters, " ++
                "digits and _, a letter first");
        }

        const api = dimension.api;

        if (!@hasDecl(api, "field") or !is_field_option(api.field)) {
            @compileError("dimension `" ++ dimension.name ++ "`: its `.api` has `pub const " ++
                "field = publr.dimension.field_option(...)`");
        }

        if (@hasDecl(api, "read") and !is_read_option(api.read)) {
            @compileError("dimension `" ++ dimension.name ++ "`: its `.api`'s `read` is " ++
                "made with `publr.dimension.read_option`");
        }

        var checked = dimension;

        checked.param = if (dimension.param.len > 0) dimension.param else dimension.name;

        const done = checked;

        return done;
    }
}

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
            const checked = define(listed);
            const List = @import("operation_define.zig").Described(checked.list, name, Plugin.docs);
            const kind = if (@hasDecl(List, "given")) List.given.kind else List.kind;

            const answers = @hasField(List.Out, "values") or @hasField(List.Out, "dimensions");

            if (kind != .read or !answers) {
                @compileError("plugin " ++ name ++ ": dimension `" ++ checked.name ++
                    "`'s list is a read answering `values`, or `dimensions` for a family");
            }

            var one = checked;

            one.list = List;

            if (checked.shown) |given_shown| {
                const operation_define = @import("operation_define.zig");
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
    const Api = struct {
        pub const Translatable = enum { none, required, optional };

        fn holds(translatable: Translatable) Holds {
            std.debug.assert(@intFromEnum(translatable) < 3);

            return switch (translatable) {
                .none => .one,
                .required => .required,
                .optional => .fallback,
            };
        }

        pub const field = field_option(.{
            .name = "translatable",
            .takes = Translatable,
            .holds = holds,
        });

        pub const read = read_option(.{
            .name = "language",
        });
    };
    const List = struct {
        pub const name = "languages.list";
        pub const Out = struct {
            values: []const Value,
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
    const setting = comptime declared(define(.{
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
    try std.testing.expectEqual(Holds.required, model_dimension.holds_named(option, "required").?);
    try std.testing.expect(model_dimension.holds_named(option, "sometimes") == null);
    try std.testing.expectEqualStrings(
        "optional",
        model_dimension.choice_holding(option, .fallback).?.value,
    );
    try std.testing.expect(model_dimension.choice_holding(option, .empty) == null);
    try std.testing.expectEqualStrings("language", setting.read.name);
    try std.testing.expectEqualStrings("Content language", setting.read.label);
}
