//! Calling an operation by its name: a built-in operation's JSON is parsed and dispatched
//! as any other; one an installed plugin brings runs through the same pipeline
//! (`SDK.pipeline`) with its body in the sandbox, its input and answer as they come
//! (`sandboxed_plugins.Passed`): JSON text from the outer edge, or a value another plugin
//! handed over, which reaches it with no JSON in between.
const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const operation = @import("operation.zig");
const sandboxed_plugins = @import("sandboxed_plugins.zig");
const json = @import("../lib/json.zig");
const Grant = @import("grant.zig").Grant;
const contract = @import("../model/contract.zig");
const plugin_names = @import("../model/plugin_contracts.zig");
const Value = std.json.Value;

const Error = operation.Error;
const Scratch = @import("scratch.zig").Scratch;
const Passed = sandboxed_plugins.Passed;

pub fn call(comptime SDK: type, ctx: *Ctx, name: []const u8, input: []const u8) Error![]const u8 {
    @setEvalBranchQuota(200_000);

    std.debug.assert(name.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    inline for (SDK.operations) |Operation| {
        if (std.mem.eql(u8, Operation.name, name)) {
            // A key per dimension beside the operation's own (`"language": "pl"`).
            const lift = @import("dimension_input.zig").lift;
            const given = lift(Operation.In, ctx.arena, input) catch return error.OutOfMemory;
            // A plugin's code calling (a contract's owner calling its providers) may send a
            // field added since the operation was written: it is left out, as an installed
            // provider leaves it. Whoever else calls is told of a field it got wrong.
            const in = json.parse(Operation.In, ctx.arena, given, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = ctx.plugin_code,
            }) catch return error.Invalid;
            const out = try SDK.dispatch(ctx, Operation, in);

            return @import("../sdk.zig").stringify(ctx.arena, out);
        }
    }

    const sandboxed = ctx.sandboxed_plugins orelse return error.NotFound;
    const answer = try call_passed(SDK, ctx, name, .{
        .json = input,
    });

    // The outer edge: an answer a plugin handed over is written as JSON once, here.
    return sandboxed.json_of(ctx.arena, answer, .answer);
}

/// An operation an installed plugin brings, called with a value as it comes: JSON text, or
/// as another plugin handed it over. The answer is as the operation's plugin handed it back.
pub fn call_passed(comptime SDK: type, ctx: *Ctx, name: []const u8, input: Passed) Error!Passed {
    const sandboxed = ctx.sandboxed_plugins orelse return error.NotFound;
    const found = sandboxed.find(name) orelse return error.NotFound;

    std.debug.assert(input.bytes().len > 0);

    if (ctx.plugin_depth == sandboxed_plugins.depth_max) {
        return error.Invalid;
    }

    ctx.plugin_depth += 1;
    defer ctx.plugin_depth -= 1;

    return in_working_memory(SDK, ctx, .{
        .sandboxed = sandboxed,
        .found = found,
        .input = input,
    });
}

/// An installed operation run in working memory of its own (the request's scratch), given
/// back once it answered: only its answer, or its refusal's words, are kept. Nested calls
/// (checkout calling orders calling every provider) take the deepest path's memory, never
/// the sum of every call. One that runs out of working memory fails as out of memory: it is
/// never run a second time.
fn in_working_memory(comptime SDK: type, ctx: *Ctx, body: Installed(SDK)) Error!Passed {
    std.debug.assert(body.input.bytes().len > 0);
    std.debug.assert(ctx.plugin_depth > 0);

    var working = Working.begin(ctx) catch return SDK.pipeline(ctx, Installed(SDK), body);
    const result = SDK.pipeline(ctx, Installed(SDK), body);

    working.end();

    const answer = result catch |err| {
        try working.give_back_failed();

        return err;
    };

    var pieces = [_][]const u8{answer.bytes()};

    carry(ctx, working.scratch, working.begun, &pieces) catch |err| {
        working.give_back();

        return err;
    };

    return answer.moved(pieces[0]);
}

/// The request's working memory taken for one piece of work a plugin's code does (an
/// installed operation, a hook, a queued run): `ctx.arena` is the scratch from `begin` to
/// `end`, so each call the plugin makes into core gives its memory back as it answers
/// (`host_call_begun`), and what the piece of work itself took goes with `give_back`.
pub const Working = struct {
    ctx: *Ctx,
    scratch: *Scratch,
    begun: Scratch.Mark,
    outer: std.mem.Allocator,
    lasting: ?std.mem.Allocator,

    pub fn begin(ctx: *Ctx) error{OutOfMemory}!Working {
        const scratch = try ctx.call_scratch();
        const working: Working = .{
            .ctx = ctx,
            .scratch = scratch,
            .begun = scratch.mark(),
            .outer = ctx.arena,
            .lasting = ctx.lasting,
        };

        std.debug.assert(working.begun.index <= scratch.fixed.buffer.len);

        ctx.lasting = working.lasting orelse working.outer;
        ctx.arena = scratch.allocator();

        return working;
    }

    /// The caller's own memory is `ctx.arena` again; nothing is given back yet.
    pub fn end(working: *const Working) void {
        std.debug.assert(working.scratch.holds(working.ctx.arena));

        working.ctx.arena = working.outer;
        working.ctx.lasting = working.lasting;
    }

    /// Everything the work took given back; nothing of it is read after this. Words of a
    /// refusal still waiting (an event's hook refused the write around it) are kept first.
    pub fn give_back(working: *const Working) void {
        const ctx = working.ctx;

        std.debug.assert(working.begun.index <= working.scratch.fixed.buffer.len);

        if (working.scratch.fixed.end_index <= working.begun.index) {
            return;
        }

        if (ctx.failure == null and ctx.problems.len == 0) {
            working.scratch.rewind(working.begun);

            return;
        }

        carry_failure(ctx, working.scratch, working.begun) catch {
            ctx.failure = null;
            ctx.problems = &.{};
            working.scratch.rewind(working.begun);
        };
    }

    /// As `give_back` for work that was refused: its words (`ctx.failure`, `ctx.problems`)
    /// are kept in the caller's memory. Out of memory keeping them, only the error is left.
    pub fn give_back_failed(working: *const Working) error{OutOfMemory}!void {
        const ctx = working.ctx;

        std.debug.assert(working.begun.index <= working.scratch.fixed.end_index);

        carry_failure(ctx, working.scratch, working.begun) catch {
            ctx.failure = null;
            ctx.problems = &.{};
            working.give_back();

            return error.OutOfMemory;
        };
    }
};

/// Where a call the plugin's code makes from the sandbox begins in the working memory its
/// installed operation runs in; null when it runs in the call's own. A built-in operation
/// it calls (`record.get`, `internal.save`) works there too: given back with `give_back`
/// once its answer is in the plugin, so an operation making many calls takes the largest
/// one's memory, never the sum.
pub fn host_call_begun(ctx: *const Ctx) ?Scratch.Mark {
    std.debug.assert(ctx.now_ms >= 0);

    const working = ctx.calls_set_aside orelse return null;

    if (!working.holds(ctx.arena)) {
        return null;
    }

    std.debug.assert(ctx.lasting != null);

    return working.mark();
}

/// The memory of a call the plugin's code made given back to `begun`; a refusal's words
/// (`ctx.failure`, `ctx.problems`) are kept, laid where it began. Out of memory keeping
/// them, the refusal keeps only its error.
pub fn give_back(ctx: *Ctx, begun: Scratch.Mark) void {
    const working = ctx.calls_set_aside.?;

    std.debug.assert(working.holds(ctx.arena));
    std.debug.assert(begun.index <= working.fixed.end_index);

    if (ctx.failure == null and ctx.problems.len == 0) {
        working.rewind(begun);

        return;
    }

    carry_failure(ctx, working, begun) catch {
        ctx.failure = null;
        ctx.problems = &.{};
        working.rewind(begun);
    };
}

/// A refused call's words (`ctx.failure`, `ctx.problems`) kept out of the working memory
/// before it is given back: copied once into the memory that lasts the call, never moved
/// within the working memory again. A refusal may wait while its code goes on (an event's
/// `after` hook refused: the write fails as it ends), and the calls it makes meanwhile give
/// the working memory under the words back as they answer. Words already outside what is
/// given back stay where they are.
fn carry_failure(ctx: *Ctx, working: *Scratch, begun: Scratch.Mark) Error!void {
    std.debug.assert(begun.index <= working.fixed.end_index);

    const memory = ctx.kept_memory() orelse return carry_failure_down(ctx, working, begun);

    if (working.lies_past(begun, std.mem.sliceAsBytes(ctx.problems))) {
        ctx.problems = memory.dupe(operation.Problem, ctx.problems) catch {
            return error.OutOfMemory;
        };
    }

    for (@constCast(ctx.problems)) |*problem| {
        problem.field = try kept_past(memory, working, begun, problem.field);
        problem.message = try kept_past(memory, working, begun, problem.message);
    }

    if (ctx.failure) |*failure| {
        failure.name = try kept_past(memory, working, begun, failure.name);
        failure.message = try kept_past(memory, working, begun, failure.message);
    }

    working.rewind(begun);

    std.debug.assert(working.fixed.end_index == begun.index);
}

/// `text` copied into `memory` when it lies in the working memory past `begun`; as it is
/// otherwise.
fn kept_past(
    memory: std.mem.Allocator,
    working: *Scratch,
    begun: Scratch.Mark,
    text: []const u8,
) Error![]const u8 {
    std.debug.assert(begun.index <= working.fixed.end_index);

    if (!working.lies_past(begun, text)) {
        return text;
    }

    return memory.dupe(u8, text) catch error.OutOfMemory;
}

/// `carry_failure` when nothing lasts the call but the working memory itself: the words
/// moved down to `begun`.
fn carry_failure_down(ctx: *Ctx, working: *Scratch, begun: Scratch.Mark) Error!void {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(begun.index <= working.fixed.end_index);

    // Lists in the memory that lasts: never in the working memory moved below.
    const memory = ctx.lasting orelse ctx.arena;
    const problems = ctx.problems;

    if (problems.len > 0) {
        const kept = memory.alloc(operation.Problem, problems.len) catch {
            return error.OutOfMemory;
        };

        @memcpy(kept, problems);
        ctx.problems = kept;
    }

    var pieces: std.ArrayList([]const u8) = .empty;

    if (ctx.failure) |failure| {
        pieces.append(memory, failure.name) catch return error.OutOfMemory;
        pieces.append(memory, failure.message) catch return error.OutOfMemory;
    }

    for (ctx.problems) |problem| {
        pieces.append(memory, problem.field) catch return error.OutOfMemory;
        pieces.append(memory, problem.message) catch return error.OutOfMemory;
    }

    try carry(ctx, working, begun, pieces.items);

    var at: u32 = 0;

    if (ctx.failure) |*failure| {
        failure.name = pieces.items[0];
        failure.message = pieces.items[1];
        at = 2;
    }

    for (@constCast(ctx.problems)) |*problem| {
        problem.field = pieces.items[at];
        problem.message = pieces.items[at + 1];
        at += 2;
    }
}

/// Each piece copied out of the working memory into the call's own, the working memory
/// given back to `begun`. When the call's own is that working memory too (a nested call's
/// nested call), the pieces are laid past what is in use, then moved down to `begun`.
fn carry(ctx: *Ctx, working: *Scratch, begun: Scratch.Mark, pieces: [][]const u8) Error!void {
    std.debug.assert(begun.index <= working.fixed.end_index);
    std.debug.assert(pieces.len < 1 << 16);

    if (!working.holds(ctx.arena)) {
        for (pieces) |*piece| {
            piece.* = ctx.arena.dupe(u8, piece.*) catch return error.OutOfMemory;
        }

        working.rewind(begun);

        return;
    }

    // One piece that lies in the working memory (an answer) moves down where it is.
    if (pieces.len == 1) {
        if (working.keep_from(begun, pieces[0])) |low| {
            pieces[0] = low;

            return;
        }
    }

    var total: usize = 0;

    for (pieces) |piece| {
        total += piece.len;
    }

    if (total == 0) {
        working.rewind(begun);

        for (pieces) |*piece| {
            piece.* = "";
        }

        return;
    }

    const high = working.allocator().alloc(u8, total) catch return error.OutOfMemory;
    var offset: usize = 0;

    for (pieces) |piece| {
        @memcpy(high[offset..][0..piece.len], piece);
        offset += piece.len;
    }

    // Moved down to `begun` before the rest is given back: nothing is read once rewound.
    const low = working.keep_at(begun, high);

    offset = 0;

    for (pieces) |*piece| {
        const length = piece.len;

        piece.* = low[offset..][0..length];
        offset += length;
    }
}

/// The content type an operation is about, read from its input by the same convention
/// built-in operations follow: `type`.
const ResourceFields = struct {
    type: ?[]const u8 = null,
};

/// An installed operation as `SDK.pipeline` runs it: its input and answer as they come
/// (`Passed`), its body in the sandbox. JSON is written only for what core keeps as JSON:
/// a failure's log entry, a removal list, an event an `on` hook hears.
fn Installed(comptime SDK: type) type {
    return struct {
        sandboxed: *const sandboxed_plugins.SandboxedPlugins,
        found: sandboxed_plugins.Operation,
        input: Passed,

        const Self = @This();
        pub const Out = Passed;

        pub fn name(self: Self) []const u8 {
            return self.found.name;
        }

        pub fn kind(self: Self) operation.Kind {
            return self.found.kind;
        }

        pub fn owner(self: Self) []const u8 {
            return plugin_names.plugin_of(self.found.name);
        }

        pub fn secret(self: Self) []const []const u8 {
            return self.found.secret;
        }

        pub fn input_text(self: Self, ctx: *Ctx) []const u8 {
            return self.sandboxed.json_of(ctx.arena, self.input, .request) catch "";
        }

        /// A top-level call is counted against the rate limits first.
        pub fn admit(self: Self, ctx: *Ctx, top: bool) Error!Grant {
            const found = self.found;

            std.debug.assert(ctx.parent != null);

            if (top) {
                try SDK.check_limits(ctx, found.name, if (found.limit > 0) found.limit else null);
            }

            try SDK.run_pre_hooks(ctx, found.name, found.kind);
            try SDK.check_fence(ctx, plugin_names.plugin_of(found.name));

            // As a compiled-in `.destructive` operation: a device's call goes on its removal
            // list.
            if (found.destructive and ctx.caller == .token and !ctx.kept) {
                const put_on_list = SDK.removal orelse return ctx.fail(operation.needs_person);
                const written = try self.sandboxed.json_of(ctx.arena, self.input, .request);

                return put_on_list(ctx, found.name, written);
            }

            const answered = try SDK.admit_answer(ctx, found.name, .{
                .untrusted_callers = found.untrusted_callers,
                .answer = found.answer,
                .open = found.open,
            });

            return SDK.authorize_request(ctx, .{
                .operation_name = found.name,
                .kind = found.kind,
                .type_id = try self.type_named(ctx),
                .open = answered,
            });
        }

        /// The content type the input names, by the convention built-in operations follow.
        fn type_named(self: Self, ctx: *Ctx) Error!?[]const u8 {
            std.debug.assert(ctx.parent != null);

            switch (self.input) {
                .laid => return self.sandboxed.text_field(ctx.arena, self.input, "type"),
                .json => |text| {
                    const fields = json.parse(ResourceFields, ctx.arena, text, .{
                        .ignore_unknown_fields = true,
                        .allocate = .alloc_always,
                    }) catch return error.Invalid;

                    return fields.type;
                },
            }
        }

        pub fn run(self: Self, ctx: *Ctx, _: *const Grant) Error!Passed {
            const found = self.found;
            const sandboxed = self.sandboxed;

            std.debug.assert(ctx.parent != null);

            if (found.deprecated.len > 0) {
                SDK.note_deprecated(ctx, found.deprecated, operation.namespace(found.name));
            }

            const changed = if (sandboxed.hooked(.before, found.name))
                try sandboxed.before(ctx, found.name, self.input)
            else
                self.input;
            const resolved = try self.with_references(ctx, changed);
            const was_destructive = ctx.destructive;

            // The core operations its calls may destroy only for a `.destructive` one.
            ctx.destructive = found.destructive;
            defer ctx.destructive = was_destructive;

            const output = try sandboxed.run(ctx, found, resolved);

            if (sandboxed.hooked(.after, found.name)) {
                try sandboxed.after(ctx, found.name, changed, output, null);
            }

            return output;
        }

        /// The input with its references read: only an operation that takes references
        /// has its input written as JSON for it.
        fn with_references(self: Self, ctx: *Ctx, changed: Passed) Error!Passed {
            const shape = self.found.input;

            std.debug.assert(shape.len <= contract.nodes_max);

            if (!has_reference(shape)) {
                return changed;
            }

            const written = try self.sandboxed.json_of(ctx.arena, changed, .request);

            return .{
                .json = try resolve_references(SDK, ctx, shape, written),
            };
        }

        pub fn queue(self: Self, ctx: *Ctx, out: Passed) Error!void {
            const heard = self.found.name;

            std.debug.assert(out.bytes().len > 0);

            if (!SDK.answer_heard(ctx, heard)) {
                return;
            }

            return SDK.queue_answer_passed(ctx, heard, out);
        }

        pub fn committed(_: Self, _: *Ctx, _: Passed) Error!void {}
    };
}

test "an unknown name without plugins is not found" {
    var harness: @import("../sdk.zig").testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    const TestSDK = @import("../sdk.zig").SDK(.{
        .operations = &.{@import("../sdk.zig").testing.Record},
    });

    try std.testing.expectError(error.NotFound, call(TestSDK, &ctx, "nope.verb", "{}"));

    const out = try call(TestSDK, &ctx, "hello.record", "{\"note\":\"hi\"}");

    try std.testing.expectEqualStrings("{\"rows\":1}", out);
    try std.testing.expectError(error.Invalid, call(TestSDK, &ctx, "hello.record", "{"));

    // A field the operation does not know: wrong from a person, left out from a plugin's
    // code (a contract's owner sending a field added since its provider was written).
    const grown = "{\"note\":\"hi\",\"lines\":[]}";

    try std.testing.expectError(error.Invalid, call(TestSDK, &ctx, "hello.record", grown));

    ctx.plugin_code = true;

    const answered = try call(TestSDK, &ctx, "hello.record", grown);

    try std.testing.expectEqualStrings("{\"rows\":2}", answered);
}

/// An installed operation's references read now, as a compiled-in one's are: each field its
/// shape marks a reference (or a list of them), at the top of the input, becomes
/// `{ id, value }`, the record read with the caller's access.
fn resolve_references(
    comptime SDK: type,
    ctx: *Ctx,
    shape: []const contract.Node,
    input: []const u8,
) Error![]const u8 {
    std.debug.assert(input.len > 0);
    std.debug.assert(shape.len <= contract.nodes_max);

    if (!has_reference(shape)) {
        return input;
    }

    var parsed = std.json.parseFromSliceLeaky(Value, ctx.arena, input, .{}) catch {
        return error.Invalid;
    };

    if (parsed != .object) {
        return error.Invalid;
    }

    for (shape) |node| {
        if (node.kind != .reference or node.parent < 0) {
            continue;
        }

        const holder = shape[@intCast(node.parent)];

        if (node.parent == 0) {
            const value = parsed.object.getPtr(node.name) orelse continue;

            // An optional reference left out as null names no record: it stays null.
            if (value.* == .null) {
                continue;
            }

            value.* = try reference_read(SDK, ctx, node.to, value.*);
        } else if (holder.kind == .list and holder.parent == 0) {
            const list = parsed.object.getPtr(holder.name) orelse continue;

            if (list.* != .array) {
                return error.Invalid;
            }

            for (list.array.items) |*item| {
                item.* = try reference_read(SDK, ctx, node.to, item.*);
            }
        }
    }

    return std.json.Stringify.valueAlloc(ctx.arena, parsed, .{}) catch error.OutOfMemory;
}

/// One reference read (`record_for`), and in the call's working memory only what it read
/// kept: the reading itself (a whole `record.get`, its answer as text and as a tree) is
/// given back, so a list of references takes one record's reading at a time, never every
/// one's. What is kept is the JSON it stands for, written into the input as it is.
fn reference_read(comptime SDK: type, ctx: *Ctx, handle: []const u8, id: Value) Error!Value {
    std.debug.assert(handle.len <= 128);

    const begun = host_call_begun(ctx);
    const read = try record_for(SDK, ctx, handle, id);
    const at = begun orelse return read;
    const text = std.json.Stringify.valueAlloc(ctx.arena, read, .{}) catch {
        return error.OutOfMemory;
    };
    const kept = ctx.calls_set_aside.?.keep_from(at, text) orelse return read;

    std.debug.assert(kept.len == text.len);

    // Text the writer copies as it stands: std's own name for it is a number kept as text.
    return .{
        .number_string = kept,
    };
}

fn has_reference(shape: []const contract.Node) bool {
    std.debug.assert(shape.len <= contract.nodes_max);

    for (shape) |node| {
        if (node.kind == .reference) {
            return true;
        }
    }

    return false;
}

/// `{ id, value }` for an id: the record of content type `handle`, as `record.get` answers
/// the caller; not found when it is another type's. With no `handle` (any type), `{ id,
/// type, value, missing }`: the value only when the caller may read it.
fn record_for(comptime SDK: type, ctx: *Ctx, handle: []const u8, id: Value) Error!Value {
    std.debug.assert(handle.len <= 128);

    if (id != .string or id.string.len == 0 or id.string.len > 128) {
        return error.Invalid;
    }

    if (handle.len == 0) {
        return any_for(SDK, ctx, id);
    }

    // An internal collection (`internal:test`): the plugin's own.
    const prefix = @import("../operations/record/typed.zig").internal_prefix;

    if (std.mem.startsWith(u8, handle, prefix)) {
        return internal_for(SDK, ctx, handle[prefix.len..], id);
    }

    const asked = std.json.Stringify.valueAlloc(ctx.arena, .{
        .id = id.string,
    }, .{}) catch {
        return error.OutOfMemory;
    };
    const answer = try call(SDK, ctx, "record.get", asked);
    const Got = struct {
        record: struct {
            type: []const u8,
        },
        document: Value,
    };
    const got = std.json.parseFromSliceLeaky(Got, ctx.arena, answer, .{
        .ignore_unknown_fields = true,
    }) catch return error.Invalid;

    if (!std.mem.eql(u8, got.record.type, handle)) {
        return error.NotFound;
    }

    const document = got.document;
    var pair: std.json.ObjectMap = .empty;

    pair.put(ctx.arena, "id", id) catch return error.OutOfMemory;
    pair.put(ctx.arena, "value", document) catch return error.OutOfMemory;

    return .{
        .object = pair,
    };
}

/// `{ id, value }` for an id of the running plugin's internal collection `kind`, as
/// `internal.get` answers it; not found when it is none of that collection's.
fn internal_for(comptime SDK: type, ctx: *Ctx, kind: []const u8, id: Value) Error!Value {
    std.debug.assert(kind.len > 0);
    std.debug.assert(id == .string);

    const asked = std.json.Stringify.valueAlloc(ctx.arena, .{
        .kind = kind,
        .id = id.string,
    }, .{}) catch {
        return error.OutOfMemory;
    };
    const answer = try call(SDK, ctx, "internal.get", asked);
    const Got = struct {
        document: Value,
    };
    const got = std.json.parseFromSliceLeaky(Got, ctx.arena, answer, .{
        .ignore_unknown_fields = true,
    }) catch return error.Invalid;
    const document = got.document;
    var pair: std.json.ObjectMap = .empty;

    pair.put(ctx.arena, "id", id) catch return error.OutOfMemory;
    pair.put(ctx.arena, "value", document) catch return error.OutOfMemory;

    return .{
        .object = pair,
    };
}

fn any_for(comptime SDK: type, ctx: *Ctx, id: Value) Error!Value {
    std.debug.assert(id == .string);

    const asked = std.json.Stringify.valueAlloc(ctx.arena, .{
        .id = id.string,
    }, .{}) catch {
        return error.OutOfMemory;
    };
    const Reached = struct {
        reason: ?[]const u8 = null,
        type: []const u8,
    };
    const reached = std.json.parseFromSliceLeaky(
        Reached,
        ctx.arena,
        try call(SDK, ctx, "record.reach", asked),
        .{
            .ignore_unknown_fields = true,
        },
    ) catch return error.Invalid;
    var any: std.json.ObjectMap = .empty;

    any.put(ctx.arena, "id", id) catch return error.OutOfMemory;
    any.put(ctx.arena, "type", .{
        .string = reached.type,
    }) catch return error.OutOfMemory;

    if (reached.reason) |reason| {
        any.put(ctx.arena, "missing", .{
            .bool = std.mem.eql(u8, reason, "deleted"),
        }) catch return error.OutOfMemory;
    } else if (call(SDK, ctx, "record.get", asked)) |answer| {
        const Got = struct {
            document: Value,
        };
        const got = std.json.parseFromSliceLeaky(Got, ctx.arena, answer, .{
            .ignore_unknown_fields = true,
        }) catch return error.Invalid;
        any.put(ctx.arena, "value", got.document) catch return error.OutOfMemory;
    } else |err| if (err != error.NotFound) {
        return err;
    }

    return .{
        .object = any,
    };
}

test "an optional reference left null stays null; one given must name a record" {
    var harness: @import("../sdk.zig").testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    const TestSDK = @import("../sdk.zig").SDK(.{
        .operations = &.{@import("../sdk.zig").testing.Record},
    });
    const shape = [_]contract.Node{
        .{
            .parent = -1,
            .kind = .object,
        },
        .{
            .parent = 0,
            .name = "party",
            .kind = .reference,
            .optional = true,
            .required = false,
        },
    };
    const left_out = try resolve_references(TestSDK, &ctx, &shape, "{\"party\":null}");

    try std.testing.expectEqualStrings("{\"party\":null}", left_out);
    try std.testing.expectError(
        error.Invalid,
        resolve_references(TestSDK, &ctx, &shape, "{\"party\":\"\"}"),
    );
}

test "a refusal's words waiting while the write goes on outlive the memory given back" {
    var harness: @import("../sdk.zig").testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    const buffer = try std.testing.allocator.alloc(u8, 16 << 10);
    defer std.testing.allocator.free(buffer);

    var working_memory: Scratch = .{
        .fixed = .init(buffer),
    };

    ctx.calls_set_aside = &working_memory;
    ctx.call_memory = ctx.arena;

    // A hook refuses inside a piece of work; the write around it goes on and fails later.
    var hooked = try Working.begin(&ctx);
    const problems = try ctx.arena.alloc(operation.Problem, 1);

    problems[0] = .{
        .field = try ctx.arena.dupe(u8, "charges"),
        .message = try ctx.arena.dupe(u8, "At most 200"),
    };
    ctx.problems = problems;
    hooked.end();
    hooked.give_back();

    // Later work takes the same memory and gives it back as it answers.
    for (0..3) |_| {
        var later = try Working.begin(&ctx);

        @memset(try ctx.arena.alloc(u8, 1024), 0xAA);
        later.end();
        later.give_back();
    }

    try std.testing.expectEqual(@as(usize, 1), ctx.problems.len);
    try std.testing.expectEqualStrings("charges", ctx.problems[0].field);
    try std.testing.expectEqualStrings("At most 200", ctx.problems[0].message);
    try std.testing.expectEqual(@as(usize, 0), working_memory.fixed.end_index);
}
