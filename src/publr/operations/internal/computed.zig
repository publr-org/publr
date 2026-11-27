//! The operations computed fields bring to internal records: a whole number added up over a
//! collection in core (its computed values worked out first, a page at a time), and how long
//! the answer a computed field's work gives holds.
const operation = @import("../../operation.zig");

pub const Sum = struct {
    pub const name = "internal.sum";
    pub const description = "Add up a whole number over internal records";
    pub const details =
        \\The whole numbers at `path` (`size.tallies`, a field and the fields inside it) of
        \\every record of the collection added up, or of those whose indexed `field` holds
        \\`value`. A record with nothing there, or something else, adds nothing. Added up by
        \\the database: no record is handed over. A computed field's values are worked out
        \\first where stale, a page at a time. Changes nothing a caller wrote.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        kind: []const u8,
        path: []const u8,
        field: ?[]const u8 = null,
        value: ?[]const u8 = null,
        plugin: ?[]const u8 = null,
        app: ?[]const u8 = null,
    };
    pub const Out = struct {
        sum: i64,
    };
    pub const example: In = .{
        .plugin = "greeter",
        .kind = "visit",
        .path = "count",
    };
    pub const example_out: Out = .{
        .sum = 12,
    };
    pub const field_docs: operation.Docs(In) = .{
        .kind = "The collection",
        .path = "The number to add up: a field, dotted into the fields inside it",
        .field = "An indexed field to filter on",
        .value = "The value it holds, as text",
        .plugin = "Whose records, when no plugin is running",
        .app = "Which app's, when no plugin is running",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .sum = "The numbers added up; 0 when there are none",
    };
};

pub const HoldsUntil = struct {
    pub const name = "internal.holds_until";
    pub const description = "Say until when a computed field's answer holds";
    pub const details =
        \\Called by a computed field's own function while it works a value out
        \\(`ctx.holds_until`): the value is worked out again at `until_ms` whatever else
        \\happens (a sale ends at midnight). The earliest one said counts. Outside that work it
        \\does nothing.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        until_ms: i64,
    };
    pub const Out = struct {};
    pub const example: In = .{
        .until_ms = 1767225600000,
    };
    pub const example_out: Out = .{};
    pub const field_docs: operation.Docs(In) = .{
        .until_ms = "When the answer stops holding, in milliseconds since 1970",
    };
    pub const output_docs: operation.Docs(Out) = .{};
};
