//! What a template's frontmatter reads: the Publr API (`Publr.build.*`, `Publr.request.*`)
//! over the record operations, dispatched anonymously so a template can only ever see live
//! records of public types. Every read is written down in `Deps` when a build asks for it.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const identity_module = @import("../rest/identity.zig");
const record_operations = @import("../../operations/record.zig");
const user_operations = @import("../../operations/user.zig");
const http = @import("../../lib/http.zig");
const time = @import("../../lib/time.zig");
const changes = @import("../../operations/project/changes.zig");
const engine = @import("../../template.zig");
const Project = @import("../../server/project.zig").Project;
const App = @import("state.zig").App;

pub const Error = error{EntryNotFound};
pub const query_limit_default: u32 = 50;
pub const query_limit_max = record_operations.list_max;
/// How many targets one reference field is followed to.
pub const references_max: u32 = record_operations.list_max;
/// A Caraway-sized page reads some 500 records (a header and footer of navigation
/// records, sections, blocks, settings); the budget leaves room for a product grid of
/// collections.
pub const keys_max: u32 = 16384;
pub const template_key_prefix = "template:";
pub const asset_key_prefix = "asset:";
pub const islands_prefix = "/_islands/";
/// Where an app's generated assets are, under its mount: `/_app/islands.js`.
pub const assets_prefix = "/_app/";
/// The app's compiled stylesheet, among its assets.
pub const stylesheet = engine.compile.stylesheet;

/// What a render read, as the index's keys. Bounded: a render past `keys_max` distinct
/// reads marks the set incomplete; callers must not certify it as fresh.
pub const Deps = struct {
    arena: std.mem.Allocator,
    /// The app the render is for: its templates and its assets are its own keys.
    app: []const u8,
    keys: std.ArrayList([]const u8) = .empty,
    /// The keys, for a constant-time "seen already".
    seen: std.StringHashMapUnmanaged(void) = .empty,
    complete: bool = true,

    pub fn checked(deps: *Deps) error{IncompleteDependencies}![]const []const u8 {
        std.debug.assert(deps.keys.items.len <= keys_max);

        if (!deps.complete) {
            return error.IncompleteDependencies;
        }

        return deps.keys.items;
    }

    pub fn record_entry(deps: *Deps, id: []const u8) void {
        std.debug.assert(id.len > 0);
        std.debug.assert(deps.keys.items.len <= keys_max);

        var buffer: [changes.key_len_max]u8 = undefined;
        const key = changes.record_key(&buffer, id) catch {
            deps.complete = false;
            return;
        };

        deps.add(key);
    }

    /// A key a render read that is not a record or a type: `setting:currencies`.
    pub fn record_key(deps: *Deps, key: []const u8) void {
        std.debug.assert(key.len > 0);
        std.debug.assert(key.len <= changes.key_len_max);

        deps.add(key);
    }

    pub fn record_type(deps: *Deps, handle: []const u8) void {
        std.debug.assert(handle.len > 0);
        std.debug.assert(deps.keys.items.len <= keys_max);

        var buffer: [changes.key_len_max]u8 = undefined;
        const key = changes.type_key(&buffer, handle) catch {
            deps.complete = false;
            return;
        };

        deps.add(key);
        deps.add(changes.all_records_key);
    }

    /// `template:<app>/<path>`; a template imported from outside the app is keyed by the
    /// folder it lives in, `../shared/nav.publr` as `template:shared/nav.publr`.
    pub fn record_template(deps: *Deps, rel: []const u8) void {
        std.debug.assert(rel.len > 0);
        std.debug.assert(deps.keys.items.len <= keys_max);

        const outside = std.mem.startsWith(u8, rel, engine.imports.outside_prefix);
        const key = if (outside)
            std.fmt.allocPrint(deps.arena, "{s}{s}", .{
                template_key_prefix,
                rel[engine.imports.outside_prefix.len..],
            })
        else
            std.fmt.allocPrint(deps.arena, "{s}{s}/{s}", .{ template_key_prefix, deps.app, rel });
        const recorded = key catch {
            deps.complete = false;
            return;
        };

        deps.add(recorded);
    }

    pub fn record_asset(deps: *Deps) void {
        std.debug.assert(deps.app.len > 0);
        std.debug.assert(deps.keys.items.len <= keys_max);

        const prefix = asset_key_prefix;
        const key = std.fmt.allocPrint(deps.arena, "{s}{s}", .{ prefix, deps.app }) catch {
            deps.complete = false;
            return;
        };

        deps.add(key);
    }

    fn add(deps: *Deps, key: []const u8) void {
        std.debug.assert(key.len > 0);
        std.debug.assert(deps.keys.items.len <= keys_max);

        if (deps.seen.contains(key)) {
            return;
        }

        if (deps.keys.items.len == keys_max) {
            deps.complete = false;
            return;
        }

        const owned = deps.arena.dupe(u8, key) catch {
            deps.complete = false;
            return;
        };

        deps.keys.append(deps.arena, owned) catch {
            deps.complete = false;
            return;
        };
        deps.seen.put(deps.arena, owned, {}) catch {
            deps.complete = false;
            return;
        };

        std.debug.assert(deps.seen.count() == deps.keys.items.len);
    }
};

/// What one render has loaded already, by record id: a settings record that fifty blocks
/// point at is read once. One per page or fragment render, in its arena.
pub const Memo = struct {
    entries: std.StringHashMapUnmanaged(Context.Entry) = .empty,
};

pub const Params = struct { slug: ?[]const u8 = null };

pub const Context = struct {
    /// A published record as templates read it: `post.title`, `post.slug ?? ""`,
    /// `post.data.body`.
    pub const Entry = struct {
        id: []const u8,
        /// The type's handle.
        type: []const u8,
        slug: ?[]const u8,
        title: []const u8,
        created_at: []const u8,
        updated_at: []const u8,
        data: Data,
    };

    /// The record's document: a field's value as text, or null when it is not a scalar.
    pub const Data = struct {
        arena: std.mem.Allocator,
        document: std.json.Value,

        pub fn javascript_value(data: Data, _: std.mem.Allocator) !std.json.Value {
            std.debug.assert(data.document == .object);
            return data.document;
        }

        /// A money field's amount in one currency, in minor units.
        pub fn getAmount(data: Data, key: []const u8, currency: []const u8) ?i64 {
            std.debug.assert(key.len > 0);
            std.debug.assert(data.document == .object);

            const field = data.document.object.get(key) orelse return null;

            if (field != .object) {
                return null;
            }

            const amount = field.object.get(currency) orelse return null;

            return if (amount == .integer) amount.integer else null;
        }

        pub fn getText(data: Data, key: []const u8) ?[]const u8 {
            std.debug.assert(key.len > 0);
            std.debug.assert(data.document == .object);

            const value = data.document.object.get(key) orelse return null;

            return switch (value) {
                .string => |text| text,
                .integer => |number| std.fmt.allocPrint(data.arena, "{d}", .{number}) catch null,
                .float => |number| std.fmt.allocPrint(data.arena, "{d}", .{number}) catch null,
                .bool => |flag| if (flag) "true" else "false",
                else => null,
            };
        }

        /// A reference field's targets: one id, or a list of ids in the order stored, up
        /// to `references_max`; any other value points at nothing.
        pub fn getIds(data: Data, arena: std.mem.Allocator, key: []const u8) ![]const []const u8 {
            std.debug.assert(key.len > 0);
            std.debug.assert(data.document == .object);

            const value = data.document.object.get(key) orelse return &.{};

            switch (value) {
                .string => |id| {
                    const one = try arena.alloc([]const u8, 1);
                    one[0] = id;

                    return one;
                },
                .array => |items| {
                    var ids: std.ArrayList([]const u8) = .empty;

                    for (items.items) |item| {
                        if (item == .string and ids.items.len < references_max) {
                            try ids.append(arena, item.string);
                        }
                    }

                    return ids.items;
                },
                else => return &.{},
            }
        }

        /// A repeater's rows as entries with no identity: `row.data.label` reads a row's
        /// field, and `getReferences(row, 'field')` follows one. Up to `references_max` rows.
        pub fn getItems(data: Data, arena: std.mem.Allocator, key: []const u8) ![]const Entry {
            std.debug.assert(key.len > 0);
            std.debug.assert(data.document == .object);

            const value = data.document.object.get(key) orelse return &.{};

            if (value != .array) {
                return &.{};
            }

            var items: std.ArrayList(Entry) = .empty;

            for (value.array.items) |item| {
                if (item != .object or items.items.len == references_max) {
                    continue;
                }

                try items.append(arena, .{
                    .id = "",
                    .type = "",
                    .slug = null,
                    .title = "",
                    .created_at = "",
                    .updated_at = "",
                    .data = .{ .arena = data.arena, .document = item },
                });
            }

            return items.items;
        }
    };

    pub const QueryOptions = struct { limit: ?u32 = null, offset: ?u32 = null };

    /// `Publr.request.session`: who is signed in. `email` is null for a visitor.
    pub const Session = struct { email: ?[]const u8 = null };

    arena: std.mem.Allocator,
    project: *const Project,
    app: *const App,
    /// The live request, or null during the static build.
    request: ?*http.Request = null,
    params: Params = .{},
    /// Set by the static build to learn what the page read.
    deps: ?*Deps = null,
    /// The render's loaded entries; null reads every reference afresh.
    memo: ?*Memo = null,
    /// A per-request render (a live page, a dynamic fragment): dynamic islands flatten.
    live: bool = false,
    /// Who the records are read as in a per-request render (`visitor`); anything else is
    /// shared by every visitor and reads as nobody.
    caller: sdk.Caller = .anonymous,
    /// The page being rendered, for what its `<head>` owes it; null for a fragment.
    page: ?*const engine.Template = null,
    /// Where a live page's `Publr.request.redirect()` sends the visitor; null where no
    /// redirect can be answered (a build, a fragment).
    redirect_to: ?*?[]const u8 = null,

    /// A dynamic island's prerender pass: no request, not live, a visitor nobody knows.
    pub fn prerender(ctx: *const Context) Context {
        std.debug.assert(!ctx.live or ctx.request != null);
        std.debug.assert(ctx.app.pages().templates.len > 0);

        return .{
            .arena = ctx.arena,
            .project = ctx.project,
            .app = ctx.app,
            .params = ctx.params,
            .deps = ctx.deps,
            .memo = ctx.memo,
        };
    }

    /// A static island's prerender pass: the same minus `deps`, so the page does not
    /// subscribe to what the island reads.
    pub fn stale(ctx: *const Context) Context {
        std.debug.assert(ctx.app.pages().templates.len > 0);
        std.debug.assert(ctx.page != null or ctx.deps == null);

        return .{
            .arena = ctx.arena,
            .project = ctx.project,
            .app = ctx.app,
            .params = ctx.params,
            .memo = ctx.memo,
        };
    }

    /// Everything a page's `<head>` owes it, written where the app closes the head: the
    /// stylesheet inline, the client half when the page will hold an interactive component,
    /// the island preloads, and the loader.
    pub fn head_assets(ctx: *const Context, writer: *std.Io.Writer) !void {
        std.debug.assert(ctx.app.css.len > 0);
        std.debug.assert(ctx.app.version.len == 16);

        if (ctx.deps) |deps| {
            deps.record_asset();
        }

        try writer.writeAll("<style>");
        try writer.writeAll(ctx.app.css);
        try writer.writeAll("</style>");
        try ctx.write_module(writer, "toolbar.js");

        const page = ctx.page orelse return;

        if (page.has_interactive) {
            for (ctx.app.stores_imports) |path| {
                try ctx.write_module(writer, path);
            }

            try ctx.write_module(writer, "stores.js");
        }

        if (!page.page_islands()) {
            return;
        }

        try write_preloads(writer, ctx.app.base(), page);

        if (ctx.app.options.dev) {
            try writer.writeAll(island_tint);
        }

        try writer.writeAll(island_conditions);
        try ctx.write_module(writer, "islands.js");
    }

    /// One module its own low-priority script: nothing on screen waits for it.
    fn write_module(ctx: *const Context, writer: *std.Io.Writer, path: []const u8) !void {
        std.debug.assert(path.len > 0);
        std.debug.assert(std.mem.endsWith(u8, path, ".js"));

        try writer.print("<script type=\"module\" async fetchpriority=\"low\" " ++
            "src=\"{s}{s}{s}?v={s}\"></script>", .{
            ctx.app.base(),
            assets_prefix,
            path,
            &ctx.app.version,
        });
    }

    /// An `/_app/...` URL under the app's mount, with the fingerprint of the build. The
    /// compiler refused any other, so only a query or fragment makes one unknown here.
    pub fn asset_url(ctx: *const Context, writer: *std.Io.Writer, path: []const u8) !void {
        std.debug.assert(std.mem.startsWith(u8, path, assets_prefix));
        std.debug.assert(ctx.app.version.len == 16);

        const relative = path[assets_prefix.len..];

        try writer.writeAll(ctx.app.base());

        if (!std.mem.eql(u8, relative, stylesheet) and ctx.app.asset(relative) == null) {
            return writer.writeAll(path);
        }

        if (ctx.deps) |deps| {
            deps.record_asset();
        }

        try writer.print("{s}?v={s}", .{ path, &ctx.app.version });
    }

    pub fn param(ctx: *const Context, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);
        std.debug.assert(ctx.app.pages().routes.len > 0);

        return if (std.mem.eql(u8, name, "slug")) ctx.params.slug else null;
    }

    pub fn report_declaration_error(
        ctx: *const Context,
        template: []const u8,
        decl: engine.ast.Decl,
        err: anyerror,
    ) void {
        if (ctx.request != null) {
            return;
        }

        const reason = ctx.app.options.diagnostic orelse return;

        if (err != error.EntryNotFound) {
            return;
        }

        switch (decl.value) {
            .entry => |lookup| {
                if (lookup.first) {
                    reason.set("[{s}] `{s}` {s}: no published entry of type '{s}'; " ++
                        "publish the required content before building", .{
                        ctx.app.spec.name,
                        template,
                        decl.name,
                        lookup.type_id,
                    });
                } else {
                    reason.set("[{s}] `{s}` {s}: no published entry of type '{s}' " ++
                        "with slug '{s}'; " ++
                        "publish the required content before building", .{
                        ctx.app.spec.name,
                        template,
                        decl.name,
                        lookup.type_id,
                        lookup.slug orelse ctx.param("slug") orelse "unknown",
                    });
                }
            },
            else => {},
        }
    }

    pub fn report_javascript_error(ctx: *const Context, message: []const u8) void {
        std.debug.assert(message.len > 0);
        const reason = ctx.app.options.diagnostic orelse return;
        reason.set("[{s}] template JavaScript: {s}", .{ ctx.app.spec.name, message });
    }

    /// `Publr.build.getEntry()`: the live record of `type_id` whose slug is `slug`. A type
    /// the site has no (public) record of has no entries: not found.
    pub fn entry(ctx: *const Context, type_id: []const u8, slug: []const u8) !Entry {
        std.debug.assert(type_id.len > 0);
        std.debug.assert(ctx.app.pages().routes.len > 0);

        if (slug.len == 0) {
            return error.EntryNotFound;
        }

        var sdk_ctx = ctx.sdk_context();
        const listed = registry.SDK.dispatch(&sdk_ctx, record_operations.List, .{
            .type = type_id,
            .slug = slug,
            .limit = 1,
        }) catch |err| switch (err) {
            error.NotFound => return error.EntryNotFound,
            else => return err,
        };

        if (listed.records.len == 0) {
            return error.EntryNotFound;
        }

        return ctx.load(listed.records[0].id);
    }

    /// `Publr.build.getEntry({ type })` outside a `[slug]` template: the type's newest live
    /// record, for a type that holds one (the site's settings).
    pub fn first(ctx: *const Context, type_id: []const u8) !Entry {
        std.debug.assert(type_id.len > 0);
        std.debug.assert(ctx.app.pages().routes.len > 0);

        const found = try ctx.query(type_id, .{ .limit = 1 });

        if (found.len == 0) {
            return error.EntryNotFound;
        }

        return found[0];
    }

    /// `Publr.build.getCollection({ type, limit, offset })`: the type's live records,
    /// newest first. A type the site does not have yet (a fresh install, a type not public)
    /// is an empty collection: the read is recorded, so the type's arrival rebuilds the page.
    pub fn query(ctx: *const Context, type_id: []const u8, options: QueryOptions) ![]const Entry {
        std.debug.assert(type_id.len > 0);
        std.debug.assert(query_limit_default <= query_limit_max);

        if (ctx.deps) |deps| {
            deps.record_type(type_id);
        }

        var sdk_ctx = ctx.sdk_context();
        const listed = registry.SDK.dispatch(&sdk_ctx, record_operations.List, .{
            .type = type_id,
            .order = .created_desc,
            .limit = @min(options.limit orelse query_limit_default, query_limit_max),
            .offset = options.offset orelse 0,
        }) catch |err| switch (err) {
            error.NotFound => return &.{},
            else => return err,
        };
        const entries = try ctx.arena.alloc(Entry, listed.records.len);

        for (listed.records, entries) |record, *out| {
            out.* = try ctx.load(record.id);
        }

        return entries;
    }

    /// `Publr.build.getReferences(entry, 'field')`: the records `ids` name, in that order.
    /// A target that is not live and public (or is gone) is left out; every id is written
    /// down anyway, so the target's arrival rebuilds the page.
    pub fn references(ctx: *const Context, ids: []const []const u8) ![]const Entry {
        std.debug.assert(ids.len <= references_max);
        std.debug.assert(ctx.app.pages().routes.len > 0);

        var entries: std.ArrayList(Entry) = .empty;

        for (ids) |id| {
            if (id.len == 0) continue;
            if (ctx.deps) |deps| {
                deps.record_entry(id);
            }

            const found = ctx.load(id) catch |err| switch (err) {
                error.EntryNotFound => continue,
                else => return err,
            };

            try entries.append(ctx.arena, found);
        }

        return entries.items;
    }

    /// `Publr.build.getReference(entry, 'field')`: the first record `ids` name that is live
    /// and public, else a blank entry (empty id and type, no fields), so a template reads
    /// `settings.data.theme ?? "cream"` whether or not the field points anywhere.
    pub fn reference(ctx: *const Context, ids: []const []const u8) !Entry {
        std.debug.assert(ids.len <= references_max);
        std.debug.assert(ctx.app.pages().routes.len > 0);

        const found = try ctx.references(ids);

        if (found.len > 0) {
            return found[0];
        }

        const empty = try @import("../../lib/json.zig").parse(std.json.Value, ctx.arena, "{}", .{});

        return .{
            .id = "",
            .type = "",
            .slug = null,
            .title = "",
            .created_at = "",
            .updated_at = "",
            .data = .{ .arena = ctx.arena, .document = empty },
        };
    }

    /// The record's document, and the read written down; the memo answers a repeat.
    fn load(ctx: *const Context, id: []const u8) !Entry {
        std.debug.assert(id.len > 0);
        std.debug.assert(ctx.project.connection.transaction_depth == 0);

        if (ctx.deps) |deps| {
            deps.record_entry(id);
        }

        if (ctx.memo) |memo| {
            if (memo.entries.get(id)) |known| {
                return known;
            }
        }

        const loaded = try ctx.fetch(id);

        if (ctx.memo) |memo| {
            try memo.entries.put(ctx.arena, loaded.id, loaded);
        }

        return loaded;
    }

    fn fetch(ctx: *const Context, id: []const u8) !Entry {
        std.debug.assert(id.len > 0);
        std.debug.assert(ctx.project.auth.secret.len > 0);

        var sdk_ctx = ctx.sdk_context();
        const got = registry.SDK.dispatch(&sdk_ctx, record_operations.Get, .{
            .id = id,
        }) catch |err| switch (err) {
            error.NotFound => return error.EntryNotFound,
            else => return err,
        };
        const parsed = @import("../../lib/json.zig").parse(
            std.json.Value,
            ctx.arena,
            got.document,
            .{},
        );
        const document = parsed catch return error.EntryNotFound;

        if (document != .object) {
            return error.EntryNotFound;
        }

        return .{
            .id = got.record.id,
            .type = got.record.type,
            .slug = got.record.slug,
            .title = got.record.title,
            .created_at = try time.date_text(ctx.arena, got.record.created_at),
            .updated_at = try time.date_text(ctx.arena, got.record.updated_at),
            .data = .{ .arena = ctx.arena, .document = document },
        };
    }

    /// `Publr.build.now()`: when the site was last built, in milliseconds.
    pub const money_code = @import("money.zig").code;
    pub const money = @import("money.zig").write;

    pub fn build_time(ctx: *const Context) i64 {
        std.debug.assert(ctx.app.built_at >= 0);
        std.debug.assert(ctx.app.css.len > 0);

        return ctx.app.built_at;
    }

    /// `Publr.request.now()`: the request's clock; the build's in a prerender pass.
    pub fn now(ctx: *const Context) i64 {
        std.debug.assert(ctx.app.built_at >= 0);
        std.debug.assert(ctx.app.css.len > 0);

        if (ctx.request == null) {
            return ctx.app.built_at;
        }

        return sdk.context.wall_clock_ms(ctx.project.io);
    }

    /// The caller a per-request render reads records as: the request's session user, within
    /// that user's grant and live records only (see `sdk_context`).
    pub fn visitor(
        project: *const Project,
        app: *const App,
        arena: std.mem.Allocator,
        request: *const http.Request,
    ) sdk.Caller {
        std.debug.assert(project.connection.transaction_depth == 0);
        std.debug.assert(app.spec.name.len > 0);

        return identify(project, app, arena, request).caller;
    }

    /// `Publr.request.session`: the request's cookie resolved to a user. Nobody, without a
    /// request.
    pub fn session(ctx: *const Context) !Session {
        std.debug.assert(ctx.project.connection.transaction_depth == 0);
        std.debug.assert(!ctx.live or ctx.request != null);

        const request = ctx.request orelse return .{};
        const identity = identify(ctx.project, ctx.app, ctx.arena, request);

        return .{ .email = if (identity.email.len > 0) identity.email else null };
    }

    /// `Publr.request.header('name')`.
    pub fn header(ctx: *const Context, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);
        std.debug.assert(!ctx.live or ctx.request != null);

        const request = ctx.request orelse return null;

        return request.header(name);
    }

    /// `Publr.request.cookie('name')`: one cookie's value, raw.
    pub fn cookie(ctx: *const Context, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);
        std.debug.assert(!ctx.live or ctx.request != null);

        const request = ctx.request orelse return null;
        const header_text = request.header("cookie") orelse return null;

        return identity_module.cookie_value(header_text, name);
    }

    /// `Publr.request.call('<namespace>.<verb>')`: runs the operation as the visitor, through
    /// the same pipeline as the API. Only an operation that declares
    /// `allow_frontmatter_calls` runs from a page (anything else fails the render); a
    /// prefetch runs nothing. A refused or failed call is a blank entry, so the page stays
    /// up; a finished one carries the operation's output as its `data`.
    pub fn call(ctx: *const Context, operation: []const u8) !Entry {
        std.debug.assert(operation.len > 0);
        std.debug.assert(ctx.project.connection.transaction_depth == 0);

        const blank = try ctx.reference(&.{});
        const request = ctx.request orelse return blank;

        if (prefetch(request)) {
            return blank;
        }

        inline for (registry.SDK.operations) |Operation| {
            if (std.mem.eql(u8, Operation.name, operation)) {
                return ctx.run(Operation, blank);
            }
        }

        return error.UnknownOperation;
    }

    fn run(ctx: *const Context, comptime Operation: type, blank: Entry) !Entry {
        std.debug.assert(Operation.name.len > 0);
        std.debug.assert(blank.id.len == 0);

        const allowed = @hasDecl(Operation, "allow_frontmatter_calls") and
            Operation.allow_frontmatter_calls;

        if (!allowed) {
            return error.FrontmatterCallRefused;
        }

        const json = @import("../../lib/json.zig");
        const in = json.parse(Operation.In, ctx.arena, "{}", .{}) catch {
            return error.FrontmatterCallNeedsInput;
        };
        var sdk_ctx = identity_module.context(ctx.project, ctx.arena, ctx.caller);

        sdk_ctx.app = ctx.app.spec.name;
        sdk_ctx.app_plugins = ctx.app.spec.plugins;

        const out = registry.SDK.dispatch(&sdk_ctx, Operation, in) catch return blank;
        const text = try std.json.Stringify.valueAlloc(ctx.arena, out, .{});
        const document = json.parse(std.json.Value, ctx.arena, text, .{}) catch return blank;

        if (document != .object) {
            return blank;
        }

        var result = blank;
        result.data = .{ .arena = ctx.arena, .document = document };

        return result;
    }

    /// `Publr.request.userField('<group>.<field>')`: the signed-in user's custom field as
    /// text, read as the system for the caller's own account; null when nobody is signed
    /// in, or the field is empty.
    pub fn user_field(ctx: *const Context, path: []const u8) !?[]const u8 {
        std.debug.assert(path.len > 0);
        std.debug.assert(!ctx.live or ctx.request != null);

        const request = ctx.request orelse return null;
        const identity = identify(ctx.project, ctx.app, ctx.arena, request);
        const user_id = identity.caller.user_id() orelse return null;

        return user_field_of(ctx.project, ctx.arena, user_id, path);
    }

    /// `Publr.request.redirect(path)`: the page answers `303 See Other` to `path`, which
    /// must be a path on this site (`/spaces/ada`), never another host or a scheme.
    pub fn redirect(ctx: *const Context, path: []const u8) !void {
        std.debug.assert(path.len > 0);
        std.debug.assert(!ctx.live or ctx.request != null);

        const slot = ctx.redirect_to orelse return error.RedirectUnavailable;

        if (!local_path(path)) {
            return error.RedirectNotLocal;
        }

        slot.* = path;
    }

    /// `Publr.request.random(n)`: a number in [0, n); 0 in a prerender pass.
    pub fn random(ctx: *const Context, bound: u32) i64 {
        std.debug.assert(bound > 0);
        std.debug.assert(!ctx.live or ctx.request != null);

        if (ctx.request == null) {
            return 0;
        }

        var bytes: [4]u8 = undefined;

        ctx.project.io.randomSecure(&bytes) catch return 0;

        return std.mem.readInt(u32, &bytes, .little) % bound;
    }

    /// Every template a render goes through is a dependency of the artifact.
    pub fn record_template(ctx: *const Context, rel: []const u8) void {
        std.debug.assert(rel.len > 0);
        std.debug.assert(std.mem.endsWith(u8, rel, ".publr"));

        if (ctx.deps) |deps| {
            deps.record_template(rel);
        }
    }

    pub fn sdk_context(ctx: *const Context) sdk.Ctx {
        std.debug.assert(ctx.project.connection.transaction_depth == 0);
        std.debug.assert(ctx.live or ctx.caller == .anonymous);
        std.debug.assert(ctx.deps == null or ctx.caller == .anonymous);

        var sdk_ctx = identity_module.context(ctx.project, ctx.arena, ctx.caller);
        sdk_ctx.delivery = true;
        sdk_ctx.app = ctx.app.spec.name;
        sdk_ctx.app_plugins = ctx.app.spec.plugins;

        return sdk_ctx;
    }
};

/// Who is asking, as the app sees it: an app that names roles (`app.zon`'s `.roles`) sees
/// a signed-in account holding none of them as nobody.
pub fn identify(
    project: *const Project,
    app: *const App,
    arena: std.mem.Allocator,
    request: *const http.Request,
) identity_module.Identity {
    std.debug.assert(project.connection.transaction_depth == 0);
    std.debug.assert(app.spec.roles.len <= @import("../../model/app.zig").roles_max);

    const identity = identity_module.identify(request, arena, project);

    if (app.spec.roles.len == 0 or identity.caller != .user) {
        return identity;
    }

    for (app.spec.roles) |name| {
        if (identity.caller.holds(name)) {
            return identity;
        }
    }

    return .{};
}

/// A browser fetching the page ahead of the visitor (a hover preload, speculation rules):
/// nobody has opened it yet.
fn prefetch(request: *const http.Request) bool {
    std.debug.assert(request.path().len > 0);

    const sec_purpose = request.header("sec-purpose") orelse "";
    const purpose = request.header("purpose") orelse "";

    return std.mem.indexOf(u8, sec_purpose, "prefetch") != null or
        std.mem.eql(u8, purpose, "prefetch");
}

/// A path on this site: one leading slash, not `//` or `/\` (which a browser reads as
/// another host), and no control characters.
fn local_path(path: []const u8) bool {
    std.debug.assert(path.len > 0);

    if (path[0] != '/') {
        return false;
    }

    if (path.len > 1 and (path[1] == '/' or path[1] == '\\')) {
        return false;
    }

    for (path) |char| {
        if (char < 0x20 or char == 0x7f) {
            return false;
        }
    }

    std.debug.assert(path[0] == '/');

    return true;
}

/// A user's custom field (`<group>.<field>`) as text, read as the system; null when the
/// field is empty or not there. What templates' `userField` and middleware's `user_field`
/// both read.
pub fn user_field_of(
    project: *const Project,
    arena: std.mem.Allocator,
    user_id: []const u8,
    path: []const u8,
) !?[]const u8 {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(path.len > 0);

    var sdk_ctx = identity_module.context(project, arena, .system);
    const got = try registry.SDK.dispatch(&sdk_ctx, user_operations.Get, .{ .user = user_id });
    const document = @import("../../lib/json.zig").parse(
        std.json.Value,
        arena,
        got.document,
        .{},
    ) catch return null;
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse return null;

    if (document != .object) {
        return null;
    }

    const group = document.object.get(path[0..dot]) orelse return null;

    if (group != .object) {
        return null;
    }

    const data: Context.Data = .{ .arena = arena, .document = group };
    const text = data.getText(path[dot + 1 ..]) orelse return null;

    return if (text.len == 0) null else text;
}

test "a redirect stays on the site" {
    try std.testing.expect(local_path("/"));
    try std.testing.expect(local_path("/spaces/ada"));
    try std.testing.expect(local_path("/spaces/ada?tab=sites"));
    try std.testing.expect(!local_path("https://evil.test/"));
    try std.testing.expect(!local_path("//evil.test/"));
    try std.testing.expect(!local_path("/\\evil.test/"));
    try std.testing.expect(!local_path("spaces/ada"));
    try std.testing.expect(!local_path("/x\r\nSet-Cookie: a=1"));
}

/// A static island is cookieless, so an anonymous preload; nested ones included. A dynamic
/// tier is one request, the URL the loader will build, credentialed as it fetches.
fn write_preloads(writer: *std.Io.Writer, base: []const u8, page: *const engine.Template) !void {
    std.debug.assert(page.page_islands());
    std.debug.assert(page.kind == .page);

    for ([_][]const []const u8{ page.static_island_keys, page.static_idle_keys }) |set| {
        for (set) |key| {
            try writer.print("<link rel=\"preload\" as=\"fetch\" crossorigin " ++
                "href=\"{s}{s}{s}\">", .{ base, islands_prefix, key });
        }
    }

    for ([_][]const []const u8{ page.dynamic_eager_keys, page.dynamic_idle_keys }) |tier| {
        if (tier.len == 0) {
            continue;
        }

        try writer.print("<link rel=\"preload\" as=\"fetch\" crossorigin=\"use-credentials\" " ++
            "href=\"{s}{s}", .{ base, islands_prefix });

        if (tier.len == 1) {
            try writer.writeAll(tier[0]);
        } else {
            try writer.writeAll("?keys=");

            for (tier, 0..) |key, at| {
                if (at > 0) {
                    try writer.writeAll(",");
                }

                try writer.writeAll(key);
            }
        }

        try writer.writeAll("\">");
    }
}

/// Before any of the page's own scripts: `Publr.islands.condition(name, fn)`, where a page
/// names the browser conditions its `dynamic-if` islands wait on, with `signedIn` (Publr's
/// own hint, kept in step with the session by the server) already there; and `whenReady`,
/// which the loader runs its conditional islands through once every script on the page
/// has run, so a condition is never judged missing only because its script came later.
const island_conditions =
    "<script>(()=>{const publr=window.Publr??={};const islands=publr.islands??={};" ++
    "const conditions=islands.conditions??={};let ready=false;const waiting=[];" ++
    "islands.condition=(name,test)=>{conditions[name]=test};" ++
    "islands.whenReady=(run)=>ready?run():waiting.push(run);" ++
    "document.addEventListener('DOMContentLoaded',()=>{ready=true;" ++
    "for(const run of waiting.splice(0))run()});" ++
    "islands.condition('signedIn',()=>document.cookie.split('; ')" ++
    ".includes('publr_signed_in=1'))})()</script>";

/// `--dev`: every placed island tinted so the boundaries are visible.
const island_tint = "<style>" ++
    "[data-island-kind=\"static\"] { outline: 2px dashed yellowgreen; outline-offset: 2px; " ++
    "box-shadow: inset 0 0 0 100vmax rgba(154, 205, 50, .12); }" ++
    "[data-island-kind=\"dynamic\"] { outline: 2px dashed rebeccapurple; outline-offset: 2px; " ++
    "box-shadow: inset 0 0 0 100vmax rgba(102, 51, 153, .12); }" ++
    "</style>";

test "deps: keys are recorded once, a type read also depends on every record" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var deps: Deps = .{ .arena = arena_state.allocator(), .app = "www" };
    deps.record_entry("abc");
    deps.record_entry("abc");
    deps.record_type("post");
    deps.record_template("layouts/base.publr");
    deps.record_asset();

    try std.testing.expectEqual(@as(usize, 5), deps.keys.items.len);
    try std.testing.expectEqualStrings("record:abc", deps.keys.items[0]);
    try std.testing.expectEqualStrings("type:post", deps.keys.items[1]);
    try std.testing.expectEqualStrings("records", deps.keys.items[2]);
    try std.testing.expectEqualStrings("template:www/layouts/base.publr", deps.keys.items[3]);
    try std.testing.expectEqualStrings("asset:www", deps.keys.items[4]);
}

test "data: scalars read as text, anything else is null" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "{\"title\":\"Hi\",\"views\":3,\"ratio\":1.5,\"on\":true,\"tags\":[\"a\"]}";
    const document = try @import("../../lib/json.zig").parse(std.json.Value, arena, text, .{});
    const data: Context.Data = .{ .arena = arena, .document = document };

    try std.testing.expectEqualStrings("Hi", data.getText("title").?);
    try std.testing.expectEqualStrings("3", data.getText("views").?);
    try std.testing.expectEqualStrings("1.5", data.getText("ratio").?);
    try std.testing.expectEqualStrings("true", data.getText("on").?);
    try std.testing.expect(data.getText("tags") == null);
    try std.testing.expect(data.getText("missing") == null);
}

test "data: a reference field's ids come back in order, one or many, nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "{\"one\":\"a\",\"many\":[\"b\",3,\"c\"],\"none\":7}";
    const document = try @import("../../lib/json.zig").parse(std.json.Value, arena, text, .{});
    const data: Context.Data = .{ .arena = arena, .document = document };

    const one = try data.getIds(arena, "one");
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings("a", one[0]);
    const many = try data.getIds(arena, "many");
    try std.testing.expectEqual(@as(usize, 2), many.len);
    try std.testing.expectEqualStrings("b", many[0]);
    try std.testing.expectEqualStrings("c", many[1]);
    try std.testing.expectEqual(@as(usize, 0), (try data.getIds(arena, "none")).len);
    try std.testing.expectEqual(@as(usize, 0), (try data.getIds(arena, "missing")).len);
}
