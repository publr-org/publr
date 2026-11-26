//! Adding, enabling, disabling and removing a plugin: what is checked before a module
//! is taken, what enabling grants, and what removing leaves. Versions are `versions.zig`.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");
const state = @import("state.zig");
const plugin_types = @import("../../sdk/plugin/types.zig");
const types = @import("../content_type.zig");
const versions = @import("versions.zig");
const depends_on = @import("../../sdk/plugin/depends_on.zig");
const contracts = @import("contracts.zig");
const grants = @import("grants.zig");
const auth_events = @import("../../sdk/auth_events.zig");
const error_events = @import("../../sdk/error_events.zig");
const stale = @import("../role/stale.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const sandboxed_plugin = model.sandboxed_plugin;
const statuses = @import("statuses.zig");
const groq = @import("../../lib/groq.zig");

pub fn sandboxed(ctx: *Ctx) Error!*const sdk.sandboxed_plugins.SandboxedPlugins {
    std.debug.assert(ctx.now_ms >= 0);

    return ctx.sandboxed_plugins orelse error.Unavailable;
}

/// A module whose manifest passed the checks.
pub const Checked = struct {
    staged: sdk.sandboxed_plugins.Staged,
    manifest: sandboxed_plugin.Manifest,
};

/// Reads and checks a module and its manifest: an upload by its name, or (`anywhere`, the
/// local operator) any path.
pub fn stage(ctx: *Ctx, file: []const u8, anywhere: bool) Error!Checked {
    std.debug.assert(ctx.now_ms >= 0);

    if (file.len == 0 or file.len > 4096) {
        return error.Invalid;
    }

    const staged = try (try sandboxed(ctx)).stage(ctx.arena, file, anywhere);

    if (staged.refused.len > 0) {
        return ctx.fail(.{
            .name = "ModuleDoesNotLoad",
            .status = 422,
            .message = try std.fmt.allocPrint(
                ctx.arena,
                "The module does not load: {s}. Build it again for this Publr.",
                .{staged.refused},
            ),
        });
    }

    const manifest = try state.parse_manifest(ctx.arena, staged.manifest);

    try check(ctx, &manifest);
    try @import("fit.zig").check(ctx, &manifest);
    try check_source(ctx, staged.source);

    return .{
        .staged = staged,
        .manifest = manifest,
    };
}

/// The install gate: the plugin checks `plugin build` runs, over the source the module
/// carries; an error refuses the module, naming each check that failed, a warning never
/// does. A module without its source is refused: there is nothing to check.
fn check_source(ctx: *Ctx, source: []const u8) Error!void {
    std.debug.assert(ctx.now_ms >= 0);

    const doc_reader = @import("../../sdk/plugin/doc_reader.zig");
    const Carried = struct {
        path: []const u8,
        text: []const u8,
    };

    if (source.len == 0) {
        return ctx.fail(.{
            .name = "SourceMissing",
            .status = 422,
            .message = "the module carries no source to check: build it with " ++
                "`publr plugin build`",
        });
    }

    // Read and checked apart from the request's arena: a large plugin's source (orders')
    // parsed outgrows it. Only the refusal's words are kept, in the arena.
    var reading_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer reading_state.deinit();

    const reading = reading_state.allocator();
    const carried = std.json.parseFromSliceLeaky([]const Carried, reading, source, .{
        .allocate = .alloc_always,
    }) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.Invalid;
    };

    if (carried.len > doc_reader.files_max) {
        return error.Invalid;
    }

    const files = try reading.alloc(doc_reader.File, carried.len);

    for (carried, files) |one, *file| {
        if (one.path.len == 0 or !doc_reader.read_file(one.path)) {
            return error.Invalid;
        }

        file.* = .{
            .path = one.path,
            .text = try reading.dupeSentinel(u8, one.text, 0),
        };
    }

    const read = doc_reader.source_of(reading, files) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.Invalid;
    };

    if (!doc_reader.failing(read.problems)) {
        return;
    }

    var message: std.ArrayList(u8) = .empty;

    try message.appendSlice(ctx.arena, "the plugin checks failed:");

    for (read.problems) |placed| {
        if (!placed.problem.warning) {
            try message.print(ctx.arena, " {s}:{d}: {s};", .{
                placed.path,
                placed.problem.line,
                placed.problem.message,
            });
        }
    }

    return ctx.fail(.{
        .name = "ChecksFailed",
        .status = 422,
        .message = message.items[0 .. message.items.len - 1],
    });
}

/// What a manifest must hold to be installed at all, whatever an administrator grants;
/// refused with what is wrong, for the administrator adding it.
fn check(ctx: *Ctx, manifest: *const sandboxed_plugin.Manifest) Error!void {
    std.debug.assert(sandboxed_plugin.format_known(manifest));

    const name = manifest.name;

    if (!sandboxed_plugin.valid_name(name)) {
        return refuse_manifest(ctx, name, "its name is not a plugin's name: a-z, 0-9 and _");
    }

    if (manifest.version.len == 0 or manifest.version.len > sandboxed_plugin.version_len_max) {
        return refuse_manifest(ctx, name, "its version is empty or too long");
    }

    if (taken(name)) {
        return refuse_manifest(ctx, name, "its name is taken by Publr or a built-in plugin");
    }

    for (manifest.operations) |operation| {
        if (operation.name.len > sdk.operation.name_len_max or
            std.mem.indexOfScalar(u8, operation.name, '.') == null or
            !sdk.plugin_access.own(name, operation.name))
        {
            return refuse_manifest(ctx, name, try std.fmt.allocPrint(
                ctx.arena,
                "its operation {s} is not named `{s}.<verb>`",
                .{ operation.name, name },
            ));
        }
    }

    const problems = [_]?[]const u8{
        model.internal_record.problem(manifest.internal_records),
        sandboxed_plugin.statuses_problem(name, manifest.statuses),
        model.user_type.problem(manifest.user_types),
        grants.problem(manifest),
    };

    for (problems) |found| {
        if (found) |problem| {
            return refuse_manifest(ctx, name, problem);
        }
    }

    if (before_unrefusable(manifest)) {
        return refuse_manifest(ctx, name, "it hooks `before` an event that cannot be " ++
            "refused, or `before`/`after` one heard only with `on`");
    }

    for (manifest.permissions) |ask| {
        const target = model.permission.called_operation(ask.key) orelse continue;

        if (!depended_on(manifest, target)) {
            return refuse_manifest(ctx, name, try std.fmt.allocPrint(
                ctx.arena,
                "it asks to call {s} without naming its plugin in `depends_on` or " ++
                    "`compatible_with`",
                .{target},
            ));
        }
    }

    try queries_read(ctx, name, manifest.queries);
}

/// The module is refused, `why` in plain words.
fn refuse_manifest(ctx: *Ctx, name: []const u8, why: []const u8) Error {
    std.debug.assert(why.len > 0);
    std.debug.assert(name.len <= 4096);

    const shown = if (name.len > 0 and name.len <= sandboxed_plugin.name_len_max) name else "it";

    return ctx.fail(.{
        .name = "PluginRefused",
        .status = 422,
        .message = std.fmt.allocPrint(ctx.arena, "{s} can't be added: {s}", .{
            shown,
            why,
        }) catch return error.OutOfMemory,
    });
}

/// Each GROQ text a plugin prepares parses: one that does not refuses the plugin, named
/// with the query and the problem. Compiled-in plugins' are read the same way at boot.
pub fn queries_read(
    ctx: *Ctx,
    plugin_name: []const u8,
    queries: []const sandboxed_plugin.Query,
) Error!void {
    std.debug.assert(plugin_name.len > 0);

    for (queries) |query| {
        if (query.text.len == 0) {
            continue;
        }

        const problem = try groq.problem_of(ctx.arena, query.text) orelse continue;

        return ctx.fail(.{
            .name = "InvalidQuery",
            .status = 422,
            .message = std.fmt.allocPrint(ctx.arena, "plugin {s}: the query at {s}:{d} " ++
                "does not read: {s}", .{
                plugin_name,
                query.path,
                query.line,
                problem,
            }) catch return error.OutOfMemory,
        });
    }
}

/// Whether the manifest asks for a `before` hook on an event that already happened when it
/// is emitted (`auth.signed_out`), or a `before` or `after` hook on one kept outside the
/// write (`errors.failed`): a compiled-in plugin's build stops on it.
pub fn before_unrefusable(manifest: *const sandboxed_plugin.Manifest) bool {
    std.debug.assert(manifest.name.len > 0);
    std.debug.assert(manifest.hooks.len <= sandboxed_plugin.requests_max);

    for (manifest.hooks) |hook| {
        if (hook_refused(hook.stage, hook.target)) {
            return true;
        }
    }

    return false;
}

/// The operations that take or answer a credential: a password, a token, a secret's value,
/// a device's or a tool's access. A hook is handed an operation's whole input and answer,
/// so an installed plugin's hook is never on one, at any stage. People signing in are heard
/// through the `auth.*` events, which carry no credential.
const credential_namespaces = [_][]const u8{ "secret.", "device.", "sign_on.", "oauth." };
const credential_operations = [_][]const u8{
    "user.sign_in",
    "user.sign_out",
    "user.create",
    "user.set_password",
    "user.password_link",
    "project.init",
    "mail.send",
    "link.verify",
};

pub fn keeps_credentials(target: []const u8) bool {
    std.debug.assert(target.len > 0);
    std.debug.assert(credential_operations.len > 0);

    for (credential_namespaces) |prefix| {
        if (std.mem.startsWith(u8, target, prefix)) {
            return true;
        }
    }

    for (credential_operations) |name| {
        if (std.mem.eql(u8, target, name)) {
            return true;
        }
    }

    return false;
}

/// Whether a hook of `stage` may never be on `target`.
pub fn hook_refused(hook_stage: sandboxed_plugin.Hook.Stage, target: []const u8) bool {
    std.debug.assert(target.len > 0);
    std.debug.assert(auth_events.unrefusable.len > 0);

    if (keeps_credentials(target)) {
        return true;
    }

    if (hook_stage == .before and auth_events.before_refused(target)) {
        return true;
    }

    return (hook_stage == .before or hook_stage == .after) and error_events.on_only(target);
}

/// Whether an operation belongs to a plugin the manifest depends on: the only kind a `call:`
/// permission may name.
fn depended_on(manifest: *const sandboxed_plugin.Manifest, operation_name: []const u8) bool {
    std.debug.assert(operation_name.len > 0);
    std.debug.assert(manifest.name.len > 0);

    if (manifest.depends_on.len > depends_on.depends_on_max) {
        return false;
    }

    if (manifest.compatible_with.len > depends_on.depends_on_max) {
        return false;
    }

    for ([_][]const []const u8{ manifest.depends_on, manifest.compatible_with }) |list| {
        if (depends_on.names_owner(list, operation_name)) {
            return true;
        }
    }

    return false;
}

/// Whether a name is reserved by core or taken by a native plugin: a plugin cannot take it.
fn taken(name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (registry.reserved_names) |reserved| {
        if (std.mem.eql(u8, reserved, name)) {
            return true;
        }
    }

    inline for (registry.native_plugins.all) |Plugin| {
        if (std.mem.eql(u8, Plugin.manifest.name, name)) {
            return true;
        }
    }

    return false;
}

/// Whether a plugin or a native plugin called `name` is there.
fn provided(ctx: *Ctx, text: []const u8) bool {
    std.debug.assert(text.len > 0);

    const wanted = depends_on.parse(text);
    const name = wanted.name;

    inline for (registry.native_plugins.all) |Plugin| {
        if (std.mem.eql(u8, Plugin.manifest.name, name)) {
            return depends_on.satisfies(Plugin.manifest.version, wanted.range);
        }
    }

    if (!sandboxed_plugin.valid_name(name)) {
        return false;
    }

    const found = store.sandboxed_plugins.get(ctx.db, ctx.arena, name) catch return false;
    const row = found orelse return false;

    return depends_on.satisfies(row.version, wanted.range);
}

/// Creates or brings up to date the taxonomies, content types, custom fields and roles the
/// plugin declares, as the system: owned by the plugin, their declared fields locked.
pub fn apply_types(ctx: *Ctx, manifest: *const sandboxed_plugin.Manifest) Error!void {
    std.debug.assert(manifest.name.len > 0);
    std.debug.assert(manifest.content_types.len <= 64);

    for (manifest.content_types) |def| {
        if (try types.find_raw(ctx, def.handle)) |existing| {
            if (!std.mem.eql(u8, existing.def.owner, manifest.name)) {
                return error.Conflict;
            }
        }
    }

    const saved = ctx.caller;

    ctx.caller = .system;
    defer ctx.caller = saved;

    // Its own kinds are known while its types are made; they load with it once it commits.
    const kept = ctx.kinds;

    ctx.kinds = try registry.with_kinds(ctx.arena, registry.kinds(ctx), &.{manifest.*});
    defer ctx.kinds = kept;

    // Its taxonomies first, each under its name: the types filed under them name them.
    for (manifest.taxonomies) |def| {
        const own = std.mem.startsWith(u8, def.handle, manifest.name) and
            def.handle.len > manifest.name.len + 1 and def.handle[manifest.name.len] == '.';

        if (!own) {
            return error.Invalid;
        }

        try plugin_types.apply_taxonomy(ctx, .{
            .owner = manifest.name,
            .def = def,
            .dimensions = manifest.dimensions,
        });
    }

    for (manifest.content_types) |def| {
        try plugin_types.apply_one(ctx, .{
            .owner = manifest.name,
            .def = def,
            .dimensions = manifest.dimensions,
        });
    }

    for (manifest.custom_fields) |def| {
        try plugin_types.apply_group(ctx, .{
            .owner = manifest.name,
            .def = def,
            .dimensions = manifest.dimensions,
        });
    }

    try sdk.stored_roles.declare(ctx, manifest.name, manifest.roles);
    _ = try stale.drop_installed(ctx, manifest);
    try refuse_staff_types(ctx, manifest);
}

/// The types of the enabled installed plugins whose fields name an option of `owner`'s
/// dimensions, applied again with them: an owner installed after a plugin naming its
/// option reaches that plugin's fields.
pub fn reapply_naming(ctx: *Ctx, owner: *const sandboxed_plugin.Manifest) Error!void {
    std.debug.assert(owner.name.len > 0);
    std.debug.assert(owner.dimensions.len <= 64);

    if (owner.dimensions.len == 0) {
        return;
    }

    const scratch = try ctx.scratch();
    const in_scratch = scratch.holds(ctx.arena);

    // One manifest at a time, each given back before the next: nothing of them is kept.
    for (try store.sandboxed_plugins.needs(ctx.db, ctx.arena)) |plugin| {
        if (!plugin.enabled or std.mem.eql(u8, plugin.name, owner.name)) {
            continue;
        }

        const begun = scratch.mark();
        defer if (!in_scratch) scratch.rewind(begun);

        // Read and parsed where there is room, sized from its length: a large manifest (an
        // orders plugin's) outgrows the scratch.
        const len = try store.sandboxed_plugins.manifest_bytes(ctx.db, plugin.name);
        const room = scratch.fixed.buffer.len - scratch.fixed.end_index;
        const fits = !in_scratch and room >= state.parse_bytes(len);
        const working = if (fits) scratch.allocator() else ctx.arena;
        const row = try store.sandboxed_plugins.get(ctx.db, working, plugin.name) orelse {
            continue;
        };

        // Only a manifest whose text holds an option's name can name it: the rest are
        // never parsed, however large.
        if (!text_names_option(row.manifest, owner.dimensions)) {
            continue;
        }

        const manifest = try state.parse_manifest(working, row.manifest);

        if (!names_option(&manifest, owner.dimensions)) {
            continue;
        }

        var with_owner = manifest;

        with_owner.dimensions = try std.mem.concat(working, model.dimension.Declared, &.{
            manifest.dimensions,
            owner.dimensions,
        });
        try apply_types(ctx, &with_owner);
    }
}

/// Whether `text` holds any of `dimensions`' option names as a JSON string: true for every
/// manifest that names one, and for some that do not.
fn text_names_option(text: []const u8, dimensions: []const model.dimension.Declared) bool {
    std.debug.assert(dimensions.len <= 64);
    std.debug.assert(text.len > 0);

    for (dimensions) |dimension| {
        const option = dimension.field.name;
        var at: u64 = 0;

        while (std.mem.indexOfPos(u8, text, @intCast(at), option)) |found| {
            const before = found > 0 and text[found - 1] == '"';
            const end = found + option.len;
            const after = end < text.len and text[end] == '"';

            if (before and after) {
                return true;
            }

            at = end;
        }
    }

    return false;
}

fn names_option(
    manifest: *const sandboxed_plugin.Manifest,
    dimensions: []const model.dimension.Declared,
) bool {
    std.debug.assert(manifest.name.len > 0);
    std.debug.assert(dimensions.len <= 64);

    const types_named = [_][]const model.content_type.Def{
        manifest.content_types,
        manifest.taxonomies,
        manifest.custom_fields,
    };

    for (types_named) |defs| {
        for (defs) |def| {
            if (fields_name(def.fields, dimensions)) {
                return true;
            }
        }
    }

    return false;
}

fn fields_name(
    fields: []const model.field.Def,
    dimensions: []const model.dimension.Declared,
) bool {
    std.debug.assert(dimensions.len <= 64);

    for (fields) |field| {
        if (fields_name(field.fields, dimensions)) {
            return true;
        }

        for (field.wrapped) |wrapped| {
            for (dimensions) |dimension| {
                if (std.mem.eql(u8, dimension.field.name, wrapped.option)) {
                    return true;
                }
            }
        }
    }

    return false;
}

/// What adding a module did: a plugin new to the list, or a newer version of one there.
pub const Added = struct {
    name: []const u8,
    version: []const u8,
    update: bool,
};

/// Adds a checked module to the list: a new plugin, disabled; or, for a plugin there
/// already, its next version, waiting to be applied. Nothing runs yet.
pub fn add(ctx: *Ctx, checked: Checked) Error!Added {
    std.debug.assert(checked.staged.hash.len > 0);

    const manifest = checked.manifest;
    const added: Added = .{
        .name = manifest.name,
        .version = manifest.version,
        .update = false,
    };

    if (try store.sandboxed_plugins.get(ctx.db, ctx.arena, manifest.name)) |row| {
        var decoded = try state.decode(ctx.arena, row);

        if (std.mem.eql(u8, row.hash, checked.staged.hash)) {
            return error.Conflict;
        }

        decoded.row.next_version = manifest.version;
        decoded.row.next_hash = checked.staged.hash;
        decoded.row.next_manifest = checked.staged.manifest;
        try state.save(ctx, decoded);

        return .{
            .name = added.name,
            .version = added.version,
            .update = true,
        };
    }

    if (try store.sandboxed_plugins.count(ctx.db) >= sandboxed_plugin.sandboxed_plugins_max) {
        return error.Invalid;
    }

    try state.save(ctx, .{
        .row = .{
            .name = manifest.name,
            .version = manifest.version,
            .hash = checked.staged.hash,
            .manifest = checked.staged.manifest,
            .enabled = false,
            .granted = "[]",
            .denied = "[]",
            .grants = "[]",
            .next_version = null,
            .next_hash = null,
            .next_manifest = null,
            .previous_version = null,
            .previous_hash = null,
            .previous_manifest = null,
            .installed_at = ctx.now_ms,
            .updated_at = ctx.now_ms,
        },
        .manifest = manifest,
        .granted = &.{},
        .denied = &.{},
        .grants = &.{},
    });

    return added;
}

/// Starts it: the plugins it depends on must be there, its content types are created, and
/// it is granted what enabling grants (see `versions.carried`), then what a person chose on
/// its review (each key on or off, each flag). A plugin disabled before keeps what it held.
pub fn enable(ctx: *Ctx, name: []const u8, chosen: []const grants.Choice) Error!state.Decoded {
    std.debug.assert(name.len > 0);

    return enable_among(ctx, name, chosen, try contracts.providers(ctx, .{}));
}

/// `enable` against `there`, what provides contracts now: plugins enabled together read
/// it once and add each one they start, rather than every manifest again for each.
pub fn enable_among(
    ctx: *Ctx,
    name: []const u8,
    chosen: []const grants.Choice,
    there: []const contracts.Provider,
) Error!state.Decoded {
    std.debug.assert(name.len > 0);
    std.debug.assert(there.len <= 1 << 16);

    var decoded = try state.load(ctx, name);

    for (decoded.manifest.depends_on) |required| {
        if (!provided(ctx, required)) {
            return refuse_unprovided(ctx, name, required);
        }
    }

    try contracts.check_user(ctx, &decoded.manifest, there);
    try apply_types(ctx, &decoded.manifest);
    try reapply_naming(ctx, &decoded.manifest);

    const asked = try requests(ctx, &decoded.manifest);

    const held = decoded.granted;

    decoded.granted = try versions.carried(ctx.arena, asked, held, decoded.denied, false);

    if (chosen.len > grants.choices_max) {
        return error.Invalid;
    }

    for (chosen) |choice| {
        try grants.apply(ctx.arena, &decoded, choice);
    }

    decoded.row.enabled = true;
    try state.save(ctx, decoded);

    return decoded;
}

/// Refused when a type of user the plugin registers gives a role that is staff here: a type
/// gives visitor roles only (`model.user_type.problem` refuses core's by name at add).
fn refuse_staff_types(ctx: *Ctx, manifest: *const sandboxed_plugin.Manifest) Error!void {
    std.debug.assert(manifest.name.len > 0);
    std.debug.assert(manifest.user_types.len <= model.user_type.types_max);

    for (manifest.user_types) |declared| {
        const given = try stale.staff_given(ctx, manifest, declared) orelse continue;

        return ctx.fail(.{
            .name = "StaffRoleGiven",
            .status = 422,
            .message = try std.fmt.allocPrint(ctx.arena, "{s} can't be enabled: its type " ++
                "{s} gives the role {s}, which reaches the admin or what staff call; a type " ++
                "gives visitor roles only", .{ manifest.name, declared.label, given }),
        });
    }
}

/// Refused in words: `name` needs `required`, at a version that is not there.
fn refuse_unprovided(ctx: *Ctx, name: []const u8, required: []const u8) Error {
    std.debug.assert(name.len > 0);
    std.debug.assert(required.len > 0);

    const wanted = depends_on.parse(required);
    const there = installed_version(ctx, wanted.name);
    const message = if (there) |version|
        std.fmt.allocPrint(ctx.arena, "{s} needs {s}, and {s} {s} is installed: {s}", .{
            name,
            required,
            wanted.name,
            version,
            "update one of them so they fit",
        })
    else
        std.fmt.allocPrint(ctx.arena, "{s} needs {s}, which is not installed", .{
            name,
            required,
        });

    return ctx.fail(.{
        .name = "DependencyMissing",
        .status = 409,
        .message = message catch return error.OutOfMemory,
    });
}

/// The version of the plugin called `name` there now, compiled in or installed.
fn installed_version(ctx: *Ctx, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);

    inline for (registry.native_plugins.all) |Plugin| {
        if (std.mem.eql(u8, Plugin.manifest.name, name)) {
            return Plugin.manifest.version;
        }
    }

    if (!sandboxed_plugin.valid_name(name)) {
        return null;
    }

    const found = store.sandboxed_plugins.get(ctx.db, ctx.arena, name) catch return null;

    return if (found) |row| row.version else null;
}

/// Stops it: its operations and hooks unload; its grants, content types and records stay.
pub fn disable(ctx: *Ctx, name: []const u8) Error!state.Decoded {
    std.debug.assert(name.len > 0);

    var decoded = try state.load(ctx, name);

    try statuses.leave(ctx, name, null);
    decoded.row.enabled = false;
    try state.save(ctx, decoded);

    return decoded;
}

pub fn requests(
    ctx: *Ctx,
    manifest: *const sandboxed_plugin.Manifest,
) Error![]const sandboxed_plugin.Request {
    std.debug.assert(manifest.name.len > 0);

    return sandboxed_plugin.requests(manifest, ctx.arena) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Invalid => error.Invalid,
    };
}

/// Takes it off the list: unloaded, its grants and versions dropped; its content types and
/// records stay until an administrator deletes them. Its files go at the next reload.
pub fn remove(ctx: *Ctx, name: []const u8) Error!void {
    std.debug.assert(name.len > 0);

    if (!sandboxed_plugin.valid_name(name)) {
        return error.NotFound;
    }

    try statuses.leave(ctx, name, null);
    try store.sandboxed_plugins.delete(ctx.db, name);
}

pub const Change = enum { grant, revoke, deny };

/// Grants, revokes or denies one request, by its key.
pub fn decide(ctx: *Ctx, name: []const u8, key: []const u8, change: Change) Error!state.Decoded {
    std.debug.assert(name.len > 0);

    var decoded = try state.load(ctx, name);
    const shown = try state.requests_of(
        ctx.arena,
        &decoded.manifest,
        decoded.granted,
        decoded.denied,
        decoded.grants,
    );
    const request = for (shown) |candidate| {
        if (std.mem.eql(u8, candidate.key, key)) {
            break candidate;
        }
    } else {
        return error.NotFound;
    };

    switch (change) {
        .grant => {
            if (request.state == .unavailable) {
                return error.Invalid;
            }

            decoded.granted = try state.with(ctx.arena, decoded.granted, request.key);
            decoded.denied = try state.without(ctx.arena, decoded.denied, request.key);
        },
        .revoke => decoded.granted = try state.without(ctx.arena, decoded.granted, request.key),
        .deny => {
            decoded.granted = try state.without(ctx.arena, decoded.granted, request.key);
            decoded.denied = try state.with(ctx.arena, decoded.denied, request.key);
        },
    }

    try statuses.leave(ctx, name, &decoded);
    try state.save(ctx, decoded);

    return decoded;
}

test "a before hook on signing out is refused at install; on signing in it is taken" {
    const hooks_out = [_]sandboxed_plugin.Hook{.{
        .stage = .before,
        .target = "auth.signed_out",
        .reason = "Keeps people signed in",
    }};
    const hooks_in = [_]sandboxed_plugin.Hook{
        .{
            .stage = .before,
            .target = "auth.signed_in",
            .reason = "Keeps suspended accounts out",
        },
        .{
            .stage = .after,
            .target = "auth.signed_out",
            .reason = "Empties the bag",
        },
    };
    const refused: sandboxed_plugin.Manifest = .{
        .name = "keeper",
        .version = "0.1.0",
        .summary = "Keeps",
        .hooks = &hooks_out,
    };
    const taken_manifest: sandboxed_plugin.Manifest = .{
        .name = "keeper",
        .version = "0.1.0",
        .summary = "Keeps",
        .hooks = &hooks_in,
    };

    try std.testing.expect(before_unrefusable(&refused));
    try std.testing.expect(!before_unrefusable(&taken_manifest));
    // Kept outside the write: `on` only.
    try std.testing.expect(hook_refused(.after, "errors.failed"));
    try std.testing.expect(hook_refused(.before, "auth.sign_in_failed"));
    try std.testing.expect(!hook_refused(.event, "errors.failed"));
}

test "no installed hook is on an operation that takes or answers a credential" {
    try std.testing.expect(hook_refused(.after, "user.sign_in"));
    try std.testing.expect(hook_refused(.before, "secret.set"));
    try std.testing.expect(hook_refused(.event, "device.redeem"));
    try std.testing.expect(!hook_refused(.after, "record.create"));
    try std.testing.expect(!hook_refused(.event, "auth.signed_in"));

    // An operation that declares a secret field is one of them, whenever it is added.
    // Unrolled once over every operation: the budget grows with the list.
    @setEvalBranchQuota(1000 + registry.SDK.operations.len * 8);

    inline for (registry.SDK.operations) |Operation| {
        if (@hasDecl(Operation, "secret")) {
            try std.testing.expect(keeps_credentials(Operation.name));
        }
    }
}

test "a prepared query that does not read refuses its plugin, named with the query and why" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    const fine = [_]sandboxed_plugin.Query{.{
        .path = "operations/count.zig",
        .line = 3,
        .text = "count(*[_type == $type][$from...$to])",
    }};
    const broken = fine ++ [_]sandboxed_plugin.Query{.{
        .path = "queries/notes.zig",
        .line = 12,
        .text = "*[_type == \"note\"",
    }};

    try queries_read(&system, "shelf", &fine);
    try std.testing.expectError(error.Failed, queries_read(&system, "shelf", &broken));
    try std.testing.expect(std.mem.startsWith(
        u8,
        system.failure.?.message,
        "plugin shelf: the query at queries/notes.zig:12 does not read: ",
    ));
}

test "an owner of dimensions enables beside an enabled plugin whose manifest outgrows the scratch" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    const arena = system.arena;
    const scratch_bytes = @import("../../sdk/scratch.zig").bytes_default;
    const operations = try arena.alloc(sandboxed_plugin.Operation, 400);
    const nodes = try arena.alloc(model.contract.Node, 40);

    nodes[0] = .{
        .parent = -1,
        .kind = .object,
    };

    for (nodes[1..]) |*node| {
        node.* = .{
            .parent = 0,
            .name = "amount",
            .kind = .integer,
        };
    }

    for (operations, 0..) |*operation, index| {
        operation.* = .{
            .name = try std.fmt.allocPrint(arena, "shop.operation_{d}", .{index}),
            .kind = .write,
            .description = "Changes the order, as an orders plugin's many operations do",
            .output = nodes,
        };
    }

    // One never names the option; the other holds its name in its words only.
    const summaries = [_][]const u8{ "A shop", "A shop, not \"translatable\"" };
    const names = [_][]const u8{ "shop", "shop_words" };

    for (names, summaries) |plugin_name, summary| {
        const manifest: sandboxed_plugin.Manifest = .{
            .name = plugin_name,
            .version = "0.1.0",
            .summary = summary,
            .operations = operations,
        };
        const text = try std.json.Stringify.valueAlloc(arena, manifest, .{
            .emit_null_optional_fields = false,
        });

        // Parsed in the scratch, it would not fit.
        const scratch_buffer = try std.testing.allocator.alloc(u8, scratch_bytes);
        defer std.testing.allocator.free(scratch_buffer);

        var in_scratch: std.heap.FixedBufferAllocator = .init(scratch_buffer);

        try std.testing.expectError(
            error.OutOfMemory,
            state.parse_manifest(in_scratch.allocator(), text),
        );
        try store.sandboxed_plugins.put(system.db, .{
            .name = plugin_name,
            .version = "0.1.0",
            .hash = "0000000000000000000000000000000000000000000000000000000000000000",
            .manifest = text,
            .enabled = true,
            .granted = "[]",
            .denied = "[]",
            .grants = "[]",
            .next_version = null,
            .next_hash = null,
            .next_manifest = null,
            .previous_version = null,
            .previous_hash = null,
            .previous_manifest = null,
            .installed_at = 0,
            .updated_at = 0,
        });
    }

    const dimensions = [_]model.dimension.Declared{.{
        .name = "language",
        .list = "languages.list",
        .field = .{
            .name = "translatable",
            .label = "Translate",
            .choices = &.{},
        },
    }};
    const owner: sandboxed_plugin.Manifest = .{
        .name = "languages",
        .version = "0.1.0",
        .summary = "Languages",
        .dimensions = &dimensions,
    };

    try reapply_naming(&system, &owner);
}
