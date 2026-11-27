//! Core's reading of taxonomies (`publr/plugin/taxonomy_define.zig` is what a plugin writes):
//! each a bound plugin declares as the type core stores, its registrations on other plugins'
//! types checked, and those registrations as the site keeps them: whose each is, and which
//! types its patterns pick.
const std = @import("std");
const content_type = @import("../../model/content_type.zig");
const field_model = @import("../../model/field.zig");
const plugin_define = @import("../../publr/plugin/define.zig");
const record_define = @import("../../publr/plugin/record_define.zig");
const taxonomy_define = @import("../../publr/plugin/taxonomy_define.zig");
const field_of = @import("records.zig").field_of;

const Registration = @import("../../publr/model/taxonomy.zig").Registration;

/// A registration as the site keeps it: whose it is.
pub const Registered = struct {
    plugin: []const u8,
    taxonomy: []const u8,
    to: []const []const u8,
};

/// Whether `pattern` picks the type `handle`: itself, `plugin.*` for every type of that
/// plugin, `*` for every one.
pub fn matches(pattern: []const u8, handle: []const u8) bool {
    std.debug.assert(pattern.len > 0);
    std.debug.assert(handle.len > 0);

    if (std.mem.eql(u8, pattern, "*")) {
        return true;
    }

    if (std.mem.endsWith(u8, pattern, ".*")) {
        const prefix = pattern[0 .. pattern.len - 1];

        return std.mem.startsWith(u8, handle, prefix) and handle.len > prefix.len;
    }

    return std.mem.eql(u8, pattern, handle);
}

/// Whether `pattern` is one type by name, not a pattern.
pub fn is_exact(pattern: []const u8) bool {
    std.debug.assert(pattern.len > 0);

    return !std.mem.eql(u8, pattern, "*") and !std.mem.endsWith(u8, pattern, ".*");
}

test "a pattern picks one type, a plugin's types, or every type" {
    try std.testing.expect(matches("*", "post"));
    try std.testing.expect(matches("products.*", "products.variant"));
    try std.testing.expect(!matches("products.*", "products"));
    try std.testing.expect(!matches("products.*", "productsx.variant"));
    try std.testing.expect(matches("events.event", "events.event"));
    try std.testing.expect(!matches("events.event", "events.other"));
    try std.testing.expect(is_exact("events.event"));
    try std.testing.expect(!is_exact("products.*"));
    try std.testing.expect(!is_exact("*"));
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
    const Topics = taxonomy_define.define(Topic, .{
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
