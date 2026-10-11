//! What runs the admin views' compiled expressions while a page renders: the same
//! JavaScript the browser runs after hydration, so the first render and the live page
//! agree. One QuickJS heap per render, made when the first expression needs it, its
//! memory bounded by the engine (`vm.zig`), not taken from the request's arena.
const std = @import("std");
const runtime = @import("runtime");
const engine = @import("../template/javascript/vm.zig");

/// A module's slot table, made once per state a render instance hands over.
const Table = struct {
    state: u64,
    state_len: u64,
    module: []const u8,
    value: engine.Value,
};

const tables_max: u32 = 4096;
/// One call's scope and answer: a list's row, a value. A larger one goes to the arena.
const scratch_bytes: u32 = 128 << 10;

pub const Runner = struct {
    arena: std.mem.Allocator,
    /// The views' compiled expressions as bytecode (`scripts/expressions_bytecode.zig`).
    bytecode: []const u8,
    /// The path the project is served under, for `Publr.url` in an expression.
    base: []const u8 = "",
    /// The person's catalogue as a script, for `Publr.t` in an expression; empty: English.
    catalogue: []const u8 = "",
    vm: ?*engine.VM = null,
    make_table: engine.Value = undefined,
    call: engine.Value = undefined,
    tables: std.ArrayList(Table) = .empty,
    scratch: std.heap.FixedBufferAllocator = .init(&.{}),
    expressions: runtime.Expressions,

    /// A runner whose `expressions` the render hands down in the request.
    pub fn create(arena: std.mem.Allocator, bytecode: []const u8) error{OutOfMemory}!*Runner {
        std.debug.assert(bytecode.len <= 64 << 20);

        const runner = try arena.create(Runner);

        runner.* = .{
            .arena = arena,
            .bytecode = bytecode,
            .expressions = .{
                .context = runner,
                .scratch = scratch_of,
                .reset = reset,
                .run = run,
            },
        };

        std.debug.assert(runner.expressions.context == @as(*anyopaque, runner));

        return runner;
    }

    pub fn deinit(runner: *Runner) void {
        std.debug.assert(runner.expressions.context == @as(*anyopaque, runner));

        if (runner.vm) |vm| {
            for (runner.tables.items) |made| {
                vm.free(made.value);
            }

            vm.free(runner.make_table);
            vm.free(runner.call);
            vm.deinit();
            runner.vm = null;
        }
    }

    fn start(runner: *Runner) !*engine.VM {
        std.debug.assert(runner.vm == null);

        // Views without compiled expressions never call; the empty program says so.
        if (runner.bytecode.len == 0) {
            return error.NoExpressions;
        }

        const vm = try runner.arena.create(engine.VM);

        vm.* = try engine.VM.init(runner.arena);
        errdefer vm.deinit();
        vm.guard();

        const loaded = try vm.load(runner.bytecode);

        vm.free(loaded);

        const global = engine.api.JS_GetGlobalObject(vm.context);
        defer vm.free(global);

        try vm.set(global, "__publr_base", try vm.string(runner.base));

        if (runner.catalogue.len > 0) {
            vm.free(try vm.eval(runner.catalogue, "publr:messages"));
        }

        runner.scratch = .init(try runner.arena.alloc(u8, scratch_bytes));
        runner.make_table = try vm.get(global, "__publr_table");
        runner.call = try vm.get(global, "__publr_call");
        runner.vm = vm;

        std.debug.assert(engine.api.JS_IsFunction(vm.context, runner.call));

        return vm;
    }

    /// The module's table over `state`, made on first use.
    fn table_of(
        runner: *Runner,
        vm: *engine.VM,
        module: []const u8,
        state: []const u8,
    ) !engine.Value {
        std.debug.assert(runner.vm == vm);

        const key = @intFromPtr(state.ptr);

        for (runner.tables.items) |known| {
            const same_state = known.state == key and known.state_len == state.len;

            if (same_state and std.mem.eql(u8, known.module, module)) {
                return known.value;
            }
        }

        if (runner.tables.items.len == tables_max) {
            return error.TooManyTables;
        }

        const arguments = [_]engine.Value{ try vm.string(module), try vm.string(state) };
        defer for (arguments) |argument| vm.free(argument);

        const made = try vm.call(runner.make_table, &arguments);

        try runner.tables.append(runner.arena, .{
            .state = key,
            .state_len = state.len,
            .module = module,
            .value = made,
        });

        return made;
    }

    fn scratch_of(context: *anyopaque) std.mem.Allocator {
        const runner: *Runner = @ptrCast(@alignCast(context));

        std.debug.assert(runner.expressions.context == context);

        return runner.scratch.allocator();
    }

    fn reset(context: *anyopaque) void {
        const runner: *Runner = @ptrCast(@alignCast(context));

        std.debug.assert(runner.expressions.context == context);

        runner.scratch.reset();
    }

    /// A JavaScript string copied into `into`.
    fn text_in(vm: *engine.VM, into: std.mem.Allocator, value: engine.Value) ![]const u8 {
        std.debug.assert(!engine.api.JS_IsException(value));

        var size: usize = 0;
        const bytes = engine.api.JS_ToCStringLen(vm.context, &size, value) orelse {
            return error.JavaScript;
        };
        defer engine.api.JS_FreeCString(vm.context, bytes);

        return into.dupe(u8, bytes[0..size]);
    }

    fn run(
        context: *anyopaque,
        arena: std.mem.Allocator,
        module: []const u8,
        slot: []const u8,
        state: []const u8,
        scope: []const u8,
    ) anyerror![]const u8 {
        const runner: *Runner = @ptrCast(@alignCast(context));

        std.debug.assert(module.len > 0 and slot.len > 0);

        const vm = runner.vm orelse try runner.start();
        const slots = runner.table_of(vm, module, state) catch |err| {
            std.log.scoped(.expressions).err("{s}: {s}", .{ module, vm.failure });

            return err;
        };
        const arguments = [_]engine.Value{ slots, try vm.string(slot), try vm.string(scope) };
        defer for (arguments[1..]) |argument| vm.free(argument);

        const answer = vm.call(runner.call, &arguments) catch |err| {
            std.log.scoped(.expressions).err("{s}.{s}: {s}", .{ module, slot, vm.failure });

            return err;
        };
        defer vm.free(answer);

        return text_in(vm, arena, answer);
    }
};
