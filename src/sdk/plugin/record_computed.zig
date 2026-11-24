//! A record's computed fields: `.priced = .{ .kind = "virtual", .options = .{ .virtual =
//! .{ .computed = priced } } }` declares that core works `priced` out with the plugin's
//! `fn (*publr.Ctx, *const Doc) publr.Error!Field`, stores it with the record, and works it
//! out again when anything it read has changed. The function reaches core as a batch
//! modifier only its own plugin has, named `computed.<record>.<field>` (core applies that
//! name and no one else may), so it runs the same way compiled in and installed. What it
//! answers then goes through `<record>.<field>`, which any plugin may modify.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const hook_define = @import("hook_define.zig");
const PluginCtx = @import("context.zig").PluginCtx;

/// The first part of every name core works a computed field out under.
pub const prefix = "computed";

/// What core hands a computed field's own function and its modifiers: the record's id, the
/// record as stored, and the value. Modifiers of `<record>.<field>` take it as
/// `publr.Computed(Doc, Field)`.
pub fn Computed(comptime Doc: type, comptime Field: type) type {
    return struct {
        id: []const u8,
        record: Doc,
        value: Field,
    };
}

/// What the owner's function is handed: the value is not there before it is worked out.
fn Computing(comptime Doc: type, comptime Field: type) type {
    return struct {
        id: []const u8,
        record: Doc,
        value: ?Field = null,
    };
}

/// The names of `Definition`'s computed fields, in the record's order.
pub fn names_of(comptime Definition: type) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};

        std.debug.assert(Definition.type_name.len > 0);

        for (std.meta.fieldNames(Definition.Doc)) |name| {
            if (function_of(Definition, name) != null) {
                names = names ++ [_][]const u8{name};
            }
        }

        const done = names;

        return done;
    }
}

/// Whether the field `name` of `Definition` is computed.
pub fn is_computed(comptime Definition: type, comptime name: []const u8) bool {
    comptime {
        std.debug.assert(name.len > 0);

        return function_of(Definition, name) != null;
    }
}

/// The function `.fields.<name>.options.virtual.computed` names, or null.
fn function_of(comptime Definition: type, comptime name: []const u8) ?type {
    comptime {
        const given = Definition.given;

        std.debug.assert(name.len > 0);

        if (!@hasField(@TypeOf(given), "fields") or !@hasField(@TypeOf(given.fields), name)) {
            return null;
        }

        const overrides = @field(given.fields, name);

        if (!@hasField(@TypeOf(overrides), "options")) {
            return null;
        }

        const options = overrides.options;

        if (!@hasField(@TypeOf(options), "virtual")) {
            return null;
        }

        if (@typeInfo(@TypeOf(options.virtual)) != .@"struct") {
            return null;
        }

        if (!@hasField(@TypeOf(options.virtual), "computed")) {
            @compileError("record " ++ Definition.type_name ++ ": field `" ++ name ++
                "`: `.virtual = .{ .computed = fn }` names the function that works it out");
        }

        const kind_virtual = @hasField(@TypeOf(overrides), "kind") and
            std.mem.eql(u8, overrides.kind, "virtual");

        if (!kind_virtual) {
            @compileError("record " ++ Definition.type_name ++ ": computed field `" ++ name ++
                "` is `.kind = \"virtual\"`");
        }

        if (!Definition.is_internal) {
            @compileError("record " ++ Definition.type_name ++ ": computed fields are on " ++
                "internal records (`.internal = true`) so far");
        }

        return Function(Definition, name, options.virtual.computed);
    }
}

fn Function(
    comptime Definition: type,
    comptime name: []const u8,
    comptime compute: anytype,
) type {
    const Field = @FieldType(Definition.Doc, name);
    const Plain = fn (*PluginCtx, *const Definition.Doc) sdk.Error!Field;
    // The record's id beside it, for a value that names it to others (a line's parts).
    const Named = fn (*PluginCtx, []const u8, *const Definition.Doc) sdk.Error!Field;
    const named = @TypeOf(compute) == Named;

    if (@TypeOf(compute) != Plain and !named) {
        @compileError("record " ++ Definition.type_name ++ ": `" ++ name ++ "` is worked " ++
            "out by `fn (ctx: *publr.Ctx, record: *const " ++ @typeName(Definition.Doc) ++
            ") publr.Error!" ++ @typeName(Field) ++ "`, or with `id: []const u8` before " ++
            "the record");
    }

    return struct {
        pub const Value = Computing(Definition.Doc, Field);

        /// Every value of the batch worked out; one that fails refuses them all.
        pub fn run(ctx: *PluginCtx, values: []Value) sdk.Error!void {
            std.debug.assert(values.len <= sdk.mods.items_max);
            std.debug.assert(name.len > 0);

            for (values) |*value| {
                value.value = if (named)
                    try compute(ctx, value.id, &value.record)
                else
                    try compute(ctx, &value.record);
            }
        }
    };
}

/// The name core works `field` of `record` out under: `computed.orders.line.priced`.
pub fn compute_name(comptime record: []const u8, comptime field: []const u8) []const u8 {
    comptime {
        std.debug.assert(record.len > 0);
        std.debug.assert(field.len > 0);

        return prefix ++ "." ++ record ++ "." ++ field;
    }
}

/// The hooks a record's computed fields bring: one batch modifier each, its plugin's own.
pub fn hooks_of(comptime Definition: type, comptime plugin: []const u8) []const type {
    comptime {
        var hooks: []const type = &.{};

        std.debug.assert(plugin.len > 0);

        for (names_of(Definition)) |name| {
            const Worked = function_of(Definition, name).?;
            const Hook = hook_define.owned_modify_all(
                compute_name(Definition.type_name, name),
                Worked.Value,
                Worked.run,
            );
            const reason = "Works out " ++ name ++ " of each " ++ Definition.type_name;

            hooks = hooks ++ [_]type{hook_define.Described(Hook, plugin, reason)};
        }

        const done = hooks;

        return done;
    }
}

/// Whether `name` is one core alone applies: a computed field worked out.
pub fn reserved(name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(prefix.len > 0);

    const first = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];

    return std.mem.eql(u8, first, prefix);
}

test "a computed field's name is core's alone" {
    try std.testing.expect(reserved("computed.orders.line.priced"));
    try std.testing.expect(reserved("computed"));
    try std.testing.expect(!reserved("orders.line.priced"));
    try std.testing.expect(!reserved("computedx.line"));
    try std.testing.expectEqualStrings(
        "computed.orders.line.priced",
        comptime compute_name("orders.line", "priced"),
    );
}
