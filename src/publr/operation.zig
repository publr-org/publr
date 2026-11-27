//! What every operation is made of, as plugins name it: `publr.operation.Kind`,
//! `publr.Deprecated`, the `Failure`s a plugin declares and the `Problem`s `.validate` adds.
const std = @import("std");

/// A value whose shape comes with the data, as an operation's `In` or `Out` holds it: JSON
/// text in Publr, bytes read where they lie in an installed plugin's module.
pub const Json = @import("operation/json.zig").Json;

/// The longest operation name, `namespace.verb`.
pub const name_len_max: u32 = 64;
/// The most fields an operation's `In` or `Out` holds at one level.
pub const fields_max: u32 = 64;
/// The most operations one Publr holds, its plugins' included.
pub const operations_max: u32 = 1024;
/// The largest page a list answers at once (`limit`).
pub const page_limit_max: u32 = 200;

/// How an operation ends when it cannot do what it was asked.
pub const Error = error{
    Denied,
    Invalid,
    NotFound,
    Conflict,
    Throttled,
    /// The operation's own failure, one the core does not name: `ctx.failure` says which
    /// (a `Failure` its plugin declares), and the adapters answer with its status and name.
    Failed,
    /// A service the operation depends on could not be reached; nothing was changed.
    Unavailable,
    BadCredentials,
    InvalidationFailed,
    /// A modifier's read, noted for its batch: the modifier runs again once the batch's reads
    /// are in. Only a modifier's first pass sees it.
    NotYet,
    OutOfMemory,
};

pub const Kind = enum { read, write };

/// A group of operations, as REST, the CLI and MCP show it: `money` and what it is for.
pub const Namespace = struct {
    name: []const u8,
    summary: []const u8,
    details: []const u8,
    /// What people call it: `Media library`. Empty shows the name.
    label: []const u8 = "",
    /// Where it sits when roles are edited.
    area: Area = .site,

    pub const Area = enum {
        /// What editors write: records, terms, media, their history.
        content,
        /// The site's structure and setup: types, fields, apps, design.
        site,
        /// Accounts, roles and how people sign in.
        people,
        /// How this Publr runs: plugins, secrets, updates, logs.
        system,
        /// What every role needs or no one grants by hand (liveness, a person's own pins
        /// and views): not listed when roles are edited, its grants kept as they are.
        background,
    };
};

/// A way an operation fails that the core's errors do not name, raised with `ctx.fail`:
/// "your email is not verified", "the plan's limit is reached". A plugin's operation lists
/// the ones it can end with on its `Fails:` lines.
pub const Failure = struct {
    /// What REST answers (`{ "error": "Unverified" }`): letters only, starting upper-case.
    name: []const u8,
    /// An HTTP status from 400 to 599.
    status: u16,
    /// For people: the CLI prints it, REST sends it as `message`.
    message: []const u8,
};

/// One thing wrong with a call's input, beside its field: `.validate`'s `problems.add`.
pub const Problem = struct {
    /// A field of the input, as named in it.
    field: []const u8,
    /// For people, shown beside the field.
    message: []const u8,
};

/// An operation on its way out: it keeps working until `removed_on`, every caller is told,
/// and its `migration` is what a release's migration prompt says of it.
/// `.deprecated = .{ .since = "0.9.0", .removed_on = "2027-03-01", .instead = "money.format",
/// .migration = "Pass amount and currency instead of value." }`
pub const Deprecated = struct {
    /// The release that deprecated it.
    since: []const u8,
    /// The day it goes (`2027-03-01`): the first release made on or after it removes it.
    removed_on: []const u8,
    /// The operation to call instead; empty when nothing replaces it.
    instead: []const u8 = "",
    /// What to change, often with a before and after.
    migration: []const u8,
};

/// A text for each field of `Shape`, empty by default: an operation's `field_docs`.
pub fn Docs(comptime Shape: type) type {
    comptime {
        const source = @typeInfo(Shape).@"struct".field_names;
        const empty: []const u8 = "";
        const default_ptr: ?*const anyopaque = @ptrCast(&empty);

        std.debug.assert(source.len <= fields_max);

        return @Struct(
            .auto,
            null,
            std.meta.fieldNames(Shape),
            &@splat([]const u8),
            &@splat(.{
                .default_value_ptr = default_ptr,
            }),
        );
    }
}

/// Everything before the verb: `record` of `record.create`.
pub fn namespace(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse unreachable;
    std.debug.assert(dot > 0);
    return name[0..dot];
}

/// The verb: `create` of `record.create`.
pub fn verb(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse unreachable;
    std.debug.assert(dot + 1 < name.len);
    return name[dot + 1 ..];
}

test "namespace and verb split" {
    try std.testing.expectEqualStrings("record", namespace("record.create"));
    try std.testing.expectEqualStrings("create", verb("record.create"));
}
