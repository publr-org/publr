//! The tables each kind of stored thing holds rows in.

const std = @import("std");

pub const Kind = enum {
    record,
    internal,
    term,
    content_type,
    taxonomy,
    field_group,
    role,
    user,
    plugin,
};

pub const Outcome = enum {
    added,
    replaced,
    removed,
    unchanged,
};

/// A table a unit holds rows in: the column naming the unit, and the scope its rows have
/// when the table is shared by several kinds (`field_groups`).
pub const Table = struct {
    name: []const u8,
    key: []const u8,
    scope: ?[]const u8 = null,
};

pub const Shape = struct {
    own: Table,
    /// The own table's primary key, what an upsert conflicts on.
    conflict: []const u8,
    children: []const Table = &.{},
    /// Made again from the values once the unit lands; accepted and left out.
    derived: ?Table = null,
};

pub fn shape_of(kind: Kind) Shape {
    const shape: Shape = switch (kind) {
        .record => .{
            .own = .{
                .name = "records",
                .key = "id",
            },
            .conflict = "id",
            .children = &.{
                .{
                    .name = "record_values",
                    .key = "record",
                },
                .{
                    .name = "record_terms",
                    .key = "record",
                },
            },
            .derived = .{
                .name = "record_search",
                .key = "record",
            },
        },
        .term => .{
            .own = .{
                .name = "terms",
                .key = "id",
            },
            .conflict = "id",
            .children = &.{.{
                .name = "term_values",
                .key = "record",
            }},
            .derived = .{
                .name = "term_search",
                .key = "record",
            },
        },
        .internal => .{
            .own = .{
                .name = "internal_records",
                .key = "id",
            },
            .conflict = "id",
            .children = &.{.{
                .name = "internal_record_values",
                .key = "record",
            }},
        },
        .content_type => typed("content_types"),
        .taxonomy => typed("taxonomies"),
        .field_group => .{
            .own = .{
                .name = "field_groups",
                .key = "owner",
                .scope = "custom_fields",
            },
            .conflict = "scope, owner",
        },
        .role => .{
            .own = .{
                .name = "roles",
                .key = "name",
            },
            .conflict = "name",
            .children = &.{.{
                .name = "role_grants",
                .key = "role",
            }},
        },
        .user => .{
            .own = .{
                .name = "users",
                .key = "id",
            },
            .conflict = "id",
            .children = &.{
                .{
                    .name = "user_roles",
                    .key = "user_id",
                },
                .{
                    .name = "user_values",
                    .key = "record",
                },
                .{
                    .name = "user_search",
                    .key = "record",
                },
                .{
                    .name = "identities",
                    .key = "user_id",
                },
            },
        },
        .plugin => .{
            .own = .{
                .name = "sandboxed_plugins",
                .key = "name",
            },
            .conflict = "name",
        },
    };

    std.debug.assert(shape.own.name.len > 0);
    std.debug.assert(shape.children.len <= 4);

    return shape;
}

/// A type's or a taxonomy's row, and its fields: the field group its id owns.
fn typed(comptime table: []const u8) Shape {
    std.debug.assert(table.len > 0);

    return .{
        .own = .{
            .name = table,
            .key = "id",
        },
        .conflict = "id",
        .children = &.{.{
            .name = "field_groups",
            .key = "owner",
            .scope = table,
        }},
    };
}
