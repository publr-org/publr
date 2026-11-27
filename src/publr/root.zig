const std = @import("std");

pub const version = @import("version.zig").version;
/// What a plugin is called and which version it is: `publr.plugin.define(manifest, options)`.
pub const Manifest = @import("plugin/define.zig").Manifest;
/// A plugin's registration and what its options take: `pub const plugin = publr.plugin.define(
/// manifest, .{ .roles, .user_types, .pages, .panels, .row_actions, .translations, .limits })`.
pub const plugin = struct {
    pub const define = @import("plugin/define.zig").define;
    /// A role a plugin declares, in `.roles`.
    pub const Role = @import("model/role.zig").Declared;
    /// A type of user a plugin registers, in `.user_types`: `.{ .name, .label, .apps }`.
    pub const UserType = @import("model/user_type.zig").Declared;
    /// What an installed plugin asks of the sandbox, in `.limits`.
    pub const Limits = @import("model/sandboxed_plugin.zig").Limits;
    /// The admin pages, panels and row actions a plugin adds, in `.pages`, `.panels` and
    /// `.row_actions`; `Blank` is what a column an `only_one` row leaves empty says instead.
    pub const Page = @import("plugin/admin_slots.zig").Page;
    pub const Panel = @import("plugin/admin_slots.zig").Panel;
    pub const RowAction = @import("plugin/admin_slots.zig").RowAction;
    pub const Blank = @import("plugin/admin_slots.zig").Blank;
    /// A language's words a plugin brings, in `.translations`, with its grammar.
    pub const Translation = @import("plugin/translation.zig").Translation;
    pub const Grammar = @import("plugin/translation.zig").Grammar;
    pub const Word = @import("plugin/translation.zig").Word;
};
/// What a plugin's code runs with, and how it fails.
pub const Ctx = @import("ctx.zig").Ctx;
pub const Error = @import("operation.zig").Error;
/// Whether this build of the plugin is compiled into Publr (a built-in plugin), not installed
/// (a Wasm module the host runs): what only a built-in plugin carries is chosen by it.
pub const compiled_in = @import("ctx.zig").compiled_in;
/// What a built-in plugin's `.extend` registers through: `fn extend(host: *publr.Host)`.
pub const Host = @import("extend/host.zig").Host;
/// SQL on a built-in plugin's own tables: `ctx.database()`.
pub const Database = @import("extend/database.zig").Database;
/// `publr.operation.define(In, Out, .{ .name, .kind, .authorize, ... })`.
pub const operation = struct {
    pub const define = @import("plugin/operation_define.zig").define;
    pub const Kind = @import("operation.zig").Kind;
    /// A way an operation fails beyond core's errors, listed in its `failures`.
    pub const Failure = @import("operation.zig").Failure;
    /// One thing wrong with a call's input, as `ctx.refuse` and `Problems` hold it.
    pub const Problem = @import("operation.zig").Problem;
    /// A text for each field of a shape: `field_docs: publr.operation.Docs(In)`.
    pub const Docs = @import("operation.zig").Docs;
    /// A value whose shape comes with the data: `try publr.operation.Json.of(arena, value)`.
    pub const Json = @import("operation.zig").Json;
    /// A group of operations as REST, the CLI and MCP show it: each `publr.operations.*` file's
    /// `namespace`.
    pub const Namespace = @import("operation.zig").Namespace;
    /// `record` of `record.create`, and `create`.
    pub const namespace = @import("operation.zig").namespace;
    pub const verb = @import("operation.zig").verb;
    pub const name_len_max = @import("operation.zig").name_len_max;
    pub const fields_max = @import("operation.zig").fields_max;
    pub const operations_max = @import("operation.zig").operations_max;
    /// The largest page a list answers at once.
    pub const page_limit_max = @import("operation.zig").page_limit_max;
    pub const failure_message_len_max = @import("operation.zig").failure_message_len_max;
};
/// `publr.record.define(Document, .{ .name, .internal, ... })` and a reference to any record.
pub const record = struct {
    pub const define = @import("plugin/record_define.zig").define;
    pub const AnyRef = @import("plugin/record_define.zig").AnyRef;
    /// A collection's reads by its stored name, for code that names it rather than its handle:
    /// `publr.record.Store(Line, "line", true).find(ctx, "order", id, 200, 0)`.
    pub const Store = @import("plugin/record_define.zig").Store;
    /// One transition of a record's flow: `[_]publr.record.Transition(Status){ ... }`.
    pub const Transition = @import("plugin/record_flow.zig").Transition;
    /// Every status but the transition's target and the trash: `.from = publr.record.any`.
    pub const any = @import("plugin/record_flow.zig").any;
    /// What a hook on `X.any_transition` hears: `.{ .record, .transition, .from, .to }`.
    pub const Transitioned = @import("model/flow.zig").Transitioned;
};
/// `publr.taxonomy.define(Term, .{ .name, .public, .hierarchical, .single, .internal, .fields })`,
/// and what `.register_taxonomies` takes: `.{ .taxonomy, .to }`.
/// `publr.dimension.define(.{ .name, .api, .list, .priority, .addresses, ... })`, listed in
/// `.dimensions`; its `.api` the owner's wrapper, a `field_option` and a `read_option`;
/// `publr.dimension.Value` is one value its list answers; a family's list answers `Member`s,
/// its `.shown` `Shown`s.
pub const dimension = struct {
    pub const define = @import("plugin/dimensions.zig").define;
    pub const field_option = @import("plugin/dimensions.zig").field_option;
    pub const read_option = @import("plugin/dimensions.zig").read_option;
    pub const Holds = @import("model/dimension.zig").Holds;
    /// One dimension at one code, `language` at `pl`, and a value's key read:
    /// `publr.dimension.split("title@language=pl")`, `publr.dimension.parse(key.combination)`.
    pub const Pair = @import("model/dimension.zig").Pair;
    pub const Combination = @import("model/dimension.zig").Combination;
    pub const Key = @import("model/dimension.zig").Key;
    pub const split = @import("model/dimension.zig").split;
    pub const parse = @import("model/dimension.zig").parse;
    pub const varies_by = @import("model/dimension.zig").varies_by;
    pub const valid_code = @import("model/dimension.zig").valid_code;
    pub const family_of = @import("model/dimension.zig").family_of;
    pub const Dimension = @import("plugin/dimensions.zig").Dimension;
    pub const Value = @import("plugin/dimensions.zig").Value;
    pub const Member = @import("plugin/dimensions.zig").Member;
    pub const Shown = @import("plugin/dimensions.zig").Shown;
    pub const values_max = @import("plugin/dimensions.zig").values_max;
};

/// `publr.hook.request(run)` in `.hooks`: a page request before it is drawn.
pub const hook = struct {
    pub const request = @import("plugin/hook_define.zig").request;
    /// `publr.hook.about("shop.product", publr.after(publr.operations.record.List, run))`:
    /// the hook hears only calls that name that content type.
    pub const about = @import("plugin/hook_define.zig").about;
};
pub const PageRequest = @import("page_request.zig").PageRequest;
pub const Answered = @import("page_request.zig").Answered;

pub const taxonomy = struct {
    pub const define = @import("plugin/taxonomy_define.zig").define;
    pub const Registration = @import("model/taxonomy.zig").Registration;
};
/// GROQ queries with `$names` bound from a struct: `publr.query.prepare(text, .{})`.
pub const query = struct {
    pub const prepare = @import("plugin/query_define.zig").prepare;
};
/// Changes or refuses an operation's input inside its write: `publr.before(Sign, refuse_links)`.
pub const before = @import("plugin/hook_define.zig").before;
/// Runs inside the write after an operation or an event; may refuse, rolling it back.
pub const after = @import("plugin/hook_define.zig").after;
/// Runs from the queue once the write committed, with the operation's answer or the event's
/// payload: `publr.on(Orders.place, send_confirmation)`.
pub const on = @import("plugin/hook_define.zig").on;
/// A menu item in the admin: `.{ .name, .label = publr.t("Orders"), .icon, .record, .parent }`.
pub const MenuItem = @import("plugin/menu_define.zig").MenuItem;
/// An icon of a plugin's own: `.{ .name = "bag", .svg = @embedFile("icons/bag.svg") }`.
pub const Icon = @import("plugin/menu_define.zig").Icon;
/// JS's `String` for plugins: `publr.text.starts_with(name, "admin")`,
/// `publr.text.upper(ctx, name)`. See `publr/plugin/text.zig`.
pub const text = @import("plugin/text.zig");
/// Text a person reads, written where it is declared and translated where it is shown.
pub const t = @import("plugin/menu_define.zig").t;
/// Changes the value applied under a name, wherever its owner applies it (`ctx.mod`):
/// `publr.modify("variant.title", title)`, `*` for one part (`*.title`).
pub const modify = @import("plugin/hook_define.zig").modify;
/// A batch modifier: `publr.modify_all("orders.charge", price_all)`, `fn (ctx: *publr.Ctx,
/// charges: []Charge) publr.Error!void`, called once with every value applied.
pub const modify_all = @import("plugin/hook_define.zig").modify_all;
/// A record's title as core applies it, `<type>.title`: `.id`, the record's fields typed
/// (`.record`), and the `.title` to change.
pub const Title = @import("plugin/modify_define.zig").Title;
/// A computed field as its modifiers take it: `publr.modify("<record>.<field>", run)` with
/// `fn (ctx: *publr.Ctx, value: *publr.Computed(Doc, Field)) publr.Error!void`.
pub const Computed = @import("plugin/record_computed.zig").Computed;
/// What a `<type>.<field>.help` modifier takes: the help under one field of a record in the
/// editor, asked again as its values change; change `help`.
pub const FieldHelp = @import("plugin/modify_define.zig").FieldHelp;
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
    required: []const @import("model/dimension.zig").Pair = &.{},
    /// The whole record as the editor holds it, every value beside its field.
    record: @import("operation.zig").Json = .object,
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
pub const mod_changed = @import("mods.zig").Changed;
/// People signing in, up and out, hooked by type: `publr.after(publr.auth.SignedIn, run)`;
/// sign-ins refused (`SignInFailed`, `SignOnFailed` …), heard with `publr.on` only.
pub const auth = @import("auth_events.zig");
/// Everything that lands in the Error log as an error: `publr.on(publr.errors.Failed, run)`.
pub const errors = struct {
    pub const Failed = @import("error_events.zig").Failed;
};
/// Something that happens that is not a call: `publr.event.define(.{ .name, .payload })`,
/// emitted with `ctx.emit(Event, payload)`.
pub const event = struct {
    pub const define = @import("plugin/hook_define.zig").event;
};
/// Another plugin's operations, records and events, with only what this plugin uses.
pub const remote = @import("plugin/hook_define.zig").remote;
/// A secret a plugin declares in its `.secrets` struct: it never holds the value.
pub const Secret = struct {};
/// A field kind a plugin brings: `publr.field.kind(Value, .{ .name, .validate })`.
/// A plugin's own `.register_fields` group on an account, as its struct:
/// `publr.fields.get(ctx, Profile.Fields, user)`, `publr.fields.save(ctx, Profile.Fields,
/// user, values)`, compiled in or installed.
pub const fields = @import("plugin/fields_api.zig");
/// What a `.register_location_rules` entry's `matches` is given: the account or file being
/// edited, and the rule, compared with `rule.compare(value)`.
pub const location = struct {
    pub const Target = @import("model/field_group.zig").Target;
    pub const Operator = @import("model/conditions.zig").Operator;
    pub const Rule = @import("plugin/location_rule_define.zig").Rule;
};
pub const field = struct {
    pub const kind = @import("plugin/field_kind_define.zig").kind;
    /// What one field of `record.define`'s `.fields` takes: `.{ .validation = .{ .max_len =
    /// 80 }, .options = .{ ... }, .visibility = .{ .restricted = true } }`.
    pub const Overrides = @import("field_options.zig").Overrides;
    pub const Validation = @import("field_options.zig").Validation;
    pub const Options = @import("field_options.zig").Options;
    pub const Visibility = @import("field_options.zig").Visibility;
};
/// Queued work: `publr.job.define(In, .{ .name, .run })` for `ctx.enqueue`,
/// `publr.job.define_recurring(.{ .name, .run, .every, .at })` for what repeats.
pub const job = struct {
    pub const define = @import("plugin/job_define.zig").define;
    pub const define_recurring = @import("plugin/job_define.zig").define_recurring;
};
/// What another server sends: `publr.webhook.define(Event, .{ .name, .secret, .signature,
/// .run })` at `/_webhooks/<plugin>.<name>`, listed in `.webhooks`.
pub const webhook = struct {
    pub const define = @import("plugin/webhook_define.zig").define;
    pub const Signature = @import("model/sandboxed_plugin.zig").Signature;
    pub const DeliveryId = @import("model/sandboxed_plugin.zig").DeliveryId;
    pub const Delivery = @import("plugin/webhook_define.zig").Delivery;
};
/// What queued work (a job) runs with: every call `Ctx` has, and `fetch`, queued work's
/// alone. Record handles and queries take either.
pub const QueueCtx = @import("queue_ctx.zig").QueueCtx;
/// What a sign-in provider's `exchange` runs with: `fetch` to its own domains, within a
/// short time, and `log`; nothing else.
pub const ExchangeCtx = @import("exchange_ctx.zig").ExchangeCtx;
/// A moment, as a `datetime` field holds it.
pub const Time = @import("plugin/words.zig").Time;
/// A day on the calendar (`time.local_date(zone)`).
pub const Date = @import("model/calendar.zig").Date;
/// The site's time zone, as `ctx.time_zone()` answers it.
pub const TimeZone = @import("plugin/words.zig").TimeZone;
/// An exact number with `places` decimal places, as a `decimal` field holds it:
/// `publr.Decimal(3)` keeps `1.25` kg as 1250 units, never a binary fraction.
pub const Decimal = @import("plugin/decimal.zig").Decimal;
/// An operation on its way out: `.deprecated = .{ .since = "0.4.0", .instead = "x.y" }`.
pub const Deprecated = @import("operation.zig").Deprecated;
/// What `.validate` fills: `problems.add(.page, "Must start with /")`.
pub const Problems = @import("plugin/operation_define.zig").Problems;
/// Ready answers to who may call an operation.
pub const authorize = struct {
    const Answer = @import("authorize.zig").Answer;

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
pub const views = @import("plugin/views.zig");
/// A named set of operations providers implement: `publr.contract.define(.{ .name,
/// .operations, .optional, .component })`.
pub const contract = struct {
    pub const define = @import("contract.zig").define;
};
/// Published interfaces: another plugin's contracts and dimension wrappers as data, what
/// `@import("<plugin>")` gives a plugin naming it in `depends_on` or `compatible_with`.
pub const published = @import("published.zig");
/// The enabled providers of a contract, in the administrator's order:
/// `publr.providers(ctx, Contract, .{ .can = &.{.refund} })`.
pub const providers = @import("contract.zig").providers;
/// A record's field naming one provider of a contract: `method: publr.ProviderRef(Method)`.
/// `ref.provider(ctx)` is the provider while it is registered and on.
pub const ProviderRef = @import("provider_ref.zig").ProviderRef;
/// JSON as Publr's wire reads and writes it: `publr.json.parse(Line, ctx.arena(), text)` and
/// `publr.json.stringify(ctx.arena(), value)`, as `std.json` does, at a cost close to the bytes.
pub const json = @import("plugin/json_api.zig");
/// Money: whole minor units by currency, as a `money` field holds it and as operations pass
/// it: `try publr.Money.of(ctx.arena(), "PLN", 12300)`, `price.get("PLN")`. A plain list of
/// amounts, handed over as it lies; JSON, where Publr keeps or sends it, is `{ "PLN": 12300 }`.
pub const Money = @import("money.zig").Money;
/// A value whose shape comes with the data, read where it lies: `value.get("title")`,
/// `value.at(0)`, `value.text()`; written with `publr.value.Builder`, or from a struct with
/// `publr.value.of(arena, value)`.
pub const Value = @import("free_value.zig").Value;
/// A plugin's own collections, made with `init(ctx)` and growing in the memory they were made
/// in whatever is open when they grow: `publr.List(T)`, `publr.IdMap(V)` (keyed by text that
/// is mostly ids, hashed in 64-bit steps) and `publr.IdList(V)` (one that keeps its keys in
/// the order they were put).
pub const List = @import("plugin/collections.zig").List;
pub const IdMap = @import("plugin/collections.zig").IdMap;
pub const IdList = @import("plugin/collections.zig").IdList;
pub const id_map = @import("plugin/id_map.zig");
/// Publr's REST API as its clients read it, for code calling another Publr:
/// `publr.api_client.path(arena, "device.redeem")`,
/// `publr.api_client.result(Out, arena, body)`, `publr.api_client.refusal(arena, body)`. One
/// shape, kept in `lib/api`.
pub const api_client = @import("publr_api");
/// Every page of an operation that answers a page at a time (`after` in, `next` out), one
/// held at a time: `var roles = publr.pages(ctx, Operation, .{});`, `while (try roles.next())`.
pub const pages = @import("plugin/pages.zig").pages;
pub const Pages = @import("plugin/pages.zig").Pages;
pub const value = struct {
    pub const Builder = @import("free_builder.zig").Builder;
    pub const of = @import("free_typed.zig").of;
    pub const as = @import("free_typed.zig").as;
};
/// A field naming a person's account, kept as its id (a `user` field): `owner: publr.Account`.
/// `ctx.caller().account()` is the signed-in person's.
pub const Account = @import("account_ref.zig").Account;
/// Roles as plugins read them: `publr.role.permits(&role, "record.save")`, `grants_max`,
/// `settings_grant`, `owner_core`, and the `Declared` shape `.roles` takes.
pub const role = @import("model/role.zig");
/// A site currency as people see it (`publr.money.Entry`) and an amount written with it:
/// `publr.money.format(&buffer, 123456, entry)` is `£1,234.56`.
pub const money = @import("model/money.zig");
/// ISO 4217: `publr.currency.find("GBP").?.digits` is 2.
pub const currency = @import("model/currency.zig");
/// The process environment, for plugins compiled into Publr: `publr.environment.get(name)`.
pub const environment = @import("environment.zig");
/// Text made safe to put in HTML: `try publr.html.escape(writer, text)`.
pub const html = @import("html.zig");
/// Files: what `ctx.make_file` makes, and whether a key names a media file
/// (`publr.files.valid_key(key)`).
pub const files = @import("files.zig");
/// What a write changed, unit by unit, for a built-in plugin's hooks:
/// `publr.changed_units.hooks(&.{ .record }, changed)`.
pub const changed_units = @import("changed_units.zig");
/// A device acting for an account: its `Scope`, `valid_name`, `name_len_max`.
pub const device = @import("model/device.zig");
/// A sign-on token an issuer signs for one site: `sign`, `verify`, `key_from_hex`.
pub const sign_on_token = @import("model/sign_on_token.zig");
/// An app as `app.zon` declares it: `Config`, `Mount`, `valid_name`, `valid_mount`, `label_of`.
pub const app = @import("model/app.zig");
/// A site in memory for a plugin's tests: `var site: publr.testing.Site = undefined;`,
/// `site.call(Operation, who, in)`, `site.json(who, name, input)`, `site.drain()`.
pub const testing = @import("testing.zig");
/// An app loaded from the folder, as the server started or the folder changed:
/// `publr.after(publr.AppsLoaded, run)`.
pub const AppsLoaded = @import("apps_loaded.zig").AppsLoaded;
/// The double-entry ledger: `pub const Ledger = publr.ledger.define(struct { ... }, .{
/// .reasons = Reason })`, listed in `define` as `.ledger`, used as `Ledger.transfer(ctx, ...)`;
/// reads as `publr.ledger.balance(ctx, account)` and the rest.
pub const ledger = struct {
    const ledger_define = @import("plugin/ledger_define.zig");

    pub const define = ledger_define.define;
    pub const Kind = @import("model/ledger.zig").Kind;
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
    pub const AccountView = @import("operations/ledger.zig").AccountView;
    pub const Transfer = @import("operations/ledger.zig").Shown;
    pub const Line = @import("operations/ledger.zig").Line;
    pub const Sum = @import("operations/ledger.zig").Sum;
    /// A hold voided by its expiry: `publr.on(publr.ledger.Expired, run)`.
    pub const Expired = @import("operations/ledger.zig").Expired;
};
/// Messages Publr hands to providers: `ctx.emit(publr.messaging.Email, .{ .to, .subject,
/// .text })`, and the `messaging` contract providers register into.
pub const messaging = @import("messaging.zig");
/// Model providers: the contract, and the two operations a provider plugin registers with.
pub const ai = @import("ai.zig");
/// What an app's `middleware.zig` is given, and what it answers with.
pub const Request = @import("app_middleware.zig").Request;
pub const Response = @import("app_middleware.zig").Response;
pub const operations = struct {
    pub const device = @import("operations/device.zig");
    pub const apps = @import("operations/apps.zig");
    pub const heartbeat = @import("operations/heartbeat.zig");
    pub const money = @import("operations/money.zig");
    pub const project = @import("operations/project.zig");
    pub const clock = @import("operations/clock.zig");
    pub const custom_fields = @import("operations/custom_fields.zig");
    pub const user = @import("operations/user.zig");
    pub const user_type = @import("operations/user_type.zig");
    pub const sign_in = @import("operations/sign_in.zig");
    pub const sign_on = @import("operations/sign_on.zig");
    pub const identity = @import("operations/identity.zig");
    pub const status = @import("operations/status.zig");
    pub const flow = @import("operations/flow.zig");
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
    pub const mail = @import("operations/mail.zig");
    pub const internal = @import("operations/internal.zig");
    pub const request = @import("operations/request.zig");
    pub const link = @import("operations/link.zig");
    pub const messaging = @import("operations/messaging.zig");
    pub const plugin = @import("operations/plugin.zig");
    pub const ledger = @import("operations/ledger.zig");
    pub const activity = @import("operations/activity.zig");
    pub const errors = @import("operations/errors.zig");
    pub const event = @import("operations/event.zig");
    pub const job = @import("operations/job.zig");
    pub const mod = @import("operations/mod.zig");
    pub const random = @import("operations/random.zig");
    pub const trash = @import("operations/trash.zig");
    pub const webhook = @import("operations/webhook.zig");
    pub const health = @import("operations/health.zig");
    pub const provider = @import("operations/provider.zig");
    pub const removal = @import("operations/removal.zig");
    pub const update = @import("operations/update.zig");
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(operations);
}
