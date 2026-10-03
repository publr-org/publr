const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const operation = @import("operation.zig");

pub const middleware_max: u32 = 256;

const Error = operation.Error;

/// `display` changes how a value is shown (`display.zig`), never what an operation does.
pub const Stage = enum { pre, before, after, on, display };

pub const Event = union(enum) {
    completed: Completed,
    rejected: Failed,
    failed: Failed,
    notice: Notice,

    pub const Completed = struct {
        operation_name: []const u8,
        operation_id: u64,
        duration_ns: u64,
    };
    pub const Failed = struct {
        operation_name: []const u8,
        operation_id: u64,
        err: operation.Error,
    };
    pub const Notice = struct { operation_id: u64, name: []const u8, subject: []const u8 };
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
            .display => @import("display.zig").validate(Middleware),
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
        pub fn run(_: *Ctx, _: []const u8) Error!void {}
    };
    comptime validate(Before);
    comptime validate(Listener);
    comptime validate(Gate);
}
