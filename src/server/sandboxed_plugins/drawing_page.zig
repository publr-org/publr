//! `publr_draw`: a whole page an installed plugin's view described, drawn in one call. The
//! plugin hands over its markup and every component it reached (`sdk/plugin/view_wire.zig`);
//! each component's props are read where they lie in the plugin's memory, by the layout its
//! build describes, straight into the design system's own `Props`, and drawn natively.
//!
//! Nothing the plugin says is trusted: every address and length is checked against its
//! memory, a name must be a component an installed plugin may draw, a prop must be one of
//! the component's with a value of its type, and the page's size, its count of components
//! and what is read out of the plugin are all bounded.
const std = @import("std");
const wasm = @import("publr_wasm");
const sdk = @import("../../sdk.zig");
const wire = @import("../../sdk/plugin/wire.zig");
const view_wire = @import("../../sdk/plugin/view_wire.zig");
const admin = @import("../../adapters/admin.zig");
const placed = @import("../../ui/drawn_placed.zig");
const invoke = @import("invoke.zig");
const host_calls = @import("host_calls.zig");
const shaped_read = @import("shaped_read.zig");
const described_module = @import("described.zig");
const given_module = @import("given.zig");
const given_typed = @import("given_typed.zig");

const Described = described_module.Described;
const Given = given_module.Given;

/// What holds a page while it is drawn: given back when the call ends.
const gpa = std.heap.c_allocator;

/// The most one page's props take, read out of the plugin, and the most layouts it names.
pub const props_bytes_max: u64 = 8 << 20;
pub const layouts_max: u32 = 256;
pub const page_bytes_max: u32 = admin.render.page_bytes_max;

const steps_per_prop: u32 = 200;
const doctype = "<!doctype html>\n";

/// `publr_draw(page, result)`: the page `page` (`view_wire.Page`) describes, drawn, doctype
/// first; `Invalid` before `publr_frame` or for a page that is not sound, `NotFound` for a
/// component an installed plugin may not draw.
pub fn publr_draw(env: *wasm.Env, page_ptr: u32, result_ptr: u32) callconv(.c) u32 {
    const invocation = invoke.invocation_of(env) orelse {
        return wire.code_of(error.Unavailable);
    };
    const drawing = invocation.drawing orelse return wire.code_of(error.Invalid);
    var working = std.heap.ArenaAllocator.init(gpa);
    defer working.deinit();

    std.debug.assert(drawing.request.admin.framed);

    if (invocation.calls_left == 0) {
        return wire.code_of(error.Throttled);
    }

    invocation.calls_left -= 1;
    invocation.loaded.counted.host_calls += 1;

    const html = drawn(env, drawing, working.allocator(), page_ptr) catch |err| {
        return wire.code_of(err);
    };

    std.debug.assert(html.len >= doctype.len);

    return host_calls.reply(env, html, result_ptr);
}

fn drawn(
    env: *wasm.Env,
    drawing: *admin.drawn.Drawing,
    memory: std.mem.Allocator,
    page_ptr: u32,
) sdk.Error![]const u8 {
    var page: view_wire.Page = undefined;

    if (!env.read(page_ptr, std.mem.asBytes(&page))) {
        return error.Invalid;
    }

    const too_long = page.markup_len > view_wire.markup_bytes_max;

    if (too_long or page.components_len > view_wire.components_max) {
        return error.Invalid;
    }

    const markup = try copied(env, memory, page.markup, page.markup_len);
    const components = memory.alloc(view_wire.Component, page.components_len) catch {
        return error.OutOfMemory;
    };
    const parts = memory.alloc([]const u8, page.components_len) catch return error.OutOfMemory;

    if (components.len > 0 and !env.read(page.components, std.mem.sliceAsBytes(components))) {
        return error.Invalid;
    }

    var layouts: Layouts = .{
        .env = env,
        .memory = memory,
    };
    var left: u64 = props_bytes_max;

    for (components, parts) |component, *part| {
        part.* = try component_drawn(drawing, &layouts, component, &left);
    }

    var out: std.Io.Writer.Allocating = .init(memory);

    out.writer.writeAll(doctype) catch return error.OutOfMemory;
    try placed.expand(memory, &out.writer, markup, parts, page_bytes_max);

    std.debug.assert(out.written().len <= doctype.len + page_bytes_max);

    return out.written();
}

fn copied(env: *wasm.Env, memory: std.mem.Allocator, ptr: u32, len: u32) sdk.Error![]const u8 {
    std.debug.assert(len <= view_wire.markup_bytes_max);

    if (len == 0) {
        return "";
    }

    const bytes = memory.alloc(u8, len) catch return error.OutOfMemory;

    if (!env.read(ptr, bytes)) {
        return error.Invalid;
    }

    return bytes;
}

/// The layouts a page's components name, each read and checked once: the components of
/// one kind share theirs.
const Layouts = struct {
    env: *wasm.Env,
    memory: std.mem.Allocator,
    known: std.ArrayList(Known) = .empty,

    const Known = struct {
        ptr: u32,
        len: u32,
        described: Described,
    };

    fn of(layouts: *Layouts, ptr: u32, len: u32) sdk.Error!*const Described {
        std.debug.assert(layouts.known.items.len <= layouts_max);

        for (layouts.known.items) |*known| {
            if (known.ptr == ptr and known.len == len) {
                return &known.described;
            }
        }

        if (layouts.known.items.len == layouts_max) {
            return error.Invalid;
        }

        // Room for every layout is made at once: an address handed out stays good.
        layouts.known.ensureTotalCapacity(layouts.memory, layouts_max) catch {
            return error.OutOfMemory;
        };
        layouts.known.appendAssumeCapacity(.{
            .ptr = ptr,
            .len = len,
            .described = try shaped_read.description(layouts.env, layouts.memory, ptr, len),
        });

        return &layouts.known.items[layouts.known.items.len - 1].described;
    }
};

fn component_drawn(
    drawing: *admin.drawn.Drawing,
    layouts: *Layouts,
    component: view_wire.Component,
    left: *u64,
) sdk.Error![]const u8 {
    const memory = layouts.memory;

    std.debug.assert(left.* <= props_bytes_max);

    if (component.name_len == 0 or component.name_len > view_wire.name_len_max) {
        return error.Invalid;
    }

    const name = try copied(layouts.env, memory, component.name, component.name_len);

    if (!admin.drawn.callable(name)) {
        return error.NotFound;
    }

    var given: Given = .{
        .described = try layouts.of(component.described, component.described_len),
        .memory = .{
            .guest = layouts.env,
        },
        .arena = memory,
        .table = shaped_read.table_of(
            layouts.env,
            memory,
            component.table,
            component.table_len,
        ) catch |err| switch (err) {
            error.Invalid => return error.Invalid,
            error.OutOfMemory => return error.OutOfMemory,
        },
        .left = left.*,
    };
    const source: Source = .{
        .given = &given,
        .bytes = try given.window(Described.root, component.props),
    };
    const html = admin.drawn.draw(drawing, memory, name, source) catch |err| switch (err) {
        error.NotFound => return error.NotFound,
        error.Invalid => return error.Invalid,
        error.OutOfMemory => return error.OutOfMemory,
    };

    left.* = given.left;

    return html;
}

/// A component's props where the plugin left them, read into the design system's own.
pub const Source = struct {
    given: *Given,
    bytes: []const u8,

    /// Each prop the plugin sent, by its name; one it left out takes its default, one with
    /// no default must be there. A prop the component does not have is passed over: the
    /// plugin was built with another release's design system.
    pub fn read(source: Source, comptime Props: type) given_module.Error!Props {
        const info = @typeInfo(Props).@"struct";
        const given = source.given;

        // Each prop is looked at a few times while the reads are laid out: a handful of
        // steps a prop, however many the component has.
        @setEvalBranchQuota(1000 + info.field_names.len * steps_per_prop);

        var props: Props = undefined;
        var found: [info.field_names.len]bool = @splat(false);

        std.debug.assert(source.bytes.len >= given.described.span(Described.root));

        if (given.described.nodes[Described.root].kind != .object) {
            return error.Invalid;
        }

        for (given.described.fields_of(Described.root)) |field| {
            const inside = source.bytes[field.offset..];
            const none = given.described.nodes[field.node].kind == .optional and
                !given.present(field.node, inside);
            var taken = false;

            inline for (info.field_names, info.field_types, 0..) |name, Field, own| {
                if (comptime view_wire.crosses(Props, name)) {
                    const wanted = !taken and std.mem.eql(u8, field.name, name);

                    if (wanted and !(none and @typeInfo(Field) != .optional)) {
                        @field(props, name) = try prop(Field, given, field.node, inside);
                        found[own] = true;
                        taken = true;
                    }
                }
            }

            if (!taken) {
                try given.skip(field.node, inside);
            }
        }

        const names = info.field_names;

        inline for (names, info.field_types, info.field_attrs, 0..) |name, Field, attrs, own| {
            if (!found[own]) {
                if (comptime view_wire.node_of(Field) != null and @typeInfo(Field) != .optional) {
                    @field(props, name) = .{
                        .raw = "",
                    };
                } else if (attrs.defaultValue(Field)) |default| {
                    @field(props, name) = default;
                } else {
                    return error.Invalid;
                }
            }
        }

        return props;
    }
};

/// One prop: a node is the markup the plugin wrote for it, anything else its value.
fn prop(
    comptime Field: type,
    given: *Given,
    node: u32,
    bytes: []const u8,
) given_module.Error!Field {
    std.debug.assert(node < given.described.nodes.len);

    if (comptime view_wire.node_of(Field) == null) {
        return given_typed.read(Field, given, node, bytes, .{
            .ignore_unknown = true,
        });
    }

    const markup = try given_typed.read(?[]const u8, given, node, bytes, .{});

    if (comptime @typeInfo(Field) == .optional) {
        const html = markup orelse return null;

        return .{
            .raw = html,
        };
    }

    return .{
        .raw = markup orelse "",
    };
}
