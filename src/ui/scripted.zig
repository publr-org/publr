//! An interactive component drawn by its render as JavaScript (pjsx's `render_js`): what a
//! place with no compiler brings, an installed plugin's `interactive/` or an app's loaded
//! from a folder. The markup is the one the Zig lowering writes, so the browser's stores
//! hydrate it the same. One script heap per program per page (held by the page), its memory
//! bounded by the engine, the program loaded from bytecode made once when the bundle was read.
const std = @import("std");
const runtime = @import("runtime");
const engine = @import("../template/javascript/vm.zig");
const render = @import("../template/render.zig");

const api = engine.api;

/// The most bytes a component's props may take as JSON.
const props_bytes_max: u32 = 1 << 20;

/// A program of interactive components: their render as bytecode.
pub const Bundle = struct {
    bytecode: []const u8,
};

/// One component of a bundle, as a template's render calls it (`render.PjsxRender`).
pub const Component = struct {
    bundle: *const Bundle,
    name: []const u8,

    pub fn pjsx_render(component: *const Component) render.PjsxRender {
        std.debug.assert(component.name.len > 0);
        std.debug.assert(component.bundle.bytecode.len > 0);

        return .{
            .context = component,
            .draw = &draw,
        };
    }
};

/// What the program asks of the page while it draws: the class stack merged with the
/// page's book.
const Host = struct {
    arena: std.mem.Allocator,
    book: ?*const anyopaque,
};

/// A program's script heap with the program loaded: kept for the page when it has a place
/// for it (`render.PjsxPage.held`), so the page's next component of the same program draws
/// in it instead of starting the engine and loading the program again.
const Heap = struct {
    vm: engine.VM,
    host: Host,
};

/// Draws the component `context` names (a `*const Component`) with a call site's props and
/// children, on the page's class book and catalogue.
pub fn draw(
    context: ?*const anyopaque,
    writer: *std.Io.Writer,
    arena: std.mem.Allocator,
    props: []const render.Prop,
    children: ?[]const u8,
    page: render.PjsxPage,
) anyerror!void {
    const component: *const Component = @ptrCast(@alignCast(context.?));

    std.debug.assert(component.name.len > 0);
    std.debug.assert(props.len <= 1 << 16);

    const kept = if (page.held) |held| held.find(component.bundle) else null;
    const heap: *Heap = if (kept) |value| @ptrCast(@alignCast(value)) else try start(
        arena,
        component.bundle,
        page,
    );
    const alone = kept == null and !try keep(arena, heap, component.bundle, page);
    defer if (alone) release(heap);

    heap.host = .{
        .arena = arena,
        .book = page.classes,
    };
    heap.vm.interrupts = 0;

    const vm = &heap.vm;
    const global = api.JS_GetGlobalObject(vm.context);
    defer vm.free(global);

    const function = try vm.get(global, "__publr_render");
    defer vm.free(function);

    const json = try props_json(arena, props);
    const terminated = try arena.dupeSentinel(u8, json, 0);
    const markup = if (children) |given| try vm.string(given) else api.publr_js_null();
    const arguments = [_]engine.Value{
        try vm.string(component.name),
        try vm.check(api.JS_ParseJSON(vm.context, terminated.ptr, json.len, "publr:props")),
        markup,
        api.publr_js_boolean(vm.context, @intFromBool(page.catalogue.len > 0)),
    };
    defer free_all(vm, &arguments);

    const answer = vm.call(function, &arguments) catch |err| {
        std.log.scoped(.interactive).err("{s}: {s}", .{ component.name, vm.failure });
        return err;
    };
    defer vm.free(answer);

    try writer.writeAll(try vm.text(answer));
}

/// A heap for `bundle`'s program: the engine started, the page's catalogue read, the
/// program loaded.
fn start(arena: std.mem.Allocator, bundle: *const Bundle, page: render.PjsxPage) !*Heap {
    std.debug.assert(bundle.bytecode.len > 0);

    const heap = try arena.create(Heap);

    heap.* = .{
        .vm = try engine.VM.init(arena),
        .host = .{
            .arena = arena,
            .book = page.classes,
        },
    };
    errdefer heap.vm.deinit();

    const vm = &heap.vm;

    vm.guard();
    vm.host = &heap.host;

    const global = api.JS_GetGlobalObject(vm.context);
    defer vm.free(global);

    const merge = api.JS_NewCFunction(vm.context, classes, "__publr_classes", 1);

    try vm.set(global, "__publr_classes", merge);

    if (page.catalogue.len > 0) {
        vm.free(try vm.eval(page.catalogue, "publr:messages"));
    }

    vm.free(try load(vm, bundle.bytecode));

    std.debug.assert(vm.host != null);

    return heap;
}

/// Whether the page keeps `heap` for its next component of `bundle`.
fn keep(arena: std.mem.Allocator, heap: *Heap, bundle: *const Bundle, page: render.PjsxPage) !bool {
    std.debug.assert(bundle.bytecode.len > 0);

    const held = page.held orelse return false;

    std.debug.assert(held.find(bundle) == null);

    return held.keep(arena, .{
        .key = bundle,
        .value = heap,
        .release = &release_kept,
    });
}

fn release_kept(value: *anyopaque) void {
    release(@ptrCast(@alignCast(value)));
}

fn release(heap: *Heap) void {
    std.debug.assert(heap.vm.host != null);

    heap.vm.deinit();
}

fn load(vm: *engine.VM, bytecode: []const u8) !engine.Value {
    std.debug.assert(bytecode.len > 0);

    return vm.load(bytecode) catch |err| {
        std.log.scoped(.interactive).err("the components' program: {s}", .{vm.failure});
        return err;
    };
}

/// A call site's props as one JSON object: a text as a string, a number and a boolean as
/// themselves, one left out (null) not at all.
fn props_json(arena: std.mem.Allocator, props: []const render.Prop) ![]const u8 {
    std.debug.assert(props.len <= 1 << 16);

    var out: std.Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{
        .writer = &out.writer,
    };

    try stringify.beginObject();

    for (props) |prop| {
        const value = prop.value orelse continue;

        try stringify.objectField(prop.name);

        switch (prop.kind) {
            .string => try stringify.write(value),
            .number, .boolean, .json => try stringify.print("{s}", .{value}),
        }
    }

    try stringify.endObject();

    if (out.written().len > props_bytes_max) {
        return error.PropsTooLarge;
    }

    return out.written();
}

/// `__publr_classes(parts)`: the stack merged with the page's class book, as the Zig render
/// merges it.
fn classes(
    ctx: ?*api.JSContext,
    _: engine.Value,
    argc: c_int,
    argv: [*c]engine.Value,
) callconv(.c) engine.Value {
    const vm: *engine.VM = @ptrCast(@alignCast(api.JS_GetContextOpaque(ctx).?));
    const host: *Host = @ptrCast(@alignCast(vm.host.?));

    std.debug.assert(argc >= 0);

    if (argc != 1 or !api.JS_IsArray(argv[0])) {
        return api.JS_ThrowTypeError(ctx, "a class stack is a list");
    }

    const merged = merged_classes(vm, host, argv[0]) catch {
        return api.JS_ThrowInternalError(ctx, "the class stack did not merge");
    };

    return vm.string(merged) catch api.JS_ThrowOutOfMemory(ctx);
}

fn merged_classes(vm: *engine.VM, host: *Host, list: engine.Value) ![]const u8 {
    std.debug.assert(api.JS_IsArray(list));

    const count = try vm.length(list);
    const parts = try host.arena.alloc([]const u8, count);

    for (parts, 0..) |*part, index| {
        const item = try vm.item(list, @intCast(index));
        defer vm.free(item);

        part.* = if (api.JS_IsString(item)) try vm.text(item) else "";
    }

    return runtime.merge_classes(host.arena, parts, .{
        .book = host.book,
    });
}

test "a call site's props are one JSON object, the absent ones left out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const json = try props_json(arena_state.allocator(), &.{
        .{
            .name = "label",
            .value = "a \"b\"",
        },
        .{
            .name = "count",
            .value = "3",
            .kind = .number,
        },
        .{
            .name = "hint",
            .value = null,
        },
    });

    try std.testing.expectEqualStrings("{\"label\":\"a \\\"b\\\"\",\"count\":3}", json);
}

fn free_all(vm: *engine.VM, values: []const engine.Value) void {
    std.debug.assert(values.len <= 16);

    for (values) |value| {
        vm.free(value);
    }
}
