//! What an `on` hook takes of an event, as the queue keeps it: only the fields the hook's own
//! type names, read by its layout (`publr_shape`) from the value where it lies, then written
//! as JSON once. A hook that declares three fields of an answer of a megabyte waits in the
//! queue with those three.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const job_queue = @import("../../store/job_queue.zig");
const described_module = @import("described.zig");
const given_module = @import("given.zig");
const held_module = @import("held.zig");
const laid_module = @import("laid.zig");
const shaped_entry = @import("shaped_entry.zig");
const transfer = @import("transfer.zig");
const Loaded = @import("loaded.zig").Loaded;

const Described = described_module.Described;
const Passed = sdk.sandboxed_plugins.Passed;

const gpa = std.heap.c_allocator;

/// Where the projected value is placed to be read back: never zero, which says none.
const base: u32 = 16;

/// `passed` as the JSON hook `entry` of `loaded` waits in the queue with, in `arena`. JSON
/// that fits a queued run is kept as it is; anything else is read into the hook's layout.
pub fn json_for(
    loaded: *Loaded,
    entry: u32,
    arena: std.mem.Allocator,
    passed: Passed,
) sdk.Error![]const u8 {
    std.debug.assert(passed.bytes().len > 0);
    std.debug.assert(entry >= loaded.manifest.operations.len);

    if (passed == .json and passed.json.len <= job_queue.input_bytes_max) {
        return passed.json;
    }

    if (loaded.spoiled) {
        return error.Unavailable;
    }

    loaded.enter();
    defer loaded.leave();

    const instance = loaded.ensure_instance() catch return error.Unavailable;
    const described = shaped_entry.described_kept(loaded, instance, entry) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable;
    };

    var working = std.heap.ArenaAllocator.init(gpa);
    defer working.deinit();

    const written = try projected(described, working.allocator(), passed);

    return arena.dupe(u8, written) catch error.OutOfMemory;
}

/// The envelope's `in` built from `passed` as `described` lays it out, then written as JSON.
fn projected(
    described: *const Described,
    memory: std.mem.Allocator,
    passed: Passed,
) sdk.Error![]const u8 {
    const root = Described.root;

    if (described.nodes[root].kind != .object) {
        return error.Invalid;
    }

    const index = described.field_named(root, "in", 0) orelse return error.Invalid;
    const node = described.fields_of(root)[index].node;
    var laid: laid_module.Laid = .{};
    var layout: laid_module.Layout = .{
        .gpa = memory,
        .scratch = memory,
        .described = described,
        .laid = &laid,
    };
    const at = try layout.reserve(@max(described.span(node), 1), 16);

    std.debug.assert(at == 0);

    switch (passed) {
        .json => |text| {
            const tree = std.json.parseFromSliceLeaky(std.json.Value, memory, text, .{}) catch {
                return error.Invalid;
            };

            try layout.write(node, tree, at);
        },
        .laid => |piece| {
            const held = try held_module.open(memory, piece);
            var reading = held.given(memory);

            try transfer.move(&layout, node, at, &reading, root, try held.window(&reading));
        },
    }

    laid.place(base);

    var reading: given_module.Given = .{
        .described = described,
        .memory = .{
            .block = .{
                .base = base,
                .bytes = laid.block.items,
            },
        },
        .arena = memory,
        .table = laid.table.items,
    };

    return reading.json_of(node, try reading.window(node, base), .null);
}

test "an event is cut to what the hook's own type names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const shape_wire = @import("../../sdk/plugin/shape_wire.zig");
    const Envelope = struct {
        now_ms: i64,
        in: struct {
            id: []const u8,
            total: i64,
        },
    };
    const described = try described_module.parse(arena, comptime shape_wire.describe(Envelope));
    const whole = "{\"id\":\"o1\",\"lines\":[{\"title\":\"Tea\"},{\"title\":\"Cup\"}],\"total\":7}";
    const cut = try projected(&described, arena, .{
        .json = whole,
    });

    try std.testing.expectEqualStrings("{\"id\":\"o1\",\"total\":7}", cut);
    try std.testing.expectError(error.Invalid, projected(&described, arena, .{
        .json = "{\"id\":7}",
    }));
    try std.testing.expectError(error.Invalid, projected(&described, arena, .{
        .laid = "not a piece",
    }));
}
