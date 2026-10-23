const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const operation = @import("operation.zig");

pub const hooks_max: u32 = 256;

const Error = operation.Error;

/// `modify` changes a value applied under a name (`mods.zig`), never what an operation does.
pub const Stage = enum { pre, before, after, on, modify };

/// An operation's end, refused or failed alike, or an event emitted.
pub const Event = union(enum) {
    completed: Ended,
    failed: Ended,
    emitted: Emitted,

    pub const Ended = struct {
        operation_name: []const u8,
        operation_id: u64,
    };
    /// An event emitted under its name (`<plugin>.<event>`, `role.created`, or an operation's
    /// own on success), its payload as JSON.
    pub const Emitted = struct {
        operation_id: u64,
        name: []const u8,
        subject: []const u8,
    };
};

pub fn validate(comptime Middleware: type) void {
    comptime {
        const type_name = @typeName(Middleware);

        if (!@hasDecl(Middleware, "stage")) {
            @compileError(type_name ++ ": missing `stage`");
        }

        if (!@hasDecl(Middleware, "run")) {
            @compileError(@typeName(Middleware) ++ ": missing `run`");
        }

        switch (Middleware.stage) {
            .before, .after => {
                if (!@hasDecl(Middleware, "operation")) {
                    @compileError(type_name ++ ": missing `operation`");
                }
                operation.assert_name(Middleware.operation);
            },
            .modify => if (!@hasDecl(Middleware, "pattern")) {
                @compileError(@typeName(Middleware) ++ ": a modifier names its `pattern`");
            },
            .pre, .on => {},
        }
    }
}

pub fn applies(comptime Middleware: type, comptime Operation: type) bool {
    comptime {
        if (Middleware.stage != .before and Middleware.stage != .after) {
            return false;
        }

        if (Middleware.operation.len == 0) {
            @compileError(@typeName(Middleware) ++ ": empty op");
        }

        if (Operation.name.len == 0) {
            @compileError(@typeName(Operation) ++ ": empty name");
        }

        return std.mem.eql(u8, Middleware.operation, Operation.name);
    }
}

test "validate accepts a before middleware and an event subscriber" {
    const Before = struct {
        pub const stage: Stage = .before;
        pub const operation = "hello.record";
        pub fn run(_: *Ctx, _: *anyopaque) Error!void {}
    };
    const Listener = struct {
        pub const stage: Stage = .on;
        pub fn run(_: *Ctx, _: Event) void {}
    };
    const Gate = struct {
        pub const stage: Stage = .pre;
        pub fn run(_: *Ctx, _: []const u8, _: operation.Kind) Error!void {}
    };
    comptime validate(Before);
    comptime validate(Listener);
    comptime validate(Gate);
}
