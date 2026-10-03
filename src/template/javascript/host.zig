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

            if (std.mem.eql(u8, method, "money")) {
                return money(vm, frame.ctx, args);
            }

            if (std.mem.eql(u8, method, "get") or std.mem.eql(u8, method, "findOne")) {
                return one_record(vm, frame, method, args);
            }

            if (std.mem.eql(u8, method, "find")) {
                return found_records(vm, frame, args);
            }

            if (std.mem.eql(u8, method, "query")) {
                return queried(vm, frame, args);
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

            if (std.mem.eql(u8, method, "param")) {
                return optional(vm, try ctx.query_param(text));
            }

            if (std.mem.eql(u8, method, "userField")) {
                return optional(vm, try ctx.user_field(text));
            }

            if (std.mem.eql(u8, method, "call")) {
                const given = try vm.item(args, 1);
                defer vm.free(given);
                const input = if (api.JS_IsString(given)) try string(vm, given) else "";

                return answer(vm, try ctx.call_with(text, input));
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

        /// `get(type, id)`: the live record by id when it is of that type; `findOne(type, field,
        /// value)`: the one whose field holds the value. Null for none; two for findOne fail.
        fn one_record(vm: *VM, frame: *Frame, method: []const u8, args: Value) !Value {
            std.debug.assert(api.JS_IsArray(args));
            std.debug.assert(method.len > 0);

            const type_value = try vm.item(args, 0);
            defer vm.free(type_value);
            const second = try vm.item(args, 1);
            defer vm.free(second);
            const type_id = try string(vm, type_value);

            if (std.mem.eql(u8, method, "get")) {
                const got = try frame.ctx.get_record(type_id, try string(vm, second)) orelse {
                    return api.publr_js_null();
                };

                return entry(vm, frame, got);
            }

            const third = try vm.item(args, 2);
            defer vm.free(third);
            const field = try string(vm, second);
            const wanted = try string(vm, third);
            const listed = try frame.ctx.find_records(type_id, field, wanted, 2, 0);

            if (listed.len > 1) {
                return error.FindOneFoundTwo;
            }

            return if (listed.len == 0) api.publr_js_null() else entry(vm, frame, listed[0]);
        }

        /// `find(type, { field: value }, { limit, offset })`: live records, newest first; `where`
        /// names at most one field, matched by equality.
        fn found_records(vm: *VM, frame: *Frame, args: Value) !Value {
            std.debug.assert(api.JS_IsArray(args));
            std.debug.assert(frame.template.rel.len > 0);

            const type_value = try vm.item(args, 0);
            defer vm.free(type_value);
            const where_value = try vm.item(args, 1);
            defer vm.free(where_value);
            const page_value = try vm.item(args, 2);
            defer vm.free(page_value);
            const where = try parsed(vm, where_value);
            const page = try parsed(vm, page_value);

            if (where != .object or where.object.count() > 1 or page != .object) {
                return error.FindTakesOneField;
            }

            var field: []const u8 = "";
            var wanted: []const u8 = "";

            if (where.object.count() == 1) {
                field = where.object.keys()[0];
                wanted = try scalar_text(vm.arena, where.object.values()[0]);
            }

            const limit = number_of(page, "limit") orelse 50;
            const offset = number_of(page, "offset") orelse 0;
            const type_id = try string(vm, type_value);
            const listed = try frame.ctx.find_records(type_id, field, wanted, limit, offset);
            return collection(vm, frame, listed);
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

        /// An operation's answer as the page reads it: `{ data: <the answer> }`, the answer
        /// plain JSON as the operation returned it; its lists are not records.
        fn answer(vm: *VM, value: Ctx.Entry) !Value {
            const object = try vm.check(api.JS_NewObject(vm.context));
            errdefer vm.free(object);
            const document = try value.data.javascript_value(vm.arena);

            std.debug.assert(document == .object);

            try vm.set(object, "data", try json(vm, document));

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
    // QuickJS reads to a terminating NUL, not to the length given: without one it reads
    // whatever the arena holds next.
    const terminated = try vm.arena.dupeZ(u8, text);

    std.debug.assert(terminated.len == text.len);

    return vm.check(api.JS_ParseJSON(vm.context, terminated.ptr, terminated.len, "publr:data"));
}

/// `query(groq, params)`: the answer as plain JSON.
fn queried(vm: *VM, frame: anytype, args: Value) !Value {
    std.debug.assert(api.JS_IsArray(args));

    const text_value = try vm.item(args, 0);
    defer vm.free(text_value);
    const given = try vm.item(args, 1);
    defer vm.free(given);
    const text = try string(vm, text_value);
    const params = if (api.JS_IsString(given)) try string(vm, given) else "{}";

    return json_text(vm, try frame.ctx.run_query(text, params));
}

/// JSON text as a JavaScript value, as a query answers it.
fn json_text(vm: *VM, text: []const u8) !Value {
    std.debug.assert(text.len > 0);

    const terminated = try vm.arena.dupeZ(u8, text);

    return vm.check(api.JS_ParseJSON(vm.context, terminated.ptr, terminated.len, "publr:query"));
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

/// `money(price)` or `money(price, "EUR")`: the amount the site's default (or the named)
/// currency holds in `price`, written as the site writes it; "" when it holds none.
fn money(vm: *VM, ctx: anytype, args: Value) !Value {
    std.debug.assert(api.JS_IsArray(args));

    const price = try vm.item(args, 0);
    defer vm.free(price);
    const named = try vm.item(args, 1);
    defer vm.free(named);
    const wanted: ?[]const u8 = if (api.JS_IsString(named)) try string(vm, named) else null;
    const currency = try ctx.money_code(wanted) orelse return vm.string("");

    if (!api.JS_IsObject(price)) {
        return vm.string("");
    }

    const held = try vm.get(price, currency);
    defer vm.free(held);
    var amount: i64 = 0;

    if (!api.JS_IsNumber(held) or api.JS_ToInt64(vm.context, &amount, held) < 0) {
        return vm.string("");
    }

    return vm.string(try ctx.money(amount, currency));
}

fn parsed(vm: *VM, value: Value) !std.json.Value {
    std.debug.assert(!api.JS_IsException(value));

    return std.json.parseFromSliceLeaky(std.json.Value, vm.arena, try string(vm, value), .{});
}

fn scalar_text(arena: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    std.debug.assert(@intFromEnum(value) <= 8);

    return switch (value) {
        .string => |text| text,
        .integer => |number| std.fmt.allocPrint(arena, "{d}", .{number}),
        .bool => |flag| if (flag) "true" else "false",
        else => error.FindTakesOneField,
    };
}

fn number_of(object: std.json.Value, key: []const u8) ?u32 {
    std.debug.assert(key.len > 0);

    const value = object.object.get(key) orelse return null;

    if (value != .integer or value.integer < 0) {
        return null;
    }

    return @intCast(@min(value.integer, 200));
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
