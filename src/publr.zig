const std = @import("std");
const builtin = @import("builtin");

pub const version = "0.8.4";

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
pub const Manifest = @import("publr/plugin/define.zig").Manifest;
/// What a plugin's code runs with, and how it fails.
pub const Ctx = @import("publr/ctx.zig").Ctx;
pub const Error = sdk.Error;
/// What a built-in plugin's `.extend` registers through: `fn extend(host: *publr.Host)`.
pub const Host = @import("publr/extend/host.zig").Host;
/// SQL on a built-in plugin's own tables: `ctx.database()`.
pub const Database = @import("publr/extend/database.zig").Database;
/// `publr.operation.define(In, Out, .{ .name, .kind, .authorize, ... })`.
pub const operation = struct {
    pub const define = @import("publr/plugin/operation_define.zig").define;
    pub const Kind = @import("publr/operation.zig").Kind;
    /// A way an operation fails beyond core's errors, listed in its `failures`.
    pub const Failure = @import("publr/operation.zig").Failure;
    /// One thing wrong with a call's input, as `ctx.refuse` and `Problems` hold it.
    pub const Problem = @import("publr/operation.zig").Problem;
    /// A text for each field of a shape: `field_docs: publr.operation.Docs(In)`.
    pub const Docs = @import("publr/operation.zig").Docs;
    /// A value whose shape comes with the data: `try publr.operation.Json.of(arena, value)`.
    pub const Json = @import("publr/operation.zig").Json;
    /// A group of operations as REST, the CLI and MCP show it: each `publr.operations.*` file's
    /// `namespace`.
    pub const Namespace = @import("publr/operation.zig").Namespace;
    /// `record` of `record.create`, and `create`.
    pub const namespace = @import("publr/operation.zig").namespace;
    pub const verb = @import("publr/operation.zig").verb;
    pub const name_len_max = @import("publr/operation.zig").name_len_max;
    pub const fields_max = @import("publr/operation.zig").fields_max;
    pub const operations_max = @import("publr/operation.zig").operations_max;
    /// The largest page a list answers at once.
    pub const page_limit_max = @import("publr/operation.zig").page_limit_max;
};
/// `publr.record.define(Document, .{ .name, .internal, ... })` and a reference to any record.
pub const record = struct {
    pub const define = @import("publr/plugin/record_define.zig").define;
    pub const AnyRef = @import("publr/plugin/record_define.zig").AnyRef;
    /// A collection's reads by its stored name, for code that names it rather than its handle:
    /// `publr.record.Store(Line, "line", true).find(ctx, "order", id, 200, 0)`.
    pub const Store = @import("publr/plugin/record_define.zig").Store;
    /// One transition of a record's flow: `[_]publr.record.Transition(Status){ ... }`.
    pub const Transition = @import("publr/plugin/record_flow.zig").Transition;
    /// Every status but the transition's target and the trash: `.from = publr.record.any`.
    pub const any = @import("publr/plugin/record_flow.zig").any;
    /// What a hook on `X.any_transition` hears: `.{ .record, .transition, .from, .to }`.
    pub const Transitioned = @import("publr/model/flow.zig").Transitioned;
};
/// `publr.taxonomy.define(Term, .{ .name, .public, .hierarchical, .single, .internal, .fields })`,
/// and what `.register_taxonomies` takes: `.{ .taxonomy, .to }`.
/// `publr.dimension.define(.{ .name, .api, .list, .priority, .addresses, ... })`, listed in
/// `.dimensions`; its `.api` the owner's wrapper, a `field_option` and a `read_option`;
/// `publr.dimension.Value` is one value its list answers; a family's list answers `Member`s,
/// its `.shown` `Shown`s.
pub const dimension = struct {
    pub const define = @import("publr/plugin/dimensions.zig").define;
    pub const field_option = @import("publr/plugin/dimensions.zig").field_option;
    pub const read_option = @import("publr/plugin/dimensions.zig").read_option;
    pub const Holds = @import("publr/model/dimension.zig").Holds;
    /// One dimension at one code, `language` at `pl`, and a value's key read:
    /// `publr.dimension.split("title@language=pl")`, `publr.dimension.parse(key.combination)`.
    pub const Pair = @import("publr/model/dimension.zig").Pair;
    pub const Combination = @import("publr/model/dimension.zig").Combination;
    pub const Key = @import("publr/model/dimension.zig").Key;
    pub const split = @import("publr/model/dimension.zig").split;
    pub const parse = @import("publr/model/dimension.zig").parse;
    pub const varies_by = @import("publr/model/dimension.zig").varies_by;
    pub const valid_code = @import("publr/model/dimension.zig").valid_code;
    pub const family_of = @import("publr/model/dimension.zig").family_of;
    pub const Dimension = @import("publr/plugin/dimensions.zig").Dimension;
    pub const Value = @import("publr/plugin/dimensions.zig").Value;
    pub const Member = @import("publr/plugin/dimensions.zig").Member;
    pub const Shown = @import("publr/plugin/dimensions.zig").Shown;
    pub const values_max = @import("publr/plugin/dimensions.zig").values_max;
};

/// `publr.hook.request(run)` in `.hooks`: a page request before it is drawn.
pub const hook = struct {
    pub const request = @import("publr/plugin/hook_define.zig").request;
    /// `publr.hook.about("shop.product", publr.after(publr.operations.record.List, run))`:
    /// the hook hears only calls that name that content type.
    pub const about = @import("publr/plugin/hook_define.zig").about;
};
pub const PageRequest = @import("publr/page_request.zig").PageRequest;
pub const Answered = @import("publr/page_request.zig").Answered;

pub const taxonomy = struct {
    pub const define = @import("publr/plugin/taxonomy_define.zig").define;
    pub const Registration = @import("publr/model/taxonomy.zig").Registration;
};
/// GROQ queries with `$names` bound from a struct: `publr.query.prepare(text, .{})`.
pub const query = struct {
    pub const prepare = @import("publr/plugin/query_define.zig").prepare;
};
/// Changes or refuses an operation's input inside its write: `publr.before(Sign, refuse_links)`.
pub const before = @import("publr/plugin/hook_define.zig").before;
/// Runs inside the write after an operation or an event; may refuse, rolling it back.
pub const after = @import("publr/plugin/hook_define.zig").after;
/// Runs from the queue once the write committed, with the operation's answer or the event's
/// payload: `publr.on(Orders.place, send_confirmation)`.
pub const on = @import("publr/plugin/hook_define.zig").on;
/// A menu item in the admin: `.{ .name, .label = publr.t("Orders"), .icon, .record, .parent }`.
pub const MenuItem = @import("publr/plugin/menu_define.zig").MenuItem;
/// An icon of a plugin's own: `.{ .name = "bag", .svg = @embedFile("icons/bag.svg") }`.
pub const Icon = @import("publr/plugin/menu_define.zig").Icon;
/// JS's `String` for plugins: `publr.text.starts_with(name, "admin")`,
/// `publr.text.upper(ctx, name)`. See `publr/plugin/text.zig`.
pub const text = @import("publr/plugin/text.zig");
/// Text a person reads, written where it is declared and translated where it is shown.
pub const t = @import("publr/plugin/menu_define.zig").t;
/// Changes the value applied under a name, wherever its owner applies it (`ctx.mod`):
/// `publr.modify("variant.title", title)`, `*` for one part (`*.title`).
pub const modify = @import("publr/plugin/hook_define.zig").modify;
/// A batch modifier: `publr.modify_all("orders.charge", price_all)`, `fn (ctx: *publr.Ctx,
/// charges: []Charge) publr.Error!void`, called once with every value applied.
pub const modify_all = @import("publr/plugin/hook_define.zig").modify_all;
/// A record's title as core applies it, `<type>.title`: `.id`, the record's fields typed
/// (`.record`), and the `.title` to change.
pub const Title = @import("publr/plugin/modify_define.zig").Title;
/// A computed field as its modifiers take it: `publr.modify("<record>.<field>", run)` with
/// `fn (ctx: *publr.Ctx, value: *publr.Computed(Doc, Field)) publr.Error!void`.
pub const Computed = @import("publr/plugin/record_computed.zig").Computed;
/// What a `<type>.<field>.help` modifier takes: the help under one field of a record in the
/// editor, asked again as its values change; change `help`.
pub const FieldHelp = @import("publr/plugin/modify_define.zig").FieldHelp;
/// What a `<type>.markers` modifier takes: one field of a record in the editor, with the
/// markers beside its label so far; add yours to `markers`.
pub const FieldMarkers = struct {
    field: []const u8,
    /// The record's type, and its id once saved (empty before).
    type: []const u8 = "",
    id: []const u8 = "",
    /// The dimensions the field varies by (`language`, a test's).
    varies_by: []const []const u8 = &.{},
    /// Each value it must hold before its record goes live: `language` at `pl`.
    required: []const @import("publr/model/dimension.zig").Pair = &.{},
    /// The whole record as the editor holds it, every value beside its field.
    record: @import("publr/operation.zig").Json = .object,
    markers: []const Marker = &.{},
};
/// A marker beside a field's label: `PL`, `Variant B`. Markers of one `dimension` are drawn
/// together as one pill, `group` first when given (`Hero test`); one naming a `dimension` is
/// a link: clicking it shows the field at `code` there (empty: its main).
pub const Marker = struct {
    label: []const u8,
    /// What its dimension's markers are of, drawn once before them: `Hero test`.
    group: []const u8 = "",
    /// `outline` (the default), `neutral`, `success`, or `danger` for a value that must be
    /// filled before going live and is not.
    tone: []const u8 = "outline",
    dimension: []const u8 = "",
    code: []const u8 = "",
    /// `show` (the default) or `hide` while the field is shown at this very code: a marker
    /// for going elsewhere is not needed where you are.
    current: []const u8 = "show",
    /// A page of the admin it opens instead (`/admin/plugin/ab_test/attach?…`): an action
    /// on the field. Empty: none.
    href: []const u8 = "",
};
/// What a plugin calls when the data its modifier of a name answers from changed:
/// `ctx.call(publr.mod_changed, .{ .name = "money.currencies" })` builds again the pages
/// made with those values.
pub const mod_changed = @import("publr/mods.zig").Changed;
/// People signing in, up and out, hooked by type: `publr.after(publr.auth.SignedIn, run)`;
/// sign-ins refused (`SignInFailed`, `SignOnFailed` …), heard with `publr.on` only.
pub const auth = @import("publr/auth_events.zig");
/// Everything that lands in the Error log as an error: `publr.on(publr.errors.Failed, run)`.
pub const errors = struct {
    pub const Failed = @import("publr/error_events.zig").Failed;
};
/// Something that happens that is not a call: `publr.event.define(.{ .name, .payload })`,
/// emitted with `ctx.emit(Event, payload)`.
pub const event = struct {
    pub const define = @import("publr/plugin/hook_define.zig").event;
};
/// Another plugin's operations, records and events, with only what this plugin uses.
pub const remote = @import("publr/plugin/hook_define.zig").remote;
/// A secret a plugin declares in its `.secrets` struct: it never holds the value.
pub const Secret = struct {};
/// A field kind a plugin brings: `publr.field.kind(Value, .{ .name, .validate })`.
/// A plugin's own `.register_fields` group on an account, as its struct:
/// `publr.fields.get(ctx, Profile.Fields, user)`, `publr.fields.save(ctx, Profile.Fields,
/// user, values)`, compiled in or installed.
pub const fields = @import("publr/plugin/fields_api.zig");
/// What a `.register_location_rules` entry's `matches` is given: the account or file being
/// edited, and the rule, compared with `rule.compare(value)`.
pub const location = struct {
    pub const Target = @import("publr/model/field_group.zig").Target;
    pub const Operator = @import("publr/model/conditions.zig").Operator;
    pub const Rule = @import("publr/plugin/location_rule_define.zig").Rule;
};
pub const field = struct {
    pub const kind = @import("publr/plugin/field_kind_define.zig").kind;
    /// What one field of `record.define`'s `.fields` takes: `.{ .validation = .{ .max_len =
    /// 80 }, .options = .{ ... }, .visibility = .{ .restricted = true } }`.
    pub const Overrides = @import("publr/field_options.zig").Overrides;
    pub const Validation = @import("publr/field_options.zig").Validation;
    pub const Options = @import("publr/field_options.zig").Options;
    pub const Visibility = @import("publr/field_options.zig").Visibility;
};
/// Queued work: `publr.job.define(In, .{ .name, .run })` for `ctx.enqueue`,
/// `publr.job.define_recurring(.{ .name, .run, .every, .at })` for what repeats.
pub const job = struct {
    pub const define = @import("publr/plugin/job_define.zig").define;
    pub const define_recurring = @import("publr/plugin/job_define.zig").define_recurring;
};
/// What another server sends: `publr.webhook.define(Event, .{ .name, .secret, .signature,
/// .run })` at `/_webhooks/<plugin>.<name>`, listed in `.webhooks`.
pub const webhook = struct {
    pub const define = @import("publr/plugin/webhook_define.zig").define;
    pub const Signature = @import("publr/model/sandboxed_plugin.zig").Signature;
    pub const DeliveryId = @import("publr/model/sandboxed_plugin.zig").DeliveryId;
    pub const Delivery = @import("publr/plugin/webhook_define.zig").Delivery;
};
/// What queued work (a job) runs with: every call `Ctx` has, and `fetch`, queued work's
/// alone. Record handles and queries take either.
pub const QueueCtx = @import("publr/queue_ctx.zig").QueueCtx;
/// What a sign-in provider's `exchange` runs with: `fetch` to its own domains, within a
/// short time, and `log`; nothing else.
pub const ExchangeCtx = @import("publr/exchange_ctx.zig").ExchangeCtx;
/// A moment, as a `datetime` field holds it.
pub const Time = @import("publr/plugin/words.zig").Time;
/// A day on the calendar (`time.local_date(zone)`).
pub const Date = @import("publr/model/calendar.zig").Date;
/// The site's time zone, as `ctx.time_zone()` answers it.
pub const TimeZone = @import("publr/plugin/words.zig").TimeZone;
/// An exact number with `places` decimal places, as a `decimal` field holds it:
/// `publr.Decimal(3)` keeps `1.25` kg as 1250 units, never a binary fraction.
pub const Decimal = @import("publr/plugin/decimal.zig").Decimal;
/// An operation on its way out: `.deprecated = .{ .since = "0.4.0", .instead = "x.y" }`.
pub const Deprecated = @import("publr/operation.zig").Deprecated;
/// What `.validate` fills: `problems.add(.page, "Must start with /")`.
pub const Problems = @import("publr/plugin/operation_define.zig").Problems;
/// Ready answers to who may call an operation.
pub const authorize = struct {
    const Answer = @import("publr/authorize.zig").Answer;

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
pub const views = @import("publr/plugin/views.zig");
/// A named set of operations providers implement: `publr.contract.define(.{ .name,
/// .operations, .optional, .component })`.
pub const contract = struct {
    pub const define = @import("publr/contract.zig").define;
};
/// Published interfaces: another plugin's contracts and dimension wrappers as data, what
/// `@import("<plugin>")` gives a plugin naming it in `depends_on` or `compatible_with`.
pub const published = @import("publr/published.zig");
/// The enabled providers of a contract, in the administrator's order:
/// `publr.providers(ctx, Contract, .{ .can = &.{.refund} })`.
pub const providers = @import("publr/contract.zig").providers;
/// A record's field naming one provider of a contract: `method: publr.ProviderRef(Method)`.
/// `ref.provider(ctx)` is the provider while it is registered and on.
pub const ProviderRef = @import("publr/provider_ref.zig").ProviderRef;
/// JSON as Publr's wire reads and writes it: `publr.json.parse(Line, ctx.arena(), text)` and
/// `publr.json.stringify(ctx.arena(), value)`, as `std.json` does, at a cost close to the bytes.
pub const json = @import("publr/plugin/json_api.zig");
/// Money: whole minor units by currency, as a `money` field holds it and as operations pass
/// it: `try publr.Money.of(ctx.arena(), "PLN", 12300)`, `price.get("PLN")`. A plain list of
/// amounts, handed over as it lies; JSON, where Publr keeps or sends it, is `{ "PLN": 12300 }`.
pub const Money = @import("publr/money.zig").Money;
/// A value whose shape comes with the data, read where it lies: `value.get("title")`,
/// `value.at(0)`, `value.text()`; written with `publr.value.Builder`, or from a struct with
/// `publr.value.of(arena, value)`.
pub const Value = @import("publr/free_value.zig").Value;
/// A plugin's own collections, made with `init(ctx)` and growing in the memory they were made
/// in whatever is open when they grow: `publr.List(T)`, `publr.IdMap(V)` (keyed by text that
/// is mostly ids, hashed in 64-bit steps) and `publr.IdList(V)` (one that keeps its keys in
/// the order they were put).
pub const List = @import("publr/plugin/collections.zig").List;
pub const IdMap = @import("publr/plugin/collections.zig").IdMap;
pub const IdList = @import("publr/plugin/collections.zig").IdList;
pub const id_map = @import("publr/plugin/id_map.zig");
/// Publr's REST API as its clients read it, for code calling another Publr:
/// `publr.api_client.path(arena, "device.redeem")`,
/// `publr.api_client.result(Out, arena, body)`, `publr.api_client.refusal(arena, body)`. One
/// shape, kept in `lib/api`.
pub const api_client = @import("publr_api");
/// Every page of an operation that answers a page at a time (`after` in, `next` out), one
/// held at a time: `var roles = publr.pages(ctx, Operation, .{});`, `while (try roles.next())`.
pub const pages = @import("publr/plugin/pages.zig").pages;
pub const Pages = @import("publr/plugin/pages.zig").Pages;
pub const value = struct {
    pub const Builder = @import("publr/free_builder.zig").Builder;
    pub const of = @import("publr/free_typed.zig").of;
    pub const as = @import("publr/free_typed.zig").as;
};
/// A field naming a person's account, kept as its id (a `user` field): `owner: publr.Account`.
/// `ctx.caller().account()` is the signed-in person's.
pub const Account = @import("publr/account_ref.zig").Account;
/// Roles as plugins read them: `publr.role.permits(&role, "record.save")`, `grants_max`,
/// `settings_grant`, `owner_core`, and the `Declared` shape `.roles` takes.
pub const role = @import("publr/model/role.zig");
/// A site currency as people see it (`publr.money.Entry`) and an amount written with it:
/// `publr.money.format(&buffer, 123456, entry)` is `£1,234.56`.
pub const money = @import("publr/model/money.zig");
/// ISO 4217: `publr.currency.find("GBP").?.digits` is 2.
pub const currency = @import("publr/model/currency.zig");
/// The process environment, for plugins compiled into Publr: `publr.environment.get(name)`.
pub const environment = @import("publr/environment.zig");
/// Text made safe to put in HTML: `try publr.html.escape(writer, text)`.
pub const html = @import("publr/html.zig");
/// Files: what `ctx.make_file` makes, and whether a key names a media file
/// (`publr.files.valid_key(key)`).
pub const files = @import("publr/files.zig");
/// What a write changed, unit by unit, for a built-in plugin's hooks:
/// `publr.changed_units.hooks(&.{ .record }, changed)`.
pub const changed_units = @import("publr/changed_units.zig");
/// A device acting for an account: its `Scope`, `valid_name`, `name_len_max`.
pub const device = @import("publr/model/device.zig");
/// A sign-on token an issuer signs for one site: `sign`, `verify`, `key_from_hex`.
pub const sign_on_token = @import("publr/model/sign_on_token.zig");
/// An app as `app.zon` declares it: `Config`, `Mount`, `valid_name`, `valid_mount`, `label_of`.
pub const app = @import("publr/model/app.zig");
/// A site in memory for a plugin's tests: `var site: publr.testing.Site = undefined;`,
/// `site.call(Operation, who, in)`, `site.json(who, name, input)`, `site.drain()`.
pub const testing = @import("publr/testing.zig");
/// The double-entry ledger: `pub const Ledger = publr.ledger.define(struct { ... }, .{
/// .reasons = Reason })`, listed in `define` as `.ledger`, used as `Ledger.transfer(ctx, ...)`;
/// reads as `publr.ledger.balance(ctx, account)` and the rest.
pub const ledger = struct {
    const ledger_define = @import("publr/plugin/ledger_define.zig");

    pub const define = ledger_define.define;
    pub const Kind = @import("publr/model/ledger.zig").Kind;
    pub const Asset = ledger_define.Asset;
    pub const Liability = ledger_define.Liability;
    pub const Equity = ledger_define.Equity;
    pub const Income = ledger_define.Income;
    pub const Expense = ledger_define.Expense;
    pub const Unit = ledger_define.Unit;
    pub const UnitName = ledger_define.UnitName;
    pub const unit = ledger_define.unit;
    pub const unit_of = ledger_define.unit_of;
    pub const Account = ledger_define.Account;
    pub const TransferRef = ledger_define.TransferRef;
    pub const Holder = ledger_define.Holder;
    pub const Done = ledger_define.Done;
    pub const Pair = ledger_define.Pair;
    pub const balance = ledger_define.balance;
    pub const balance_at = ledger_define.balance_at;
    pub const history = ledger_define.history;
    pub const find = ledger_define.find;
    pub const page = ledger_define.page;
    pub const Page = ledger_define.Page;
    pub const totals = ledger_define.totals;
    pub const get = ledger_define.get;
    pub const accounts = ledger_define.accounts;
    pub const account = ledger_define.account_of;
    pub const AccountView = @import("publr/operations/ledger.zig").AccountView;
    pub const Transfer = @import("publr/operations/ledger.zig").Shown;
    pub const Line = @import("publr/operations/ledger.zig").Line;
    pub const Sum = @import("publr/operations/ledger.zig").Sum;
    /// A hold voided by its expiry: `publr.on(publr.ledger.Expired, run)`.
    pub const Expired = @import("publr/operations/ledger.zig").Expired;
};
/// Messages Publr hands to providers: `ctx.emit(publr.messaging.Email, .{ .to, .subject,
/// .text })`, and the `messaging` contract providers register into.
pub const messaging = @import("publr/messaging.zig");
/// Model providers: the contract, and the two operations a provider plugin registers with.
pub const ai = @import("publr/ai.zig");
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
pub const Request = @import("publr/app_middleware.zig").Request;
pub const Response = @import("publr/app_middleware.zig").Response;
pub const template = @import("template.zig");
pub const operations = struct {
    pub const device = @import("publr/operations/device.zig");
    pub const apps = @import("publr/operations/apps.zig");
    pub const heartbeat = @import("publr/operations/heartbeat.zig");
    pub const money = @import("publr/operations/money.zig");
    pub const project = @import("publr/operations/project.zig");
    pub const clock = @import("publr/operations/clock.zig");
    pub const custom_fields = @import("publr/operations/custom_fields.zig");
    pub const user = @import("publr/operations/user.zig");
    pub const user_type = @import("publr/operations/user_type.zig");
    pub const sign_in = @import("publr/operations/sign_in.zig");
    pub const sign_on = @import("publr/operations/sign_on.zig");
    pub const identity = @import("publr/operations/identity.zig");
    pub const status = @import("publr/operations/status.zig");
    pub const flow = @import("publr/operations/flow.zig");
    pub const role = @import("publr/operations/role.zig");
    pub const operation = @import("publr/operations/operation.zig");
    pub const content_type = @import("publr/operations/content_type.zig");
    pub const record = @import("publr/operations/record.zig");
    pub const taxonomy = @import("publr/operations/taxonomy.zig");
    pub const term = @import("publr/operations/term.zig");
    pub const media = @import("publr/operations/media.zig");
    pub const design = @import("publr/operations/design.zig");
    pub const snapshot = @import("publr/operations/snapshot.zig");
    pub const view = @import("publr/operations/view.zig");
    pub const rail = @import("publr/operations/rail.zig");
    pub const ai = @import("publr/operations/ai.zig");
    pub const secret = @import("publr/operations/secret.zig");
    pub const http = @import("publr/operations/http.zig");
    pub const mail = @import("publr/operations/mail.zig");
    pub const internal = @import("publr/operations/internal.zig");
    pub const request = @import("publr/operations/request.zig");
    pub const link = @import("publr/operations/link.zig");
    pub const messaging = @import("publr/operations/messaging.zig");
    pub const plugin = @import("publr/operations/plugin.zig");
    pub const ledger = @import("publr/operations/ledger.zig");
    pub const activity = @import("publr/operations/activity.zig");
    pub const errors = @import("publr/operations/errors.zig");
    pub const event = @import("publr/operations/event.zig");
    pub const job = @import("publr/operations/job.zig");
    pub const mod = @import("publr/operations/mod.zig");
    pub const random = @import("publr/operations/random.zig");
    pub const trash = @import("publr/operations/trash.zig");
    pub const webhook = @import("publr/operations/webhook.zig");
    pub const health = @import("publr/operations/health.zig");
    pub const provider = @import("publr/operations/provider.zig");
    pub const removal = @import("publr/operations/removal.zig");
    pub const update = @import("publr/operations/update.zig");
};
pub const serve = if (builtin.os.tag == .wasi) void else @import("server/serve.zig");
pub const build = if (builtin.os.tag == .wasi) void else @import("server/build.zig");
pub const plugin_sdk = if (builtin.os.tag == .wasi) void else @import("server/plugin_sdk.zig");
pub const plugin_build = if (builtin.os.tag == .wasi) void else @import("server/plugin_build.zig");
pub const plugin_check = if (builtin.os.tag == .wasi)
    void
else
    @import("server/plugin_build/check.zig");
pub const operator = if (builtin.os.tag == .wasi) void else @import("server/operator.zig");
pub const database = if (builtin.os.tag == .wasi) void else @import("server/database.zig");
pub const bundle = if (builtin.os.tag == .wasi) void else @import("server/bundle.zig");
pub const gate_backup = if (builtin.os.tag == .wasi) void else @import("server/gate/backup.zig");
pub const update = if (builtin.os.tag == .wasi) void else @import("server/update.zig");
pub const agents = if (builtin.os.tag == .wasi) void else @import("server/agents.zig");
pub const apps_load = if (builtin.os.tag == .wasi) void else @import("server/apps_load.zig");
pub const seed = if (builtin.os.tag == .wasi) void else @import("server/seed.zig");
pub const clone_pack = if (builtin.os.tag == .wasi)
    void
else
    @import("server/clone/pack_process.zig");
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
