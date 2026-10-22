//! The fields a one-type list shows as columns (the view's `columns`, in order): their values
//! read for the listed records in one query, drawn by `cell_values.zig`. A column that is not
//! a field of the type, or a field that holds no value (a tab, a message), is left out.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const records = @import("../../../operations/record.zig");
const types = @import("../../../operations/content_type.zig");
const query = @import("../../../operations/record/query.zig");
const list = @import("list.zig");

const Error = admin.Error;
const Value = std.json.Value;

/// The kinds a list cell shows as text.
const column_kinds = [_][]const u8{
    "string",  "text",   "email",   "url",      "slug",  "select",
    "integer", "number", "boolean", "datetime", "money", "color",
};

pub fn column_kind(kind: []const u8) bool {
    std.debug.assert(column_kinds.len > 0);

    for (column_kinds) |allowed| {
        if (std.mem.eql(u8, allowed, kind)) {
            return true;
        }
    }

    return false;
}

pub const Field = struct {
    name: []const u8,
    label: []const u8,
    kind: []const u8,
};

pub const Columns = struct {
    fields: []const Field,
    /// Per record, in the list's order: each field's value as stored, null when it has none.
    values: []const []const Value,
};

/// The field columns of a list showing one type: the fields its view shows, in order; null
/// for a list over several types, or a view showing none.
pub fn of(page: *const list.Page, found: []const records.Record) Error!?Columns {
    std.debug.assert(page.session.signed_in());
    std.debug.assert(found.len <= records.list_max);

    const shown = page.effective.types;
    const names = page.columns();

    if (shown.len != 1) {
        return null;
    }

    const fields = try fields_of(page.session, shown[0], names);

    if (fields.len == 0) {
        return null;
    }

    return .{
        .fields = fields,
        .values = try values_of(page.session, fields, found),
    };
}

fn fields_of(
    session: *admin.Session,
    handle: []const u8,
    columns: []const []const u8,
) Error![]const Field {
    std.debug.assert(handle.len > 0);

    var reading = session.*;
    const got = registry.SDK.dispatch(&reading.ctx, types.Get, .{
        .type = handle,
    }) catch {
        return &.{};
    };
    var fields: std.ArrayList(Field) = .empty;

    std.debug.assert(columns.len <= model.content_type.view_columns_max);

    for (columns) |column| {
        for (got.definition.fields) |field| {
            const holds = !model.field.is_layout(field.kind);

            if (std.mem.eql(u8, field.name, column) and holds) {
                try fields.append(session.arena, .{
                    .name = field.name,
                    .label = field.label,
                    .kind = field.kind,
                });
            }
        }
    }

    return fields.items;
}

fn values_of(
    session: *admin.Session,
    fields: []const Field,
    found: []const records.Record,
) Error![]const []const Value {
    std.debug.assert(fields.len > 0);

    const arena = session.arena;
    const cells = try arena.alloc([]const Value, found.len);

    for (cells) |*row| {
        row.* = try arena.alloc(Value, fields.len);
        @memset(@constCast(row.*), .null);
    }

    if (found.len == 0) {
        return cells;
    }

    var ids: std.ArrayList([]const u8) = .empty;

    for (found) |record| {
        try ids.append(arena, record.id);
    }

    var projection: std.Io.Writer.Allocating = .init(arena);

    projection.writer.writeAll("*[_id in $ids]{ _id") catch return error.OutOfMemory;

    for (fields, 0..) |field, index| {
        projection.writer.print(", \"c{d}\": {s}", .{ index, field.name }) catch
            return error.OutOfMemory;
    }

    projection.writer.writeAll(" }") catch return error.OutOfMemory;

    const params = std.json.Stringify.valueAlloc(arena, .{
        .ids = ids.items,
    }, .{}) catch
        return error.OutOfMemory;
    var reading = session.*;
    const answered = registry.SDK.dispatch(&reading.ctx, query.Query, .{
        .query = projection.written(),
        .params = params,
        .perspective = .all,
    }) catch |err| {
        std.log.warn("list columns: {t}", .{err});
        return cells;
    };
    const text = answered.result.text;
    const parsed = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch return cells;

    if (parsed != .array) {
        return cells;
    }

    for (parsed.array.items) |item| {
        if (item != .object) continue;

        const id = item.object.get("_id") orelse continue;
        const position = position_of(found, if (id == .string) id.string else "") orelse continue;
        const row: []Value = @constCast(cells[position]);

        for (row, 0..) |*value, index| {
            var key_buffer: [8]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buffer, "c{d}", .{index}) catch unreachable;

            value.* = item.object.get(key) orelse .null;
        }
    }

    return cells;
}

fn position_of(found: []const records.Record, id: []const u8) ?u32 {
    std.debug.assert(found.len <= records.list_max);

    for (found, 0..) |record, position| {
        if (std.mem.eql(u8, record.id, id)) {
            return @intCast(position);
        }
    }

    return null;
}

/// A field's value as a cell shows it.
pub fn text_of(arena: std.mem.Allocator, kind: []const u8, value: ?Value) Error![]const u8 {
    std.debug.assert(kind.len > 0);

    const present = value orelse return "";
    const print = std.fmt.allocPrint;

    if (std.mem.eql(u8, kind, "boolean")) {
        return if (present == .bool and present.bool) "Yes" else "No";
    }

    if (std.mem.eql(u8, kind, "datetime")) {
        const ok = present == .integer and present.integer >= 0 and present.integer < 1 << 50;

        return if (ok) admin.time_text(arena, present.integer) else "";
    }

    if (std.mem.eql(u8, kind, "money")) {
        return money_text(arena, present);
    }

    return switch (present) {
        .string => |text| text,
        .integer => |number| print(arena, "{d}", .{number}) catch error.OutOfMemory,
        .float => |number| print(arena, "{d}", .{number}) catch error.OutOfMemory,
        else => "",
    };
}

/// `{ "GBP": 850 }` as `8.50 GBP`, several amounts joined.
fn money_text(arena: std.mem.Allocator, value: Value) Error![]const u8 {
    std.debug.assert(model.currency.all.len > 0);

    if (value != .object) {
        return "";
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    var entries = value.object.iterator();
    var first = true;

    while (entries.next()) |entry| {
        const currency = model.currency.find(entry.key_ptr.*) orelse continue;

        if (entry.value_ptr.* != .integer) continue;

        const minor = entry.value_ptr.integer;
        const scale = std.math.pow(i64, 10, currency.digits);
        const sign: []const u8 = if (minor < 0) "-" else "";
        const whole = @abs(minor);

        if (!first) out.writer.writeAll(", ") catch return error.OutOfMemory;
        first = false;

        if (currency.digits == 0) {
            out.writer.print("{s}{d} {s}", .{ sign, whole, currency.code }) catch
                return error.OutOfMemory;
        } else {
            const fraction = whole % @as(u64, @intCast(scale));
            var digits_buffer: [24]u8 = undefined;
            const digits = std.fmt.bufPrint(&digits_buffer, "{d}", .{fraction}) catch unreachable;
            const padding = currency.digits -| @as(u8, @intCast(digits.len));

            out.writer.print("{s}{d}.", .{ sign, whole / @as(u64, @intCast(scale)) }) catch
                return error.OutOfMemory;
            out.writer.splatByteAll('0', padding) catch return error.OutOfMemory;
            out.writer.print("{s} {s}", .{ digits, currency.code }) catch return error.OutOfMemory;
        }
    }

    return out.written();
}

test "a cell shows a field's value by its kind" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var amounts: std.json.ObjectMap = .empty;

    try amounts.put(arena, "GBP", .{
        .integer = 850,
    });

    const money = try text_of(arena, "money", .{
        .object = amounts,
    });

    try std.testing.expectEqualStrings("8.50 GBP", money);
    try std.testing.expectEqualStrings("Yes", try text_of(arena, "boolean", .{
        .bool = true,
    }));
    try std.testing.expectEqualStrings("12", try text_of(arena, "integer", .{
        .integer = 12,
    }));
    try std.testing.expectEqualStrings("", try text_of(arena, "string", null));
}
