//! `publr.taxonomy.define(Term, .{ .name, .public, .hierarchical, .single, .internal, .fields })`:
//! a taxonomy a plugin declares, stored as `<plugin>.<name>`. Every term has a name and a
//! slug; `Term` holds its own fields beyond them, each labelled by its `///`, overridden by
//! field name as a record's are. The taxonomy's name and description are the `///` above it
//! or its file's `//!`. It never names types: a type lists it (`.taxonomies` on the record),
//! another plugin's type gets it by `.register_taxonomies`.
const std = @import("std");
const field_model = @import("../../model/field.zig");
const record_define = @import("record_define.zig");

const Option = enum {
    name,
    public,
    hierarchical,
    single,
    internal,
    fields,
};

/// The fields every term has; `Term` adds to them.
const own_fields = [_][]const u8{ "name", "slug" };

pub fn define(comptime Term: type, comptime options: anytype) type {
    comptime {
        const Options = @TypeOf(options);

        if (@typeInfo(Term) != .@"struct") {
            @compileError("`publr.taxonomy.define` takes the term's own fields as a struct " ++
                "first: `struct {}` for a name and a slug only");
        }

        for (std.meta.fieldNames(Options)) |given| {
            if (!@hasField(Option, given)) {
                @compileError("taxonomy: no option `." ++ given ++ "`");
            }
        }

        if (!@hasField(Options, "name") or !field_model.valid_name(options.name)) {
            @compileError("a taxonomy needs `.name`, its own part: `.name = \"topic\"`, " ++
                "stored under its plugin's name");
        }

        const public = @hasField(Options, "public") and options.public;
        const internal = @hasField(Options, "internal") and options.internal;

        if (public and internal) {
            @compileError("taxonomy " ++ options.name ++ ": an internal taxonomy never " ++
                "reaches the site, so it is not public");
        }

        for (own_fields) |taken| {
            if (@hasField(Term, taken)) {
                @compileError("taxonomy " ++ options.name ++ ": every term has `" ++ taken ++
                    "` already; `" ++ @typeName(Term) ++ "` holds the fields beyond it");
            }
        }

        record_define.overrides_named(Term, options.name, options);

        return struct {
            pub const publr_taxonomy_definition = true;
            pub const Doc = Term;
            pub const given = options;
            pub const name = options.name;
            pub const type_name = options.name;
        };
    }
}
