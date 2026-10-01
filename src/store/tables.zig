//! The two document domains and the four tables each one owns. A store generic over
//! `Tables` serves records and terms alike; the instantiation names the tables.

const std = @import("std");

pub const Tables = struct {
    /// The schemas: `content_types` or `taxonomies`.
    definitions: []const u8,
    /// The rows with identity and lifecycle: `records` or `terms`.
    documents: []const u8,
    /// The typed field values per slot.
    values: []const u8,
    /// The FTS5 index over searchable values.
    search: []const u8,
    /// The membership index of `terms` fields, when the domain's documents are assigned
    /// to terms: `record_terms` for records, nothing for terms.
    assignments: ?[]const u8 = null,
};

pub const records: Tables = .{
    .definitions = "content_types",
    .documents = "records",
    .values = "record_values",
    .search = "record_search",
    .assignments = "record_terms",
};

pub const terms: Tables = .{
    .definitions = "taxonomies",
    .documents = "terms",
    .values = "term_values",
    .search = "term_search",
};

/// Users are not a document domain (no lifecycle, no definitions of their own), but the
/// values of their custom fields use the same value store, over `users`.
pub const users: Tables = .{
    .definitions = "field_groups",
    .documents = "users",
    .values = "user_values",
    .search = "user_search",
};

/// A project's structure, as against its content: its types, fields, taxonomies and plugins,
/// what a copy of the structure alone takes.
pub const structure = [_][]const u8{
    "content_types",
    "taxonomies",
    "field_groups",
    "sandboxed_plugins",
};

test "the two domains name four distinct tables each" {
    inline for ([_]Tables{ records, terms, users }) |tables| {
        try std.testing.expect(tables.definitions.len > 0);
        try std.testing.expect(!std.mem.eql(u8, tables.documents, tables.values));
        try std.testing.expect(!std.mem.eql(u8, tables.values, tables.search));
    }

    try std.testing.expect(!std.mem.eql(u8, records.documents, terms.documents));
}
