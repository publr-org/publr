const std = @import("std");
const publr = @import("publr");

const db = publr.db;
const files = publr.lib.files;
const routes = publr.routes;
const auth = publr.auth;
const http = publr.http;

const heap_bytes: u32 = 16 << 20;
const arena_bytes: u32 = 4 << 20;
const request_bytes_max: u32 = 8 << 20;
/// What one allocation from the worker may hold: a request, or a file it hands over.
const allocation_bytes_max: u32 = files.bytes_max;
/// How many runs a request gets to name the files it needs, one at a time.
const needs_max: u32 = files.kept_elsewhere.attachments_max;
const allocations_max: u32 = 64;

const State = struct {
    gpa: std.mem.Allocator,
    heap: []align(8) u8,
    runtime: db.Runtime,
    connection: db.Db,
    auth: auth.State,
    project: routes.Project,
    app: http.App,
    io_backend: std.Io.Threaded,
    arena_buffer: []u8,
    response: []u8,
    /// The last response's body, which the worker reads by pointer: it may be bytes.
    body: []const u8,
    allocations: [allocations_max]?[]u8,
    /// The media library's files, which the worker keeps in OPFS.
    deferred: files.Deferred,
};

// A wasm module is one instance behind a C ABI; the exports below are its only record points.
var state: ?*State = null;

const RequestJson = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8 = "",
    headers: []const Header = &.{},
    body: []const u8 = "",

    const Header = struct { name: []const u8, value: []const u8 };
};

const ResponseJson = struct {
    status: u16,
    headers: []const RequestJson.Header,
    /// A file the request needs and the worker has not handed over: attach it, run again.
    need: ?Wanted = null,
    /// What to do in OPFS once the response is taken, in order; each one's bytes by index.
    effects: []const Effect = &.{},

    const Wanted = struct { area: []const u8, key: []const u8 };
    const Effect = struct { kind: []const u8, area: []const u8, key: []const u8, offset: u64 };
};

export fn publr_init() i32 {
    if (state != null) {
        return 0;
    }

    const gpa = std.heap.wasm_allocator;
    const instance = gpa.create(State) catch return 1;

    initialize(instance, gpa) catch |err| {
        gpa.destroy(instance);
        return switch (err) {
            error.Heap => 2,
            error.Runtime => 3,
            error.Database => 4,
            error.Arena => 5,
            error.Auth => 6,
            error.Bootstrap => 7,
        };
    };
    state = instance;
    return 0;
}

const InitError = error{ Heap, Runtime, Database, Arena, Auth, Bootstrap };

fn initialize(instance: *State, gpa: std.mem.Allocator) InitError!void {
    instance.gpa = gpa;
    std.debug.assert(heap_bytes >= db.heap_bytes_min);
    instance.heap = gpa.alignedAlloc(u8, .@"8", heap_bytes) catch return error.Heap;
    errdefer gpa.free(instance.heap);
    instance.runtime = db.Runtime.init(.{ .heap = instance.heap }) catch return error.Runtime;
    errdefer instance.runtime.deinit();
    instance.connection = db.open(&instance.runtime, ":memory:") catch return error.Database;
    errdefer instance.connection.close();
    db.schema.apply(&instance.connection) catch return error.Database;
    publr.registry.SDK.apply_schemas(&instance.connection) catch return error.Database;
    open_index(&instance.connection) catch return error.Database;
    instance.io_backend = std.Io.Threaded.init(gpa, .{});
    errdefer instance.io_backend.deinit();
    instance.auth.init(gpa, instance.io_backend.io(), .{}) catch return error.Auth;
    errdefer instance.auth.deinit();
    instance.project = .{
        .connection = &instance.connection,
        .auth = &instance.auth,
        .io = instance.io_backend.io(),
    };
    instance.app = http.App.offline(.{});
    instance.app.user_data = &instance.project;
    instance.arena_buffer = gpa.alloc(u8, arena_bytes) catch return error.Arena;
    errdefer gpa.free(instance.arena_buffer);
    instance.response = &.{};
    instance.body = &.{};
    instance.allocations = @splat(null);
    instance.deferred = files.Deferred.init(gpa);
    instance.project.files = .{ .deferred = &instance.deferred };
    routes.register(instance.app.router());
    apply_declared_types(instance) catch return error.Bootstrap;
    std.debug.assert(instance.app.routes.routes_len > 0);
    std.debug.assert(instance.runtime.open_count == 1);
}

export fn publr_deinit() void {
    const instance = state orelse return;
    state = null;

    for (instance.allocations) |allocation| {
        if (allocation) |bytes| instance.gpa.free(bytes);
    }

    instance.deferred.deinit();
    instance.gpa.free(instance.response);
    instance.gpa.free(instance.arena_buffer);
    instance.auth.deinit();
    instance.io_backend.deinit();
    instance.connection.close();
    instance.runtime.deinit();
    instance.gpa.free(instance.heap);
    instance.gpa.destroy(instance);
}

export fn publr_alloc(len: u32) ?[*]u8 {
    const instance = state orelse return null;

    if (len == 0 or len > allocation_bytes_max) {
        return null;
    }

    for (&instance.allocations) |*slot| {
        if (slot.* != null) continue;
        const bytes = instance.gpa.alloc(u8, len) catch return null;
        slot.* = bytes;
        return bytes.ptr;
    }

    return null;
}

export fn publr_free(ptr: [*]u8, len: u32) void {
    const instance = state orelse return;

    for (&instance.allocations) |*slot| {
        const bytes = slot.* orelse continue;
        if (bytes.ptr == ptr and bytes.len == len) {
            instance.gpa.free(bytes);
            slot.* = null;
            return;
        }
    }
}

/// Validate C ABI pointers against allocations we own before constructing a slice.
fn owns(instance: *const State, ptr: [*]const u8, len: u32) bool {
    std.debug.assert(instance.runtime.open_count == 1);

    if (len == 0 or len > allocation_bytes_max) {
        return false;
    }

    for (instance.allocations) |allocation| {
        const bytes = allocation orelse continue;
        if (bytes.ptr == ptr and len <= bytes.len) return true;
    }

    return false;
}

/// One request: its head as JSON at `ptr`, its body's bytes as they are at `body_ptr`
/// (`body_len` 0 for none), both from `publr_alloc`.
export fn publr_request(ptr: [*]const u8, len: u32, body_ptr: [*]const u8, body_len: u32) i32 {
    const instance = state orelse return 1;

    if (!owns(instance, ptr, len)) {
        return 2;
    }

    if (body_len > 0 and !owns(instance, body_ptr, body_len)) {
        return 2;
    }

    var arena_state = std.heap.FixedBufferAllocator.init(instance.arena_buffer);
    const arena = arena_state.allocator();

    const json_in = ptr[0..len];
    const parsed = publr.lib.json.parse(RequestJson, arena, json_in, .{}) catch return 3;
    var head = build_request(parsed) catch return 4;

    const body = if (body_len > 0) body_ptr[0..body_len] else parsed.body;

    head.content_length = body.len;

    var request: http.Request = .{ .inner = &head, .body = body };

    instance.deferred.begin();

    var response = instance.app.handle(arena, &request);

    response.set_header("X-Publr-Runtime", "wasm") catch return 5;

    const effects = effects_of(arena, instance.deferred.done()) catch return 6;
    var envelope: ResponseJson = .{
        .status = response.status.code(),
        .headers = @ptrCast(response.headers[0..response.headers_len]),
        .effects = effects,
    };

    if (instance.deferred.needed) |*wanted| {
        envelope.need = .{ .area = @tagName(wanted.area), .key = wanted.key() };
        envelope.effects = &.{};
    }

    const json = std.json.Stringify.valueAlloc(instance.gpa, envelope, .{}) catch return 6;

    if (instance.response.len > 0) {
        instance.gpa.free(instance.response);
    }

    instance.response = json;
    instance.body = response.body;

    std.debug.assert(instance.response.len > 0);
    std.debug.assert(instance.connection.transaction_depth == 0);

    return 0;
}

fn effects_of(
    arena: std.mem.Allocator,
    done: []const files.kept_elsewhere.Effect,
) error{OutOfMemory}![]const ResponseJson.Effect {
    std.debug.assert(done.len <= files.kept_elsewhere.effects_max);
    std.debug.assert(needs_max > 0);

    const out = try arena.alloc(ResponseJson.Effect, done.len);

    for (done, out) |effect, *entry| {
        entry.* = .{
            .kind = @tagName(effect.kind),
            .area = @tagName(effect.area),
            .key = effect.key,
            .offset = effect.offset,
        };
    }

    return out;
}

/// The last response's body, bytes as they are: an image as much as a page.
export fn publr_body_ptr() [*]const u8 {
    const instance = state orelse return @ptrFromInt(8);
    return if (instance.body.len > 0) instance.body.ptr else @ptrFromInt(8);
}

export fn publr_body_len() u32 {
    const instance = state orelse return 0;
    return @intCast(instance.body.len);
}

/// The bytes of the last response's effect `index`: what a write or a piece writes.
export fn publr_effect_ptr(index: u32) [*]const u8 {
    const instance = state orelse return @ptrFromInt(8);
    const done = instance.deferred.done();

    if (index >= done.len or done[index].bytes.len == 0) {
        return @ptrFromInt(8);
    }

    return done[index].bytes.ptr;
}

export fn publr_effect_len(index: u32) u32 {
    const instance = state orelse return 0;
    const done = instance.deferred.done();

    return if (index < done.len) @intCast(done[index].bytes.len) else 0;
}

/// Hands over a file the last response needed: `area` is 0 for files, 1 for uploads under
/// way; the bytes come from `publr_alloc` and are the module's from now on.
export fn publr_attach(area: u32, key_ptr: [*]const u8, key_len: u32, ptr: [*]u8, len: u32) i32 {
    const instance = state orelse return 1;

    if (area > @intFromEnum(files.Area.incoming) or !owns(instance, key_ptr, key_len)) {
        return 2;
    }

    const bytes = take(instance, ptr, len) orelse return 3;
    const key = key_ptr[0..key_len];

    instance.deferred.attach(@enumFromInt(area), key, bytes) catch {
        instance.gpa.free(bytes);
        return 4;
    };

    return 0;
}

/// Once the worker has the response, its effects and its body: the files handed over go.
export fn publr_settle() void {
    const instance = state orelse return;

    instance.deferred.settle();
    instance.body = &.{};
}

/// An allocation the worker made, out of the table: its owner is whoever takes it.
fn take(instance: *State, ptr: [*]u8, len: u32) ?[]u8 {
    std.debug.assert(allocations_max > 0);

    if (len == 0 or len > allocation_bytes_max) {
        return null;
    }

    for (&instance.allocations) |*slot| {
        const bytes = slot.* orelse continue;

        if (bytes.ptr == ptr and bytes.len == len) {
            slot.* = null;
            return bytes;
        }
    }

    return null;
}

export fn publr_response_ptr() [*]const u8 {
    const instance = state orelse return @ptrFromInt(8);
    return instance.response.ptr;
}

export fn publr_response_len() u32 {
    const instance = state orelse return 0;
    return @intCast(instance.response.len);
}

export fn publr_export() i32 {
    const instance = state orelse return 1;

    var arena_state = std.heap.FixedBufferAllocator.init(instance.arena_buffer);
    const bytes = instance.connection.serialize(arena_state.allocator()) catch return 2;
    const copy = instance.gpa.dupe(u8, bytes) catch return 3;

    if (instance.response.len > 0) {
        instance.gpa.free(instance.response);
    }

    instance.response = copy;

    std.debug.assert(instance.response.len > 0);
    std.debug.assert(instance.connection.transaction_depth == 0);

    return 0;
}

export fn publr_import(ptr: [*]const u8, len: u32) i32 {
    const instance = state orelse return 1;

    if (!owns(instance, ptr, len)) {
        return 2;
    }

    var candidate = db.open(&instance.runtime, ":memory:") catch return 3;
    var accepted = false;
    defer if (!accepted) candidate.close();
    candidate.deserialize(ptr[0..len]) catch return 3;
    db.schema.apply(&candidate) catch return 4;
    publr.registry.SDK.apply_schemas(&candidate) catch return 4;
    open_index(&candidate) catch return 4;
    apply_types(instance, &candidate) catch return 7;
    instance.connection.close();
    instance.connection = candidate;
    accepted = true;

    std.debug.assert(instance.connection.transaction_depth == 0);

    return 0;
}

/// The dependency index's tables, which every record write records into, as the native
/// server opens them; the browser build serves no built pages, so it keeps no handle.
fn open_index(connection: *db.Db) !void {
    std.debug.assert(connection.transaction_depth == 0);

    const deps = publr.lib.deps;

    _ = try deps.Index.open(connection, .{ .quiet_ms = deps.quiet_ms });
}

fn apply_declared_types(instance: *State) !void {
    try apply_types(instance, &instance.connection);
}

fn apply_types(instance: *State, connection: *db.Db) !void {
    std.debug.assert(instance.connection.transaction_depth == 0);
    std.debug.assert(instance.arena_buffer.len == arena_bytes);

    var arena_state = std.heap.FixedBufferAllocator.init(instance.arena_buffer);
    var ctx = publr.sdk.Ctx.init(.{
        .caller = .system,
        .db = connection,
        .io = instance.io_backend.io(),
        .arena = arena_state.allocator(),
        .auth = &instance.auth,
        .now_ms = publr.sdk.context.wall_clock_ms(instance.io_backend.io()),
    });

    try publr.operations.media.bootstrap(&ctx);
    try publr.plugin.types.apply_all(&ctx);
}

fn build_request(parsed: RequestJson) !http.Head {
    std.debug.assert(request_bytes_max > arena_bytes);

    if (parsed.path.len == 0 or parsed.path[0] != '/' or
        std.mem.indexOfAny(u8, parsed.path, " \r\n\x00") != null) return error.InvalidPath;

    var request: http.Head = .{
        .method = parse_method(parsed.method) orelse return error.UnknownMethod,
        .path = parsed.path,
        .query = parsed.query,
        .version = .http_1_1,
        .headers = undefined,
        .headers_len = 0,
        .content_length = parsed.body.len,
        .keep_alive = true,
        .head_len = 0,
    };

    if (parsed.headers.len > request.headers.len) {
        return error.TooManyHeaders;
    }

    for (parsed.headers) |header| {
        if (header.name.len == 0 or std.mem.indexOfAny(u8, header.name, " :\r\n\x00") != null or
            std.mem.indexOfAny(u8, header.value, "\r\n\x00") != null) return error.InvalidHeader;
        request.headers[request.headers_len] = .{ .name = header.name, .value = header.value };
        request.headers_len += 1;
    }

    return request;
}

fn parse_method(text: []const u8) ?http.Method {
    std.debug.assert(@typeInfo(http.Method).@"enum".fields.len > 0);

    if (text.len == 0 or text.len > 16) {
        return null;
    }

    inline for (@typeInfo(http.Method).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(field.name, text)) {
            return @enumFromInt(field.value);
        }
    }

    return null;
}
