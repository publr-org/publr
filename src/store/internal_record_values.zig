//! `internal_record_values`: the declared fields of each internal record, as text, so a
//! plugin finds its records by one field without reading every document.

const std = @import("std");
const db = @import("../lib/db.zig");
const model = @import("../model/internal_record.zig");

pub const Error = db.Error;

pub const Value = struct {
    field: []const u8,
    value: []const u8,
};

/// Replaces what the record is found by.
pub fn replace(connection: *db.Db, record: []const u8, values: []const Value) Error!void {
    std.debug.assert(record.len > 0);
    std.debug.assert(values.len <= model.indexed_max);

    var clear = try connection.prepare("DELETE FROM internal_record_values WHERE record = ?1");
    defer clear.finalize();

    try clear.bind_text(1, record);
    try clear.exec();

    for (values) |value| {
        std.debug.assert(value.field.len > 0 and value.field.len <= model.field_len_max);

        var insert = try connection.prepare(
            "INSERT INTO internal_record_values (record, field, value) VALUES (?1, ?2, ?3)",
        );
        defer insert.finalize();

        try insert.bind_text(1, record);
        try insert.bind_text(2, value.field);
        try insert.bind_text(3, value.value);
        try insert.exec();
    }
}

/// What the record is found by now, in `arena`.
pub fn values_of(
    connection: *db.Db,
    arena: std.mem.Allocator,
    record: []const u8,
) Error![]const Value {
    std.debug.assert(record.len > 0);
    std.debug.assert(model.indexed_max > 0);

    var select = try connection.prepare(
        "SELECT field, value FROM internal_record_values WHERE record = ?1 LIMIT ?2",
    );
    defer select.finalize();

    try select.bind_text(1, record);
    try select.bind_int(2, model.indexed_max);

    var values: std.ArrayList(Value) = .empty;

    while (try select.step()) {
        const row = try select.read(Value, arena);

        try values.append(arena, row);
    }

    return values.items;
}
