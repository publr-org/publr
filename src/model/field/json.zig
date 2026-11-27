//! How a field's definition is written as JSON, as Publr stores it and answers it at REST, the
//! CLI and MCP: its options, rules and readers sparsely (only what differs from the
//! defaults), and the field without `visibility` unless the field is hidden, since releases
//! before 0.8 refuse a definition holding a member they do not know.
const std = @import("std");

/// `value` as an object of what differs from `Struct`'s defaults, its groups the same way.
pub fn sparse(comptime Struct: type, value: Struct, writer: anytype) !void {
    comptime std.debug.assert(@typeInfo(Struct) == .@"struct");
    comptime std.debug.assert(std.meta.fieldNames(Struct).len > 0);

    const base: Struct = .{};

    try writer.beginObject();

    inline for (
        comptime std.meta.fieldNames(Struct),
        comptime std.meta.fieldTypes(Struct),
    ) |info_name, InfoType| {
        const field_value = @field(value, info_name);

        if (!std.meta.eql(field_value, @field(base, info_name))) {
            try writer.objectField(info_name);

            if (@typeInfo(InfoType) == .@"struct") {
                try sparse(InfoType, field_value, writer);
            } else {
                try writer.write(field_value);
            }
        }
    }

    try writer.endObject();
}

/// A field's definition: every member as std.json writes it, but `visibility` only when the
/// field is hidden.
pub fn definition(comptime Def: type, def: Def, writer: anytype) !void {
    var count: u32 = 0;

    try writer.beginObject();

    const info = @typeInfo(Def).@"struct";

    inline for (info.field_names, info.field_types) |name, Member| {
        const value = @field(def, name);
        const kept = if (comptime std.mem.eql(u8, name, "visibility"))
            def.visibility.restricted or def.visibility.special
        else if (comptime @typeInfo(Member) == .optional)
            value != null or writer.options.emit_null_optional_fields
        else
            true;

        if (kept) {
            try writer.objectField(name);
            try writer.write(value);
            count += 1;
        }
    }

    try writer.endObject();

    // Name, label and kind always.
    std.debug.assert(count >= 3);
}
