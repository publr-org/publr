const std = @import("std");
const builtin = @import("builtin");

pub const version = "0.4.0";

pub const lib = @import("lib.zig");
pub const db = lib.db;
pub const http = lib.http;
pub const report = lib.report;
pub const sdk = @import("sdk.zig");
pub const model = @import("model.zig");
pub const store = @import("store.zig");
pub const cli = @import("adapters/cli.zig");
pub const server = @import("server.zig");
pub const registry = @import("server/registry.zig");
pub const plugin = @import("sdk/plugin.zig");
/// What a plugin is called and which version it is: `publr.plugin.define(manifest, options)`.
pub const Manifest = @import("sdk/plugin/define.zig").Manifest;
/// What a plugin's code runs with, and how it fails.
pub const Ctx = plugin.PluginCtx;
pub const Error = sdk.Error;
/// What a built-in plugin's `.extend` registers through: `fn extend(host: *publr.Host)`.
pub const Host = @import("sdk/plugin/host.zig").Host;
/// SQL on a built-in plugin's own tables: `ctx.database()`.
pub const Database = @import("sdk/plugin/host.zig").Database;
/// `publr.operation.define(In, Out, .{ .name, .kind, .authorize, ... })`.
pub const operation = struct {
    pub const define = @import("sdk/plugin/operation_define.zig").define;
    pub const Kind = @import("sdk/plugin/operation_define.zig").Kind;
};
/// `publr.record.define(Document, .{ .name, .internal, ... })` and a reference to any record.
pub const record = struct {
    pub const define = @import("sdk/plugin/record_define.zig").define;
    pub const AnyRef = @import("sdk/plugin/record_define.zig").AnyRef;
    /// One transition of a record's flow: `[_]publr.record.Transition(Status){ ... }`.
    pub const Transition = @import("sdk/plugin/record_flow.zig").Transition;
    /// Every status but the transition's target and the trash: `.from = publr.record.any`.
    pub const any = @import("sdk/plugin/record_flow.zig").any;
    /// What a hook on `X.any_transition` hears: `.{ .record, .transition, .from, .to }`.
    pub const Transitioned = @import("model/flow.zig").Transitioned;
};
/// GROQ queries with `$names` bound from a struct: `publr.query.prepare(text, .{})`.
pub const query = struct {
    pub const prepare = @import("sdk/plugin/query_define.zig").prepare;
};
/// Changes or refuses an operation's input inside its write: `publr.before(Sign, refuse_links)`.
pub const before = @import("sdk/plugin/hook_define.zig").before;
/// Runs inside the write after an operation or an event; may refuse, rolling it back.
pub const after = @import("sdk/plugin/hook_define.zig").after;
/// Runs from the queue once the write committed, with the operation's answer or the event's
/// payload: `publr.on(Orders.place, send_confirmation)`.
pub const on = @import("sdk/plugin/hook_define.zig").on;
/// A menu item in the admin: `.{ .name, .label = publr.t("Orders"), .icon, .record, .parent }`.
pub const MenuItem = @import("sdk/plugin/menu_define.zig").MenuItem;
/// An icon of a plugin's own: `.{ .name = "bag", .svg = @embedFile("icons/bag.svg") }`.
pub const Icon = @import("sdk/plugin/menu_define.zig").Icon;
/// JS's `String` for plugins: `publr.text.starts_with(name, "admin")`,
/// `publr.text.upper(ctx, name)`. See `sdk/plugin/text.zig`.
pub const text = @import("sdk/plugin/text.zig");
/// Text a person reads, written where it is declared and translated where it is shown.
pub const t = @import("sdk/plugin/menu_define.zig").t;
/// Changes the value applied under a name, wherever its owner applies it (`ctx.mod`):
/// `publr.modify("variant.title", title)`, `*` for one part (`*.title`).
pub const modify = @import("sdk/plugin/hook_define.zig").modify;
/// A record's title as core applies it, `<type>.title`: `.id`, the record's fields typed
/// (`.record`), and the `.title` to change.
pub const Title = @import("sdk/plugin/modify_define.zig").Title;
/// People signing in, up and out, hooked by type: `publr.after(publr.auth.SignedIn, run)`;
/// sign-ins refused (`SignInFailed`, `SignOnFailed` …), heard with `publr.on` only.
pub const auth = @import("sdk/auth_events.zig");
/// Everything that lands in the Error log as an error: `publr.on(publr.errors.Failed, run)`.
pub const errors = struct {
    pub const Failed = @import("sdk/error_events.zig").Failed;
};
/// Something that happens that is not a call: `publr.event.define(.{ .name, .payload })`,
/// emitted with `ctx.emit(Event, payload)`.
pub const event = struct {
    pub const define = @import("sdk/plugin/hook_define.zig").event;
};
/// Another plugin's operations, records and events, with only what this plugin uses.
pub const remote = @import("sdk/plugin/hook_define.zig").remote;
/// A secret a plugin declares in its `.secrets` struct: it never holds the value.
pub const Secret = struct {};
/// A field kind a plugin brings: `publr.field.kind(Value, .{ .name, .validate })`.
/// A plugin's own `.register_fields` group on an account, as its struct:
/// `publr.fields.get(ctx, Profile.Fields, user)`, `publr.fields.save(ctx, Profile.Fields,
/// user, values)`. Compiled-in plugins only, for now.
pub const fields = @import("sdk/plugin/fields_api.zig");
/// What a `.register_location_rules` entry's `matches` is given: the account or file being
/// edited, and the rule, compared with `rule.compare(value)`.
pub const location = struct {
    pub const Target = @import("sdk/plugin/location_rule_define.zig").Target;
    pub const Rule = @import("sdk/plugin/location_rule_define.zig").Rule;
};
pub const field = struct {
    pub const kind = @import("sdk/plugin/field_kind_define.zig").kind;
};
/// Queued work: `publr.job.define(In, .{ .name, .run })` for `ctx.enqueue`,
/// `publr.job.define_recurring(.{ .name, .run, .every, .at })` for what repeats.
pub const job = struct {
    pub const define = @import("sdk/plugin/job_define.zig").define;
    pub const define_recurring = @import("sdk/plugin/job_define.zig").define_recurring;
};
/// What another server sends: `publr.webhook.define(Event, .{ .name, .secret, .signature,
/// .run })` at `/_webhooks/<plugin>.<name>`, listed in `.webhooks`.
pub const webhook = struct {
    pub const define = @import("sdk/plugin/webhook_define.zig").define;
    pub const Signature = @import("sdk/plugin/webhook_define.zig").Signature;
    pub const DeliveryId = @import("sdk/plugin/webhook_define.zig").DeliveryId;
    pub const Delivery = @import("sdk/plugin/webhook_define.zig").Delivery;
};
/// What queued work (a job) runs with: every call `Ctx` has, and `fetch`, queued work's
/// alone. Record handles and queries take either.
pub const QueueCtx = @import("sdk/plugin/queue.zig").Queue(Ctx);
/// What a sign-in provider's `exchange` runs with: `fetch` to its own domains, within a
/// short time, and `log`; nothing else.
pub const ExchangeCtx = @import("sdk/provider.zig").ExchangeCtx;
/// A moment, as a `datetime` field holds it.
pub const Time = @import("sdk/plugin/words.zig").Time;
/// An operation on its way out: `.deprecated = .{ .since = "0.4.0", .instead = "x.y" }`.
pub const Deprecated = @import("sdk/operation.zig").Deprecated;
/// What `.validate` fills: `problems.add(.page, "Must start with /")`.
pub const Problems = @import("sdk/plugin/operation_define.zig").Problems;
/// Ready answers to who may call an operation.
pub const authorize = struct {
    const Answer = @import("sdk/plugin/operation_define.zig").Answer;

    pub const user_is_signed_in: Answer = .signed_in;
    pub const plugin_calls: Answer = .plugin_calls;

    pub fn user_has_role(comptime roles: []const []const u8) Answer {
        comptime std.debug.assert(roles.len > 0);

        return .{
            .roles = roles,
        };
    }
};
/// A plugin's page from its own PTSX view, the same HTML either way it runs:
/// `publr.views.render(ctx, in.base, publr.views.all.SamplerLog, props)`.
pub const views = @import("sdk/plugin/views.zig");
/// A named set of operations providers implement: `publr.contract.define(.{ .name,
/// .operations, .optional, .component })`.
pub const contract = struct {
    pub const define = @import("sdk/contract.zig").define;
};
/// The enabled providers of a contract, in the administrator's order:
/// `publr.providers(ctx, Contract, .{ .can = &.{.refund} })`.
pub const providers = @import("sdk/contract.zig").providers;
/// Messages Publr hands to providers: `ctx.emit(publr.messaging.Email, .{ .to, .subject,
/// .text })`, and the `messaging` contract providers register into.
pub const messaging = @import("sdk/messaging.zig");
/// Model providers: the contract, and the two operations a provider plugin registers with.
pub const ai = @import("sdk/ai.zig");
pub const routes = @import("server/routes.zig");
pub const plugin_routes = @import("server/plugin_routes.zig");
pub const plugin_states = @import("server/plugin_states.zig");
pub const plugin_hooks = @import("server/plugin_hooks.zig");
pub const rest = @import("adapters/rest.zig");
pub const admin = @import("adapters/admin.zig");
pub const project = @import("server/project.zig");
pub const split = @import("server/split.zig");
pub const apps = @import("adapters/apps.zig");
/// What an app's `middleware.zig` is given, and what it answers with.
pub const Request = apps.middleware.Request;
pub const Response = apps.middleware.Response;
pub const template = @import("template.zig");
pub const operations = struct {
    pub const device = @import("operations/device.zig");
    pub const apps = @import("operations/apps.zig");
    pub const heartbeat = @import("operations/heartbeat.zig");
    pub const project = @import("operations/project.zig");
    pub const custom_fields = @import("operations/custom_fields.zig");
    pub const user = @import("operations/user.zig");
    pub const sign_in = @import("operations/sign_in.zig");
    pub const sign_on = @import("operations/sign_on.zig");
    pub const identity = @import("operations/identity.zig");
    pub const status = @import("operations/status.zig");
    pub const role = @import("operations/role.zig");
    pub const operation = @import("operations/operation.zig");
    pub const content_type = @import("operations/content_type.zig");
    pub const record = @import("operations/record.zig");
    pub const taxonomy = @import("operations/taxonomy.zig");
    pub const term = @import("operations/term.zig");
    pub const media = @import("operations/media.zig");
    pub const design = @import("operations/design.zig");
    pub const snapshot = @import("operations/snapshot.zig");
    pub const view = @import("operations/view.zig");
    pub const rail = @import("operations/rail.zig");
    pub const ai = @import("operations/ai.zig");
    pub const secret = @import("operations/secret.zig");
    pub const http = @import("operations/http.zig");
    pub const internal = @import("operations/internal.zig");
    pub const plugin = @import("operations/plugin.zig");
    pub const variants = @import("operations/variants.zig");
};
pub const serve = if (builtin.os.tag == .wasi) void else @import("server/serve.zig");
pub const build = if (builtin.os.tag == .wasi) void else @import("server/build.zig");
pub const toolchain = if (builtin.os.tag == .wasi) void else @import("server/toolchain.zig");
pub const plugin_build = if (builtin.os.tag == .wasi) void else @import("server/plugin_build.zig");
pub const plugin_check = if (builtin.os.tag == .wasi)
    void
else
    @import("server/plugin_build/check.zig");
pub const operator = if (builtin.os.tag == .wasi) void else @import("server/operator.zig");
pub const database = if (builtin.os.tag == .wasi) void else @import("server/database.zig");
pub const bundle = if (builtin.os.tag == .wasi) void else @import("server/bundle.zig");
pub const cloud_deploy = if (builtin.os.tag == .wasi) void else @import("server/cloud_deploy.zig");
pub const update = if (builtin.os.tag == .wasi) void else @import("server/update.zig");
pub const agents = if (builtin.os.tag == .wasi) void else @import("server/agents.zig");
pub const apps_load = if (builtin.os.tag == .wasi) void else @import("server/apps_load.zig");
pub const login = if (builtin.os.tag == .wasi) void else @import("server/login.zig");
pub const skill = if (builtin.os.tag == .wasi) void else @import("server/skill.zig");
pub const new_site = if (builtin.os.tag == .wasi) void else @import("server/new_site.zig");
pub const forwarding = if (builtin.os.tag == .wasi) void else @import("server/remote.zig");
pub const work = if (builtin.os.tag == .wasi) void else @import("server/work.zig");
pub const queue_worker = if (builtin.os.tag == .wasi) void else @import("server/queue_worker.zig");
/// Queued work's passes: the worker's on a server, after each answer in the browser.
pub const queued_jobs = @import("server/queued_jobs.zig");
pub const agent_script = if (builtin.os.tag == .wasi) void else @import("server/agent_script.zig");
pub const agent = if (builtin.os.tag == .wasi) void else @import("server/agent.zig");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(operations);
    std.testing.refAllDecls(http);
}

test "version is a semantic version with three components" {
    var parts: u32 = 0;
    var iterator = std.mem.splitScalar(u8, version, '.');

    while (iterator.next()) |part| : (parts += 1) {
        try std.testing.expect(part.len > 0);
        _ = try std.fmt.parseInt(u32, part, 10);
    }

    try std.testing.expectEqual(@as(u32, 3), parts);
}
