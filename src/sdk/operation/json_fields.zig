//! The rule that an operation of Publr's hands over `operation.Json` only where the shape
//! comes with the data: a record's document, a job's input, a query's result. Where the shape
//! is Publr's own (a definition, a list of fields), the field is that type, a value laid out
//! like every other. A `Json` field, at any depth of `In` or `Out`, is named after what it
//! holds, from this list; any other name does not build.
const std = @import("std");
const Json = @import("../../publr/operation/json.zig").Json;
const held = @import("held.zig");

/// The names a `Json` field may have, each a value whose shape someone else decides.
pub const data_names = [_][]const u8{
    // A record's, a term's or an internal record's fields, as its type says.
    "document",
    "documents",
    // Custom field values, a modifier's values: as the fields or the modifier say.
    "values",
    // What a job, a failed call or an activity entry was given, as its operation says.
    "input",
    "answer",
    // A provider's answers, as its contract says.
    "answers",
    // A query, its parameters and its result, as the query says.
    "query",
    "params",
    "result",
    // A copy's rows, as its table says.
    "rows",
    // A transition's changes to the record, as its type says.
    "changes",
    // A design system's tokens and the system itself, as the designer made them.
    "tokens",
    "system",
    // A browser agent's tool call, as the tool says.
    "call",
    // The translations a person picked, keyed by the strings they replace.
    "chosen_translations",
};

/// The first `Json` field of `Operation` under a name not in `data_names`, as the compiler
/// says it, or null.
pub fn problem(comptime Operation: type) ?[]const u8 {
    comptime {
        std.debug.assert(Operation.name.len > 0);

        const in = misnamed_in(Operation.In);
        const out = misnamed_in(Operation.Out);
        const side = if (in != null) "input" else "output";
        const found = (if (in != null) in else out) orelse return null;

        return Operation.name ++ ": its " ++ side ++ "'s `" ++ found ++ "` is `operation.Json`, " ++
            "for a value whose shape comes with the data (" ++ "`document`, `values`, " ++
            "`query`: `sdk/operation/json_fields.zig`); a shape of Publr's is its own type";
    }
}

/// Walked once per type, whatever holds it: a tree's node is not walked again inside itself.
fn misnamed_in(comptime Type: type) ?[]const u8 {
    comptime {
        std.debug.assert(@typeInfo(Type) != .type);

        switch (@typeInfo(Type)) {
            .optional => |optional| return misnamed_in(optional.child),
            .pointer => |pointer| return misnamed_in(pointer.child),
            .@"union" => |choice| {
                for (choice.field_types) |Field| {
                    if (misnamed_in(Field)) |found| {
                        return found;
                    }
                }

                return null;
            },
            .@"struct" => |structure| {
                if (Type == Json or @hasDecl(Type, "reference")) {
                    return null;
                }

                for (structure.field_names, structure.field_types) |name, Field| {
                    if (holds_json(Field) and !data_name(name)) {
                        return name;
                    }

                    if (held.inner_of(Field) != Type) {
                        if (misnamed_in(Field)) |found| {
                            return found;
                        }
                    }
                }

                return null;
            },
            else => return null,
        }
    }
}

/// Whether a field of `Field` holds `Json`: itself, a list of them, or one that may be left.
fn holds_json(comptime Field: type) bool {
    comptime {
        std.debug.assert(@typeInfo(Field) != .type);

        return switch (@typeInfo(Field)) {
            .optional => |optional| holds_json(optional.child),
            .pointer => |pointer| pointer.size == .slice and pointer.child == Json,
            else => Field == Json,
        };
    }
}

fn data_name(comptime name: []const u8) bool {
    comptime {
        std.debug.assert(name.len > 0);

        for (data_names) |allowed| {
            if (std.mem.eql(u8, allowed, name)) {
                return true;
            }
        }

        return false;
    }
}

test "a Json field passes under a data name and fails under another" {
    const Document = struct {
        pub const name = "test.document";
        pub const In = struct {
            document: Json,
            documents: []const Json = &.{},
        };
        pub const Out = struct {
            done: bool,
        };
    };
    const Definition = struct {
        pub const name = "test.definition";
        pub const In = struct {};
        pub const Out = struct {
            item: struct {
                definition: ?Json,
            },
        };
    };

    try std.testing.expect(comptime problem(Document) == null);
    const refused = comptime problem(Definition).?;

    try std.testing.expect(std.mem.indexOf(u8, refused, "`definition`") != null);
}
