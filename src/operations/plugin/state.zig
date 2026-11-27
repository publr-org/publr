//! A plugin's row read and written as data: its manifest, what is granted and denied, each
//! permission's flags, and the requests an administrator sees with where each one stands.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const json = @import("../../lib/json.zig");
const public = @import("../../publr/operations/plugin/detail.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const sandboxed_plugin = model.sandboxed_plugin;
const permission = model.permission;

pub const Request = public.Request;

/// A row with its JSON columns decoded.
pub const Decoded = struct {
    row: store.sandboxed_plugins.Row,
    manifest: sandboxed_plugin.Manifest,
    granted: []const []const u8,
    denied: []const []const u8,
    /// Each permission's flags as an administrator left them.
    grants: []const permission.Held,
    /// Built in, read from its declarations (no row holds it), or installed.
    mode: Mode = .sandboxed,
};

pub const Mode = public.Mode;

const parse_options: std.json.ParseOptions = .{
    .allocate = .alloc_always,
    .ignore_unknown_fields = true,
};

pub fn load(ctx: *Ctx, name: []const u8) Error!Decoded {
    std.debug.assert(name.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    if (!sandboxed_plugin.valid_name(name)) {
        return error.NotFound;
    }

    const found = try store.sandboxed_plugins.get(ctx.db, ctx.arena, name);
    const row = found orelse return error.NotFound;

    return decode(ctx.arena, row);
}

pub fn decode(arena: std.mem.Allocator, row: store.sandboxed_plugins.Row) Error!Decoded {
    std.debug.assert(row.name.len > 0);
    std.debug.assert(row.manifest.len > 0);

    return .{
        .row = row,
        .manifest = try parse_manifest(arena, row.manifest),
        .granted = json.parse([]const []const u8, arena, row.granted, parse_options) catch {
            return error.Invalid;
        },
        .denied = json.parse([]const []const u8, arena, row.denied, parse_options) catch {
            return error.Invalid;
        },
        .grants = json.parse([]const permission.Held, arena, row.grants, parse_options) catch {
            return error.Invalid;
        },
    };
}

/// What parsing a manifest of `len` bytes takes at most: the values it parses into beside
/// the text, which its texts point into.
pub fn parse_bytes(len: u64) u64 {
    std.debug.assert(manifest_factor > 1);
    std.debug.assert(len <= std.math.maxInt(u32));

    return parse_slack_bytes + len * manifest_factor;
}

/// How many times its length a manifest's parsed values take, at most.
pub const manifest_factor = @import("../../publr/operations/plugin.zig").Enable.manifest_factor;
const parse_slack_bytes: u32 = 64 << 10;

pub fn parse_manifest(arena: std.mem.Allocator, text: []const u8) Error!sandboxed_plugin.Manifest {
    std.debug.assert(text.len > 0);
    std.debug.assert(sandboxed_plugin.format > 0);

    // Its texts point into `text` where they hold no escapes: a manifest is large, and
    // whoever holds it holds the row it came from.
    var manifest = json.parse(sandboxed_plugin.Manifest, arena, text, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Invalid,
    };

    if (!sandboxed_plugin.format_known(&manifest)) {
        return error.Invalid;
    }

    try sandboxed_plugin.resolve_shapes(arena, &manifest);

    return manifest;
}

/// Of a manifest, only what the plugin provides other plugins (its operations' shapes, its
/// records, events, contracts and dimensions): its words, help and pages left unread, so a
/// loop over every plugin reads a fraction of each.
pub fn parse_provided(arena: std.mem.Allocator, text: []const u8) Error!sandboxed_plugin.Manifest {
    std.debug.assert(text.len > 0);
    std.debug.assert(sandboxed_plugin.format > 0);

    const Operation = sandboxed_plugin.Operation;
    const Provided = struct {
        format: u32,
        name: []const u8,
        version: []const u8,
        operations: []const struct {
            name: []const u8,
            kind: sandboxed_plugin.Kind,
            input: @FieldType(Operation, "input") = &.{},
            output: @FieldType(Operation, "output") = &.{},
            input_shape: ?u32 = null,
            output_shape: ?u32 = null,
        } = &.{},
        shapes: @FieldType(sandboxed_plugin.Manifest, "shapes") = &.{},
        content_types: @FieldType(sandboxed_plugin.Manifest, "content_types") = &.{},
        internal_records: @FieldType(sandboxed_plugin.Manifest, "internal_records") = &.{},
        events: @FieldType(sandboxed_plugin.Manifest, "events") = &.{},
        contracts: @FieldType(sandboxed_plugin.Manifest, "contracts") = &.{},
        dimensions: @FieldType(sandboxed_plugin.Manifest, "dimensions") = &.{},
    };
    const provided = json.parse(Provided, arena, text, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Invalid,
    };
    const operations = try arena.alloc(Operation, provided.operations.len);

    for (provided.operations, operations) |given, *operation| {
        operation.* = .{
            .name = given.name,
            .kind = given.kind,
            .description = "",
            .input = given.input,
            .output = given.output,
            .input_shape = given.input_shape,
            .output_shape = given.output_shape,
        };
    }

    var manifest: sandboxed_plugin.Manifest = .{
        .format = provided.format,
        .name = provided.name,
        .version = provided.version,
        .summary = "",
        .operations = operations,
        .shapes = provided.shapes,
        .content_types = provided.content_types,
        .internal_records = provided.internal_records,
        .events = provided.events,
        .contracts = provided.contracts,
        .dimensions = provided.dimensions,
    };

    if (!sandboxed_plugin.format_known(&manifest)) {
        return error.Invalid;
    }

    try sandboxed_plugin.resolve_shapes(arena, &manifest);

    return manifest;
}

/// Everything the manifest asks for, each with where it stands for this plugin and, for a
/// permission, its flags as set now.
pub fn requests_of(
    arena: std.mem.Allocator,
    manifest: *const sandboxed_plugin.Manifest,
    granted: []const []const u8,
    denied: []const []const u8,
    grants: []const permission.Held,
) Error![]const Request {
    std.debug.assert(manifest.name.len > 0);
    std.debug.assert(granted.len <= sandboxed_plugin.requests_max);

    const asked = sandboxed_plugin.requests(manifest, arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return error.Invalid,
    };
    const out = try arena.alloc(Request, asked.len);

    for (asked, out) |request, *shown| {
        const state: Request.State = if (!request.available)
            .unavailable
        else if (permission.contains(granted, request.key))
            .granted
        else if (permission.contains(denied, request.key))
            .denied
        else
            .pending;

        shown.* = .{
            .key = request.key,
            .sentence = request.sentence,
            .reason = request.reason,
            .tier = request.tier,
            .state = state,
        };

        if (request.asked) |as_asked| {
            const set = sandboxed_plugin.as_set(as_asked, grants);

            shown.tier = permission.tier_of_held(permission.find(request.key).?, &set);
            shown.names = set.names();
            shown.domains = set.domains;
            shown.flags = try flags_of(arena, as_asked, set);
        }
    }

    return out;
}

fn flags_of(
    arena: std.mem.Allocator,
    asked: permission.Held,
    set: permission.Held,
) Error![]const Request.Flag {
    std.debug.assert(asked.key.len > 0);
    std.debug.assert(std.mem.eql(u8, asked.key, set.key));

    var flags: std.ArrayList(Request.Flag) = .empty;

    inline for (comptime std.meta.tags(permission.Flag)) |flag| {
        if (asked.flag(flag)) {
            flags.append(arena, .{
                .name = flag,
                .on = set.flag(flag),
            }) catch return error.OutOfMemory;
        }
    }

    return flags.items;
}

pub fn encode(arena: std.mem.Allocator, value: anytype) Error![]const u8 {
    return sdk.stringify(arena, value);
}

/// `list` with `key` added once.
pub fn with(
    arena: std.mem.Allocator,
    list: []const []const u8,
    key: []const u8,
) Error![]const []const u8 {
    std.debug.assert(key.len > 0);
    std.debug.assert(list.len <= sandboxed_plugin.requests_max);

    if (permission.contains(list, key)) {
        return list;
    }

    return std.mem.concat(arena, []const u8, &.{ list, &.{key} }) catch error.OutOfMemory;
}

/// `list` without `key`.
pub fn without(
    arena: std.mem.Allocator,
    list: []const []const u8,
    key: []const u8,
) Error![]const []const u8 {
    std.debug.assert(key.len > 0);
    std.debug.assert(list.len <= sandboxed_plugin.requests_max);

    var kept: std.ArrayList([]const u8) = .empty;

    for (list) |item| {
        if (!std.mem.eql(u8, item, key)) {
            kept.append(arena, item) catch return error.OutOfMemory;
        }
    }

    return kept.items;
}

/// Writes the decoded state back to its row.
pub fn save(ctx: *Ctx, decoded: Decoded) Error!void {
    std.debug.assert(decoded.row.name.len > 0);
    std.debug.assert(decoded.granted.len <= sandboxed_plugin.requests_max);

    var row = decoded.row;

    row.granted = try encode(ctx.arena, decoded.granted);
    row.denied = try encode(ctx.arena, decoded.denied);
    row.grants = try encode(ctx.arena, decoded.grants);
    row.updated_at = ctx.now_ms;

    try store.sandboxed_plugins.put(ctx.db, row);
}

test "requests show where each one stands, with each flag asked for as set now" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const manifest: sandboxed_plugin.Manifest = .{
        .name = "greeter",
        .version = "0.1.0",
        .summary = "Greets",
        .permissions = &.{
            .{
                .key = "records.write",
                .records = &.{"post"},
                .publish = true,
                .reason = "Keeps greetings",
            },
            .{
                .key = "users.read",
                .reason = "Greets by name",
            },
            .{
                .key = "http.fetch",
                .reason = "Fetches greetings",
            },
            .{
                .key = "newsletter.send",
                .reason = "Mails them",
            },
        },
    };
    const switched = [_]permission.Held{.{
        .key = "records.write",
        .publish = false,
    }};
    const shown = try requests_of(
        arena,
        &manifest,
        &.{"records.write"},
        &.{"http.fetch"},
        &switched,
    );

    try std.testing.expectEqual(Request.State.granted, shown[0].state);
    try std.testing.expectEqual(Request.State.pending, shown[1].state);
    try std.testing.expectEqual(Request.State.denied, shown[2].state);
    try std.testing.expectEqual(Request.State.unavailable, shown[3].state);
    try std.testing.expectEqual(@as(usize, 1), shown[0].flags.len);
    try std.testing.expect(!shown[0].flags[0].on);
    try std.testing.expectEqualStrings("post", shown[0].names[0]);
    try std.testing.expectEqual(permission.Tier.medium, shown[0].tier);
    try std.testing.expectEqual(@as(usize, 2), (try with(arena, &.{"a"}, "b")).len);
    try std.testing.expectEqual(@as(usize, 0), (try without(arena, &.{"a"}, "a")).len);
}

test "a plugin with many operations sharing a large answer is read as a provider in a scratch" {
    const contract = model.contract;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nodes = try arena.alloc(contract.Node, 200);

    nodes[0] = .{
        .parent = -1,
        .kind = .object,
    };

    for (nodes[1..], 1..) |*node, index| {
        node.* = .{
            .parent = 0,
            .name = try std.fmt.allocPrint(arena, "field_{d}", .{index}),
            .kind = .integer,
        };
    }

    const operations = try arena.alloc(sandboxed_plugin.Operation, 60);

    for (operations, 0..) |*operation, index| {
        operation.* = .{
            .name = try std.fmt.allocPrint(arena, "shop.operation_{d}", .{index}),
            .kind = .write,
            .description = "Changes the order",
            .output = nodes,
        };
    }

    var manifest: sandboxed_plugin.Manifest = .{
        .name = "shop",
        .version = "0.1.0",
        .summary = "A shop",
        .operations = operations,
    };

    try sandboxed_plugin.share_shapes(arena, &manifest);

    const text = try std.json.Stringify.valueAlloc(arena, manifest, .{
        .emit_null_optional_fields = false,
    });

    // The answer is written once, not sixty times.
    try std.testing.expect(text.len < 16 << 10);

    var buffer: [256 << 10]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const provided = try parse_provided(fixed.allocator(), text);

    try std.testing.expectEqual(@as(usize, 60), provided.operations.len);
    try std.testing.expectEqual(@as(usize, 200), provided.operations[59].output.len);
    try std.testing.expectEqualStrings("field_199", provided.operations[59].output[199].name);

    const whole = try parse_manifest(arena, text);

    try std.testing.expectEqual(@as(usize, 200), whole.operations[0].output.len);
}
