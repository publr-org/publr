//! `publr.taxonomy.define(Term, .{ .name, .public, .hierarchical, .single, .internal, .fields })`:
//! a taxonomy a plugin declares, stored as `<plugin>.<name>`. Every term has a name and a
//! slug; `Term` holds its own fields beyond them, each labelled by its `///`, overridden by
//! field name as a record's are. The taxonomy's name and description are the `///` above it
//! or its file's `//!`. It never names types: a type lists it (`.taxonomies` on the record),
//! another plugin's type gets it by `.register_taxonomies`.
const std = @import("std");
const content_type = @import("../../model/content_type.zig");
const field_model = @import("../../model/field.zig");
const plugin_define = @import("define.zig");
const record_define = @import("record_define.zig");
const field_of = @import("../../sdk/plugin/records.zig").field_of;

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

/// Whether `T` is what `publr.taxonomy.define` makes.
pub fn is_taxonomy(comptime Listed: type) bool {
    return @typeInfo(Listed) == .@"struct" and @hasDecl(Listed, "publr_taxonomy_definition");
}

/// The taxonomy as core stores it: `<plugin>.<name>`, a name and a slug, then its own fields.
pub fn def_of(
    comptime Taxonomy: type,
    comptime plugin: []const u8,
    comptime Docs: type,
) content_type.Def {
    comptime {
        std.debug.assert(plugin.len > 0);

        const options = Taxonomy.given;
        const Options = @TypeOf(options);
        const key = "taxonomy:" ++ Taxonomy.name;
        _ = plugin_define.words(Docs, key) orelse @compileError("taxonomy " ++ Taxonomy.name ++
            ": needs a `///` above it or a `//!` atop its file: its first line is its name");
        var fields: []const field_model.Def = &.{
            .{
                .name = "name",
                .label = "Name",
                .kind = "string",
                .locked = true,
                .validation = .{
                    .required = true,
                },
            },
            .{
                .name = "slug",
                .label = "Slug",
                .kind = "slug",
                .locked = true,
                .options = .{
                    .source = "name",
                },
            },
        };

        @setEvalBranchQuota(1000 + std.meta.fieldNames(Taxonomy.Doc).len *
            record_define.field_branches_max);

        for (std.meta.fieldNames(Taxonomy.Doc)) |field_name| {
            const made = field_of(Taxonomy, Docs, field_name);
            fields = fields ++ [_]field_model.Def{made};
        }

        const done = fields;

        return .{
            .handle = plugin ++ "." ++ Taxonomy.name,
            .name = record_define.label_of(plugin_define.first(Docs, key).?),
            .description = plugin_define.rest(Docs, key).?,
            .public = @hasField(Options, "public") and options.public,
            .hierarchical = @hasField(Options, "hierarchical") and options.hierarchical,
            .single = @hasField(Options, "single") and options.single,
            .internal = @hasField(Options, "internal") and options.internal,
            .system = true,
            .owner = plugin,
            .title_field = "name",
            .fields = done,
        };
    }
}

/// `.register_taxonomies` entries: a taxonomy on other plugins' types, by name or pattern.
pub const Registration = @import("../model/taxonomy.zig").Registration;

/// How many types and patterns one registration names.
pub const to_max: u32 = 16;

/// What a plugin's `.register_taxonomies` names: real handles and patterns, each a few.
pub fn check(comptime plugin: []const u8, comptime list: []const Registration) void {
    comptime {
        std.debug.assert(plugin.len > 0);

        for (list) |entry| {
            if (!content_type.valid_handle(entry.taxonomy)) {
                @compileError("plugin " ++ plugin ++ ": `.register_taxonomies` names a " ++
                    "taxonomy by its handle, `shipping.region`: " ++ entry.taxonomy);
            }

            if (entry.to.len == 0 or entry.to.len > to_max) {
                @compileError("plugin " ++ plugin ++ ": `.register_taxonomies` puts " ++
                    entry.taxonomy ++ " on 1 to 16 types or patterns");
            }

            for (entry.to) |pattern| {
                const prefix = if (std.mem.endsWith(u8, pattern, ".*"))
                    pattern[0 .. pattern.len - 2]
                else
                    "";
                const valid = std.mem.eql(u8, pattern, "*") or
                    (prefix.len > 0 and field_model.valid_name(prefix)) or
                    content_type.valid_handle(pattern);

                if (!valid) {
                    @compileError("plugin " ++ plugin ++ ": `.to` takes a type " ++
                        "(`events.event`), `plugin.*` or `*`: " ++ pattern);
                }
            }
        }
    }
}

test "a declared taxonomy is stored under its plugin, a name and a slug before its fields" {
    const Topic = struct {
        colour: ?[]const u8 = null,
    };
    const Topics = define(Topic, .{
        .name = "topic",
        .public = true,
        .hierarchical = true,
        .fields = .{
            .colour = .{
                .kind = "color",
            },
        },
    });
    const Docs = plugin_define.Words(.{
        .{ "taxonomy:topic", "Topics\n\nWhat a post is about." },
        .{ @typeName(Topic) ++ ".colour", "Colour" },
    });
    const def = comptime def_of(Topics, "blog", Docs);

    try std.testing.expectEqualStrings("blog.topic", def.handle);
    try std.testing.expectEqualStrings("Topics", def.name);
    try std.testing.expectEqualStrings("What a post is about.", def.description);
    try std.testing.expect(def.public and def.hierarchical and !def.single and !def.internal);
    try std.testing.expectEqualStrings("blog", def.owner);
    try std.testing.expectEqual(@as(usize, 3), def.fields.len);
    try std.testing.expectEqualStrings("name", def.fields[0].name);
    try std.testing.expectEqualStrings("slug", def.fields[1].name);
    try std.testing.expectEqualStrings("color", def.fields[2].kind);
    try std.testing.expectEqualStrings("Colour", def.fields[2].label);
}
