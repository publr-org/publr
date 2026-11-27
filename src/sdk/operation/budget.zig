//! What one operation's checks may spend at compile time, from what it declares. Each walk
//! over its input and output reads a field once, so the walks' branches follow the fields
//! the shapes hold; the rest follows its doc lines, its failures and its declarations.
const std = @import("std");
const public = @import("../../publr/operation.zig");
const held = @import("held.zig");
const values = @import("values.zig");

/// Branches the checks take whatever the operation holds: its declarations looked up, its
/// name read a byte at a time.
const branches_base: u32 = 1000 + 4 * public.name_len_max;
/// Branches the walks over a shape take for one field they read, all of them together
/// (`assert_serialisable`, `lists`, `json_fields`), what it holds looked through.
const branches_per_field: u32 = 64;
/// Branches reading one failure take: its name a letter at a time.
const branches_per_failure: u32 = public.failure_name_len_max + 8;
/// Branches comparing one declaration with its public shape's (`shaped`) take.
const branches_per_declaration: u32 = 64;
/// Branches counting one field of a struct take: what it holds looked through, its count read.
const branches_per_count: u32 = 16;

/// The most branches `Operation`'s checks take.
pub fn of(comptime Operation: type) u32 {
    comptime {
        std.debug.assert(Operation.name.len > 0);

        const fields = fields_in(Operation.In) +| fields_in(Operation.Out);
        const lines = own_fields(Operation.In) + own_fields(Operation.Out);
        const failures: u32 = if (@hasDecl(Operation, "failures")) Operation.failures.len else 0;
        const declarations: u32 = @typeInfo(Operation).@"struct".decl_names.len;
        const spent = branches_base +| fields *| branches_per_field +|
            lines *| values.doc_len_max +| failures *| branches_per_failure +|
            declarations *| branches_per_declaration;

        std.debug.assert(spent >= branches_base);

        return spent;
    }
}

/// The fields a walk over `Type` reads: each struct's own and those of what each holds, a
/// tree's node not again inside itself (`held`). Each type is counted once, in an
/// evaluation of its own, so a count costs the branches of one struct's fields.
pub fn fields_in(comptime Type: type) u32 {
    return Count(Type).fields;
}

fn Count(comptime Type: type) type {
    return struct {
        const fields: u32 = count: {
            @setEvalBranchQuota(1000 + public.fields_max * branches_per_count);

            break :count switch (@typeInfo(Type)) {
                .optional => |optional| fields_in(optional.child),
                .pointer => |pointer| fields_in(pointer.child),
                .array => |array| fields_in(array.child),
                .@"union" => |choice| sum: {
                    var total: u32 = 0;

                    for (choice.field_types) |Field| {
                        total +|= fields_in(Field);
                    }

                    break :sum total;
                },
                .@"struct" => struct_fields(Type),
                else => 0,
            };
        };
    };
}

fn struct_fields(comptime Type: type) u32 {
    comptime {
        const structure = @typeInfo(Type).@"struct";

        std.debug.assert(structure.field_names.len == structure.field_types.len);

        // A reference is written as its id; an object whose keys come with the data writes
        // its own JSON: neither is walked into.
        if (@hasDecl(Type, "reference") or @hasDecl(Type, "json_object")) {
            return 0;
        }

        var total: u32 = structure.field_names.len;

        for (structure.field_types) |Field| {
            if (held.inner_of(Field) != Type) {
                total +|= fields_in(Field);
            }
        }

        return total;
    }
}

/// The fields `Type` itself holds, when it is a struct: those a doc line may be read for.
fn own_fields(comptime Type: type) u32 {
    return switch (@typeInfo(Type)) {
        .@"struct" => |structure| structure.field_names.len,
        else => 0,
    };
}

test "a shape's fields are counted through lists and optionals, a tree's node once" {
    const Node = struct {
        name: []const u8,
        children: []const @This() = &.{},
    };
    const Shape = struct {
        id: []const u8,
        root: ?Node,
        nodes: []const Node,
    };

    try std.testing.expectEqual(@as(u32, 2), comptime fields_in(Node));
    try std.testing.expectEqual(@as(u32, 7), comptime fields_in(Shape));
    try std.testing.expectEqual(@as(u32, 0), comptime fields_in([]const u8));
}
