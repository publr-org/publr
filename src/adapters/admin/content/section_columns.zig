//! The fields a plugin's section shows after the title in one of its types' lists: read for
//! the listed records in one query, each shown as text by its field's kind. A column that
//! is not a field of the type, or of a kind a cell cannot show, is left out.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const records = @import("../../../operations/record.zig");
const types = @import("../../../operations/content_type.zig");
const query = @import("../../../operations/record/query.zig");
const admin_slots = @import("../../../sdk/plugin/admin_slots.zig");
const sections = @import("../sections.zig");
const list = @import("list.zig");

const Error = admin.Error;
const Value = std.json.Value;

pub const Field = struct {
    name: []const u8,
    label: []const u8,
    kind: []const u8,
};

pub const Columns = struct {
    fields: []const Field,
    /// Per record, in the list's order: each field's text.
    cells: []const []const []const u8,
};

/// The section columns of a list showing one type of a section; null for any other list.
pub fn of(page: *const list.Page, found: []const records.Record) Error!?Columns {
    std.debug.assert(page.session.signed_in());
    std.debug.assert(found.len <= records.list_max);

    const shown = page.effective.types;

    if (page.view_id != null or shown.len != 1) {
        return null;
    }

    const all = try sections.all(page.session);
    const section = sections.current(all, .{
        .filters = page.effective,
    }) orelse return null;
    const listed = section.find(shown[0]) orelse return null;

    if (listed.columns.len == 0) {
        return null;
    }

    const fields = try fields_of(page.session, listed.handle, listed.columns);

    if (fields.len == 0) {
        return null;
    }

    return .{
        .fields = fields,
        .cells = try cells_of(page.session, fields, found),
    };
}

fn fields_of(
    session: *admin.Session,
    handle: []const u8,
    columns: []const []const u8,
) Error![]const Field {
    std.debug.assert(columns.len <= admin_slots.columns_max);

    var reading = session.*;
    const got = registry.SDK.dispatch(&reading.ctx, types.Get, .{
        .type = handle,
    }) catch {
        return &.{};
    };
    var fields: std.ArrayList(Field) = .empty;

    for (columns) |column| {
        for (got.definition.fields) |field| {
            if (std.mem.eql(u8, field.name, column) and admin_slots.column_kind(field.kind)) {
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

fn cells_of(
    session: *admin.Session,
    fields: []const Field,
    found: []const records.Record,
) Error![]const []const []const u8 {
    std.debug.assert(fields.len > 0);

    const arena = session.arena;
    const cells = try arena.alloc([]const []const u8, found.len);

    for (cells) |*row| {
        row.* = try arena.alloc([]const u8, fields.len);
        @memset(@constCast(row.*), "");
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
        std.log.warn("section columns: {t}", .{err});
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
        const row: [][]const u8 = @constCast(cells[position]);

        for (fields, 0..) |field, index| {
            var key_buffer: [8]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buffer, "c{d}", .{index}) catch unreachable;

            row[index] = try text_of(arena, field.kind, item.object.get(key));
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
