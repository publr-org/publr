//! `internal_record_values`: the declared fields of each internal record, as text, so a
//! plugin finds its records by one field without reading every document.

const std = @import("std");
const db = @import("../lib/db.zig");
const model = @import("../model/internal_record.zig");

pub const Error = db.Error;

pub const Value = struct { field: []const u8, value: []const u8 };

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
