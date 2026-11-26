//! What a modifier wrote laid over the value it was given, where the value's shape comes
//! with the data (a record's document, values the outer edge sent as JSON): the two are
//! merged as the trees they stand for. Values whose layout is described are merged where
//! they lie (`merged.zig`), by the same rules.
const std = @import("std");
const id_map = @import("../../publr/plugin/id_map.zig");

/// Lays what a modifier wrote over the value it was given: a modifier reads the value in its
/// own words, with only the fields it uses, and the fields it left out stay as they were.
/// Objects take each written field. A list of objects with an `id` is matched by id, so a
/// modifier may drop, reorder or add items; another list of the same length is laid over
/// item by item. Anything else is replaced.
pub fn overlay(
    memory: std.mem.Allocator,
    target: *std.json.Value,
    written: std.json.Value,
) error{OutOfMemory}!void {
    var pending: std.ArrayList(Pending) = .empty;
    var visited: u32 = 0;

    pending.append(memory, .{
        .target = target,
        .written = written,
    }) catch return error.OutOfMemory;

    while (pending.pop()) |next| {
        visited += 1;
        std.debug.assert(visited <= overlay_nodes_max);

        if (next.target.* == .object and next.written == .object) {
            var fields = next.written.object.iterator();

            while (fields.next()) |field| {
                const kept = next.target.object.getPtr(field.key_ptr.*) orelse {
                    next.target.object.put(memory, field.key_ptr.*, field.value_ptr.*) catch {
                        return error.OutOfMemory;
                    };
                    continue;
                };

                pending.append(memory, .{
                    .target = kept,
                    .written = field.value_ptr.*,
                }) catch return error.OutOfMemory;
            }
        } else if (next.target.* == .array and next.written == .array) {
            try overlay_list(memory, next.target, next.written.array.items, &pending);
        } else {
            next.target.* = next.written;
        }
    }

    std.debug.assert(pending.items.len == 0);
}

const Pending = struct {
    target: *std.json.Value,
    written: std.json.Value,
};

/// Every node of a written value is visited once; a mod's value is a few MiB of JSON at most.
const overlay_nodes_max: u32 = 1 << 24;

fn overlay_list(
    memory: std.mem.Allocator,
    target: *std.json.Value,
    written: []const std.json.Value,
    pending: *std.ArrayList(Pending),
) !void {
    const kept = target.array.items;

    std.debug.assert(target.* == .array);

    if (!keyed(written) and kept.len == written.len) {
        for (kept, written) |*slot, item| {
            pending.append(memory, .{
                .target = slot,
                .written = item,
            }) catch return error.OutOfMemory;
        }

        return;
    }

    var list = std.json.Array.initCapacity(memory, written.len) catch return error.OutOfMemory;
    const by_id = try ids_of(memory, kept);
    const found = memory.alloc(bool, written.len) catch return error.OutOfMemory;

    for (written, found) |item, *matched| {
        const given = matching(&by_id, kept, item);

        matched.* = given != null;
        list.appendAssumeCapacity(given orelse item);
    }

    target.* = .{
        .array = list,
    };

    for (target.array.items, written, found) |*slot, item, matched| {
        if (matched) {
            pending.append(memory, .{
                .target = slot,
                .written = item,
            }) catch return error.OutOfMemory;
        }
    }

    std.debug.assert(target.array.items.len == written.len);
}

/// Whether every item is an object with a text `id`.
fn keyed(items: []const std.json.Value) bool {
    std.debug.assert(items.len <= 1 << 24);

    for (items) |item| {
        if (id_of(item) == null) {
            return false;
        }
    }

    return items.len > 0;
}

fn id_of(item: std.json.Value) ?[]const u8 {
    if (item != .object) {
        return null;
    }

    const id = item.object.get("id") orelse return null;

    if (id != .string) {
        return null;
    }

    std.debug.assert(item.object.count() > 0);

    return id.string;
}

/// Where each item given with an id is, by its id: the first of two with the same one.
fn ids_of(
    memory: std.mem.Allocator,
    kept: []const std.json.Value,
) error{OutOfMemory}!id_map.Map(u32) {
    var by_id: id_map.Map(u32) = .empty;

    std.debug.assert(kept.len <= 1 << 24);

    by_id.ensureTotalCapacity(memory, @intCast(kept.len)) catch return error.OutOfMemory;

    for (kept, 0..) |candidate, index| {
        const id = id_of(candidate) orelse continue;
        const entry = by_id.getOrPutAssumeCapacity(id);

        if (!entry.found_existing) {
            entry.value_ptr.* = @intCast(index);
        }
    }

    std.debug.assert(by_id.count() <= kept.len);

    return by_id;
}

/// The item given with the same id as `item`, if there is one.
fn matching(
    by_id: *const id_map.Map(u32),
    kept: []const std.json.Value,
    item: std.json.Value,
) ?std.json.Value {
    const id = id_of(item) orelse return null;

    std.debug.assert(id.len <= 1 << 16);

    const index = by_id.get(id) orelse return null;

    std.debug.assert(index < kept.len);

    return kept[index];
}

test "what a modifier writes lies over the value: fields it left out stay, items by id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const memory = arena_state.allocator();
    const given = "{\"parcel\":{\"subtotal\":{\"GBP\":900}},\"methods\":[" ++
        "{\"id\":\"post\",\"title\":\"Post\",\"price\":{\"GBP\":400}}," ++
        "{\"id\":\"courier\",\"title\":\"Courier\",\"price\":{\"GBP\":900}}]}";
    const written_text = "{\"methods\":[{\"id\":\"courier\",\"price\":{\"GBP\":0}}," ++
        "{\"id\":\"locker\",\"title\":\"Locker\",\"price\":{\"GBP\":300}}]}";
    var value = try std.json.parseFromSliceLeaky(std.json.Value, memory, given, .{});
    const written = try std.json.parseFromSliceLeaky(std.json.Value, memory, written_text, .{});

    try overlay(memory, &value, written);

    const methods = value.object.get("methods").?.array.items;
    const subtotal = value.object.get("parcel").?.object.get("subtotal").?;

    try std.testing.expectEqual(@as(usize, 2), methods.len);
    try std.testing.expectEqualStrings("Courier", methods[0].object.get("title").?.string);
    const courier_price = methods[0].object.get("price").?.object.get("GBP").?;

    try std.testing.expectEqual(@as(i64, 0), courier_price.integer);
    try std.testing.expectEqualStrings("Locker", methods[1].object.get("title").?.string);
    try std.testing.expectEqual(@as(i64, 900), subtotal.object.get("GBP").?.integer);

    const unkeyed = try std.json.parseFromSliceLeaky(std.json.Value, memory, "[1,2]", .{});
    var list = try std.json.parseFromSliceLeaky(std.json.Value, memory, "[5,6,7]", .{});

    try overlay(memory, &list, unkeyed);
    try std.testing.expectEqual(@as(usize, 2), list.array.items.len);
}
