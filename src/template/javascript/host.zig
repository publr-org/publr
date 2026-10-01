//! Every script data read goes through the same context as native templates.
const std = @import("std");
const engine = @import("vm.zig");
const VM = engine.VM;
const Value = engine.Value;
const api = engine.api;
const time = @import("../../lib/time.zig");

pub fn Host(comptime Renderer: type, comptime Ctx: type) type {
    return struct {
        const Frame = Renderer.Frame;

        pub fn module(userdata: *anyopaque, _: *VM, name: []const u8) ![]const u8 {
            std.debug.assert(name.len > 0);
            const frame: *Frame = @ptrCast(@alignCast(userdata));

            for (frame.execution.templates) |template| {
                if (template.kind == .module and std.mem.eql(u8, template.rel, name)) {
                    return template.javascript.?;
                }
            }

            return error.MissingModule;
        }

        pub fn call(userdata: *anyopaque, vm: *VM, name: []const u8, args: Value) anyerror!Value {
            std.debug.assert(api.JS_IsArray(args));
            const frame: *Frame = @ptrCast(@alignCast(userdata));
            const dot = std.mem.indexOfScalar(u8, name, '.') orelse return error.InvalidPublrCall;
            const request = std.mem.eql(u8, name[0..dot], "request");

            if (request and !frame.template.dynamic) {
                return error.StaticRequestAccess;
            }

            const method = name[dot + 1 ..];

            if (std.mem.eql(u8, method, "getEntry")) {
                return get_entry(vm, frame, args);
            }

            if (std.mem.eql(u8, method, "getCollection")) {
                return get_collection(vm, frame, args);
            }

            if (std.mem.eql(u8, method, "getReferences")) {
                return references(vm, frame, args, false);
            }

            if (std.mem.eql(u8, method, "getReference")) {
                return references(vm, frame, args, true);
            }

            if (std.mem.eql(u8, method, "now")) {
                const stamp = if (request) frame.ctx.now() else frame.ctx.build_time();
                return vm.string(try time.datetime_text(vm.arena, stamp));
            }

            if (!request) {
                return error.RequestOnlyAPI;
            }

            return request_call(vm, frame, method, args);
        }

        fn request_call(vm: *VM, frame: *Frame, method: []const u8, args: Value) !Value {
            std.debug.assert(api.JS_IsArray(args));
            const ctx = frame.ctx;

            if (std.mem.eql(u8, method, "session")) {
                const session = try ctx.session();

                if (session.email == null) {
                    return api.publr_js_null();
                }

                const object = try vm.check(api.JS_NewObject(vm.context));
                try vm.set(object, "email", try vm.string(session.email.?));
                return object;
            }

            const first = try vm.item(args, 0);
            defer vm.free(first);

            if (std.mem.eql(u8, method, "random")) {
                const bound = try positive(vm, first);
                return api.publr_js_number(vm.context, @floatFromInt(ctx.random(bound)));
            }

            const text = try string(vm, first);

            if (std.mem.eql(u8, method, "header")) {
                return optional(vm, ctx.header(text));
            }

            if (std.mem.eql(u8, method, "cookie")) {
                return optional(vm, ctx.cookie(text));
            }

            if (std.mem.eql(u8, method, "userField")) {
                return optional(vm, try ctx.user_field(text));
            }

            if (std.mem.eql(u8, method, "call")) {
                return entry(vm, frame, try ctx.call(text));
            }

            if (std.mem.eql(u8, method, "redirect")) {
                if (frame.template.kind != .page) {
                    return error.ComponentRedirect;
                }

                if (text.len > 0) {
                    try ctx.redirect(text);
                    return error.Redirect;
                }

                return api.publr_js_undefined();
            }

            return error.InvalidPublrCall;
        }

        fn get_entry(vm: *VM, frame: *Frame, args: Value) !Value {
            std.debug.assert(api.JS_IsArray(args));
            const options = try vm.item(args, 0);
            defer vm.free(options);
            const type_name = try option_string(vm, options, "type");
            const slug = try option_string(vm, options, "slug");
            const type_id = type_name orelse try inferred_type(frame.template.rel);
            const at_slug = std.mem.indexOf(u8, frame.template.rel, "[slug]") != null;

            if (slug) |chosen| {
                return entry(vm, frame, try frame.ctx.entry(type_id, chosen));
            }

            if (!at_slug and type_name != null) {
                return entry(vm, frame, try frame.ctx.first(type_id));
            }

            if (!at_slug) {
                return error.MissingEntryRoute;
            }

            return entry(
                vm,
                frame,
                try frame.ctx.entry(type_id, frame.ctx.param("slug") orelse "unknown"),
            );
        }

        fn get_collection(vm: *VM, frame: *Frame, args: Value) !Value {
            std.debug.assert(api.JS_IsArray(args));
            const options = try vm.item(args, 0);
            defer vm.free(options);
            const type_id = try option_string(vm, options, "type") orelse
                try inferred_type(frame.template.rel);
            const values = try frame.ctx.query(type_id, .{
                .limit = try option_number(vm, options, "limit"),
                .offset = try option_number(vm, options, "offset"),
            });
            return collection(vm, frame, values);
        }

        fn references(vm: *VM, frame: *Frame, args: Value, one: bool) !Value {
            std.debug.assert(api.JS_IsArray(args));
            const object = try vm.item(args, 0);
            defer vm.free(object);
            const field = try vm.item(args, 1);
            defer vm.free(field);
            const index_value = try vm.get(object, "__publr_entry");
            defer vm.free(index_value);
            var index: u32 = 0;

            const status = api.JS_ToUint32(vm.context, &index, index_value);

            if (!api.JS_IsNumber(index_value) or status < 0) {
                return error.InvalidEntry;
            }

            if (index >= frame.execution.entries.items.len) {
                return error.InvalidEntry;
            }

            const owner = frame.execution.entries.items[index];
            const ids = try owner.data.getIds(vm.arena, try string(vm, field));

            if (one) {
                return entry(vm, frame, try frame.ctx.reference(ids));
            }

            return collection(vm, frame, try frame.ctx.references(ids));
        }

        pub fn entry(vm: *VM, frame: *Frame, value: Ctx.Entry) !Value {
            return entry_at(vm, frame, value, 0);
        }

        fn entry_at(vm: *VM, frame: *Frame, value: Ctx.Entry, depth: u32) anyerror!Value {
            std.debug.assert(frame.template.compiled);

            if (depth >= 64) {
                return error.EntryNestingLimit;
            }

            if (frame.execution.entries.items.len == 65536) {
                return error.TooManyEntries;
            }

            const object = try vm.check(api.JS_NewObject(vm.context));
            errdefer vm.free(object);

            inline for (.{ "id", "type", "title", "created_at", "updated_at" }) |key| {
                try vm.set(object, key, try vm.string(@field(value, key)));
            }

            try vm.set(object, "slug", try optional(vm, value.slug));
            try vm.set(
                object,
                "__publr_entry",
                api.publr_js_number(vm.context, @floatFromInt(frame.execution.entries.items.len)),
            );
            try frame.execution.entries.append(vm.arena, value);
            try vm.set(object, "data", try data_value(vm, frame, value.data, depth + 1));
            return object;
        }

        fn data_value(vm: *VM, frame: *Frame, data: Ctx.Data, depth: u32) !Value {
            const document = try data.javascript_value(vm.arena);
            std.debug.assert(document == .object);
            const object = try json(vm, document);
            errdefer vm.free(object);
            var fields = document.object.iterator();

            while (fields.next()) |field| {
                const value = field.value_ptr.*;

                if (value != .array) {
                    continue;
                }

                const has_rows = for (value.array.items) |item| {
                    if (item == .object) break true;
                } else false;

                if (has_rows) {
                    const rows = try data.getItems(vm.arena, field.key_ptr.*);
                    try vm.set(object, field.key_ptr.*, try collection_at(vm, frame, rows, depth));
                }
            }

            return object;
        }

        fn collection(vm: *VM, frame: *Frame, values: []const Ctx.Entry) !Value {
            return collection_at(vm, frame, values, 0);
        }

        fn collection_at(vm: *VM, frame: *Frame, values: []const Ctx.Entry, depth: u32) !Value {
            std.debug.assert(frame.template.compiled);

            if (values.len > 65536) {
                return error.TooManyEntries;
            }

            const array = try vm.check(api.JS_NewArray(vm.context));
            errdefer vm.free(array);

            for (values, 0..) |value, index| {
                if (api.JS_SetPropertyUint32(
                    vm.context,
                    array,
                    @intCast(index),
                    try entry_at(vm, frame, value, depth),
                ) < 0) {
                    return error.JavaScript;
                }
            }

            return array;
        }
    };
}

fn json(vm: *VM, value: std.json.Value) !Value {
    const text = try std.json.Stringify.valueAlloc(vm.arena, value, .{});
    return vm.check(api.JS_ParseJSON(vm.context, text.ptr, text.len, "publr:data"));
}

fn optional(vm: *VM, text: ?[]const u8) !Value {
    return if (text) |present| vm.string(present) else api.publr_js_null();
}

fn string(vm: *VM, value: Value) ![]const u8 {
    std.debug.assert(!api.JS_IsException(value));

    if (!api.JS_IsString(value)) {
        return error.ExpectedString;
    }

    return vm.text(value);
}

fn option_string(vm: *VM, object: Value, key: []const u8) !?[]const u8 {
    std.debug.assert(key.len > 0);

    if (api.JS_IsUndefined(object)) {
        return null;
    }

    if (!api.JS_IsObject(object) or api.JS_IsNull(object)) {
        return error.ExpectedOptions;
    }

    const value = try vm.get(object, key);
    defer vm.free(value);

    if (api.JS_IsUndefined(value)) {
        return null;
    }

    return try string(vm, value);
}

fn option_number(vm: *VM, object: Value, key: []const u8) !?u32 {
    std.debug.assert(key.len > 0);

    if (api.JS_IsUndefined(object)) {
        return null;
    }

    const value = try vm.get(object, key);
    defer vm.free(value);

    if (api.JS_IsUndefined(value)) {
        return null;
    }

    var number: f64 = 0;

    if (!api.JS_IsNumber(value) or api.JS_ToFloat64(vm.context, &number, value) < 0) {
        return error.ExpectedNumber;
    }

    const in_range = std.math.isFinite(number) and number >= 0 and
        number <= std.math.maxInt(u32);

    if (!in_range or @floor(number) != number) {
        return error.ExpectedNumber;
    }

    return @intFromFloat(number);
}

fn positive(vm: *VM, value: Value) !u32 {
    std.debug.assert(!api.JS_IsException(value));
    var number: f64 = 0;

    if (!api.JS_IsNumber(value) or api.JS_ToFloat64(vm.context, &number, value) < 0) {
        return error.ExpectedNumber;
    }

    const in_range = std.math.isFinite(number) and number > 0 and
        number <= std.math.maxInt(u32);

    if (!in_range or @floor(number) != number) {
        return error.ExpectedNumber;
    }

    return @intFromFloat(number);
}

fn inferred_type(rel: []const u8) ![]const u8 {
    std.debug.assert(rel.len > 0);

    if (!std.mem.startsWith(u8, rel, "content/")) {
        return error.MissingType;
    }

    const path = rel["content/".len..];
    const cut = std.mem.lastIndexOfScalar(u8, path, '/') orelse {
        return if (std.mem.startsWith(u8, path, "[slug]")) "page" else error.MissingType;
    };
    const dir = path[0..cut];
    const name = if (std.mem.lastIndexOfScalar(u8, dir, '/')) |at| dir[at + 1 ..] else dir;
    return if (std.mem.endsWith(u8, name, "s")) name[0 .. name.len - 1] else name;
}
