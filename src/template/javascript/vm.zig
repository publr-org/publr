//! A bounded, render-local ECMAScript heap. Only compiler-produced bytecode is loaded.
const std = @import("std");
pub const api = @cImport({
    @cInclude("values.h");
});
pub const Value = api.JSValue;
pub const Error = error{ OutOfMemory, JavaScript };
pub const memory_bytes_max: u32 = 32 << 20;
pub const stack_bytes_max: u32 = 512 << 10;
pub const interrupts_max: u32 = 4096;
pub const output_bytes_max: u32 = 8 << 20;
pub const VM = struct {
    runtime: *api.JSRuntime,
    context: *api.JSContext,
    arena: std.mem.Allocator,
    failure: []const u8 = "",
    interrupts: u32 = 0,
    host: ?*anyopaque = null,
    host_call: ?*const fn (*anyopaque, *VM, []const u8, Value) anyerror!Value = null,
    host_error: ?anyerror = null,
    roots: std.ArrayList(Value) = .empty,
    factories: std.StringHashMapUnmanaged(Value) = .empty,
    module_load: ?*const fn (*anyopaque, *VM, []const u8) anyerror![]const u8 = null,
    module_source: bool = false,

    pub fn init(arena: std.mem.Allocator) error{OutOfMemory}!VM {
        std.debug.assert(memory_bytes_max > stack_bytes_max);
        const runtime = api.JS_NewRuntime() orelse return error.OutOfMemory;
        errdefer api.JS_FreeRuntime(runtime);
        api.JS_SetMemoryLimit(runtime, memory_bytes_max);
        api.JS_SetMaxStackSize(runtime, stack_bytes_max);
        const context = api.JS_NewContext(runtime) orelse return error.OutOfMemory;
        return .{ .runtime = runtime, .context = context, .arena = arena };
    }

    pub fn start(vm: *VM) Error!void {
        std.debug.assert(vm.interrupts == 0);
        api.JS_SetInterruptHandler(vm.runtime, interrupt, vm);
        api.JS_SetContextOpaque(vm.context, vm);
        api.JS_SetModuleLoaderFunc(vm.runtime, module_name, load_module, vm);
        const global = api.JS_GetGlobalObject(vm.context);
        defer vm.free(global);
        try vm.set(
            global,
            "__publr_host",
            api.JS_NewCFunction(vm.context, dispatch, "__publr_host", 2),
        );
        const result = try vm.eval(@embedFile("runtime.js"), "publr:runtime");
        vm.free(result);
    }

    pub fn deinit(vm: *VM) void {
        std.debug.assert(vm.roots.items.len <= 65536);

        for (vm.roots.items) |value| {
            vm.free(value);
        }

        api.JS_FreeContext(vm.context);
        api.JS_FreeRuntime(vm.runtime);
        vm.* = undefined;
    }

    fn interrupt(_: ?*api.JSRuntime, userdata: ?*anyopaque) callconv(.c) c_int {
        std.debug.assert(userdata != null);
        const vm: *VM = @ptrCast(@alignCast(userdata.?));
        vm.interrupts += 1;
        return @intFromBool(vm.interrupts >= interrupts_max);
    }

    fn dispatch(ctx: ?*api.JSContext, _: Value, argc: c_int, argv: [*c]Value) callconv(.c) Value {
        std.debug.assert(argc >= 0);
        const vm: *VM = @ptrCast(@alignCast(api.JS_GetContextOpaque(ctx).?));

        if (argc != 2 or vm.host_call == null) {
            return api.JS_ThrowTypeError(ctx, "no render host");
        }

        const name = vm.text(argv[0]) catch return api.JS_ThrowOutOfMemory(ctx);
        return vm.host_call.?(vm.host.?, vm, name, argv[1]) catch |err| {
            vm.host_error = err;
            return api.JS_ThrowInternalError(ctx, "%s", @errorName(err).ptr);
        };
    }

    pub fn check(vm: *VM, value: Value) Error!Value {
        std.debug.assert(vm.roots.items.len <= 65536);

        if (!api.JS_IsException(value)) {
            return value;
        }

        const exception = api.JS_GetException(vm.context);
        defer vm.free(exception);
        const stack = api.JS_GetPropertyStr(vm.context, exception, "stack");
        defer vm.free(stack);
        const message = vm.text(exception) catch "JavaScript error";
        const trace = if (api.JS_IsUndefined(stack)) "" else vm.text(stack) catch "";
        vm.failure = std.fmt.allocPrint(vm.arena, "{s}\n{s}", .{ message, trace }) catch message;
        return error.JavaScript;
    }

    pub fn eval(vm: *VM, source: []const u8, filename: []const u8) Error!Value {
        std.debug.assert(filename.len > 0);
        const text_z = try vm.arena.dupeZ(u8, source);
        const name_z = try vm.arena.dupeZ(u8, filename);
        return vm.check(api.JS_Eval(
            vm.context,
            text_z,
            source.len,
            name_z,
            api.JS_EVAL_TYPE_GLOBAL,
        ));
    }

    pub fn compile(vm: *VM, source: []const u8, filename: []const u8) Error![]const u8 {
        return vm.compile_kind(source, filename, false);
    }

    pub fn compile_kind(
        vm: *VM,
        source: []const u8,
        filename: []const u8,
        is_module: bool,
    ) Error![]const u8 {
        std.debug.assert(filename.len > 0);
        api.JS_SetModuleLoaderFunc(vm.runtime, module_name, load_module, vm);
        const text_z = try vm.arena.dupeZ(u8, source);
        const name_z = try vm.arena.dupeZ(u8, filename);
        const kind: c_int = if (is_module) api.JS_EVAL_TYPE_MODULE else api.JS_EVAL_TYPE_GLOBAL;
        const flags = kind | api.JS_EVAL_FLAG_COMPILE_ONLY;
        const code = try vm.check(api.JS_Eval(
            vm.context,
            text_z,
            source.len,
            name_z,
            flags,
        ));
        defer vm.free(code);
        var size: usize = 0;
        const bytes = api.JS_WriteObject(vm.context, &size, code, api.JS_WRITE_OBJ_BYTECODE);

        if (bytes == null) {
            return error.OutOfMemory;
        }

        defer api.js_free(vm.context, bytes);
        return vm.arena.dupe(u8, bytes[0..size]);
    }

    pub fn load(vm: *VM, bytecode: []const u8) Error!Value {
        std.debug.assert(bytecode.len > 0);
        const code = try vm.check(api.JS_ReadObject(
            vm.context,
            bytecode.ptr,
            bytecode.len,
            api.JS_READ_OBJ_BYTECODE,
        ));
        return vm.check(api.JS_EvalFunction(vm.context, code));
    }

    pub fn factory(vm: *VM, name: []const u8, bytecode: []const u8) Error!Value {
        std.debug.assert(bytecode.len > 0);

        if (vm.factories.get(name)) |value| {
            return vm.dup(value);
        }

        const code = try vm.check(api.JS_ReadObject(
            vm.context,
            bytecode.ptr,
            bytecode.len,
            api.JS_READ_OBJ_BYTECODE,
        ));
        const module_ = api.publr_js_module(code);

        if (module_ != null and api.JS_ResolveModule(vm.context, code) < 0) {
            vm.free(code);
            return vm.check(api.publr_js_exception());
        }

        const evaluated = try vm.check(api.JS_EvalFunction(vm.context, code));
        const function = if (module_ == null) evaluated else block: {
            defer vm.free(evaluated);

            if (api.JS_PromiseState(vm.context, evaluated) == api.JS_PROMISE_REJECTED) {
                return vm.check(api.JS_Throw(
                    vm.context,
                    api.JS_PromiseResult(vm.context, evaluated),
                ));
            }

            if (api.JS_PromiseState(vm.context, evaluated) == api.JS_PROMISE_PENDING) {
                vm.failure = "top-level await is not supported in synchronous template helpers";
                return error.JavaScript;
            }

            const namespace = try vm.check(api.JS_GetModuleNamespace(vm.context, module_));
            defer vm.free(namespace);
            break :block try vm.get(namespace, "default");
        };
        const held = try vm.hold(function);
        try vm.factories.put(vm.arena, name, held);
        return vm.dup(held);
    }

    fn module_name(
        ctx: ?*api.JSContext,
        _: [*c]const u8,
        name: [*c]const u8,
        _: ?*anyopaque,
    ) callconv(.c) [*c]u8 {
        std.debug.assert(name != null);
        const text_ = std.mem.span(name);
        const target = api.js_malloc(ctx, text_.len + 1) orelse return null;
        const bytes: [*]u8 = @ptrCast(target);
        @memcpy(bytes[0..text_.len], text_);
        bytes[text_.len] = 0;
        return bytes;
    }

    fn load_module(
        ctx: ?*api.JSContext,
        name: [*c]const u8,
        userdata: ?*anyopaque,
    ) callconv(.c) ?*api.JSModuleDef {
        std.debug.assert(userdata != null);
        const vm: *VM = @ptrCast(@alignCast(userdata.?));
        const loader = vm.module_load orelse return null;
        const bytes = loader(vm.host.?, vm, std.mem.span(name)) catch |err| {
            vm.host_error = err;
            _ = api.JS_ThrowReferenceError(ctx, "unknown template helper: %s", name);
            return null;
        };
        const code = if (vm.module_source) block: {
            const source_z = vm.arena.dupeZ(u8, bytes) catch return null;
            break :block api.JS_Eval(
                ctx,
                source_z,
                bytes.len,
                name,
                api.JS_EVAL_TYPE_MODULE | api.JS_EVAL_FLAG_COMPILE_ONLY,
            );
        } else api.JS_ReadObject(ctx, bytes.ptr, bytes.len, api.JS_READ_OBJ_BYTECODE);

        if (api.JS_IsException(code)) {
            return null;
        }

        const module_ = api.publr_js_module(code);
        api.JS_FreeValue(ctx, code);
        return module_;
    }

    pub fn call(vm: *VM, function: Value, args: []const Value) Error!Value {
        std.debug.assert(args.len <= 65536);
        return vm.check(api.JS_Call(
            vm.context,
            function,
            api.publr_js_undefined(),
            @intCast(args.len),
            @constCast(args.ptr),
        ));
    }

    pub fn free(vm: *VM, value: Value) void {
        api.JS_FreeValue(vm.context, value);
    }

    pub fn hold(vm: *VM, value: Value) Error!Value {
        std.debug.assert(!api.JS_IsException(value));

        if (vm.roots.items.len == 65536) {
            vm.free(value);
            return error.JavaScript;
        }

        vm.roots.append(vm.arena, value) catch {
            vm.free(value);
            return error.OutOfMemory;
        };
        return value;
    }

    pub fn dup(vm: *VM, value: Value) Value {
        return api.JS_DupValue(vm.context, value);
    }

    pub fn string(vm: *VM, text_: []const u8) Error!Value {
        std.debug.assert(vm.roots.items.len <= 65536);

        if (text_.len > output_bytes_max) {
            return error.JavaScript;
        }

        return vm.check(api.JS_NewStringLen(vm.context, text_.ptr, text_.len));
    }

    pub fn text(vm: *VM, value: Value) Error![]const u8 {
        std.debug.assert(!api.JS_IsException(value));
        var size: usize = 0;
        const bytes = api.JS_ToCStringLen(vm.context, &size, value);

        if (bytes == null) {
            return error.JavaScript;
        }

        defer api.JS_FreeCString(vm.context, bytes);

        if (size > output_bytes_max) {
            return error.JavaScript;
        }

        return vm.arena.dupe(u8, bytes[0..size]);
    }

    pub fn get(vm: *VM, object: Value, key: []const u8) Error!Value {
        std.debug.assert(vm.roots.items.len <= 65536);
        const key_z = try vm.arena.dupeZ(u8, key);
        return vm.check(api.JS_GetPropertyStr(vm.context, object, key_z));
    }
    /// Consumes value, as QuickJS's property setters do.
    pub fn set(vm: *VM, object: Value, key: []const u8, value: Value) Error!void {
        std.debug.assert(vm.roots.items.len <= 65536);
        const key_z = vm.arena.dupeZ(u8, key) catch {
            vm.free(value);
            return error.OutOfMemory;
        };

        if (api.JS_SetPropertyStr(vm.context, object, key_z, value) < 0) {
            return error.JavaScript;
        }
    }

    pub fn item(vm: *VM, array: Value, index: u32) Error!Value {
        std.debug.assert(!api.JS_IsException(array));
        return vm.check(api.JS_GetPropertyUint32(vm.context, array, index));
    }

    pub fn length(vm: *VM, array: Value) Error!u32 {
        std.debug.assert(api.JS_IsArray(array));
        const value = try vm.get(array, "length");
        defer vm.free(value);
        var size: u32 = 0;

        if (api.JS_ToUint32(vm.context, &size, value) < 0 or size > 65536) {
            return error.JavaScript;
        }

        return size;
    }
};
test "bytecode retains closures and each invocation starts with fresh state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try VM.init(arena.allocator());
    defer vm.deinit();
    try vm.start();
    const bytes = try vm.compile("(function(){ let n=0; return () => ++n; })", "closure.publr");
    const factory = try vm.load(bytes);
    defer vm.free(factory);
    const first = try vm.call(factory, &.{});
    defer vm.free(first);
    const result = try vm.call(first, &.{});
    defer vm.free(result);
    try std.testing.expectEqualStrings("1", try vm.text(result));
}
test "runaway scripts terminate and exceptions retain their filename" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try VM.init(arena.allocator());
    defer vm.deinit();
    try vm.start();
    try std.testing.expectError(
        error.JavaScript,
        vm.eval("throw new Error('broken seed')", "dots.publr"),
    );
    try std.testing.expect(std.mem.indexOf(u8, vm.failure, "broken seed") != null);
    try std.testing.expect(std.mem.indexOf(u8, vm.failure, "dots.publr") != null);
    try std.testing.expectError(error.JavaScript, vm.eval("for (;;) {}", "loop.publr"));
    try std.testing.expect(vm.interrupts >= interrupts_max);
}
