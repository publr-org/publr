//! The shape of an operation's input or output, as data: what one plugin publishes about
//! its operations, and what another declares it sends and reads when it uses one. A shape
//! is a flat list of nodes, the root first, each pointing at the node it sits in.
//!
//! A user's shape is compatible with a provider's when the provider accepts everything the
//! user sends (every field it requires is there, nothing it does not know is), and gives
//! everything the user reads, with the same kinds; the user may read fewer fields than the
//! provider gives.

const std = @import("std");
const input_rule = @import("input_rule.zig");

pub const nodes_max: u32 = 256;
pub const depth_max: u32 = 16;
pub const values_max: u32 = 64;
/// What describing one node costs the compiler at most, in branches: its own turn, and its
/// turns as a child in its parent's two walks over its fields (listed, then queued).
const branches_per_node: u32 = 24;

pub const Kind = enum { string, integer, number, boolean, enumeration, list, object, reference };

pub const Node = struct {
    /// The node it sits in; the root's is -1.
    parent: i32,
    /// Its field name inside an object; `[]` for a list's items; empty for the root.
    name: []const u8 = "",
    kind: Kind,
    /// Whether it may be null.
    optional: bool = false,
    /// Whether the object it sits in requires it: no default, not optional.
    required: bool = true,
    /// An enumeration's values.
    values: []const []const u8 = &.{},
    /// A reference's content type: the caller sends an id, the operation gets the record.
    to: []const u8 = "",
    /// The bounds the operation declares on this field of its input.
    rule: input_rule.Rule = .{},
};

/// The first top-level field of `value` that breaks its rule: `quantity is above its
/// greatest value`, into `buffer`; null when every field keeps to its rule.
pub fn rules_broken(nodes: []const Node, value: std.json.Value, buffer: []u8) ?[]const u8 {
    std.debug.assert(nodes.len > 0 and nodes.len <= nodes_max);
    std.debug.assert(buffer.len >= 64);

    if (value != .object) {
        return null;
    }

    for (nodes) |node| {
        if (node.parent != 0 or node.rule.empty()) {
            continue;
        }

        const field = value.object.get(node.name) orelse continue;
        const why = input_rule.broken(node.rule, field) orelse continue;

        return std.fmt.bufPrint(buffer, "{s} {s}", .{ node.name, why }) catch buffer[0..0];
    }

    return null;
}

pub const Reason = enum { missing, unknown, kind, nullable, value };

/// Where two shapes disagree: a node of the user's side (or of the provider's, for a field
/// the user leaves out), and why.
pub const Problem = struct { node: u32, on_user_side: bool, reason: Reason };

/// The shape of a type an operation takes or answers, built when it compiles: one pass,
/// breadth first, each node written once into a fixed-size list.
pub fn describe(comptime Type: type) []const Node {
    comptime {
        // A node costs a few branches when it is described (its turn of the loop, one per
        // field or enum value it holds): the budget follows from the node limit, so a
        // shape small enough to describe is never cut short.
        @setEvalBranchQuota(nodes_max * branches_per_node);

        const Pending = struct { type: type, parent: i32, name: []const u8, required: bool };
        var pending: [nodes_max]Pending = undefined;
        var nodes: [nodes_max]Node = undefined;
        var queued: u32 = 1;
        var count: u32 = 0;

        pending[0] = .{ .type = Type, .parent = -1, .name = "", .required = true };

        while (count < queued) : (count += 1) {
            const next = pending[count];
            const unwrapped = unwrap(next.type);

            nodes[count] = .{
                .parent = next.parent,
                .name = next.name,
                .kind = kind_of(unwrapped.type),
                .optional = unwrapped.optional,
                .required = next.required,
                .values = values_of(unwrapped.type),
                .to = reference_to(unwrapped.type),
            };

            for (children_of(unwrapped.type)) |child| {
                if (queued == nodes_max) {
                    @compileError("contract: " ++ @typeName(Type) ++ " is too large to describe");
                }

                pending[queued] = .{
                    .type = child.type,
                    .parent = @intCast(count),
                    .name = child.name,
                    .required = child.required,
                };
                queued += 1;
            }
        }

        const described = nodes[0..count].*;

        return &described;
    }
}

const Child = struct { type: type, name: []const u8, required: bool };

/// What sits inside a type: an object's fields, a list's items; nothing for a scalar.
fn children_of(comptime Type: type) []const Child {
    comptime {
        std.debug.assert(@typeInfo(Type) != .void);

        return switch (@typeInfo(Type)) {
            .pointer => |info| if (info.child == u8)
                &.{}
            else
                &.{.{ .type = info.child, .name = "[]", .required = true }},
            .@"struct" => |info| if (@hasDecl(Type, "reference")) &.{} else fields: {
                var children: [info.fields.len]Child = undefined;

                for (info.fields, &children) |field, *child| {
                    const optional = @typeInfo(field.type) == .optional;

                    child.* = .{
                        .type = field.type,
                        .name = field.name,
                        .required = field.default_value_ptr == null and !optional,
                    };
                }

                const fixed = children;

                break :fields &fixed;
            },
            else => &.{},
        };
    }
}

fn reference_to(comptime Type: type) []const u8 {
    comptime {
        std.debug.assert(@typeInfo(Type) != .void);

        const is_struct = @typeInfo(Type) == .@"struct";

        return if (is_struct and @hasDecl(Type, "reference")) Type.handle else "";
    }
}

fn values_of(comptime Type: type) []const []const u8 {
    comptime {
        std.debug.assert(@typeInfo(Type) != .void);

        const info = switch (@typeInfo(Type)) {
            .@"enum" => |info| info,
            else => return &.{},
        };
        var names: [info.fields.len][]const u8 = undefined;

        for (info.fields, &names) |field, *name| {
            name.* = field.name;
        }

        const fixed = names;

        return &fixed;
    }
}

fn unwrap(comptime Type: type) struct { type: type, optional: bool } {
    comptime {
        std.debug.assert(@typeInfo(Type) != .void);

        return switch (@typeInfo(Type)) {
            .optional => |info| .{ .type = info.child, .optional = true },
            else => .{ .type = Type, .optional = false },
        };
    }
}

fn kind_of(comptime Type: type) Kind {
    comptime {
        return switch (@typeInfo(Type)) {
            .int, .comptime_int => .integer,
            .float, .comptime_float => .number,
            .bool => .boolean,
            .@"enum" => .enumeration,
            .@"struct" => if (@hasDecl(Type, "reference")) .reference else .object,
            .pointer => |info| if (info.size == .slice and info.child == u8) .string else .list,
            else => @compileError("contract: " ++ @typeName(Type) ++ " has no JSON shape"),
        };
    }
}

/// Whether a provider accepts what a user sends: every field it requires is sent, every
/// field sent is one it knows, kinds agree, nothing it refuses as null may be null.
pub fn check_input(sent: []const Node, accepted: []const Node) ?Problem {
    std.debug.assert(sent.len > 0 and sent.len <= nodes_max);
    std.debug.assert(accepted.len > 0 and accepted.len <= nodes_max);

    for (sent, 0..) |node, index| {
        const provider = counterpart(sent, @intCast(index), accepted) orelse {
            return .{ .node = @intCast(index), .on_user_side = true, .reason = .unknown };
        };
        const theirs = accepted[provider];

        if (theirs.kind != node.kind or !std.mem.eql(u8, theirs.to, node.to)) {
            return .{ .node = @intCast(index), .on_user_side = true, .reason = .kind };
        }

        if (node.optional and !theirs.optional) {
            return .{ .node = @intCast(index), .on_user_side = true, .reason = .nullable };
        }

        if (!subset(node.values, theirs.values)) {
            return .{ .node = @intCast(index), .on_user_side = true, .reason = .value };
        }
    }

    for (accepted, 0..) |node, index| {
        if (index == 0 or !node.required) {
            continue;
        }

        const parent: u32 = @intCast(node.parent);
        const parent_sent = counterpart(accepted, parent, sent) != null;

        if (parent_sent and counterpart(accepted, @intCast(index), sent) == null) {
            return .{ .node = @intCast(index), .on_user_side = false, .reason = .missing };
        }
    }

    return null;
}

/// Whether a provider gives what a user reads: every field read is given, kinds agree,
/// nothing the user takes as present may be null, every value given is one the user knows.
pub fn check_output(read: []const Node, given: []const Node) ?Problem {
    std.debug.assert(read.len > 0 and read.len <= nodes_max);
    std.debug.assert(given.len > 0 and given.len <= nodes_max);

    for (read, 0..) |node, index| {
        const provider = counterpart(read, @intCast(index), given) orelse {
            return .{ .node = @intCast(index), .on_user_side = true, .reason = .missing };
        };
        const theirs = given[provider];

        if (theirs.kind != node.kind or !std.mem.eql(u8, theirs.to, node.to)) {
            return .{ .node = @intCast(index), .on_user_side = true, .reason = .kind };
        }

        if (theirs.optional and !node.optional) {
            return .{ .node = @intCast(index), .on_user_side = true, .reason = .nullable };
        }

        if (!subset(theirs.values, node.values)) {
            return .{ .node = @intCast(index), .on_user_side = true, .reason = .value };
        }
    }

    return null;
}

/// The node of `other` at the same path as `nodes[index]`: the same field names from the
/// root down.
fn counterpart(nodes: []const Node, index: u32, other: []const Node) ?u32 {
    std.debug.assert(index < nodes.len);
    std.debug.assert(other.len <= nodes_max);

    for (0..other.len) |candidate| {
        if (same_path(nodes, index, other, @intCast(candidate))) {
            return @intCast(candidate);
        }
    }

    return null;
}

fn same_path(left: []const Node, left_index: u32, right: []const Node, right_index: u32) bool {
    std.debug.assert(left_index < left.len);
    std.debug.assert(right_index < right.len);

    var at_left: i32 = @intCast(left_index);
    var at_right: i32 = @intCast(right_index);

    for (0..depth_max + 1) |_| {
        if (at_left < 0 or at_right < 0) {
            return at_left < 0 and at_right < 0;
        }

        const one = left[@intCast(at_left)];
        const two = right[@intCast(at_right)];

        if (!std.mem.eql(u8, one.name, two.name)) {
            return false;
        }

        at_left = one.parent;
        at_right = two.parent;
    }

    return false;
}

fn subset(some: []const []const u8, all: []const []const u8) bool {
    std.debug.assert(some.len <= values_max or all.len <= values_max);

    for (some) |value| {
        var found = false;

        for (all) |candidate| {
            found = found or std.mem.eql(u8, value, candidate);
        }

        if (!found) {
            return false;
        }
    }

    return true;
}

/// A node's path from the root, `items[].sku`, into `buffer`.
pub fn path_of(nodes: []const Node, index: u32, buffer: []u8) []const u8 {
    std.debug.assert(index < nodes.len);
    std.debug.assert(buffer.len > 0);

    var names: [depth_max][]const u8 = undefined;
    var count: u32 = 0;
    var at: i32 = @intCast(index);

    while (at > 0 and count < depth_max) : (count += 1) {
        names[count] = nodes[@intCast(at)].name;
        at = nodes[@intCast(at)].parent;
    }

    var writer = std.Io.Writer.fixed(buffer);

    while (count > 0) {
        count -= 1;

        const name = names[count];
        const separator = writer.end > 0 and !std.mem.eql(u8, name, "[]");

        if (separator) {
            writer.writeByte('.') catch break;
        }

        writer.writeAll(name) catch break;
    }

    return buffer[0..writer.end];
}

pub fn reason_text(reason: Reason) []const u8 {
    std.debug.assert(@intFromEnum(reason) <= @intFromEnum(Reason.value));

    return switch (reason) {
        .missing => "is not there",
        .unknown => "is not one the provider knows",
        .kind => "is of another kind",
        .nullable => "may be null",
        .value => "has a value the other side does not know",
    };
}

test "shapes: described from types, compatible as subsets" {
    const Provider = struct {
        sku: []const u8,
        quantity: u32,
        note: ?[]const u8 = null,
        lines: []const struct { id: []const u8, size: enum { small, large } } = &.{},
    };
    const Sends = struct { sku: []const u8, quantity: u32 };
    const Forgets = struct { sku: []const u8 };
    const Invents = struct { sku: []const u8, quantity: u32, colour: []const u8 };
    const Retyped = struct { sku: []const u8, quantity: []const u8 };

    const provider = comptime describe(Provider);

    try std.testing.expectEqual(Kind.object, provider[0].kind);
    try std.testing.expect(check_input(comptime describe(Sends), provider) == null);
    const forgets = check_input(comptime describe(Forgets), provider).?;
    const invents = check_input(comptime describe(Invents), provider).?;
    const retyped = check_input(comptime describe(Retyped), provider).?;

    try std.testing.expectEqual(Reason.missing, forgets.reason);
    try std.testing.expectEqual(Reason.unknown, invents.reason);
    try std.testing.expectEqual(Reason.kind, retyped.reason);

    const Reads = struct { lines: []const struct { size: enum { small, large, huge } } };
    const ReadsTooFew = struct { lines: []const struct { size: enum { small } } };
    const ReadsAbsent = struct { total: u32 };

    try std.testing.expect(check_output(comptime describe(Reads), provider) == null);
    const too_few = check_output(comptime describe(ReadsTooFew), provider).?;
    const absent = check_output(comptime describe(ReadsAbsent), provider).?;

    try std.testing.expectEqual(Reason.value, too_few.reason);
    try std.testing.expectEqual(Reason.missing, absent.reason);

    var buffer: [128]u8 = undefined;
    const read = comptime describe(ReadsAbsent);

    try std.testing.expectEqualStrings("total", path_of(read, absent.node, &buffer));
}
