//! JavaScript values cross into the ordinary Zig HTML writer, never raw interpolation.
const std = @import("std");
const sanitize = @import("../../lib/sanitize.zig");
const engine = @import("vm.zig");
const VM = engine.VM;
const Value = engine.Value;
const api = engine.api;
const escape = @import("../render.zig").escape;

pub fn Bridge(comptime Renderer: type, comptime Ctx: type) type {
    return struct {
        const Frame = Renderer.Frame;
        const Host = @import("host.zig").Host(Renderer, Ctx);

        pub fn begin(renderer: *const Renderer, frame: *Frame) !void {
            std.debug.assert(frame.template.javascript != null);

            if (frame.execution.vm == null) {
                const vm = try renderer.arena.create(VM);
                vm.* = try VM.init(renderer.arena);
                frame.execution.vm = vm;
                try vm.start();
            }

            const vm = frame.execution.vm.?;
            const global = api.JS_GetGlobalObject(vm.context);
            defer vm.free(global);
            const helpers = try vm.get(global, "__publr");
            defer vm.free(helpers);
            const publr_api = try vm.get(helpers, "api");
            defer vm.free(publr_api);
            bind(vm, frame);
            const props = try props_object(vm, frame);
            defer vm.free(props);
            try record_modules(frame);
            const function = try vm.factory(frame.template.rel, frame.template.javascript.?);
            defer vm.free(function);
            frame.js_scope = try vm.hold(vm.call(
                function,
                &.{ props, publr_api, helpers },
            ) catch |err|
                return vm.host_error orelse err);
        }

        fn bind(vm: *VM, frame: *Frame) void {
            std.debug.assert(frame.execution.vm == vm);
            vm.host = frame;
            vm.host_call = Host.call;
            vm.module_load = Host.module;
            vm.host_error = null;
        }

        fn record_modules(frame: *Frame) !void {
            std.debug.assert(frame.template.compiled);
            var pending: std.ArrayList(u32) = .empty;
            const vm = frame.execution.vm.?;
            try pending.appendSlice(vm.arena, frame.template.javascript_modules);
            var seen = std.StaticBitSet(512).initEmpty();

            while (pending.pop()) |index| {
                if (seen.isSet(index)) {
                    continue;
                }

                seen.set(index);
                const module_ = frame.execution.templates[index];

                if (@hasDecl(Ctx, "record_template")) {
                    frame.ctx.record_template(module_.rel);
                }

                try pending.appendSlice(vm.arena, module_.javascript_modules);

                if (pending.items.len > 65536) {
                    return error.TooManyModules;
                }
            }
        }

        fn props_object(vm: *VM, frame: *Frame) !Value {
            std.debug.assert(frame.template.compiled);
            const props = try vm.check(api.JS_NewObject(vm.context));
            errdefer vm.free(props);

            for (frame.props.values) |prop| {
                if (prop.value) |text| {
                    const value = switch (prop.kind) {
                        .string => try vm.string(text),
                        .number => api.publr_js_number(
                            vm.context,
                            try std.fmt.parseFloat(f64, text),
                        ),
                        .boolean => api.publr_js_boolean(
                            vm.context,
                            @intFromBool(std.mem.eql(u8, text, "true")),
                        ),
                    };
                    try vm.set(props, prop.name, value);
                }
            }

            const entries = try vm.check(api.JS_NewObject(vm.context));
            defer vm.free(entries);

            for (frame.props.entries) |prop| {
                const value = try Host.entry(vm, frame, prop.value);
                try vm.set(entries, prop.name, vm.dup(value));
                try vm.set(props, prop.name, value);
            }

            try vm.set(props, "entry", vm.dup(entries));

            for (frame.props.javascript) |prop| {
                try vm.set(props, prop.name, vm.dup(prop.value));

                if (api.JS_IsObject(prop.value)) {
                    const handle = try vm.get(prop.value, "__publr_entry");
                    defer vm.free(handle);

                    if (api.JS_IsNumber(handle)) {
                        try vm.set(entries, prop.name, vm.dup(prop.value));
                    }
                }
            }

            return props;
        }

        pub fn eval(_: *const Renderer, frame: *Frame, index: u32) !Value {
            std.debug.assert(frame.js_scope != null);
            const vm = frame.execution.vm.?;
            const function = try vm.item(frame.js_scope.?, index);
            defer vm.free(function);
            bind(vm, frame);
            return vm.hold(vm.call(function, &.{}) catch |err| return vm.host_error orelse err);
        }

        pub fn write(
            renderer: *const Renderer,
            frame: *Frame,
            writer: *std.Io.Writer,
            value: Value,
        ) !void {
            std.debug.assert(frame.execution.vm != null);
            var buffer: std.Io.Writer.Allocating = .init(renderer.arena);
            try write_node(renderer, frame, &buffer, value, 0);
            try writer.writeAll(buffer.written());
        }

        fn write_node(
            renderer: *const Renderer,
            frame: *Frame,
            buffer: *std.Io.Writer.Allocating,
            value: Value,
            depth: u32,
        ) anyerror!void {
            std.debug.assert(!api.JS_IsException(value));
            const vm = frame.execution.vm.?;

            if (depth >= 64 or buffer.written().len > engine.output_bytes_max) {
                return error.JavaScriptOutputLimit;
            }

            if (api.JS_IsNull(value) or api.JS_IsUndefined(value) or api.JS_IsBool(value)) {
                return;
            }

            if (api.JS_IsString(value) or api.JS_IsNumber(value)) {
                try escape(&buffer.writer, try vm.text(value));
            } else if (api.JS_IsArray(value)) {
                const size = try vm.length(value);

                for (0..size) |index| {
                    const item = try vm.item(value, @intCast(index));
                    defer vm.free(item);
                    try write_node(renderer, frame, buffer, item, depth + 1);
                }
            } else {
                if (!api.JS_IsObject(value)) {
                    return error.InvalidJavaScriptChild;
                }

                try descriptor(renderer, frame, buffer, value, depth + 1);
            }

            if (buffer.written().len > engine.output_bytes_max) {
                return error.JavaScriptOutputLimit;
            }
        }

        fn descriptor(
            renderer: *const Renderer,
            frame: *Frame,
            buffer: *std.Io.Writer.Allocating,
            value: Value,
            depth: u32,
        ) anyerror!void {
            std.debug.assert(api.JS_IsObject(value));
            const vm = frame.execution.vm.?;
            try check_descriptor(vm, value);
            const kind_value = try vm.get(value, "kind");
            defer vm.free(kind_value);
            const kind = try vm.text(kind_value);

            if (std.mem.eql(u8, kind, "text")) {
                const text = try vm.get(value, "value");
                defer vm.free(text);
                return buffer.writer.writeAll(try vm.text(text));
            }

            const children = try vm.get(value, "children");
            defer vm.free(children);
            const attributes = try vm.get(value, "attributes");
            defer vm.free(attributes);

            if (std.mem.eql(u8, kind, "component")) {
                return component(renderer, frame, buffer, value, attributes, children, depth);
            }

            if (!std.mem.eql(u8, kind, "element")) {
                return error.InvalidJavaScriptChild;
            }

            const name_value = try vm.get(value, "name");
            defer vm.free(name_value);
            const name = try vm.text(name_value);

            if (!valid_name(name)) {
                return error.InvalidJavaScriptElement;
            }

            if (std.mem.eql(u8, name, "slot")) {
                return buffer.writer.writeAll(frame.props.children);
            }

            try buffer.writer.print("<{s}", .{name});
            try write_attributes(vm, &buffer.writer, attributes);
            try buffer.writer.writeAll(">");

            if (is_void(name)) {
                return;
            }

            const raw = try vm.get(attributes, "set:html");
            defer vm.free(raw);

            if (!api.JS_IsUndefined(raw)) {
                try write_raw(vm, &buffer.writer, raw);
            } else try write_node(renderer, frame, buffer, children, depth);

            if (std.mem.eql(u8, name, "head")) {
                try frame.ctx.head_assets(&buffer.writer);
            }

            try buffer.writer.print("</{s}>", .{name});
        }

        fn component(
            renderer: *const Renderer,
            frame: *Frame,
            buffer: *std.Io.Writer.Allocating,
            descriptor_: Value,
            attributes: Value,
            children: Value,
            depth: u32,
        ) anyerror!void {
            std.debug.assert(api.JS_IsObject(attributes));
            const vm = frame.execution.vm.?;
            const number = try vm.get(descriptor_, "index");
            defer vm.free(number);
            var index: u32 = 0;

            const status = api.JS_ToUint32(vm.context, &index, number);

            if (status < 0 or index >= renderer.templates.len) {
                return error.InvalidTemplate;
            }

            var props: std.ArrayList(Renderer.JavaScriptProp) = .empty;
            const names = try property_names(vm, attributes);

            for (names) |name| {
                const item = try vm.hold(try vm.get(attributes, name));
                try props.append(renderer.arena, .{ .name = name, .value = item });
            }

            var inner: std.Io.Writer.Allocating = .init(renderer.arena);
            try write_node(renderer, frame, &inner, children, depth);
            defer bind(vm, frame);
            try renderer.render_at(&buffer.writer, index, frame.ctx, .{
                .javascript = props.items,
                .children = inner.written(),
            }, frame.depth + 1, frame.execution);
        }

        pub fn native_props(renderer: *const Renderer, frame: *Frame) !void {
            std.debug.assert(frame.template.compiled);

            if (frame.props.javascript.len == 0) {
                return;
            }

            const vm = frame.execution.vm.?;
            var props: std.ArrayList(@import("../render.zig").Prop) = .empty;
            var entries: std.ArrayList(Renderer.EntryProp) = .empty;
            try props.appendSlice(renderer.arena, frame.props.values);
            try entries.appendSlice(renderer.arena, frame.props.entries);

            for (frame.props.javascript) |prop| {
                if (api.JS_IsUndefined(prop.value)) {
                    continue;
                }

                if (api.JS_IsObject(prop.value)) {
                    const handle = try vm.get(prop.value, "__publr_entry");
                    defer vm.free(handle);
                    var index: u32 = 0;

                    if (!api.JS_IsNumber(handle) or
                        api.JS_ToUint32(vm.context, &index, handle) < 0 or
                        index >= frame.execution.entries.items.len) return error.InvalidEntry;
                    try entries.append(
                        renderer.arena,
                        .{ .name = prop.name, .value = frame.execution.entries.items[index] },
                    );
                    continue;
                }

                const text = if (api.JS_IsNull(prop.value)) null else try scalar(vm, prop.value);
                try props.append(
                    renderer.arena,
                    .{
                        .name = prop.name,
                        .value = text,
                        .kind = if (api.JS_IsNumber(prop.value))
                            .number
                        else if (api.JS_IsBool(prop.value)) .boolean else .string,
                    },
                );
            }

            frame.props.values = props.items;
            frame.props.entries = entries.items;
        }

        pub fn write_raw(vm: *VM, writer: *std.Io.Writer, value: Value) !void {
            std.debug.assert(!api.JS_IsException(value));

            if (api.JS_IsNull(value) or api.JS_IsUndefined(value)) {
                return;
            }

            if (!api.JS_IsString(value)) {
                return error.InvalidRawHTML;
            }

            const text = try vm.text(value);

            try writer.writeAll(try sanitize.sanitize(vm.arena, text, .content));
        }

        pub fn attribute(vm: *VM, writer: *std.Io.Writer, name: []const u8, value: Value) !void {
            std.debug.assert(!api.JS_IsException(value));

            if (!valid_name(name)) {
                return error.InvalidJavaScriptAttribute;
            }

            if (api.JS_IsNull(value) or api.JS_IsUndefined(value)) {
                return;
            }

            const textual = std.mem.startsWith(u8, name, "aria-") or
                std.mem.startsWith(u8, name, "data-");

            if (api.JS_IsBool(value) and !textual) {
                if (api.JS_ToBool(vm.context, value) == 1) {
                    try writer.print(" {s}", .{name});
                }

                return;
            }

            try writer.print(" {s}=\"", .{name});
            try escape(writer, try scalar(vm, value));
            try writer.writeByte('"');
        }

        fn write_attributes(vm: *VM, writer: *std.Io.Writer, attributes: Value) !void {
            std.debug.assert(api.JS_IsObject(attributes));

            for (try property_names(vm, attributes)) |name| {
                if (std.mem.eql(u8, name, "set:html")) {
                    continue;
                }

                const value = try vm.get(attributes, name);
                defer vm.free(value);
                try attribute(vm, writer, name, value);
            }
        }
    };
}

fn scalar(vm: *VM, value: Value) ![]const u8 {
    std.debug.assert(!api.JS_IsException(value));

    if (!api.JS_IsString(value) and !api.JS_IsNumber(value) and !api.JS_IsBool(value)) {
        return error.InvalidJavaScriptScalar;
    }

    return vm.text(value);
}

fn check_descriptor(vm: *VM, value: Value) !void {
    std.debug.assert(api.JS_IsObject(value));
    const global = api.JS_GetGlobalObject(vm.context);
    defer vm.free(global);
    const helpers = try vm.get(global, "__publr");
    defer vm.free(helpers);
    const check = try vm.get(helpers, "isNode");
    defer vm.free(check);
    const result = try vm.call(check, &.{value});
    defer vm.free(result);

    if (api.JS_ToBool(vm.context, result) != 1) {
        return error.InvalidJavaScriptChild;
    }
}

pub fn property_names(vm: *VM, object: Value) ![]const []const u8 {
    std.debug.assert(api.JS_IsObject(object));
    var table: [*c]api.JSPropertyEnum = null;
    var count: u32 = 0;

    const status = api.JS_GetOwnPropertyNames(
        vm.context,
        &table,
        &count,
        object,
        api.JS_GPN_STRING_MASK | api.JS_GPN_ENUM_ONLY,
    );

    if (status < 0) {
        return error.JavaScript;
    }

    defer api.JS_FreePropertyEnum(vm.context, table, count);

    if (count > 128) {
        return error.TooManyJavaScriptProperties;
    }

    const names = try vm.arena.alloc([]const u8, count);

    for (names, 0..) |*name, index| {
        const text = api.JS_AtomToCString(vm.context, table[index].atom);

        if (text == null) {
            return error.OutOfMemory;
        }

        defer api.JS_FreeCString(vm.context, text);
        name.* = try vm.arena.dupe(u8, std.mem.span(text));
    }

    return names;
}

fn valid_name(name: []const u8) bool {
    std.debug.assert(name.len <= 1 << 24);

    if (name.len == 0 or name.len > 256) {
        return false;
    }

    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and
            byte != ':' and byte != '.')
        {
            return false;
        }
    }

    return true;
}

fn is_void(name: []const u8) bool {
    std.debug.assert(name.len > 0);
    const names = [_][]const u8{
        "area",  "base", "br",   "col",    "embed", "hr",  "img",
        "input", "link", "meta", "source", "track", "wbr",
    };

    for (names) |item| {
        if (std.mem.eql(u8, name, item)) {
            return true;
        }
    }

    return false;
}
