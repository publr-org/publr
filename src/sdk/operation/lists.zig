//! The rule that no operation is handed, or hands back, a list of any length in one piece:
//! every list of an operation's input or output holds at most a page, 200, unless the struct
//! holding it says fewer in a `limits` declaration:
//!
//!     pub const In = struct {
//!         tags: []const []const u8,
//!
//!         pub const limits = .{ .tags = 20 };
//!     };
//!
//! A struct inside a list or a field follows the same rule, its own `limits` beside it. A
//! list that moves a site's data in one piece (a migration's units) names its limit past a
//! page in `bulk_limits`, up to `bulk_max`.
//! What may be longer than a page is answered a page at a time: the operation takes `after`
//! and answers `next`. A limit past a page does not build; an input past its limit is
//! refused before the operation runs, an answer past it fails the call.

const std = @import("std");
const held = @import("held.zig");

/// The most items a list of an operation may hold: one page.
pub const items_max: u32 = 200;
/// How deep the rule follows structs inside lists and fields.
const depth_max: u32 = 8;
/// The longest `next` an operation answering a page at a time may hand back.
pub const next_bytes_max: u32 = 256;

/// Whether `Operation` answers a page at a time: `after: []const u8` in its input (empty for
/// the first page), `next: []const u8` in its answer (empty after the last).
pub fn paged(comptime Operation: type) bool {
    comptime {
        std.debug.assert(@typeInfo(Operation.In) == .@"struct");

        const after = @hasField(Operation.In, "after") and
            @FieldType(Operation.In, "after") == []const u8;
        const next = @hasField(Operation.Out, "next") and
            @FieldType(Operation.Out, "next") == []const u8;

        return after and next;
    }
}

/// Half of the page convention, which a caller walking the pages could not use.
fn half_paged(comptime Operation: type) bool {
    comptime {
        std.debug.assert(@typeInfo(Operation.Out) == .@"struct");

        const after = @hasField(Operation.In, "after") and
            @FieldType(Operation.In, "after") == []const u8;
        const next = @hasField(Operation.Out, "next") and
            @FieldType(Operation.Out, "next") == []const u8;

        return after != next;
    }
}

/// The limit `Holder` sets for its list `name`: what it declares, or a page.
pub fn limit_of(comptime Holder: type, comptime name: []const u8) u32 {
    comptime {
        std.debug.assert(name.len > 0);

        if (@hasDecl(Holder, "bulk_limits") and @hasField(@TypeOf(Holder.bulk_limits), name)) {
            return @field(Holder.bulk_limits, name);
        }

        if (!@hasDecl(Holder, "limits") or !@hasField(@TypeOf(Holder.limits), name)) {
            return items_max;
        }

        const limit: u32 = @field(Holder.limits, name);

        std.debug.assert(limit <= items_max);

        return limit;
    }
}

/// The most a list moving a site's data in one piece may hold (`bulk_limits`): what one
/// migration's call carries, never a list a page reads.
pub const bulk_max: u32 = 65_536;

/// Whether `Type` is text: the one slice that is a value, not a list.
fn is_text(comptime Type: type) bool {
    return Type == []const u8 or Type == []u8;
}

/// A value of its own making that holds no list the rule reads: a reference, a JSON value.
fn opaque_struct(comptime Type: type) bool {
    return @hasDecl(Type, "reference") or @hasDecl(Type, "json_object") or
        @typeInfo(Type).@"struct".is_tuple;
}

/// The item type when `Field` is a list (optional or not), text excluded.
fn list_child(comptime Field: type) ?type {
    comptime {
        std.debug.assert(@typeInfo(Field) != .type);

        const Plain = switch (@typeInfo(Field)) {
            .optional => |optional| optional.child,
            else => Field,
        };

        if (is_text(Plain)) {
            return null;
        }

        return switch (@typeInfo(Plain)) {
            .pointer => |pointer| if (pointer.size == .slice) pointer.child else null,
            else => null,
        };
    }
}

/// What is wrong with the `limits` of `Type` or of a struct inside it, as `lines: 300`, or
/// null: a limit past a page, of none, or naming no list.
pub fn misdeclared_in(comptime Type: type, comptime depth: u32) ?[]const u8 {
    comptime {
        std.debug.assert(depth <= depth_max + 1);

        if (depth > depth_max) {
            return null;
        }

        switch (@typeInfo(Type)) {
            .optional => |optional| return misdeclared_in(optional.child, depth + 1),
            .pointer => |pointer| {
                if (pointer.size != .slice or is_text(Type)) {
                    return null;
                }

                return misdeclared_in(pointer.child, depth + 1);
            },
            .@"union" => |choice| {
                for (choice.field_types) |Field| {
                    if (misdeclared_in(Field, depth + 1)) |found| {
                        return found;
                    }
                }

                return null;
            },
            .@"struct" => |structure| {
                // Each field costs a few branches, and so does each field of what it holds.
                @setEvalBranchQuota(1000 + 100 * structure.field_names.len * (depth_max + 1));

                if (opaque_struct(Type)) {
                    return null;
                }

                if (@hasDecl(Type, "limits")) {
                    const declared = @typeInfo(@TypeOf(Type.limits)).@"struct".field_names;

                    for (declared) |name| {
                        const limit: u32 = @field(Type.limits, name);
                        const listed = @hasField(Type, name) and
                            list_child(@FieldType(Type, name)) != null;

                        if (!listed or limit == 0 or limit > items_max) {
                            return std.fmt.comptimePrint("{s}: {d}", .{ name, limit });
                        }
                    }
                }

                // Past a page only by name, for moving a site's data in one piece.
                if (@hasDecl(Type, "bulk_limits")) {
                    const declared = @typeInfo(@TypeOf(Type.bulk_limits)).@"struct".field_names;

                    for (declared) |name| {
                        const limit: u32 = @field(Type.bulk_limits, name);
                        const listed = @hasField(Type, name) and
                            list_child(@FieldType(Type, name)) != null;

                        if (!listed or limit <= items_max or limit > bulk_max) {
                            return std.fmt.comptimePrint("{s}: {d}", .{ name, limit });
                        }
                    }
                }

                // A tree's node inside itself (a field's `fields`) is the node already read.
                for (structure.field_types) |Field| {
                    if (held.inner_of(Field) == Type) {
                        continue;
                    }

                    if (misdeclared_in(Field, depth + 1)) |found| {
                        return found;
                    }
                }

                return null;
            },
            else => return null,
        }
    }
}

/// What breaks the rule in `Operation`'s declarations, for the compiler to say, or null.
pub fn problem(comptime Operation: type) ?[]const u8 {
    comptime {
        std.debug.assert(Operation.name.len > 0);

        if (half_paged(Operation)) {
            return Operation.name ++ ": an operation answering a page at a time takes " ++
                "`after: []const u8 = \"\"` and answers `next: []const u8`, both or neither";
        }

        const in = misdeclared_in(Operation.In, 0);
        const out = misdeclared_in(Operation.Out, 0);
        const side = if (in != null) "input" else "output";
        const either: ?[]const u8 = if (in != null) in else out;
        const found = either orelse return null;

        std.debug.assert(found.len > 0);

        return Operation.name ++ ": `limits` of its " ++ side ++ " says `" ++ found ++
            "`; a limit names a list and is 1 to 200. A list that may hold more is " ++
            "answered a page at a time (`after` in, `next` out)";
    }
}

/// Whether a value of `Type` may hold a list: the check walks only what can.
fn holds_list(comptime Type: type, comptime depth: u32) bool {
    comptime {
        std.debug.assert(depth <= depth_max + 1);

        if (depth > depth_max) {
            return false;
        }

        const inner: []const type = switch (@typeInfo(Type)) {
            .optional => |optional| &.{optional.child},
            .pointer => |pointer| return pointer.size == .slice and !is_text(Type),
            .@"union" => |choice| choice.field_types,
            .@"struct" => |structure| if (opaque_struct(Type)) &.{} else structure.field_types,
            else => &.{},
        };

        for (inner) |Inner| {
            if (holds_list(Inner, depth + 1)) {
                return true;
            }
        }

        return false;
    }
}

/// A list holding more than its limit: where it lies and what its limit is.
pub const Over = struct {
    path: []const u8,
    limit: u32,
};

/// The first list in `value` past its limit, or null.
pub fn over_limit(comptime Type: type, value: *const Type) ?Over {
    return over_at(Type, value, "", 0);
}

fn over_at(
    comptime Type: type,
    value: *const Type,
    comptime prefix: []const u8,
    comptime depth: u32,
) ?Over {
    if (comptime !holds_list(Type, depth)) {
        return null;
    }

    switch (@typeInfo(Type)) {
        .optional => |optional| {
            const inner = &(value.* orelse return null);

            return over_at(optional.child, inner, prefix, depth + 1);
        },
        .pointer => |pointer| {
            for (value.*) |*item| {
                if (over_at(pointer.child, item, prefix, depth + 1)) |found| {
                    return found;
                }
            }

            return null;
        },
        .@"union" => switch (value.*) {
            inline else => |*payload, tag| {
                const Payload = @TypeOf(payload.*);
                const inner_prefix = prefix ++ @tagName(tag) ++ ".";

                return over_at(Payload, payload, inner_prefix, depth + 1);
            },
        },
        .@"struct" => |structure| {
            inline for (structure.field_names, structure.field_types) |name, Field| {
                const field = &@field(value.*, name);

                if (comptime list_child(Field) != null) {
                    const limit = comptime limit_of(Type, name);
                    const count: u64 = list_len(Field, field);

                    if (count > limit) {
                        return .{
                            .path = prefix ++ name,
                            .limit = limit,
                        };
                    }
                }

                if (over_at(Field, field, prefix ++ name ++ ".", depth + 1)) |found| {
                    return found;
                }
            }

            return null;
        },
        else => return null,
    }
}

fn list_len(comptime Field: type, field: *const Field) u64 {
    return switch (@typeInfo(Field)) {
        .optional => if (field.*) |list| list.len else 0,
        else => field.len,
    };
}

test "every list holds a page unless it says fewer, at every depth" {
    const Line = struct {
        tags: []const []const u8,
        note: []const u8,

        pub const limits = .{
            .tags = 2,
        };
    };
    const Order = struct {
        lines: []const Line,
        ids: ?[]const []const u8 = null,
        name: []const u8 = "",
    };
    const tags = [_][]const u8{ "a", "b", "c" };
    const ids: [201][]const u8 = @splat("x");
    const fine = [_]Line{.{
        .tags = tags[0..2],
        .note = "kept",
    }};
    const tagged = [_]Line{.{
        .tags = &tags,
        .note = "kept",
    }};

    try std.testing.expect(over_limit(Order, &.{
        .lines = &fine,
    }) == null);

    const deep = over_limit(Order, &.{
        .lines = &tagged,
    }).?;

    try std.testing.expectEqualStrings("lines.tags", deep.path);
    try std.testing.expectEqual(@as(u32, 2), deep.limit);

    const long = over_limit(Order, &.{
        .lines = &fine,
        .ids = &ids,
    }).?;

    try std.testing.expectEqualStrings("ids", long.path);
    try std.testing.expectEqual(items_max, long.limit);
}

test "a limit names a list and is 1 to 200" {
    const Past = struct {
        ids: []const []const u8,

        pub const limits = .{
            .ids = 201,
        };
    };
    const Text = struct {
        name: []const u8,

        pub const limits = .{
            .name = 20,
        };
    };
    const Inner = struct {
        rows: []const struct {
            ids: []const []const u8,

            pub const limits = .{
                .ids = 0,
            };
        },
    };
    const Fine = struct {
        ids: ?[]const []const u8,

        pub const limits = .{
            .ids = 200,
        };
    };

    try std.testing.expectEqualStrings("ids: 201", comptime misdeclared_in(Past, 0).?);
    try std.testing.expectEqualStrings("name: 20", comptime misdeclared_in(Text, 0).?);
    try std.testing.expectEqualStrings("ids: 0", comptime misdeclared_in(Inner, 0).?);
    try std.testing.expect(comptime misdeclared_in(Fine, 0) == null);

    const Moved = struct {
        units: []const []const u8,

        pub const bulk_limits = .{
            .units = 10_000,
        };
    };
    const Small = struct {
        units: []const []const u8,

        pub const bulk_limits = .{
            .units = 100,
        };
    };
    const units: [300][]const u8 = @splat("x");

    try std.testing.expect(comptime misdeclared_in(Moved, 0) == null);
    try std.testing.expectEqualStrings("units: 100", comptime misdeclared_in(Small, 0).?);
    try std.testing.expect(over_limit(Moved, &.{
        .units = &units,
    }) == null);
}
