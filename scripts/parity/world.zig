const std = @import("std");
const publr = @import("publr");

const sdk = publr.sdk;
const store = publr.store;
const content_types = publr.operations.content_type;
const records = publr.operations.record;
const taxonomies = publr.operations.taxonomy;
const terms = publr.operations.term;
const projects = publr.operations.project;
const users = publr.operations.user;
const saved_views = publr.operations.view;
const sign_on = publr.operations.sign_on;
const identities = publr.operations.identity;
const sign_on_token = publr.model.sign_on_token;
const SDK = publr.registry.SDK;

const Ctx = sdk.Ctx;
const Error = sdk.Error;

pub const admin_email = "ada@example.com";
pub const shared_password = "correct horse battery";

/// The parity site's issuer. A sign-on token is good for a minute, so no printed one ever
/// redeems: parity signs a fresh one with this seed when it runs the example.
const issuer_seed = [_]u8{7} ** 32;

const page_definition =
    \\{"handle":"page","name":"Page","public":true,
    \\ "fields":[{"name":"title","label":"Title","kind":"string","required":true}]}
;
const second_document = "{\"title\":\"Hello, world\",\"body\":\"<p>Second.</p>\"}";
const edited_document = "{\"title\":\"Hello, world\",\"body\":\"<p>Edited.</p>\"}";
const referring_document = "{\"title\":\"See also\",\"related\":[\"" ++
    records.example_id ++ "\"]}";
const tags_definition =
    \\{"handle":"tags","name":"Tags","title_field":"name",
    \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true}]}
;

/// Everything the printed examples name: Ada, the admin every `--as` points at; an editor
/// who can sign in; an invited account holding the documented token; the `post` and `page`
/// types; the issuer `sign_on` trusts; a live record that anyone may read and that has a
/// revision behind it, a second live record with edits parked in `pending`, and a draft
/// still waiting to be published.
pub fn fill(ctx: *Ctx, dir: []const u8) Error!void {
    std.debug.assert(ctx.caller == .system);
    std.debug.assert(ctx.db.transaction_depth == 0);

    const admin_id = try fill_site(ctx);

    try fill_users(ctx);

    ctx.caller = .{ .user = .{ .id = admin_id, .roles = &.{"admin"} } };

    try fill_types(ctx);
    try fill_records(ctx);
    try fill_taxonomies(ctx);
    try fill_views(ctx);
    try fill_sign_on(ctx);
    try fill_identities(ctx);
    try fill_plugins(ctx, dir);

    const custom = publr.operations.custom_fields;
    _ = try SDK.dispatch(ctx, custom.Update, .{
        .group = "user",
        .definition = try publr.model.content_type.encode(
            ctx.arena,
            custom.Destination.user.definition(),
        ),
    });
}

/// The modules the plugin examples and the world add, beside the database's folder:
/// `greeter-0.2.0.wasm` for `plugin add`, and the copies the world adds from.
pub fn upload_plugins(io: std.Io, dir: []const u8) !void {
    std.debug.assert(dir.len > 0);
    std.debug.assert(std.fs.path.isAbsolute(dir));

    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);

    const files = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "greeter-0.2.0.wasm", .bytes = @embedFile("sandboxed_plugin_greeter_next") },
        .{ .name = "world-greeter.wasm", .bytes = @embedFile("sandboxed_plugin_greeter") },
        .{
            .name = "world-greeter-next.wasm",
            .bytes = @embedFile("sandboxed_plugin_greeter_next"),
        },
        .{ .name = "world-farewell.wasm", .bytes = @embedFile("sandboxed_plugin_farewell") },
    };

    for (files) |file| {
        try folder.writeFile(io, .{ .sub_path = file.name, .data = file.bytes });
    }
}

/// `greeter` enabled, updated to 0.2.0 and rolled back, with 0.2.0 offered again; `farewell`
/// added and disabled. Adding from a path is the local operator's.
fn fill_plugins(ctx: *Ctx, dir: []const u8) Error!void {
    std.debug.assert(ctx.caller == .user);
    std.debug.assert(ctx.sandboxed_plugins != null);

    const plugin_operations = publr.operations.plugin;
    const admin = ctx.caller;
    const greeter = try path_in(ctx, dir, "world-greeter.wasm");
    const next = try path_in(ctx, dir, "world-greeter-next.wasm");

    ctx.caller = .system;
    _ = try SDK.dispatch(ctx, plugin_operations.Add, .{ .file = greeter });
    _ = try SDK.dispatch(ctx, plugin_operations.Add, .{ .file = next });
    _ = try SDK.dispatch(ctx, plugin_operations.Add, .{
        .file = try path_in(ctx, dir, "world-farewell.wasm"),
    });
    ctx.caller = admin;
    _ = try SDK.dispatch(ctx, plugin_operations.Enable, .{ .name = "greeter" });
    _ = try SDK.dispatch(ctx, plugin_operations.Update, .{ .name = "greeter" });
    _ = try SDK.dispatch(ctx, plugin_operations.Rollback, .{ .name = "greeter" });
    ctx.caller = .system;
    _ = try SDK.dispatch(ctx, plugin_operations.Add, .{ .file = next });
    ctx.caller = admin;
}

fn path_in(ctx: *Ctx, dir: []const u8, name: []const u8) Error![]const u8 {
    std.debug.assert(name.len > 0);

    return std.fs.path.join(ctx.arena, &.{ dir, name }) catch error.OutOfMemory;
}

/// The taxonomies the examples name: `topics` (hierarchical, with a published root, a
/// published child of it, a published term with pending edits and a draft, under the ids
/// the examples print) and `tags`, flat and empty, for the delete example.
fn fill_taxonomies(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.caller == .user);
    std.debug.assert(terms.example_parent_id.len == store.terms.id_len);

    _ = try SDK.dispatch(ctx, taxonomies.Create, .{ .definition = taxonomies.example_definition });
    _ = try SDK.dispatch(ctx, taxonomies.Create, .{ .definition = tags_definition });

    try term_with_id(ctx, terms.example_parent_id, "Technology", null);
    _ = try SDK.dispatch(ctx, terms.Publish, .{ .id = terms.example_parent_id });
    try term_with_id(ctx, terms.example_id, "Engineering", terms.example_parent_id);
    _ = try SDK.dispatch(ctx, terms.Publish, .{ .id = terms.example_id });
    try term_with_id(ctx, terms.example_changed_id, "Design", null);
    _ = try SDK.dispatch(ctx, terms.Publish, .{ .id = terms.example_changed_id });
    _ = try SDK.dispatch(ctx, terms.Save, .{
        .id = terms.example_changed_id,
        .document = "{\"name\":\"Product design\"}",
    });
    try term_with_id(ctx, terms.example_draft_id, "Drafted", null);
}

/// Create a term and give it the id the examples name.
fn term_with_id(ctx: *Ctx, id: []const u8, name: []const u8, parent: ?[]const u8) Error!void {
    std.debug.assert(ctx.caller == .user);
    std.debug.assert(id.len == store.terms.id_len);

    const document = std.fmt.allocPrint(ctx.arena, "{{\"name\":\"{s}\"}}", .{name}) catch {
        return error.OutOfMemory;
    };
    const created = try SDK.dispatch(ctx, terms.Create, .{
        .taxonomy = "topics",
        .document = document,
        .parent = parent,
    });

    try store.terms.rename(ctx.db, created.id, id);
}

/// The view the examples name, Ada's.
fn fill_views(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.caller == .user);
    std.debug.assert(saved_views.example_id.len == store.views.id_len);

    const created = try SDK.dispatch(ctx, saved_views.Create, saved_views.Create.example);

    try store.views.rename(ctx.db, created.id, saved_views.example_id);
}

fn fill_site(ctx: *Ctx) Error![]const u8 {
    std.debug.assert(ctx.caller == .system);
    std.debug.assert(admin_email.len > 0);

    const created = try SDK.dispatch(ctx, projects.Init, .{
        .email = admin_email,
        .display_name = "Ada",
        .password = shared_password,
    });

    std.debug.assert(created.user_id.len > 0);

    return created.user_id;
}

fn fill_users(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.caller == .system);
    std.debug.assert(users.SetPassword.example.token.len == users.password_token_len);

    _ = try SDK.dispatch(ctx, users.Create, .{
        .email = "editor@example.com",
        .display_name = "Editor",
        .password = shared_password,
    });

    const invited = try SDK.dispatch(ctx, users.Create, .{
        .email = "invited@example.com",
        .display_name = "Invited",
        .password_link = true,
    });

    const token_hash = users.hash_token(users.SetPassword.example.token) orelse unreachable;
    const expires_at = ctx.now_ms + users.password_link_lifetime_ms;

    try store.users.set_password_token(ctx.db, invited.user_id, token_hash, expires_at);
}

fn fill_types(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.caller == .user);
    std.debug.assert(content_types.example_definition.len > 0);

    _ = try SDK.dispatch(ctx, content_types.Create, .{
        .definition = content_types.example_definition,
    });
    _ = try SDK.dispatch(ctx, content_types.Create, .{ .definition = page_definition });
}

fn fill_records(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.caller == .user);
    std.debug.assert(records.example_changed_id.len == store.records.id_len);

    try record_with_id(ctx, records.example_id);
    _ = try SDK.dispatch(ctx, records.Publish, .{ .id = records.example_id });
    _ = try SDK.dispatch(ctx, records.Save, .{
        .id = records.example_id,
        .document = second_document,
    });
    _ = try SDK.dispatch(ctx, records.Publish, .{ .id = records.example_id });

    try record_with_id(ctx, records.example_changed_id);
    _ = try SDK.dispatch(ctx, records.Publish, .{ .id = records.example_changed_id });
    _ = try SDK.dispatch(ctx, records.Save, .{
        .id = records.example_changed_id,
        .document = edited_document,
    });

    try record_with_id(ctx, records.example_draft_id);

    const referring = try SDK.dispatch(ctx, records.Create, .{
        .type = "post",
        .document = referring_document,
    });

    _ = try SDK.dispatch(ctx, records.Publish, .{ .id = referring.id });
}

/// Create a post and give it the id the examples name, so `--id a1b2...` resolves.
fn record_with_id(ctx: *Ctx, id: []const u8) Error!void {
    std.debug.assert(ctx.caller == .user);
    std.debug.assert(id.len == store.records.id_len);

    const created = try SDK.dispatch(ctx, records.Create, .{
        .type = "post",
        .document = records.example_document,
    });

    try store.records.rename(ctx.db, created.id, id);
}

/// The issuer the `sign_on` examples name, holding the parity key instead of the printed one.
fn fill_sign_on(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.caller == .user);
    std.debug.assert(sign_on.Configure.example.audience.len > 0);

    const public_hex = sign_on_token.public_key_hex(issuer_seed) catch return error.Invalid;

    _ = try SDK.dispatch(ctx, sign_on.Configure, .{
        .issuer = sign_on.Configure.example.issuer,
        .public_key = &public_hex,
        .audience = sign_on.Configure.example.audience,
    });
}

/// The identity the `identity` examples name, linked to Ada; `identity link` names another.
fn fill_identities(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.caller == .user);
    std.debug.assert(identities.example_in.verified);

    const example = identities.example_in;

    _ = try SDK.dispatch(ctx, identities.Link, .{
        .user = admin_email,
        .provider = example.provider,
        .id = example.id,
        .email = example.email,
        .verified = example.verified,
    });
}

/// The printed `sign_on redeem` command with its token replaced by one the parity issuer
/// signed just now for Ada.
pub fn fresh_sign_on(
    arena: std.mem.Allocator,
    printed: []const []const u8,
    now_ms: i64,
) ![]const []const u8 {
    std.debug.assert(printed.len > 1);
    std.debug.assert(now_ms > 0);

    const arguments = try arena.dupe([]const u8, printed);
    const token = try sign_on_token.sign(arena, issuer_seed, .{
        .aud = sign_on.Configure.example.audience,
        .sub = admin_email,
        .exp = now_ms + @divTrunc(sign_on_token.lifetime_ms, 2),
        .jti = "parity",
    });

    for (arguments[0 .. arguments.len - 1], 0..) |argument, index| {
        if (std.mem.eql(u8, argument, "--token")) {
            arguments[index + 1] = token;

            return arguments;
        }
    }

    return error.MissingToken;
}
