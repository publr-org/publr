//! Internal records: what a plugin keeps for itself (carts, reservations, ledgers), one JSON
//! document each, in collections the plugin declares. Called from a plugin's own code, every
//! operation reaches that plugin's records in the app the request came through, and nobody
//! else's. With no plugin running, an administrator names the plugin (and the app).

const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Value = std.json.Value;
const Collection = model.internal_record.Collection;
const Scope = store.internal_records.Scope;
const records = store.internal_records;

pub const namespace: sdk.operation.Namespace = .{
    .name = "internal",
    .summary = "A plugin's internal records: what it keeps for itself, never content",
    .details =
    \\Carts, reservations, stock movements, logs: records a plugin keeps and nobody edits,
    \\in collections it declares (`internal_records`), each with the fields it is found
    \\by. No statuses, drafts, revisions or search; `version` guards a stale write. From a
    \\plugin's code they reach that plugin's records in the request's app only. With no
    \\plugin running, an administrator names `plugin` (and `app`, the project's own when
    \\left out). An append-only collection refuses `save` and `delete`.
    ,
};

pub const example_id = "c3d4e5f60718293a4b5c6d7e";
pub const example_document = "{\"name\":\"Ada\",\"count\":1}";

pub const Item = struct {
    id: []const u8,
    version: i64,
    document: []const u8,
    created_at: i64,
    updated_at: i64,
};

const example_item: Item = .{
    .id = example_id,
    .version = 1,
    .document = example_document,
    .created_at = 1767225600000,
    .updated_at = 1767225600000,
};

pub const operations = [_]type{ Create, Get, Save, FindOne, Find, Delete };

pub const Create = struct {
    pub const name = "internal.create";
    pub const description = "Keep a new internal record";
    pub const details = "The document is a JSON object; its declared fields are indexed.";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        kind: []const u8,
        document: []const u8,
        plugin: ?[]const u8 = null,
        app: ?[]const u8 = null,
    };
    pub const Out = struct { id: []const u8, version: i64 };
    pub const example: In = .{ .plugin = "greeter", .kind = "visit", .document = example_document };
    pub const example_out: Out = .{ .id = example_id, .version = 1 };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .kind = "The collection, as the plugin declares it",
        .document = "The record, a JSON object",
        .plugin = "Whose records, when no plugin is running",
        .app = "Which app's, when no plugin is running; the project's own when left out",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const target = try scope_of(ctx, in.plugin, in.app, in.kind);
        const given = try object_of(ctx, in.document);
        const scope = target.scope;
        const id = try records.insert(ctx.db, ctx.io, ctx.arena, scope, in.document, ctx.now_ms);

        try index(ctx, target.collection, id, given);

        return .{ .id = id, .version = 1 };
    }
};

pub const Get = struct {
    pub const name = "internal.get";
    pub const description = "Read one internal record";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        kind: []const u8,
        id: []const u8,
        plugin: ?[]const u8 = null,
        app: ?[]const u8 = null,
    };
    pub const Out = Item;
    pub const example: In = .{ .plugin = "greeter", .kind = "visit", .id = example_id };
    pub const example_out: Out = example_item;
    pub const field_docs: sdk.operation.Docs(In) = .{
        .kind = "The collection",
        .id = "The record",
        .plugin = "Whose records, when no plugin is running",
        .app = "Which app's, when no plugin is running",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const target = try scope_of(ctx, in.plugin, in.app, in.kind);
        const row = try records.get(ctx.db, ctx.arena, target.scope, in.id) orelse {
            return error.NotFound;
        };

        return item_of(row);
    }
};

pub const Save = struct {
    pub const name = "internal.save";
    pub const description = "Write fields of an internal record";
    pub const details =
        \\The fields the document gives replace the record's; the others keep their values.
        \\`expected_version` refuses a stale write. Refused on an append-only collection.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        kind: []const u8,
        id: []const u8,
        document: []const u8,
        expected_version: ?i64 = null,
        plugin: ?[]const u8 = null,
        app: ?[]const u8 = null,
    };
    pub const Out = struct { version: i64 };
    pub const example: In = .{
        .plugin = "greeter",
        .kind = "visit",
        .id = example_id,
        .document = "{\"count\":2}",
    };
    pub const example_out: Out = .{ .version = 2 };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .kind = "The collection",
        .id = "The record",
        .document = "The fields to write, a JSON object",
        .expected_version = "The `version` you read; refuse if it changed",
        .plugin = "Whose records, when no plugin is running",
        .app = "Which app's, when no plugin is running",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const target = try scope_of(ctx, in.plugin, in.app, in.kind);

        if (target.collection.append_only) {
            return error.Invalid;
        }

        const given = try object_of(ctx, in.document);
        const row = try records.get(ctx.db, ctx.arena, target.scope, in.id) orelse {
            return error.NotFound;
        };
        var merged = try object_of(ctx, row.document);
        var fields = given.object.iterator();

        while (fields.next()) |field| {
            try merged.object.put(ctx.arena, field.key_ptr.*, field.value_ptr.*);
        }

        const text = std.json.Stringify.valueAlloc(ctx.arena, merged, .{}) catch {
            return error.OutOfMemory;
        };

        if (text.len > model.internal_record.document_bytes_max) {
            return error.Invalid;
        }

        const expected = in.expected_version;
        const version = try records.update(ctx.db, target.scope, in.id, text, expected, ctx.now_ms);

        try index(ctx, target.collection, in.id, merged);

        return .{ .version = version };
    }
};

pub const FindOne = struct {
    pub const name = "internal.find_one";
    pub const description = "The one internal record whose indexed field holds a value";
    pub const details = "Null when none does; `conflict` when two do.";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        kind: []const u8,
        field: []const u8,
        value: []const u8,
        plugin: ?[]const u8 = null,
        app: ?[]const u8 = null,
    };
    pub const Out = struct { record: ?Item };
    pub const example: In = .{
        .plugin = "greeter",
        .kind = "visit",
        .field = "name",
        .value = "Ada",
    };
    pub const example_out: Out = .{ .record = example_item };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .kind = "The collection",
        .field = "An indexed field",
        .value = "The value it holds, as text (`42`, `true`)",
        .plugin = "Whose records, when no plugin is running",
        .app = "Which app's, when no plugin is running",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const target = try scope_of(ctx, in.plugin, in.app, in.kind);
        const match = try match_of(target.collection, in.field, in.value);
        const rows = try records.list(ctx.db, ctx.arena, target.scope, match, 2, 0);

        if (rows.len > 1) {
            return error.Conflict;
        }

        return .{ .record = if (rows.len == 1) item_of(rows[0]) else null };
    }
};

pub const Find = struct {
    pub const name = "internal.find";
    pub const description = "A page of internal records, newest first";
    pub const details = "With `field` and `value`, only those whose indexed field holds it.";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        kind: []const u8,
        field: ?[]const u8 = null,
        value: ?[]const u8 = null,
        limit: u32 = 50,
        offset: u32 = 0,
        plugin: ?[]const u8 = null,
        app: ?[]const u8 = null,
    };
    pub const Out = struct { records: []const Item };
    pub const example: In = .{ .plugin = "greeter", .kind = "visit" };
    pub const example_out: Out = .{ .records = &.{example_item} };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .kind = "The collection",
        .field = "An indexed field to filter on",
        .value = "The value it holds, as text",
        .limit = "Page size, up to 200",
        .offset = "Records to skip",
        .plugin = "Whose records, when no plugin is running",
        .app = "Which app's, when no plugin is running",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const paired = (in.field == null) == (in.value == null);

        if (in.limit == 0 or in.limit > records.list_max or !paired) {
            return error.Invalid;
        }

        const target = try scope_of(ctx, in.plugin, in.app, in.kind);
        const match = if (in.field) |field|
            try match_of(target.collection, field, in.value.?)
        else
            null;
        const rows = try records.list(ctx.db, ctx.arena, target.scope, match, in.limit, in.offset);
        const items = ctx.arena.alloc(Item, rows.len) catch return error.OutOfMemory;

        for (rows, items) |row, *target_item| {
            target_item.* = item_of(row);
        }

        return .{ .records = items };
    }
};

pub const Delete = struct {
    pub const name = "internal.delete";
    pub const description = "Remove an internal record";
    pub const details = "Refused on an append-only collection.";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        kind: []const u8,
        id: []const u8,
        plugin: ?[]const u8 = null,
        app: ?[]const u8 = null,
    };
    pub const Out = struct { deleted: bool };
    pub const example: In = .{ .plugin = "greeter", .kind = "visit", .id = example_id };
    pub const example_out: Out = .{ .deleted = true };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .kind = "The collection",
        .id = "The record",
        .plugin = "Whose records, when no plugin is running",
        .app = "Which app's, when no plugin is running",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const target = try scope_of(ctx, in.plugin, in.app, in.kind);

        if (target.collection.append_only) {
            return error.Invalid;
        }

        try store.internal_record_values.replace(ctx.db, in.id, &.{});

        return .{ .deleted = try records.delete(ctx.db, target.scope, in.id) };
    }
};

const Target = struct { scope: Scope, collection: Collection };

/// Whose records a call reaches: the running plugin's in the request's app; with no plugin
/// running, the ones named. Not found when the plugin declares no such collection.
fn scope_of(ctx: *Ctx, plugin: ?[]const u8, app: ?[]const u8, kind: []const u8) Error!Target {
    std.debug.assert(ctx.now_ms >= 0);

    if (kind.len == 0 or kind.len > model.internal_record.kind_len_max) {
        return error.Invalid;
    }

    const running = ctx.plugin.len > 0;

    if (running and (plugin != null or app != null)) {
        if (plugin == null or !std.mem.eql(u8, plugin.?, ctx.plugin) or app != null) {
            return error.Denied;
        }
    }

    const owner = if (running) ctx.plugin else plugin orelse return error.Invalid;

    if (owner.len == 0) {
        return error.Invalid;
    }

    const scope: Scope = .{
        .plugin = owner,
        .app = if (running) ctx.app else app orelse ctx.app,
        .kind = kind,
    };
    const collection = registry.internal_collection(ctx, owner, kind) orelse {
        return error.NotFound;
    };

    return .{ .scope = scope, .collection = collection };
}

fn object_of(ctx: *Ctx, text: []const u8) Error!Value {
    std.debug.assert(ctx.now_ms >= 0);

    if (text.len == 0 or text.len > model.internal_record.document_bytes_max) {
        return error.Invalid;
    }

    const parsed = std.json.parseFromSliceLeaky(Value, ctx.arena, text, .{}) catch {
        return error.Invalid;
    };

    if (parsed != .object) {
        return error.Invalid;
    }

    return parsed;
}

/// What the record is found by: each indexed field it holds as text, an integer or a flag.
fn index(ctx: *Ctx, collection: Collection, id: []const u8, document: Value) Error!void {
    std.debug.assert(document == .object);
    std.debug.assert(collection.indexed.len <= model.internal_record.indexed_max);

    var values: [model.internal_record.indexed_max]store.internal_record_values.Value = undefined;
    var count: u32 = 0;

    for (collection.indexed) |field| {
        const value = document.object.get(field) orelse continue;
        const text = try model.internal_record.indexed_text(ctx.arena, value) orelse continue;

        values[count] = .{ .field = field, .value = text };
        count += 1;
    }

    try store.internal_record_values.replace(ctx.db, id, values[0..count]);
}

fn match_of(collection: Collection, field: []const u8, value: []const u8) Error!records.Match {
    std.debug.assert(collection.kind.len > 0);

    if (field.len == 0 or !model.internal_record.indexes(collection, field)) {
        return error.Invalid;
    }

    if (value.len > model.internal_record.value_len_max) {
        return error.Invalid;
    }

    return .{ .field = field, .value = value };
}

fn item_of(row: records.Row) Item {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(row.version > 0);

    return .{
        .id = row.id,
        .version = row.version,
        .document = row.document,
        .created_at = row.created_at,
        .updated_at = row.updated_at,
    };
}

const Host = @import("../server/sandboxed_plugins.zig").Host;
const plugin_operations = @import("plugin.zig");
const SDK = registry.SDK;

/// A project with greeter installed (its `visit` collection, found by `name`): for tests.
pub const TestProject = Project;

/// A project with greeter installed (its `visit` collection, found by `name`).
const Project = struct {
    harness: sdk.testing.Harness,
    temporary: std.testing.TmpDir,
    host: Host,

    pub fn init(project: *Project) !void {
        std.debug.assert(@embedFile("sandboxed_plugin_greeter").len > 0);

        try project.harness.init();
        errdefer project.harness.deinit();

        project.temporary = std.testing.tmpDir(.{});
        errdefer project.temporary.cleanup();

        try project.temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "greeter.wasm",
            .data = @embedFile("sandboxed_plugin_greeter"),
        });

        const root = ".zig-cache/tmp/" ++ project.temporary.sub_path;
        const arena = project.harness.fixed.allocator();
        const path = try std.fmt.allocPrint(arena, "{s}/greeter.wasm", .{root});
        const dir = try std.fmt.allocPrint(arena, "{s}/plugins", .{root});

        try project.host.init(std.testing.allocator, std.testing.io, dir);

        var system = project.ctx(.system);

        try SDK.bootstrap(&system);

        const added = try SDK.dispatch(&system, plugin_operations.Add, .{ .file = path });

        _ = try SDK.dispatch(&system, plugin_operations.Enable, .{ .name = added.name });
    }

    pub fn deinit(project: *Project) void {
        std.debug.assert(project.temporary.sub_path.len > 0);

        project.host.deinit();
        project.temporary.cleanup();
        project.harness.deinit();
    }

    pub fn ctx(project: *Project, who: sdk.Caller) Ctx {
        var made = project.harness.ctx(who);

        std.debug.assert(made.sandboxed_plugins == null);

        made.sandboxed_plugins = project.host.sandboxed_plugins();
        made.now_ms = 1_700_000_000_000;

        return made;
    }
};

test "internal records: a plugin's own, in its app, found by an indexed field" {
    var project: Project = undefined;
    try project.init();
    defer project.deinit();

    var greeter = project.ctx(.anonymous);
    greeter.plugin = "greeter";

    const first = try SDK.dispatch(&greeter, Create, .{
        .kind = "visit",
        .document = "{\"name\":\"Ada\",\"count\":1}",
    });
    _ = try SDK.dispatch(&greeter, Create, .{ .kind = "visit", .document = "{\"name\":\"Bob\"}" });

    var in_shop = greeter;
    in_shop.app = "shop";
    _ = try SDK.dispatch(&in_shop, Create, .{ .kind = "visit", .document = "{\"name\":\"Ada\"}" });

    const found = (try SDK.dispatch(&greeter, FindOne, .{
        .kind = "visit",
        .field = "name",
        .value = "Ada",
    })).record.?;
    try std.testing.expectEqualStrings(first.id, found.id);

    const saved = try SDK.dispatch(&greeter, Save, .{
        .kind = "visit",
        .id = first.id,
        .document = "{\"count\":2}",
        .expected_version = 1,
    });
    try std.testing.expectEqual(@as(i64, 2), saved.version);

    const got = try SDK.dispatch(&greeter, Get, .{ .kind = "visit", .id = first.id });
    try std.testing.expect(std.mem.indexOf(u8, got.document, "\"Ada\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.document, "\"count\":2") != null);

    const stale = SDK.dispatch(&greeter, Save, .{
        .kind = "visit",
        .id = first.id,
        .document = "{\"count\":3}",
        .expected_version = 1,
    });
    try std.testing.expectError(error.Conflict, stale);

    const here = try SDK.dispatch(&greeter, Find, .{ .kind = "visit" });
    const there = try SDK.dispatch(&in_shop, Find, .{ .kind = "visit" });
    try std.testing.expectEqual(@as(usize, 2), here.records.len);
    try std.testing.expectEqual(@as(usize, 1), there.records.len);

    const unindexed = SDK.dispatch(&greeter, Find, .{
        .kind = "visit",
        .field = "count",
        .value = "2",
    });
    try std.testing.expectError(error.Invalid, unindexed);

    const deleted = try SDK.dispatch(&greeter, Delete, .{ .kind = "visit", .id = first.id });
    try std.testing.expect(deleted.deleted);

    const gone = SDK.dispatch(&greeter, Get, .{ .kind = "visit", .id = first.id });
    try std.testing.expectError(error.NotFound, gone);
}

test "internal records: nobody else's, and with no plugin running only for those who may" {
    var project: Project = undefined;
    try project.init();
    defer project.deinit();

    var greeter = project.ctx(.anonymous);
    greeter.plugin = "greeter";
    _ = try SDK.dispatch(&greeter, Create, .{ .kind = "visit", .document = "{\"name\":\"Ada\"}" });

    const named_other = SDK.dispatch(&greeter, Find, .{ .kind = "visit", .plugin = "sampler" });
    try std.testing.expectError(error.Denied, named_other);

    var stranger = project.ctx(.anonymous);
    stranger.plugin = "farewell";
    const undeclared = SDK.dispatch(&stranger, Find, .{ .kind = "visit" });
    try std.testing.expectError(error.NotFound, undeclared);

    const unknown_kind = SDK.dispatch(&greeter, Find, .{ .kind = "nope" });
    try std.testing.expectError(error.NotFound, unknown_kind);

    var visitor = project.ctx(.anonymous);
    const anonymous = SDK.dispatch(&visitor, Find, .{ .kind = "visit", .plugin = "greeter" });
    try std.testing.expectError(error.Denied, anonymous);

    var operator = project.ctx(.system);
    const seen = try SDK.dispatch(&operator, Find, .{ .kind = "visit", .plugin = "greeter" });
    try std.testing.expectEqual(@as(usize, 1), seen.records.len);

    const unnamed = SDK.dispatch(&operator, Find, .{ .kind = "visit" });
    try std.testing.expectError(error.Invalid, unnamed);
}
