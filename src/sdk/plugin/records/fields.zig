//! Each field of a plugin's record as core stores its definition: its kind from its Zig type,
//! its words from the doc comments, and the overrides `.fields` gives it.
const std = @import("std");
const field_model = @import("../../../model/field.zig");
const record_define = @import("../../../publr/plugin/record_define.zig");
const plugin_define = @import("../../../publr/plugin/define.zig");
const words = @import("../../../publr/plugin/words.zig");
const Overrides = @import("../../../publr/field_options.zig").Overrides;
const remote_fields = @import("../remote_fields.zig");

const label_of = record_define.label_of;
const overrides_named = record_define.overrides_named;

/// The plugin a record's name is under: `orders` of `orders.order`.
pub fn own_plugin(comptime name: []const u8) []const u8 {
    comptime {
        std.debug.assert(name.len > 0);

        return name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    }
}

/// The plugin's own field kind whose value `Inner` is (`sampler.weight` for a `Weight`), for a
/// group it places (`.register_fields`); null otherwise. Only a struct names its kind: a
/// plain value (text, a number) is a plain field.
fn own_kind_of(comptime Definition: type, comptime Inner: type) ?[]const u8 {
    comptime {
        if (!@hasDecl(Definition, "own_kinds")) {
            return null;
        }

        std.debug.assert(Definition.owner_plugin.len > 0);

        for (Definition.own_kinds) |Kind| {
            if (@typeInfo(Inner) == .@"struct" and Kind.Shape == Inner) {
                return Definition.owner_plugin ++ "." ++ Kind.verb;
            }
        }

        return null;
    }
}

pub fn field_of(
    comptime Definition: type,
    comptime Docs: type,
    comptime name: []const u8,
) field_model.Def {
    return field_in(Definition, Definition.Doc, Definition.given, Docs, name);
}

/// A field of `Owner` (the document, or a repeater's row) with `given`'s overrides; a list of
/// structs is a repeater, its row's fields declared the same way.
fn field_in(
    comptime Definition: type,
    comptime Owner: type,
    comptime given: anytype,
    comptime Docs: type,
    comptime name: []const u8,
) field_model.Def {
    comptime {
        const info = @typeInfo(Owner).@"struct";
        const index = std.meta.fieldIndex(Owner, name).?;
        const Field = info.field_types[index];
        const attrs = info.field_attrs[index];
        const key = @typeName(Owner) ++ "." ++ name;
        _ = plugin_define.words(Docs, key) orelse @compileError("record " ++
            Definition.type_name ++ ": field `" ++ name ++ "` needs a `///` comment");
        const optional = @typeInfo(Field) == .optional;
        const Inner = if (optional) @typeInfo(Field).optional.child else Field;
        const overrides = if (@hasField(@TypeOf(given), "fields") and
            @hasField(@TypeOf(given.fields), name))
            @field(given.fields, name)
        else
            .{};
        const own_kind = own_kind_of(Definition, Inner);
        const kind_given = @hasField(@TypeOf(overrides), "kind");
        const rows = is_rows(Inner);
        const group = !kind_given and own_kind == null and is_group(Inner);
        var def: field_model.Def = .{
            .name = name,
            .label = label_of(plugin_define.first(Docs, key).?),
            .help = plugin_define.rest(Docs, key).?,
            .kind = if (kind_given)
                overrides.kind
            else if (own_kind) |kind|
                kind
            else if (rows)
                "repeater"
            else if (group)
                "group"
            else
                kind_of(Definition.type_name, name, Inner),
            .validation = .{
                .required = !optional and attrs.defaultValue(Field) == null,
            },
            .locked = true,
            .many = is_list(Inner) and !rows,
            .default = default_of(Field, attrs),
        };

        def.options.number.decimals = places_of(Inner);

        if (rows or group) {
            const Row = if (rows) std.meta.Elem(Inner) else Inner;
            var sub: []const field_model.Def = &.{};

            overrides_named(Row, Definition.type_name, overrides);

            for (std.meta.fieldNames(Row)) |row_field_name| {
                const made = field_in(Definition, Row, overrides, Docs, row_field_name);

                sub = sub ++ [_]field_model.Def{made};
            }

            def.fields = sub;
        }

        if (kind_needs_targets(Inner)) {
            def.options.to = &.{target_of(Inner)};
        }

        if (@import("../../../publr/provider_ref.zig").is_provider_ref(Inner)) {
            def.options.provider = .{
                .contract = Inner.provider_contract,
            };
        }

        if (@typeInfo(Inner) == .@"enum") {
            def.options.choices = std.meta.fieldNames(Inner);
        }

        if (std.meta.fieldNames(@TypeOf(overrides)).len > 0) {
            apply(Definition.type_name, &def, overrides);
        }

        // Its plugin reads it whoever else may not: the one declaring the type.
        if (def.visibility.hidden()) {
            def.visibility.plugin = own_plugin(Definition.type_name);
        }

        const done = def;

        return done;
    }
}

pub fn apply(
    comptime record_name: []const u8,
    comptime def: *field_model.Def,
    comptime given: anytype,
) void {
    comptime {
        std.debug.assert(record_name.len > 0);

        const Given = @TypeOf(given);

        // Any other name given a value of an enum is a dimension's field option, offered by
        // the plugin owning the dimension (`.translatable = .required`). A repeater's
        // `fields` are its rows' overrides, taken where the rows are made.
        for (std.meta.fieldNames(Given)) |name| {
            if (@hasField(Overrides, name) or std.mem.eql(u8, name, "fields")) {
                continue;
            }

            if (@typeInfo(@TypeOf(@field(given, name))) != .enum_literal) {
                @compileError("record " ++ record_name ++ ": field `" ++ def.name ++
                    "` has no option `" ++ name ++ "`");
            }

            def.wrapped = def.wrapped ++ &[_]field_model.Wrapped{.{
                .option = name,
                .value = @tagName(@field(given, name)),
            }};
        }

        // A group sets what it names; the rest keeps what the struct field gave (a field
        // that may be left out stays not required unless `.validation` says otherwise).
        for (std.meta.fieldNames(Overrides), std.meta.fieldTypes(Overrides)) |name, Member| {
            if (!@hasField(Given, name)) {
                continue;
            }

            if (@typeInfo(Member) == .@"struct") {
                apply_group(record_name, def, name, @field(given, name));
            } else {
                const typed: Member = @field(given, name);

                @field(def, name) = typed;
            }
        }
    }
}

/// The parts of `group` (`options`, `validation`, `visibility`) that `values` names, each
/// read in the public shape and made into core's.
fn apply_group(
    comptime record_name: []const u8,
    comptime def: *field_model.Def,
    comptime group: []const u8,
    comptime values: anytype,
) void {
    comptime {
        const Public = @FieldType(Overrides, group);

        std.debug.assert(record_name.len > 0);
        std.debug.assert(@hasField(field_model.Def, group));

        for (std.meta.fieldNames(@TypeOf(values))) |part| {
            if (!@hasField(Public, part)) {
                @compileError("record " ++ record_name ++ ": field `" ++ def.name ++
                    "` has no option `." ++ group ++ "." ++ part ++ "`");
            }

            const Target = @TypeOf(@field(@field(def, group), part));
            const typed = coerced(@FieldType(Public, part), @field(values, part), 0);

            @field(@field(def, group), part) = field_model.given.converted(Target, typed, 0);
        }
    }
}

/// An anonymous struct literal turned into `Target`, field by field, at every level.
fn coerced(comptime Target: type, comptime value: anytype, comptime depth: u32) Target {
    comptime {
        std.debug.assert(depth < 8);

        const Given = @TypeOf(value);

        if (Given == Target or @typeInfo(Target) != .@"struct" or @typeInfo(Given) != .@"struct") {
            return value;
        }

        var result: Target = .{};

        for (std.meta.fieldNames(Given)) |name| {
            const Field = @TypeOf(@field(result, name));

            @field(result, name) = coerced(Field, @field(value, name), depth + 1);
        }

        const done = result;

        return done;
    }
}

/// The field kind a Zig type stores as: text, whole numbers, numbers, yes or no, a moment,
/// money, a choice, a reference, or a list of references.
pub fn kind_of(
    comptime record_name: []const u8,
    comptime name: []const u8,
    comptime Type: type,
) []const u8 {
    comptime {
        std.debug.assert(name.len > 0);

        if (is_list(Type) and is_reference(std.meta.Elem(Type))) {
            return "reference";
        }

        // A list of plain values: a field of their kind holding several (`[]const []const u8`
        // is a list of text).
        if (is_list(Type)) {
            if (remote_fields.kind_of(std.meta.Elem(Type))) |kind| {
                return kind;
            }
        }

        // A list of groups: rows of a repeater.
        if (is_rows(Type) and is_group(std.meta.Elem(Type))) {
            return "repeater";
        }

        return remote_fields.kind_of(Type) orelse @compileError("record " ++ record_name ++
            ": field `" ++ name ++ "` is " ++ @typeName(Type) ++ "; give it a kind: " ++
            "`.fields = .{ ." ++ name ++ " = .{ .kind = \"...\" } }`");
    }
}

/// The places a `publr.Decimal` field keeps (a list of them too); null for any other.
pub fn places_of(comptime Type: type) ?u32 {
    comptime {
        const Value = if (is_list(Type)) std.meta.Elem(Type) else Type;

        std.debug.assert(@typeInfo(Value) != .optional);

        if (@typeInfo(Value) != .@"struct" or !@hasDecl(Value, "decimal_places")) {
            return null;
        }

        return Value.decimal_places;
    }
}

const is_reference = remote_fields.is_reference;
const is_list = remote_fields.is_list;

/// A list of plain structs: rows of a repeater (a list of references is not).
pub fn is_rows(comptime Type: type) bool {
    return is_list(Type) and @typeInfo(std.meta.Elem(Type)) == .@"struct" and
        !is_reference(std.meta.Elem(Type));
}

/// A plain struct that is not a value of its own (a reference, a moment, money's JSON map):
/// a group of fields.
fn is_group(comptime Type: type) bool {
    return @typeInfo(Type) == .@"struct" and !is_reference(Type) and Type != words.Time and
        !@hasDecl(Type, "jsonParse");
}

/// A field's default as the form starts it, written as text: `Placed`, `true`, `20`, `pl`;
/// empty for none, or a default no form field takes (a list, a struct).
fn default_of(
    comptime Field: type,
    comptime attrs: std.builtin.Type.Struct.FieldAttributes,
) []const u8 {
    comptime {
        std.debug.assert(@typeInfo(Field) != .@"fn");

        const given = attrs.defaultValue(Field) orelse return "";
        const Value = @TypeOf(given);
        const value = if (@typeInfo(Value) == .optional) given orelse return "" else given;

        return switch (@typeInfo(@TypeOf(value))) {
            .bool => if (value) "true" else "false",
            .int, .comptime_int, .float, .comptime_float => std.fmt.comptimePrint("{d}", .{value}),
            .@"enum" => @tagName(value),
            .pointer => if (@TypeOf(value) == []const u8) value else "",
            else => "",
        };
    }
}

fn kind_needs_targets(comptime Type: type) bool {
    const Target = if (is_list(Type)) std.meta.Elem(Type) else Type;

    return is_reference(Target) and @hasDecl(Target, "handle");
}

fn target_of(comptime Type: type) []const u8 {
    return if (is_list(Type)) std.meta.Elem(Type).handle else Type.handle;
}
