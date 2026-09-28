//! A taxonomy as data: a content type definition whose documents are terms, with the
//! rules that tell the two apart. No database.

const std = @import("std");
const content_type = @import("content_type.zig");
const field = @import("field.zig");
const kinds = @import("kinds.zig");

pub const Def = content_type.Def;

/// What a taxonomy definition may not be, on top of what every definition must be.
pub fn validate_def(def: Def, problems: *field.Problems) void {
    std.debug.assert(problems.len <= field.problems_max);

    if (def.fields.len > field.fields_max) {
        problems.add("fields", "too many fields");
        return;
    }

    if (def.kind != .record) {
        problems.add("kind", "a taxonomy holds terms: its kind is record");
    }

    if (def.url.len > 0) {
        problems.add("url", "term archives are not routed yet");
    }

    if (def.applies_to.len > applies_max) {
        problems.add("applies_to", "too many content types");
    }

    for (def.fields) |candidate| {
        if (std.mem.eql(u8, candidate.kind, "terms")) {
            problems.add(candidate.name, "a term is not classified by other terms");
        }
    }
}

/// The `terms` fields of a content type: every one names the taxonomy it assigns from.
pub fn terms_fields(
    fields: []const field.Def,
    buffer: *[field.fields_max]field.Def,
) []const field.Def {
    std.debug.assert(fields.len <= field.fields_max);
    std.debug.assert(buffer.len == field.fields_max);

    var count: u32 = 0;

    for (fields) |candidate| {
        if (std.mem.eql(u8, candidate.kind, "terms")) {
            buffer[count] = candidate;
            count += 1;
        }
    }

    return buffer[0..count];
}

/// The taxonomy every term test writes against: a name, a slug, and a hierarchy.
pub const test_topics: Def = .{
    .handle = "topics",
    .name = "Topics",
    .public = true,
    .title_field = "name",
    .hierarchical = true,
    .fields = &.{
        .{ .name = "name", .label = "Name", .kind = "string", .required = true },
        .{ .name = "slug", .label = "Slug", .kind = "slug", .options = .{ .source = "name" } },
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
        .{ .name = "name", .label = "Name", .kind = "string" },
        .{ .name = "tags", .label = "Tags", .kind = "terms", .options = .{ .taxonomy = "tags" } },
    };
    var bad: field.Problems = .{};
    validate_def(wrong, &bad);
    try std.testing.expectEqual(@as(u32, 3), bad.len);

    var buffer: [field.fields_max]field.Def = undefined;
    try std.testing.expectEqual(@as(usize, 1), terms_fields(wrong.fields, &buffer).len);
    try std.testing.expectEqual(@as(usize, 0), terms_fields(test_topics.fields, &buffer).len);
}

test "a terms field names a taxonomy, may sit anywhere, and takes no choices" {
    var problems: field.Problems = .{};
    const post: Def = .{
        .handle = "post",
        .name = "Post",
        .fields = &.{
            .{ .name = "title", .label = "Title", .kind = "string" },
            .{ .name = "topics", .label = "Topics", .kind = "terms", .many = true, .options = .{
                .taxonomy = "topics",
            } },
        },
    };
    content_type.validate_def(&kinds.core, post, &problems);
    try std.testing.expect(problems.is_empty());

    var bad: field.Problems = .{};
    const wrong: Def = .{
        .handle = "post",
        .name = "Post",
        .fields = &.{
            .{ .name = "topics", .label = "Topics", .kind = "terms" },
            .{ .name = "seo", .label = "SEO", .kind = "group", .fields = &.{
                .{ .name = "tags", .label = "Tags", .kind = "terms", .options = .{
                    .taxonomy = "tags",
                } },
            } },
            .{ .name = "title", .label = "Title", .kind = "string", .options = .{
                .taxonomy = "tags",
            } },
        },
    };
    content_type.validate_def(&kinds.core, wrong, &bad);
    try std.testing.expectEqual(@as(u32, 2), bad.len);
}

/// The implicit field a taxonomy gives every type it applies to: locked, named after the
/// taxonomy, one term or many as the taxonomy says.
pub fn implicit_field(def: Def) field.Def {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(def.name.len > 0);

    return .{
        .name = def.handle,
        .label = def.name,
        .kind = "terms",
        .many = !def.single,
        .locked = true,
        .help = def.description,
        .options = .{ .taxonomy = def.handle },
    };
}

/// Whether a taxonomy applies to a content type.
pub fn applies(def: Def, handle: []const u8) bool {
    std.debug.assert(def.applies_to.len <= applies_max);
    std.debug.assert(handle.len > 0);

    for (def.applies_to) |candidate| {
        if (std.mem.eql(u8, candidate, handle)) {
            return true;
        }
    }

    return false;
}

pub const applies_max: u32 = 256;

test "the implicit field of a taxonomy is locked, named after it, many unless single" {
    var topics = test_topics;
    topics.applies_to = &.{"post"};
    const implicit = implicit_field(topics);
    try std.testing.expectEqualStrings("topics", implicit.name);
    try std.testing.expectEqualStrings("Topics", implicit.label);
    try std.testing.expect(implicit.locked and implicit.many);
    try std.testing.expectEqualStrings("topics", implicit.options.taxonomy);
    try std.testing.expect(applies(topics, "post"));
    try std.testing.expect(!applies(topics, "page"));

    topics.single = true;
    try std.testing.expect(!implicit_field(topics).many);
}
