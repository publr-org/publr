//! An operation's checks, run once per operation in an evaluation of their own: what they
//! spend is the operation's alone (`budget.zig`), however many others the registry holds.
const std = @import("std");
const operation = @import("../operation.zig");
const budget = @import("budget.zig");
const held = @import("held.zig");

pub fn validate(comptime Operation: type) void {
    _ = Checked(Operation).done;
}

fn Checked(comptime Operation: type) type {
    return struct {
        const done: bool = done: {
            check_declared(Operation);
            @setEvalBranchQuota(budget.of(Operation));
            check_shapes(Operation);

            break :done true;
        };
    };
}

/// What every operation declares, and of which type.
fn check_declared(comptime Operation: type) void {
    comptime {
        assert_decl(Operation, "name", []const u8);
        assert_decl(Operation, "description", []const u8);
        assert_decl(Operation, "kind", operation.Kind);
        assert_decl(Operation, "In", type);
        assert_decl(Operation, "Out", type);

        if (!@hasDecl(Operation, "run")) {
            @compileError(Operation.name ++ ": missing `run`");
        }

        if (!@hasDecl(Operation, "example")) {
            @compileError(Operation.name ++ ": missing `example: In`");
        }

        if (@TypeOf(Operation.example) != Operation.In) {
            @compileError(Operation.name ++ ": `example` must be an `In`");
        }

        if (!@hasDecl(Operation, "example_out")) {
            @compileError(Operation.name ++ ": missing `example_out: Out`");
        }

        assert_decl(Operation, "example_out", Operation.Out);

        if (@hasDecl(Operation, "field_docs")) {
            assert_decl(Operation, "field_docs", operation.Docs(Operation.In));
        }

        if (@hasDecl(Operation, "output_docs")) {
            assert_decl(Operation, "output_docs", operation.Docs(Operation.Out));
        }

        if (@hasDecl(Operation, "details")) {
            assert_decl(Operation, "details", []const u8);
        }

        if (@hasDecl(Operation, "destroys")) {
            assert_decl(Operation, "destroys", bool);

            if (Operation.destroys and Operation.kind != .write) {
                @compileError(Operation.name ++ ": only a write destroys");
            }
        }
    }
}

/// Its name, its shapes, its examples, its deprecation and its failures.
fn check_shapes(comptime Operation: type) void {
    comptime {
        operation.assert_name(Operation.name);
        assert_serialisable(Operation.In);
        assert_serialisable(Operation.Out);

        if (operation.deprecation(Operation)) |found| {
            operation.check_deprecated(Operation.name, found);
        }

        const rules = .{
            operation.values,
            operation.lists,
            operation.shaped,
            operation.json_fields,
        };

        for (rules) |rule| {
            if (rule.problem(Operation)) |message| {
                @compileError(message);
            }
        }

        if (@hasDecl(Operation, "failures")) {
            for (Operation.failures) |failure| {
                if (!operation.valid_failure(failure)) {
                    @compileError(Operation.name ++ ": failure `" ++ failure.name ++ "` needs " ++
                        "a name of letters starting upper-case, a 4xx or 5xx status and a " ++
                        "message of 1 to 200 characters");
                }
            }
        }
    }
}

/// Each type is walked once, whatever holds it: a tree's node is not walked again inside
/// itself.
pub fn assert_serialisable(comptime Type: type) void {
    comptime {
        switch (@typeInfo(Type)) {
            .bool, .int, .float, .void => {},
            .@"enum" => {},
            .optional => |optional| assert_serialisable(optional.child),
            .pointer => |pointer| {
                if (pointer.size != .slice) {
                    @compileError("only slices: " ++ @typeName(Type));
                }

                assert_serialisable(pointer.child);
            },
            .array => |array| assert_serialisable(array.child),
            .@"struct" => |structure| {
                // A reference is written as its id, whatever its record holds; an object
                // whose keys come with the data writes its own JSON.
                if (@hasDecl(Type, "reference") or @hasDecl(Type, "json_object")) {
                    return;
                }

                if (structure.field_names.len > operation.fields_max) {
                    @compileError("too many fields: " ++ @typeName(Type));
                }

                for (structure.field_types) |Field| {
                    if (held.inner_of(Field) != Type) {
                        assert_serialisable(Field);
                    }
                }
            },
            else => @compileError("not serialisable: " ++ @typeName(Type)),
        }
    }
}

fn assert_decl(comptime Operation: type, comptime decl: []const u8, comptime Type: type) void {
    if (!@hasDecl(Operation, decl)) {
        @compileError(@typeName(Operation) ++ ": missing `" ++ decl ++ "`");
    }

    const actual = @TypeOf(@field(Operation, decl));
    const ok = actual == Type or (Type == []const u8 and @typeInfo(actual) == .pointer);

    if (!ok) {
        @compileError(@typeName(Operation) ++ "." ++ decl ++ ": wrong type");
    }
}

test "serialisable types are accepted, pointers to single items rejected at comptime" {
    const Good = struct {
        id: []const u8,
        count: u32,
        ratio: ?f64,
        tags: []const []const u8,
        on: bool,
    };

    comptime assert_serialisable(Good);
    comptime operation.assert_name("hello.record");
}
