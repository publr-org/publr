//! A core operation whose shape is public (`pub const shape = public.Text;`, from
//! `src/publr/operations/`) declares every part of it, each the shape's own, and nothing
//! public beside them but `run`: a part added to the shape is never left out, and none is
//! defined in core.

const std = @import("std");

pub fn problem(comptime Operation: type) ?[]const u8 {
    comptime {
        std.debug.assert(Operation.name.len > 0);

        if (!@hasDecl(Operation, "shape")) {
            return null;
        }

        const Shape = Operation.shape;

        if (@hasDecl(Shape, "run")) {
            return Operation.name ++ ": its public shape holds a `run`, which stays in core";
        }

        for (@typeInfo(Shape).@"struct".decl_names) |decl_name| {
            if (!@hasDecl(Operation, decl_name)) {
                return Operation.name ++ ": misses `" ++ decl_name ++ "` of its shape: " ++
                    "`pub const " ++ decl_name ++ " = shape." ++ decl_name ++ ";`";
            }

            if (!same(Operation, Shape, decl_name)) {
                return Operation.name ++ ": its `" ++ decl_name ++ "` is not its shape's";
            }
        }

        for (@typeInfo(Operation).@"struct".decl_names) |decl_name| {
            const own = std.mem.eql(u8, decl_name, "shape") or std.mem.eql(u8, decl_name, "run");

            if (!own and !@hasDecl(Shape, decl_name)) {
                return Operation.name ++ ": `" ++ decl_name ++ "` is not in its public " ++
                    "shape; define it there";
            }
        }

        return null;
    }
}

fn same(comptime Operation: type, comptime Shape: type, comptime name: []const u8) bool {
    comptime {
        std.debug.assert(name.len > 0);

        const Own = @TypeOf(@field(Operation, name));

        if (Own != @TypeOf(@field(Shape, name))) {
            return false;
        }

        return Own != type or @field(Operation, name) == @field(Shape, name);
    }
}

test "an operation declaring its shape's parts passes, one missing or added fails" {
    const Shape = struct {
        pub const name = "test.shaped";
        pub const In = struct {};
    };
    const Whole = struct {
        pub const shape = Shape;
        pub const name = shape.name;
        pub const In = shape.In;
        pub fn run() void {}
    };
    const Missing = struct {
        pub const shape = Shape;
        pub const name = shape.name;
    };
    const Added = struct {
        pub const shape = Shape;
        pub const name = shape.name;
        pub const In = shape.In;
        pub const limit_max: u32 = 2;
    };
    const Other = struct {
        pub const shape = Shape;
        pub const name = shape.name;
        pub const In = struct {};
    };

    try std.testing.expectEqual(null, comptime problem(Whole));
    try std.testing.expect(comptime problem(Missing) != null);
    try std.testing.expect(comptime problem(Added) != null);
    try std.testing.expect(comptime problem(Other) != null);
}
