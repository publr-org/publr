//! A taxonomy as data: a content type definition whose documents are terms, with the
//! rules that tell the two apart. No database.

const std = @import("std");
const content_type = @import("content_type.zig");
const field = @import("field.zig");
const kinds = @import("kinds.zig");

pub const Def = content_type.Def;

/// A plugin's taxonomy on other plugins' types (`.register_taxonomies`), by name or pattern.
pub const Registration = struct {
    /// The taxonomy, whole: `shipping.region`, or core's `tags`.
    taxonomy: []const u8,
    /// One type (`events.event`), every type of a plugin (`products.*`), or every type (`*`).
    to: []const []const u8,
};

/// What a taxonomy definition may not be, on top of what every definition must be.
pub fn validate_def(def: Def, problems: *field.Problems) void {
    std.debug.assert(problems.len <= field.problems_max);

    if (def.fields.len > field.fields_max) {
        problems.add("fields", field.too_many_fields);
        return;
    }

    if (def.kind != .record) {
        problems.add("kind", "a taxonomy holds terms: its kind is record");
    }

    if (def.url.len > 0) {
        problems.add("url", "term archives are not routed yet");
    }

    if (def.taxonomies.len > 0) {
        problems.add("taxonomies", "a taxonomy never names types; a type lists its taxonomies");
    }

    for (def.fields) |candidate| {
        if (std.mem.eql(u8, candidate.kind, "terms")) {
            problems.add(candidate.name, "a term is not classified by other terms");
        }
    }
}

/// The `terms` fields of a content type, one at a time: every one names the taxonomy it
/// assigns from.
pub fn terms_fields(fields: []const field.Def) TermsFields {
    std.debug.assert(fields.len <= field.fields_max);

    return .{
        .fields = fields,
    };
}

pub const TermsFields = struct {
    fields: []const field.Def,
    index: u32 = 0,

    pub fn next(terms: *TermsFields) ?*const field.Def {
        std.debug.assert(terms.index <= terms.fields.len);

        while (terms.index < terms.fields.len) {
            const candidate = &terms.fields[terms.index];

            terms.index += 1;

            if (std.mem.eql(u8, candidate.kind, "terms")) {
                return candidate;
            }
        }

        return null;
    }

    pub fn count(fields: []const field.Def) u32 {
        std.debug.assert(fields.len <= field.fields_max);

        var found: u32 = 0;
        var each = terms_fields(fields);

        while (each.next()) |_| {
            found += 1;
        }

        return found;
    }
};

/// The taxonomy every term test writes against: a name, a slug, and a hierarchy.
pub const test_topics: Def = .{
    .handle = "topics",
    .name = "Topics",
    .public = true,
    .title_field = "name",
    .hierarchical = true,
    .fields = &.{
        .{
            .name = "name",
            .label = "Name",
            .kind = "string",
            .validation = .{
                .required = true,
            },
        },
        .{
            .name = "slug",
            .label = "Slug",
            .kind = "slug",
            .options = .{
                .source = "name",
            },
        },
    },
};

test "a taxonomy is a record-kind definition without a url and without terms fields" {
    var problems: field.Problems = .{};
    content_type.validate_def(&kinds.core, test_topics, &problems);
    validate_def(test_topics, &problems);
    try std.testing.expect(problems.is_empty());

    var wrong = test_topics;
    wrong.kind = .settings;
    wrong.url = "topics";
    wrong.fields = &.{
        .{
            .name = "name",
            .label = "Name",
            .kind = "string",
        },
        .{
            .name = "tags",
            .label = "Tags",
            .kind = "terms",
            .options = .{
                .taxonomy = "tags",
            },
        },
    };
    var bad: field.Problems = .{};
    validate_def(wrong, &bad);
    try std.testing.expectEqual(@as(u32, 3), bad.len);

    try std.testing.expectEqual(@as(u32, 1), TermsFields.count(wrong.fields));
    try std.testing.expectEqual(@as(u32, 0), TermsFields.count(test_topics.fields));
}

test "a terms field names a taxonomy, may sit anywhere, and takes no choices" {
    var problems: field.Problems = .{};
    const post: Def = .{
        .handle = "post",
        .name = "Post",
        .fields = &.{
            .{
                .name = "title",
                .label = "Title",
                .kind = "string",
            },
            .{
                .name = "topics",
                .label = "Topics",
                .kind = "terms",
                .many = true,
                .options = .{
                    .taxonomy = "topics",
                },
            },
        },
    };
    content_type.validate_def(&kinds.core, post, &problems);
    try std.testing.expect(problems.is_empty());

    var bad: field.Problems = .{};
    const wrong: Def = .{
        .handle = "post",
        .name = "Post",
        .fields = &.{
            .{
                .name = "topics",
                .label = "Topics",
                .kind = "terms",
            },
            .{
                .name = "seo",
                .label = "SEO",
                .kind = "group",
                .fields = &.{
                    .{
                        .name = "tags",
                        .label = "Tags",
                        .kind = "terms",
                        .options = .{
                            .taxonomy = "tags",
                        },
                    },
                },
            },
            .{
                .name = "title",
                .label = "Title",
                .kind = "string",
                .options = .{
                    .taxonomy = "tags",
                },
            },
        },
    };
    content_type.validate_def(&kinds.core, wrong, &bad);
    try std.testing.expectEqual(@as(u32, 2), bad.len);
}

/// The implicit field a taxonomy gives every type it is on: locked, named after it
/// (`blog.topic` as `blog_topic`, field names have no dot), one term or many as it says.
pub fn implicit_field(arena: std.mem.Allocator, def: Def) error{OutOfMemory}!field.Def {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(def.name.len > 0);

    return .{
        .name = try field_name_of(arena, def.handle),
        .label = def.name,
        .kind = "terms",
        .many = !def.single,
        .locked = true,
        .help = def.description,
        .options = .{
            .taxonomy = def.handle,
        },
    };
}

/// The name a taxonomy's terms come back under on a record: its handle, the plugin's dot
/// an underscore.
pub fn field_name_of(arena: std.mem.Allocator, handle: []const u8) error{OutOfMemory}![]const u8 {
    std.debug.assert(handle.len > 0 and handle.len <= content_type.handle_len_max);

    const dot = std.mem.indexOfScalar(u8, handle, '.') orelse return handle;
    const name = try arena.dupe(u8, handle);

    name[dot] = '_';

    return name;
}

/// Whether a field is the implicit one of the taxonomy it names.
pub fn is_implicit(candidate: field.Def) bool {
    std.debug.assert(candidate.name.len > 0);

    if (!candidate.locked or !std.mem.eql(u8, candidate.kind, "terms")) {
        return false;
    }

    const handle = candidate.options.taxonomy;

    if (handle.len != candidate.name.len) {
        return false;
    }

    for (handle, candidate.name) |wanted, got| {
        if (wanted != got and !(wanted == '.' and got == '_')) {
            return false;
        }
    }

    return true;
}

test "the implicit field of a taxonomy is locked, named after it, many unless single" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var topics = test_topics;
    const implicit = try implicit_field(arena, topics);
    try std.testing.expectEqualStrings("topics", implicit.name);
    try std.testing.expectEqualStrings("Topics", implicit.label);
    try std.testing.expect(implicit.locked and implicit.many);
    try std.testing.expectEqualStrings("topics", implicit.options.taxonomy);
    try std.testing.expect(is_implicit(implicit));

    topics.single = true;
    try std.testing.expect(!(try implicit_field(arena, topics)).many);

    topics.handle = "blog.topic";
    const named = try implicit_field(arena, topics);
    try std.testing.expectEqualStrings("blog_topic", named.name);
    try std.testing.expectEqualStrings("blog.topic", named.options.taxonomy);
    try std.testing.expect(is_implicit(named));
    try std.testing.expectEqualStrings("blog.topic", topics.handle);
}
