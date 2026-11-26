//! A plugin's page from its own PTSX view: `publr.views.render(ctx, in.base, Views.SamplerLog,
//! props)` answers the page's HTML, doctype first, the same either way the plugin runs.
//! Compiled in, the view and every component it reaches draw in the process. Installed, the
//! view runs in the plugin and describes the page: its own markup and each component of the
//! design system it reaches, with its props. The host draws them all in one call
//! (`publr_draw`, `view_wire.zig`), so no plugin carries the design system.
const std = @import("std");
const guest = @import("../../sdk/plugin/guest.zig");
const wire = @import("../../sdk/plugin/wire.zig");
const view_wire = @import("../../sdk/plugin/view_wire.zig");
const shape_wire = @import("../../sdk/plugin/shape_wire.zig");
const shape_parts = @import("../../sdk/plugin/shape_parts.zig");

const Error = @import("../../sdk.zig").Error;

/// The plugin's views, by name: the admin's generated set compiled in, the plugin's own
/// installed.
pub const all = if (guest.mode == .native)
    @import("../../adapters/admin.zig").views
else
    @import("plugin_views");

extern "env" fn publr_frame(
    base_ptr: [*]const u8,
    base_len: u32,
    wanted: *const wire.Result,
    sizes: *[2]u32,
) u32;

/// The page `View` draws with `props`, in the plugin frame under `base`, doctype first. A
/// view declaring `ctx` gets it with its props: who is looking and the page. A number prop
/// takes an integer as it is.
pub fn render(
    ctx: anytype,
    base: []const u8,
    comptime View: type,
    props: anytype,
) Error![]const u8 {
    std.debug.assert(base.len == 0 or base[0] == '/');
    comptime std.debug.assert(@hasDecl(View, "render"));

    if (comptime guest.mode == .native) {
        const admin = @import("../../adapters/admin.zig");
        const request = admin.chrome.in_plugin_frame(ctx, base) catch return error.OutOfMemory;
        const full = props_of(View.Props, props, ctx.inner.view, ctx.arena());

        return admin.render.document(ctx.arena(), request, View, full) catch error.OutOfMemory;
    }

    // Who is looking and at what, laid out by the host as this build's own struct.
    const described = comptime @import("../../sdk/plugin/shape_wire.zig").describe(Looked);
    const wanted: wire.Result = .{
        .ptr = @intCast(@intFromPtr(described.ptr)),
        .len = described.len,
    };
    var sizes: [2]u32 = .{ 0, 0 };
    const status = publr_frame(base.ptr, @intCast(base.len), &wanted, &sizes);

    if (status != wire.ok) {
        return wire.error_of(status);
    }

    const looking = try guest.taken_as(Looked, ctx.arena(), sizes);
    var sketch: Sketch = .{
        .memory = ctx.arena(),
    };
    const arena = sketch.allocator();
    var out: std.Io.Writer.Allocating = .init(ctx.arena());
    var full = props_of(View.Props, props, looking, arena);

    // The view's own words in the person's language, looked up by the host.
    if (comptime @hasField(View.Props, "publr_request") and @hasDecl(all, "request_module")) {
        full.publr_request = try translating(ctx.arena());
    }

    View.render(&out.writer, arena, full) catch |err| {
        return as_error(err);
    };

    // One hand-over: the host draws every component and answers the page, doctype first.
    return sketch.drawn(out.written());
}

const Looking = @import("../../sdk/context.zig").View;
const Laid = @import("../../sdk/operation/json.zig").Laid;

/// `Looking` as an installed plugin's module is handed it: an editor's value read where it
/// lies, with what it reads as when it is kept as text holding JSON.
const Looked = struct {
    person: Looking.Person = .{},
    page: Looking.Page = .{},
    editor: ?Editor = null,

    const Editor = struct {
        value: Laid = .{},
        parsed: ?Laid = null,
        problems: []const []const u8 = &.{},
        options: Looking.Options = .{},
    };
};

/// What a view is told about who is looking, in the form this build holds it.
const Told = if (guest.mode == .sandboxed) Looked else Looking;

extern "env" fn publr_translate(asked: *const wire.Message, result: *wire.Result) u32;

/// A render's request whose catalogue asks the host: `Publr.t` in an installed plugin's
/// view reads the person's language as a compiled-in one's does.
fn translating(arena: std.mem.Allocator) Error!*const anyopaque {
    const Request = all.request_module.Request;
    const Translator = all.runtime_module.Translator;
    const held = arena.create(std.mem.Allocator) catch return error.OutOfMemory;
    const translator = arena.create(Translator) catch return error.OutOfMemory;
    const request = arena.create(Request) catch return error.OutOfMemory;

    held.* = arena;
    translator.* = .{
        .context = held,
        .lookup = &looked_up,
    };
    request.* = .{
        .session = .{
            .name = "",
            .email = "",
            .csrf = "",
            .avatar = "",
        },
        .admin = .{
            .base = "",
            .path = "",
            .area = "",
            .can_structure = false,
            .can_settings = false,
            .top_bar = null,
            .sidebar = null,
            .framed = true,
            .grows = true,
        },
        .publr_translations = translator,
    };

    std.debug.assert(request.publr_translations != null);

    return request;
}

/// One message as the host's catalogue has it in the person's language; null for none.
fn looked_up(
    context: *const anyopaque,
    message_context: []const u8,
    id: []const u8,
    plural: []const u8,
    count: ?f64,
) ?[]const u8 {
    const arena: *const std.mem.Allocator = @ptrCast(@alignCast(context));
    const asked = wire.Message.of(message_context, id, plural, count);
    var result: wire.Result = .{
        .ptr = 0,
        .len = 0,
    };

    std.debug.assert(id.len > 0);

    if (publr_translate(&asked, &result) != wire.ok) {
        return null;
    }

    const told = guest.take(result);
    defer @import("../../sdk/plugin/guest_memory.zig").heap.free(told);

    if (told.len == 0) {
        return null;
    }

    return arena.dupe(u8, told) catch null;
}

/// `props` as the view's `Props`: each prop from `props`, an integer where a number is asked
/// taken as it is, else its default; `ctx` from `looking`.
fn props_of(
    comptime Props: type,
    props: anytype,
    looking: Told,
    arena: std.mem.Allocator,
) Props {
    const Given = @TypeOf(props);
    var full: Props = undefined;

    inline for (
        comptime std.meta.fieldNames(Props),
        comptime std.meta.fieldTypes(Props),
        @typeInfo(Props).@"struct".field_attrs,
    ) |field_name, FieldType, field_attrs| {
        if (comptime std.mem.eql(u8, field_name, "ctx")) {
            @field(full, field_name) = ctx_of(FieldType, looking, arena);
        } else if (@hasField(Given, field_name)) {
            @field(full, field_name) = converted(FieldType, @field(props, field_name), arena);
        } else if (comptime field_attrs.defaultValue(FieldType) != null) {
            @field(full, field_name) = comptime field_attrs.defaultValue(FieldType).?;
        } else {
            @compileError("the view's prop ." ++ field_name ++ " is not given");
        }
    }

    inline for (comptime std.meta.fieldNames(Given)) |field_name| {
        if (!@hasField(Props, field_name)) {
            @compileError("the view has no prop ." ++ field_name);
        }
    }

    return full;
}

/// `value` as a prop of type `Prop`, at any depth: an integer where a number is asked as a
/// number, a struct's fields by name (a field left out takes its default), a list item by
/// item. Out of memory for a list, the prop's default stands: an empty list.
fn converted(comptime Prop: type, value: anytype, arena: std.mem.Allocator) Prop {
    const Value = @TypeOf(value);

    comptime std.debug.assert(@typeInfo(Prop) != .void);

    if (comptime Prop == Value) {
        return value;
    }

    switch (comptime @typeInfo(Prop)) {
        .float => if (comptime @typeInfo(Value) == .int or @typeInfo(Value) == .comptime_int) {
            return @floatFromInt(value);
        } else {
            return value;
        },
        .optional => |optional| {
            if (comptime @typeInfo(Value) == .optional) {
                const present = value orelse return null;

                return converted(optional.child, present, arena);
            }

            if (comptime Value == @TypeOf(null)) {
                return null;
            }

            return converted(optional.child, value, arena);
        },
        .pointer => |pointer| {
            if (comptime pointer.size != .slice or pointer.child == u8 or
                @typeInfo(Value) != .pointer)
            {
                return value;
            }

            const Item = pointer.child;
            const items = arena.alloc(Item, value.len) catch return &.{};

            for (value, items) |one, *item| {
                item.* = converted(Item, one, arena);
            }

            return items;
        },
        .@"struct" => |shape| {
            if (comptime @typeInfo(Value) != .@"struct") {
                return value;
            }

            var out: Prop = undefined;

            inline for (shape.field_names, shape.field_types, shape.field_attrs) |
                field_name,
                FieldType,
                field_attrs,
            | {
                if (comptime @hasField(Value, field_name)) {
                    const given = @field(value, field_name);

                    @field(out, field_name) = converted(FieldType, given, arena);
                } else if (comptime field_attrs.defaultValue(FieldType)) |default| {
                    @field(out, field_name) = default;
                } else {
                    @compileError("the view's prop has no ." ++ field_name ++ " given");
                }
            }

            return out;
        },
        else => return value,
    }
}

/// The view's `ctx` as it declares it: `person` and `page` filled from `looking`, and in a
/// field kind's editor `value`, `problems` and `options`; what only the browser has
/// (`query`, `call`, `navigate`, `change`) is null here.
fn ctx_of(comptime Ctx: type, looking: Told, arena: std.mem.Allocator) Ctx {
    var out: Ctx = undefined;
    const editor = looking.editor orelse Told.Editor{};

    inline for (
        comptime std.meta.fieldNames(Ctx),
        comptime std.meta.fieldTypes(Ctx),
    ) |field_name, FieldType| {
        if (comptime std.mem.eql(u8, field_name, "person")) {
            @field(out, field_name) = part_of(FieldType, looking.person);
        } else if (comptime std.mem.eql(u8, field_name, "page")) {
            @field(out, field_name) = part_of(FieldType, looking.page);
        } else if (comptime std.mem.eql(u8, field_name, "value")) {
            @field(out, field_name) = if (comptime Told == Looked)
                value_laid(FieldType, editor, arena)
            else
                value_of(FieldType, editor.value, arena);
        } else if (comptime std.mem.eql(u8, field_name, "problems")) {
            @field(out, field_name) = editor.problems;
        } else if (comptime std.mem.eql(u8, field_name, "options")) {
            @field(out, field_name) = part_of(FieldType, editor.options);
        } else if (comptime @typeInfo(FieldType) == .optional) {
            @field(out, field_name) = null;
        } else {
            @compileError("a view's ctx has person, page, query, call, navigate and, in an " ++
                "editor, value, problems, options and change, not ." ++ field_name);
        }
    }

    return out;
}

/// The value an editor edits as its view declares it: null when there is none (a new record)
/// or it is not one of the kind, for a view naming it `Place | null`; a view naming it
/// `Place` gets the zero value then. A field's help names its value `string`: the field's
/// text, empty for none.
fn value_of(comptime Value: type, value: std.json.Value, arena: std.mem.Allocator) Value {
    const optional = @typeInfo(Value) == .optional;
    const Shape = if (optional) @typeInfo(Value).optional.child else Value;
    const none: Value = if (optional) null else std.mem.zeroes(Shape);

    comptime std.debug.assert(@typeInfo(Shape) != .void);

    if (comptime @typeInfo(Shape) != .@"struct") {
        return switch (value) {
            .null => none,
            else => std.json.parseFromValueLeaky(Shape, arena, value, .{}) catch none,
        };
    }

    const parsed = switch (value) {
        .null => return none,
        // A struct kept as JSON text.
        .string => |text| std.json.parseFromSliceLeaky(Shape, arena, text, .{
            .ignore_unknown_fields = true,
        }),
        else => std.json.parseFromValueLeaky(Shape, arena, value, .{
            .ignore_unknown_fields = true,
        }),
    };

    return parsed catch none;
}

/// `value_of` in an installed plugin's module: the value read where it lies.
fn value_laid(comptime Value: type, editor: Looked.Editor, arena: std.mem.Allocator) Value {
    const optional = @typeInfo(Value) == .optional;
    const Shape = if (optional) @typeInfo(Value).optional.child else Value;
    const none: Value = if (optional) null else std.mem.zeroes(Shape);
    const held = editor.value.read(arena) catch return none;

    comptime std.debug.assert(@typeInfo(Shape) != .void);

    if (held.is_null()) {
        return none;
    }

    // A struct kept as text holding JSON: what the text reads as.
    if (comptime @typeInfo(Shape) == .@"struct") {
        if (held.kind() == .text) {
            const parsed = editor.parsed orelse return none;

            return parsed.as(Shape, arena) catch none;
        }
    }

    return editor.value.as(Shape, arena) catch none;
}

fn part_of(comptime Part: type, from: anytype) Part {
    var out: Part = undefined;

    comptime std.debug.assert(@typeInfo(Part) == .@"struct");

    inline for (comptime std.meta.fieldNames(Part)) |field_name| {
        @field(out, field_name) = @field(from, field_name);
    }

    return out;
}

/// A stand-in's `render`: `name` with `props` joins the page's components, to be drawn by
/// the host with the rest of the page, and a placeholder is written where it goes. Its node
/// props are written here first, as markup with placeholders of their own.
pub fn draw(
    writer: *std.Io.Writer,
    arena: std.mem.Allocator,
    comptime name: []const u8,
    comptime Props: type,
    props: Props,
) !void {
    comptime std.debug.assert(guest.mode == .sandboxed);
    comptime std.debug.assert(name.len > 0 and name.len <= view_wire.name_len_max);

    const sketch = Sketch.of(arena) orelse return error.Invalid;
    const kept = try sketch.memory.create(Props);

    kept.* = props;

    inline for (comptime std.meta.fieldNames(Props)) |field_name| {
        if (comptime view_wire.node_of(@FieldType(Props, field_name)) != null) {
            @field(kept, field_name) = .{
                .raw = try sketch.written(@field(props, field_name), arena),
            };
        }
    }

    const described = comptime view_wire.describe(Props);
    const number = sketch.components.items.len;

    if (number >= view_wire.components_max) {
        return error.Invalid;
    }

    var table: std.ArrayList(shape_wire.Entry) = .empty;

    if (comptime shape_parts.has_choice(Props)) {
        try shape_parts.table_of(Props, sketch.memory, kept, &table);
    }

    try sketch.components.append(sketch.memory, .{
        .name = @intCast(@intFromPtr(name.ptr)),
        .name_len = name.len,
        .described = @intCast(@intFromPtr(described.ptr)),
        .described_len = described.len,
        .props = @intCast(@intFromPtr(kept)),
        .table = @intCast(@intFromPtr(table.items.ptr)),
        .table_len = @intCast(table.items.len),
    });
    try view_wire.write_placeholder(writer, @intCast(number));
}

/// A size as an allocator takes it.
const Bytes = usize;

extern "env" fn publr_draw(page: *const view_wire.Page, result: *wire.Result) u32;

/// A page while its view runs: the components it reached so far. The view and everything
/// it renders get `allocator()`, the plugin's own memory under a name a stand-in knows the
/// page by.
const Sketch = struct {
    memory: std.mem.Allocator,
    components: std.ArrayList(view_wire.Component) = .empty,

    const forwarding: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(sketch: *Sketch) std.mem.Allocator {
        return .{
            .ptr = sketch,
            .vtable = &forwarding,
        };
    }

    /// The page `arena` belongs to; null for memory no page handed out.
    fn of(arena: std.mem.Allocator) ?*Sketch {
        if (arena.vtable != &forwarding) {
            return null;
        }

        return @ptrCast(@alignCast(arena.ptr));
    }

    /// A node prop as markup: null for one left out, empty for one that writes nothing.
    fn written(sketch: *Sketch, given: anytype, arena: std.mem.Allocator) !?[]const u8 {
        std.debug.assert(Sketch.of(arena) == sketch);

        const node = if (comptime @typeInfo(@TypeOf(given)) == .optional)
            given orelse return null
        else
            given;
        var out: std.Io.Writer.Allocating = .init(sketch.memory);

        try node.render(&out.writer, arena, .{});

        return if (out.written().len == 0) "" else out.written();
    }

    /// The whole page, drawn by the host from `markup` and the components reached.
    fn drawn(sketch: *const Sketch, markup: []const u8) Error![]const u8 {
        std.debug.assert(sketch.components.items.len <= view_wire.components_max);

        const page: view_wire.Page = .{
            .markup = @intCast(@intFromPtr(markup.ptr)),
            .markup_len = @intCast(markup.len),
            .components = @intCast(@intFromPtr(sketch.components.items.ptr)),
            .components_len = @intCast(sketch.components.items.len),
        };
        var result: wire.Result = .{
            .ptr = 0,
            .len = 0,
        };
        const status = publr_draw(&page, &result);

        if (status != wire.ok) {
            return wire.error_of(status);
        }

        return guest.take(result);
    }

    fn alloc(context: *anyopaque, len: Bytes, alignment: std.mem.Alignment, from: Bytes) ?[*]u8 {
        const sketch: *Sketch = @ptrCast(@alignCast(context));

        return sketch.memory.rawAlloc(len, alignment, from);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: Bytes,
        from: Bytes,
    ) bool {
        const sketch: *Sketch = @ptrCast(@alignCast(context));

        return sketch.memory.rawResize(memory, alignment, new_len, from);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: Bytes,
        from: Bytes,
    ) ?[*]u8 {
        const sketch: *Sketch = @ptrCast(@alignCast(context));

        return sketch.memory.rawRemap(memory, alignment, new_len, from);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, from: Bytes) void {
        const sketch: *Sketch = @ptrCast(@alignCast(context));

        sketch.memory.rawFree(memory, alignment, from);
    }
};

fn as_error(err: anyerror) Error {
    std.debug.assert(@errorName(err).len > 0);

    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Denied => error.Denied,
        error.NotFound => error.NotFound,
        else => error.Invalid,
    };
}

test "a page's memory is known by the stand-ins it reaches, and no other memory is" {
    var sketch: Sketch = .{
        .memory = std.testing.allocator,
    };
    const arena = sketch.allocator();
    const bytes = try arena.alloc(u8, 8);
    defer arena.free(bytes);

    try std.testing.expect(Sketch.of(arena) == &sketch);
    try std.testing.expect(Sketch.of(std.testing.allocator) == null);
    try std.testing.expectEqual(@as(usize, 0), sketch.components.items.len);
}

test "a view's props take an integer count as it is, and its ctx is who is looking" {
    const Props = struct {
        total: f64,
        title: []const u8 = "Notes",
        ctx: struct {
            person: struct {
                name: []const u8,
            },
            page: struct {
                path: []const u8,
                query: []const u8,
            },
            query: ?[]const u8,
        },
    };
    const count: u32 = 3;
    const full = props_of(Props, .{
        .total = count,
    }, .{
        .person = .{
            .name = "Ann",
            .email = "ann@example.com",
        },
        .page = .{
            .path = "log",
            .query = "week=2",
        },
    }, std.testing.allocator);

    try std.testing.expectEqual(@as(f64, 3), full.total);
    try std.testing.expectEqualStrings("Notes", full.title);
    try std.testing.expectEqualStrings("Ann", full.ctx.person.name);
    try std.testing.expectEqualStrings("week=2", full.ctx.page.query);
    try std.testing.expect(full.ctx.query == null);
}

test "a view's props convert integers inside lists of structs by field name" {
    const Row = struct {
        name: []const u8,
        nights: f64,
        paid: ?f64 = null,
        note: []const u8 = "",
    };
    const Props = struct {
        rows: []const Row,
    };
    const Given = struct {
        name: []const u8,
        nights: u32,
        paid: ?i64,
    };
    const given = [_]Given{.{
        .name = "Berth 4",
        .nights = 3,
        .paid = 12000,
    }};

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const full = props_of(Props, .{
        .rows = @as([]const Given, &given),
    }, .{}, arena_state.allocator());

    try std.testing.expectEqual(@as(usize, 1), full.rows.len);
    try std.testing.expectEqual(@as(f64, 3), full.rows[0].nights);
    try std.testing.expectEqual(@as(?f64, 12000), full.rows[0].paid);
    try std.testing.expectEqualStrings("", full.rows[0].note);
}

test "an editor's ctx carries its value, its problems and the field's options" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Place = struct {
        name: []const u8,
        lat: f64,
    };
    const Ctx = struct {
        value: ?Place,
        problems: []const []const u8,
        options: struct {
            placeholder: []const u8,
        },
        change: ?[]const u8,
    };
    const stored: std.json.Value = .{
        .string = "{\"name\":\"Warsaw\",\"lat\":52.2}",
    };
    const told = ctx_of(Ctx, .{
        .editor = .{
            .value = stored,
            .problems = &.{"Between -90 and 90."},
            .options = .{
                .placeholder = "Where",
            },
        },
    }, arena);

    try std.testing.expectEqualStrings("Warsaw", told.value.?.name);
    try std.testing.expectEqualStrings("Between -90 and 90.", told.problems[0]);
    try std.testing.expectEqualStrings("Where", told.options.placeholder);
    try std.testing.expect(told.change == null);

    // A new record: no value.
    const fresh = ctx_of(Ctx, .{
        .editor = .{},
    }, arena);

    try std.testing.expect(fresh.value == null);
}
