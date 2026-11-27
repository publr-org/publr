# Breaking changes before 1.0

Before 1.0, any release may change what plugins and apps build on, without notice. Each
release lists here what it broke and what to do instead, newest first. Upgrading a project:
read the sections after its release, or run `publr upgrade --prompt`, which keeps only what
the project uses.

Each entry is a `###` heading holding the item in backticks, named as `publr plugin surface`
names it (`call:money.texts`, `event:role.created` for an event a plugin emits or hooks,
`mod:media.base`, `host:publr_call_shaped`, `template:…`, `sdk:…`, `cli:…`, `config:…`),
then what changed and what to do, with a before and after where it helps. A change of
behaviour under the same name is an entry too. New entries go under `## Unreleased`; a
release renames it to its version and day.

## Unreleased

### `sdk:Ctx.state`

`ctx.state(Plugin)` answers null where the call runs with no states made (a plugin's
examples, a command with no server) instead of stopping the process; `publr.testing.Site`
makes every plugin's state, so a test reaches it. A plugin answers what it did before it had
a state: null, `error.Unavailable`, a default.

```zig
// Before
const port = ctx.state(Sampler).port;
// After
const state = ctx.state(Sampler) orelse return error.Unavailable;
const port = state.port;
```

### `sdk:Host.bootstrap`

A built-in plugin's `bootstrap` runs as the plugin's own code, as its jobs do: its internal
records are its to read and write, its calls are held to its grants, and `ctx.as_system()`
and `ctx.as_person()` answer it (they refused before). The caller is still Publr itself. A
bootstrap that set `ctx.plugin` itself drops that; one that called something its grants do
not reach calls it through `ctx.as_system()`.

```zig
// Before
fn bootstrap(ctx: *publr.sdk.Ctx) publr.sdk.Error!void {
    ctx.plugin = "cloud";
    _ = try SDK.dispatch(ctx, identity.Configure, .{ .open_sign_up = "customer" });
}
// After
fn bootstrap(ctx: *publr.Ctx) publr.Error!void {
    _ = try (try ctx.as_system()).call(identity.Configure, .{ .open_sign_up = "customer" });
}
```

### `sdk:Ctx.as_person`

A call made through `ctx.as_person(person)` is the person's own call, made by the plugin's
code: what a permission names, the plugin's grants decide (unchanged); the site's answer for
an operation (`operation authorize`, an operation's `authorize`) judges the person's roles,
and `signed_in` admits them; a core operation no permission names (`device.offer`, rail
pins, removal lists) is decided by the person's roles, as if they were signed in. What no
grant reaches stays refused (`permission.never`: sessions, passwords, identities, a
person's conversations), and so do the steps only the person's own hand takes: approving or
denying a device (`device.request`, `device.approve`, `device.deny`). `ctx.caller()` reads
`signed_in()` and the person's roles. An installed plugin relaying a call is unchanged.

```zig
// Before: refused, `device.offer` wanted a signed-in caller
const offered = try (try ctx.as_person(member)).call(device.Offer, .{ .scope = "publish" });
// After: the member's own offer
const offered = try (try ctx.as_person(member)).call(device.Offer, .{ .scope = "publish" });
```

### `sdk:Ctx.grant`

`ctx.grant(key)` answers `publr.Ctx.Grant` (`on`, `drafts`, `private`, `internal`,
`publish`, `domains`, and `publr.Ctx.Grant.off`), defined publicly. It no longer carries
`of`, `bits` or `from_bits`, which were core's. `ctx.make_file(type, filename)` answers
`publr.Ctx.Making` (`write`, `done`), and `done` a `publr.Ctx.Made`; the same calls as before.

```zig
// Before
const fetch = ctx.grant("http.fetch"); // core's permission_define.Grant
// After
const fetch: publr.Ctx.Grant = ctx.grant("http.fetch");
```

### `sdk:Error`

`publr.Error` no longer holds the database's own error names. Every call, record read and
write, `publr.Database` statement and definer a plugin uses answers the public set
(`Denied`, `Invalid`, `NotFound`, `Conflict`, `Throttled`, `Failed`, `Unavailable`,
`BadCredentials`, `InvalidationFailed`, `NotYet`, `OutOfMemory`): `Constraint` is now
`Conflict`; `Busy`, `ReadOnly` and `Sqlite` are `Unavailable`; `Interrupted` and `TooBig` are
`Invalid`. A plugin that names one of the old errors switches to the new name; a function a
plugin hands Publr (an operation's `run`, a hook, a job, a gate) returns `publr.Error`, not
`publr.sdk.Error`. An installed plugin built before keeps working: the old codes read as
their new names.

```zig
// Before
database.exec("INSERT ...", .{id}) catch |err| switch (err) {
    error.Constraint => return ctx.fail(.Taken, "Already there", .{}),
    else => |other| return other,
};
fn run(ctx: *publr.Ctx, in: In) publr.sdk.Error!Out { ... }
// After
database.exec("INSERT ...", .{id}) catch |err| switch (err) {
    error.Conflict => return ctx.fail(.Taken, "Already there", .{}),
    else => |other| return other,
};
fn run(ctx: *publr.Ctx, in: In) publr.Error!Out { ... }
```

### `sdk:Host.app_picker_segment`

`host.app_picker_segment` takes the plugin's view and a function answering its props, no
longer a function given core's admin session that draws a node itself. Core draws the view
and fills `attached`, `apps` and `csrf` when its props have them.

```zig
// Before
try host.app_picker_segment(admin.app_picker_segment); // fn (*const Session, bool, ?Node) !?Node
// After
try host.app_picker_segment(views.EnvironmentSwitcher, switcher_props); // fn (*publr.Ctx, bool) !?Props
```

### `sdk:Host.Serving`

`publr.Host.Serving` has no `project`. What a plugin did with it is on `serve.served()`, a
`publr.Host.Server` a `State` may keep: `system(arena)` (the system's `*publr.Ctx`),
`reload_apps()`, `set_session_cookie(name)`. Every session ends with
`ctx.call(publr.operations.sign_in.EndSessions, .{ .everyone = true })` (new,
`user.end_sessions`), replacing `publr.store.sessions.destroy_every`/`destroy_all`.
Another copy's database opens with `process.databases().open(memory, path)`, a
`publr.Host.Database` (`close(memory)` when done), replacing `publr.db.open(runtime, path)`.

### `sdk:Host.admin_pages`

A built-in plugin's own admin screens draw through `publr.Host.admin_pages`: `require`,
`accept` (a `Post` with `page` and `form`), and on the `*Page`: `ctx()`, `arena()`,
`param`, `query_param`, `screen(status, View, props, .{ .settings_path, .section_page })`,
`fail`, `message`, `csrf_token`, `translated`; `query_value` and `time_text` beside them.
They replace `publr.admin.require`/`accept`/`screen`/`fail`/`param`/`query_param`/
`message`/`query_value`/`time_text`, and `registry.SDK.dispatch(&session.ctx, …)` becomes
`page.ctx().call(…)`.

### `sdk:Host`

`publr.Host` is defined in `src/publr/extend/`, with every type its seams take and give:
`publr.Host.Route`, `OperatorCommand`, `Handler`, `Stream`, `Request`, `Response`,
`Context`, `Status`, `HttpError`, `Policy`, `PolicyRequest`, `PolicyGrant`, `Gate`,
`Delivery`, `Verdict`, `Refusal`, `SignInProvider`, `Claims`, `Callback`, `Authorize`,
`FromRequest`, `Command`, `Serving`, `Process`, `Database`, `Statement`, `AdminBrand`,
`timed`. Nothing a seam hands over is core's any more:

- A route's or operator command's handler takes `*publr.Host.Request`,
  `*publr.Host.Response` and `*publr.Host.Context` (no longer `publr.http`'s). Who sent the
  request is `try context.caller(request, response)`, a `*publr.Ctx` (it replaces
  `publr.plugin_routes.caller_context`); the plugin's state is `context.state(Plugin)`
  (it replaces `publr.plugin_states.of`/`from`); `context.set_session(...)` replaces
  `publr.plugin_routes.set_session`. A query or form field is `request.query_param(arena,
  name)` / `request.form_field(arena, name)`. `request.method()` answers `std.http.Method`
  (`.POST`); statuses are `std.http.Status`.
- `bootstrap` runs with `*publr.Ctx`, as the system.
- A sign-in provider's `from_request.read` and `new_member` take `*publr.Ctx`.
- A delivery gate's `Delivery.ctx` is `*publr.Ctx`, `visitor` is a caller view
  (`visitor.user_id()`, `visitor.signed_in()`).
- A policy is `fn (who: publr.Host.PolicyView, request: publr.Host.PolicyRequest) publr.Host.PolicyGrant`: the
  caller's view (`has_role`, `device`, `signed_in`), the call (`operation_name`, `kind`,
  `type_id`, `open`, `own_type`, `nested`, `delivery`), and its answer (`decision`,
  `read_only`, `types`, `own_only`, `live_only`, `public_types_only`).
- `before_command` takes `*publr.Host.Command`; `serving` takes `publr.Host.Serving`,
  whose `state(Plugin)` replaces `serve.project.plugin_states`.
- A `State`'s `init` takes `publr.Host.Process`; its `runtime` is Publr's own.
- `admin_brand` is `fn (ctx: *publr.Ctx) publr.Error!publr.Host.AdminBrand`; `sign_in_at`
  is `fn (ctx: *publr.Ctx, wanted: []const u8) anyerror!?[]const u8`, `wanted` being the
  admin page asked for.
- `publr.Database` has no `*db.Db` field and `prepare` answers a `publr.Host.Statement`
  (`bind_*`, `step`, `read`, `read_int`, `exec`, `reset`, `finalize`).

```zig
// Before
fn ping(request: *publr.http.Request, response: *publr.http.Response, ctx: *publr.http.Context) publr.http.Error!void {
    const found = try publr.plugin_routes.caller_context(request, response, ctx) orelse return;
    const state = publr.plugin_states.from(publr.project.Project.of(ctx).plugin_states.?, Plugin);
// After
fn ping(request: *publr.Host.Request, response: *publr.Host.Response, ctx: *publr.Host.Context) publr.Host.HttpError!void {
    const found = try ctx.caller(request, response) orelse return; // *publr.Ctx
    const state = ctx.state(Plugin);
```

### `sdk:field`

A field's overrides in `record.define`'s `.fields` (and a `.register_fields` group's) are
read in their own public shape, `publr.field.Overrides`, with its parts
`publr.field.Validation`, `publr.field.Options` and `publr.field.Visibility`; core makes them
into its stored field definition. What a plugin writes is the same, every option included,
except `.visibility.plugin`: the plugin a restricted field belongs to is set by core, and a
plugin naming it fails the build. Leave it out:

```zig
// Before
.notes = .{ .visibility = .{ .restricted = true, .plugin = "quotes" } },
// After
.notes = .{ .visibility = .{ .restricted = true } },
```

### `sdk:Ctx`

`publr.Ctx` is declared once (`src/publr/ctx.zig`), the same type compiled in and installed,
and it has no fields: Publr hands a plugin a `*publr.Ctx`, a plugin never makes or reads
into one. Compiled in, `ctx.inner` (core's context) is gone; so is building a `publr.Ctx`
from a core context. Every call a plugin makes is a method, the same either way it runs.
`ctx.call_value(name, value)` now works compiled in too; `ctx.call_json`, `read_shaped` and
`call_shaped` are Publr's own and no longer on `Ctx`. `ctx.database()` is still for a
built-in plugin's tables: an installed build that calls it does not compile.
`publr.plugin.PluginCtx`, `HostApi` and `SandboxApi` are not the plugin's to name: take
`*publr.Ctx`.

A built-in plugin reads the state it keeps (`host.state`) with `ctx.state(Plugin)`.

```zig
// Before
const port = publr.plugin_states.of(ctx.inner, Sampler).port;
const plugin_ctx: publr.Ctx = .{ .inner = ctx };
try publr.sdk.stored_roles.exists(ctx.inner, role);
fn complete(ctx: *publr.plugin.PluginCtx, request: ai.Request) publr.Error!ai.Response
// After: take the `*publr.Ctx` Publr hands over; no core context behind it
const port = ctx.state(Sampler).port;
fn complete(ctx: *publr.Ctx, request: ai.Request) publr.Error!ai.Response
```

### `sdk:Ctx.caller`

`ctx.caller()` no longer carries `raw` (core's caller). Read the account and roles from the
view itself.

```zig
// Before
const account = ctx.caller().raw.user_id() orelse "";
const roles = view.raw.roles() orelse &.{};
// After
const account = ctx.caller().user_id() orelse "";
const roles = view.roles() orelse &.{};
```

### `sdk:Ctx.scope`

`ctx.scope()` answers `publr.Ctx.Scope`, the same type either way: `leave`, `keep` and `end`
as before. Its fields are Publr's own (`outer`, and `held`, an opaque handle).

### `sdk:QueueCtx`

`publr.QueueCtx` is one struct (`src/publr/queue_ctx.zig`), no longer
`Queue(Ctx)`; its `base` is the job's `*publr.Ctx`. Every method is as before;
`call_value`, `refuse` and `translate` join them.

### `sdk:ExchangeCtx`

`publr.ExchangeCtx` has no fields (`inner` and `fetcher` were core's): `fetch`, `now`,
`arena`, `print` and `log` as before.

### `sdk:Request`

An app middleware's `publr.Request` no longer has the fields `project`, `app`, `http` and
`identity`; they are behind `seen`, Publr's own. Its methods are as before.

### `sdk:auth`

`publr.auth` holds the sign-in events alone (`SignedIn` through `IdentityRefused`).
`unrefusable`, `refused` and `before_refused`, core's lists of the events a `before` hook may
not hear, are no longer in it; a plugin never needed them. Hook the events as before.

### `sdk:messaging`

`publr.messaging` holds what a plugin sends and a provider implements: the events, `Message`,
`Attachment`, `Stream`, `Header`, `Feedback`, `Channels`, `Send` and `contract`. Core's
delivery (`deliver`, `hooks`, `signed`, `carries_media`, `carries_own_files_only`,
`channel_len_max`) is no longer in it. A test that hands a message to the providers itself
reaches core's delivery until a public testing harness replaces it:

```zig
// Before
const id = try publr.messaging.deliver(&ctx, message);
// After
const id = try publr.sdk.messaging.deliver(&ctx, message);
```

### `sdk:published`

`publr.published` holds what a plugin's `@import("<plugin>")` is made of: `Interface`,
`Contract`, `Part` and `contracts`. `of`, `check`, `declared_count` and
`branches_per_declared`, the build's, are no longer in it; a plugin never called them.

### `sdk:operations.money`

`publr.operations.money` is the public file of the money operations' shapes, no longer
core's whole `operations/money.zig`. `Text`, `Texts` (with `Texts.amounts_max`), `Main` and
`Read` keep their names, inputs and answers, and calls are unchanged, as does the
`namespace` descriptor. Gone from it: the `operations` list and each operation's `run`,
which are core's.

Before: `publr.operations.money.operations`, `publr.operations.money.Text.run(...)`.
After: call the operation, `ctx.call(publr.operations.money.Text, .{ .amount = price })`.

### `sdk:operations.heartbeat`

`publr.operations.heartbeat` is the public file of the heartbeat operation's shape, no longer
core's whole `operations/heartbeat.zig`. `Check`, `version`, `echo_len_max` and `namespace`
stay; calls are unchanged. Gone from it: the `operations` list and `Check.run`, core's.

Before: `publr.operations.heartbeat.Check.run(...)`.
After: `ctx.call(publr.operations.heartbeat.Check, .{})`.

### `sdk:operations.status`

`publr.operations.status` is the public file of `status.list`'s shape. `List` and
`namespace` stay; `List.Out`'s statuses and transitions are `publr/model/status.zig`'s
`Status` and `Transition`, the same fields. Gone from it: the `operations` list,
`List.run` and core's helpers `added_statuses`, `drafts_waiting`, `known`, `find`, `find_in`
and `is_live`.

Before: `publr.operations.status.is_live(ctx, id)`.
After: read `ctx.call(publr.operations.status.List, .{})` and its statuses' `live`.

### `sdk:operations.request`

`publr.operations.request` is the public file of `request.read`'s shape. `Read`, `Touch`,
`namespace` and the new `Value` (a parameter or a cookie, before core's own) stay or come;
calls are unchanged. Gone from it: the `operations` list and `Read.run`.

### `sdk:operations.clock`

`publr.operations.clock` is the public file of `project.clock` and `project.set_clock`'s
shapes. `Clock` and `SetClock` keep their inputs and answers. Gone from it: the `operations`
list, each `run`, `offset_key` and `site_ms`, core's; a plugin reads the site's time with
`ctx.now()`.

### `sdk:operations.sign_in`

`publr.operations.sign_in` is the public file of `user.sign_in` and `user.sign_out`'s shapes.
`SignIn` and `SignOut` keep their inputs and answers. Gone from it: the `operations` list,
each `run` and `session_id_len`.

### `sdk:operations.mail`

`publr.operations.mail` is the public file of `mail.send`'s shape. `Send`, `namespace`,
`recipients_max`, `message_bytes_max` and the new `Security` (what `Send.In.security` is)
stay or come. Gone from it: the `operations` list, `Send.run`, `not_allowed` and `smtp`,
core's SMTP client.

Before: `publr.operations.mail.smtp.Security`. After: `publr.operations.mail.Security`.

### `sdk:operations.link`

`publr.operations.link` is the public file of the signed-link operations' shapes. `Sign`,
`Verify`, `RevokeAll`, `namespace` and the limits `subject_len_max`, `intent_len_max` and
`token_len_max` stay. Gone from it: the `operations` list, each `run`, `key_setting` and
`verified`; a plugin reads a link back with `ctx.call(publr.operations.link.Verify, ...)`.

### `sdk:operations.sign_on`

`publr.operations.sign_on` is the public file of the trusted sign-in operations' shapes.
`Configure`, `Status`, `Redeem` and `namespace` stay. Gone from it: the `operations` list,
each `run`, the settings' keys (`issuer_key`, `public_key_key`, `audience_key`), the limits
`issuer_len_max` and `audience_len_max`, `vouched_user` and `valid_issuer`.

### `sdk:operations.rail`

`publr.operations.rail` is the public file of the rail pins' operation shapes. `List`, `Pin`,
`Unpin`, `Pinned` and `namespace` stay. Gone from it: the `operations` list, each `run` and
`per_user_max`.

### `sdk:operations.secret`

`publr.operations.secret` is the public file of the secret operations' shapes. `List`, `Set`,
`Remove`, `Digest`, `Listed` and `namespace` stay; `Algorithm` and `Encoding` (what
`Digest.In` takes) come. Gone from it: the `operations` list, each `run`, and core's
`key_variable`, `environment_names_variable`, `value_of`, `is_set`, `Declarer`, `declarers`
and `users_of`. A plugin never holds a secret's value: it writes `{secret:NAME}` where it
goes.

### `sdk:operations.messaging`

`publr.operations.messaging` is the public file of the messaging operations' shapes.
`Feedback`, `Render`, `SetLayout`, `Value`, `List`, `Kind`, `lists_max`, `items_max` and
`namespace` stay. Gone from it: the `operations` list, each `run`, `layout_setting` and
`layout_default`.

### `sdk:operations.apps`

`publr.operations.apps` is the public file of the apps operations' shapes. `Files`, `Read`,
`Write`, `Remove`, `Load`, `Edit` (new here: it was reached only through the list), `Entry`,
`Encoding` and `namespace` stay or come. Gone from it: the `operations` list, each `run` and
`files_max`.

### `sdk:operations.view`

`publr.operations.view` is the public file of the saved views' operation shapes. `List`,
`Get`, `Create`, `Update`, `Delete`, `Saved` and `namespace` stay; `Default`, `SaveDefault`,
`ResetDefault`, `Named`, `Operator` and `Filterable`, the default views', come. Gone from
it: the `operations` list, each `run`, `name_len_max`, `query_bytes_max`, `per_user_max` and
`check_query`.

### `sdk:operations.identity`

`publr.operations.identity` is the public file of the sign-in identity operations' shapes.
`SignIn`, `Configure`, `Status`, `Link`, `List`, `Unlink`, `Providers`, `Input`,
`example_in`, `in_docs` and `namespace` stay; `Summary` and `Offered` come. Gone from it: the
`operations` list, each `run`, `open_sign_up_key`, `identity_of`, `link` and the `providers`
module (its `Providers` and `Offered` are here).

Before: `publr.operations.identity.providers.Offered`.
After: `publr.operations.identity.Offered`.

### `sdk:operations.role`

`publr.operations.role` is the public file of the role operations' shapes and events.
`List`, `Get`, `Create`, `Update`, `Reset`, `Remove`, `Listed`, the events `Created`,
`Updated`, `Removed` and `GrantDropped` with their `Changed`, and `namespace` stay; the
failures `locked`, `only_role` and `given_by_type` come. Gone from it: the `operations` list
and each `run`.

### `sdk:operations.operation`

`publr.operations.operation` is the public file of the operation operations' shapes. `List`,
`Get`, `Authorize`, `Limit`, `Who`, `Rate`, `Described`, `Grouped`, `Failure`, `Hook`,
`Detailed` and `namespace` stay. Gone from it: the `operations` list, each `run` and
`hooks_on`; read an operation's hooks from `ctx.call(publr.operations.operation.Get, ...)`.
### `sdk:operations.snapshot`

`publr.operations.snapshot` is the public file of the snapshot operations' shapes, no longer
core's whole `operations/snapshot.zig`. `List`, `Get`, `Take`, `Restore`, `Prune` and `Item`
keep their names, inputs and answers, as does the `namespace` descriptor; calls are
unchanged. Gone from it: the `operations` list and each operation's `run`, which are core's.

Before: `publr.operations.snapshot.Take.run(...)`.
After: call the operation,
`ctx.call(publr.operations.snapshot.Take, .{ .id = id, .kind = "order.completed" })`.

### `sdk:operations.flow`

`publr.operations.flow` is the public file of the flow operations' shapes. `Get`,
`Authorize`, `Add`, `Remove`, `SetOn`, `AddStatus`, `RemoveStatus` and the `Status`,
`Transition` and `Flow` they answer keep their names and fields, as does `namespace`; calls
are unchanged. Gone from it: the `operations` list and each `run`.

### `sdk:operations.content_type`

`publr.operations.content_type` is the public file of the content type operations' shapes.
`Create`, `Update`, `Get`, `List`, `Delete`, `Validate`, `Summary`, `Problem` and
`example_definition` keep their names, as does `namespace`. Gone from it: the `operations`
list, each `run`, and core's readers `find`, `find_raw`, `visible`, `visible_type` and
`brief_of`; call `content_type.get` or `content_type.list` instead.

`Get`'s answer holds the definition as JSON (`publr.operation.Json`), as `Create` and
`Update` take it, no longer core's own definition type: what REST, the CLI and MCP answer is
unchanged.

Before: `const got = try ctx.call(publr.operations.content_type.Get, .{ .type = "post" });`
then `got.definition.fields`.
After: read the fields you need from it in your own shape,
`const Fields = struct { fields: []const struct { name: []const u8 } };` then
`const def = try got.definition.as(Fields, arena);`.

### `sdk:operations.taxonomy`

`publr.operations.taxonomy` is the public file of the taxonomy operations' shapes. `Create`,
`Update`, `Get`, `List`, `Delete`, `Validate`, `Summary`, `Problem` and `example_definition`
keep their names, as does `namespace`. Gone from it: the `operations` list, each `run`, and
`find`, `visible`, `visible_type` and `brief_of`. `Get`'s answer holds the definition as
JSON, as `content_type.get`'s does (above).

### `sdk:operations.internal`

`publr.operations.internal` is the public file of the internal-record operations' shapes and
events. `Create`, `CreateMany`, `Get`, `Save`, `SaveMany`, `FindOne`, `Find`, `Count`,
`Delete`, `Sum`, `HoldsUntil`, `Item`, `example_id`, `example_document`, the events
`Created`, `Saved` and `Deleted` with their `Changed`, and `namespace` stay; `example_item`
comes. Calls are unchanged. Gone from it: the `operations` list, each `run`, and core's
`many_max`, `clear_max`, `Target`, `drawn`, `drawn_matched`, `matching`, `scope_of`,
`reaches_other` and `TestProject`.

Before: `publr.operations.internal.Find.run(...)`.
After: `ctx.call(publr.operations.internal.Find, .{ .kind = "cart" })`.

### `sdk:operations.ledger`

`publr.operations.ledger` is the public file of the ledger operations' shapes and the
`ledger.expired` event. Every operation (`Open` through `Check`), `Step`, `StepAction`,
`HolderKind`, `Done`, `Shown`, `Line`, `Sum`, `AccountView`, `UnitLine`, the `BalanceOut`,
`HistoryOut` and `AccountsOut` answers, `Expired` and `namespace` stay; `Side`, `Differing`
and `ExpiredPayload` come. Gone from it: the `operations` list, each `run` and
`expire_job`, core's job voiding a hold at its expiry.

### `sdk:operations.device`

`publr.operations.device` is the public file of the device operations' shapes. `Start`,
`Offer`, `approve_path`, `example_device_code`, `namespace` and the `people` (`Request`,
`Approve`, `Deny`, `List`, `Update`, `Revoke`, `Item`) and `oauth` (`Authorize`, `Exchange`)
sub-namespaces stay; `Poll`, `Claim` and `Redeem` come. Calls are unchanged. Gone from it:
the `operations` lists, each `run`, and core's `device_code_bytes`, `device_code_len`,
`hash_of`, `Stored`, `insert`, `people.recently_used`, `oauth.sent_back` and
`offer.offered_name`.

Before: `publr.operations.device.people.recently_used(ctx, 5)`.
After: `ctx.call(publr.operations.device.people.List, .{ .all = true })`.

### `sdk:operations.ai`

`publr.operations.ai` is the public file of the conversation operations' shapes. `Ask`,
`Reply`, `Get`, `List`, `Stop`, `Conversation`, `Step`, `Pointed`, `steps_page`,
`example_id`, `example_prompt`, `example_conversation` and `namespace` stay; the agent's,
the providers', the set-up's, the browser's and speech's operations (`Begin`, `Record`,
`Finish`, `Providers`, `Choose`, `Catalog`, `SetUp`, `Test`, `Ready`, `Browse`, `Browsed`,
`Answer`, `Progress`, `Draft`, `Doing`, `Transcribe`) and what they answer (`Said`,
`Listed`, `Offered`, `Pending`) come. Gone from it: the `operations` list, each `run`, the
`live` module, and core's `bootstrap`, `connected`, `person_of`, `own` and
`conversation_of`.

Before: `publr.operations.ai.live.Draft`. After: `publr.operations.ai.Draft`.

### `sdk:ai.Progress`

`publr.ai.Progress` is the shape of `ai.progress` alone; its `run`, core's, is gone from it.
A provider calls it as before: `ctx.call(publr.ai.Progress, .{ .words = words })`.

### `sdk:operations.plugin`

`publr.operations.plugin` is the public file of the plugin operations' shapes. Every
operation (`List`, `Upload`, `Add`, `Enable`, `Get`, `Disable`, `Update`, `CancelUpdate`,
`Rollback`, `GrantRequest`, `Revoke`, `Deny`, `SetGrant`, `Remove`, `Data`, `EraseData`,
`RestoreData`, `LeftBehind`, `Interfaces`, `Labels`, `Surface`, `Fits`), `Choice`,
`Request`, `Summary`, `Detail`, `Added`, `Piece`, `Fate` and `namespace` stay; `Mode`,
`Left`, `Log`, `Scaffold`, `Find` and `Install` come. Calls are unchanged. Gone from it:
the `operations` list, each `run` and `contracts`, core's reading of the plugins' remotes.

### `sdk:operations.http`

`publr.operations.http` is the public file of the outgoing-request operations' shapes, no
longer core's whole `operations/http.zig`. `Fetch`, `stream` (`Stream`, `Read`), `Header`,
`Basic`, `FormPart`, `headers_max`, `body_bytes_max`, `answer_bytes_max`, `form_parts_max`
and `namespace` stay; calls are unchanged. Gone from it: the `operations` list, each `run`,
`timed` (now `publr.Host.timed`), `stream.Streams` and `stream.streams_max`, and core's
`Fetcher`, `fetch_as`, `fetcher_of`, `guard_of`, `Filling`, the failures `not_allowed`,
`not_queued` and `unreachable_failure`, and the download helpers `Downloaded`, `download`,
`public_host` and `not_public`.

Before: `const timed = publr.operations.http.timed;`. After: `const timed = publr.Host.timed;`.
### `sdk:operations.term`

`publr.operations.term` is the public file of the term operations' shapes. `Create`, `Get`,
`Save`, `Transition`, `Publish`, `List`, `Tree`, `Delete`, `DiscardChanges`, `Purge`,
`Validate`, `Node`, `namespace` and the examples' ids keep their names, inputs and answers;
calls are unchanged. `Term`, `Purpose`, `Order` and `Problem` are the public
`publr/model/document.zig` shapes (`Record`, `Purpose`, `Order`, `Problem`), the same fields.
Gone from it: the `operations` list, each `run`, and core's `domain`, `access`, `document`,
`published`, `has_parents` and `list_max`.

### `sdk:operations.user_type`

New: `publr.operations.user_type`, the shapes of `user_type.list` and `user_type.set`
(`List`, `Set`, `Listed`, `namespace`), callable as
`ctx.call(publr.operations.user_type.List, .{})`.

### `sdk:operations.project`

`publr.operations.project` is the public file of the project operations' shapes. `Init`,
`Status`, `Put`, `impact.Impact` (with `Artifact` and `artifacts_max`), `move_app.MoveApp`,
`namespace`, and `changes.all_records_key` and `changes.all_terms_key` keep their names and
shapes; calls are unchanged. Gone from it: the `operations` list, each `run`, `setup_key`,
and the rest of `changes` (the keys of records, terms and types, the hooks raising them),
which are core's.

### `sdk:operations.user`

`user.get`'s answer holds the custom field groups (`fields`) as JSON (`publr.operation.Json`),
no longer core's own field definitions: what REST, the CLI and MCP answer is unchanged. The
user operations' shapes are defined in `publr/operations/user.zig` (and its `user/` files),
and `publr.operations.user` names that file: every operation, `Summary`, `Link`,
`invitation_path`, `fields`, `language`, `visitors`, `columns`, `types`. Core's functions are
no longer reached through it (`language.person_speaks`, `create_user`, `staff`, `summary_of`
and the rest). The language a person reads, for a message composed in their words, is
`ctx.locale(person).code` (the site's when their account names none): before
`try publr.operations.user.language.person_speaks(ctx, reader)`, after
`ctx.locale(reader).code`.

Before: `got.fields[0].fields`.
After: `const Groups = []const struct { name: []const u8 };` then
`const groups = try got.fields.as(Groups, arena);`.

### `sdk:operations.media`

`publr.operations.media` is the public file of the media operations' shapes. Every operation
(`Upload`, `Add`, `List`, `Get`, `Update`, `Delete`, `Destroy`, `Move`, `Tag`, `File`,
`FolderDelete`, `Sync`, `Read` and those under `import`, `view`, `made`), `Item`, the
sub-namespaces' shapes and limits (`list.Folder`, `edit.Detail`, `edit.ids_max`,
`sync.Skipped`, `read.read_bytes_max`, ...) and `namespace` keep their names; calls are
unchanged. Gone from it: the `operations` lists, each `run`, `bootstrap`, `tags` (core's
folder and tag helpers), and the core helpers of each sub-namespace (`library.row_of`,
`library.save`, `upload.added`, `import.import_job`, ...).

### `sdk:operations.custom_fields`

`publr.operations.custom_fields` is the public file of the custom field operations' shapes.
`List` (with `List.Item`), `Get`, `Update`, `Validate`, `Create`, `Delete`, `Values`,
`SaveValues` and `namespace` stay. Gone from it: the `operations` list, each `run`, and
core's `Destination`.

`Get`'s, `Update`'s and `Create`'s answers hold the schema as JSON (`publr.operation.Json`),
as `Update` and `Create` take it, no longer core's own definition type: what REST, the CLI
and MCP answer is unchanged.

Before: `out.definition.handle`.
After: the group named in the call (`in.group`), or read the fields you need from it in
your own shape, `const def = try out.definition.as(struct { handle: []const u8 }, arena);`.

### `sdk:operations.record`

`publr.operations.record` is the public file of the record operations' shapes. Every
operation (`Create`, `Get`, `Save`, `List`, `Referrers`, `Validate`, `Transition`,
`TransitionAt`, `Unschedule`, `RunScheduled`, `Reschedule`, `Publish`, `DiscardChanges`,
`Delete`, `Purge`, `SaveVersion`, `PublishVersion`, `SaveIntoScheduled`, `TransitionMany`,
`CreateMany`, `DeclineRequest`, `HoldBack`, `Shown`, `Markers`, `Helps`, `Query`, `Reach`),
`Record`, `Purpose`, `Order`, `Problem`, `Referrer`, the examples (`example_id`,
`example_changed_id`, `example_draft_id`, `example_scheduled_id`, `example_document`) and
`namespace` stay; `example_record`, `Title`, `Marker` and `Help` come. Calls are unchanged.
`List.Out.extend` is as before. Gone from it: the `operations` list, each `run`, and core's
`domain`, `access`, `document`, `fixture`, `site_side` and `list_max`.

### `sdk:operations.dimensions`

`publr.operations.dimensions` is gone: it named no operation, only core's readers of the
site's dimensions (`all`, `find`, `expanded`, `values_of`, `main`, ...), which take core's
context, and four names of `publr.dimension`.

Before: `publr.operations.dimensions.Value`, `.Member`, `.Shown`, `.values_max`.
After: `publr.dimension.Value`, `.Member`, `.Shown`, `.values_max`.

### `sdk:operations.design`

`publr.operations.design` is the public file of the design operations' shapes (part of the
part A change, its line switched now). `System`, `SaveSystem`, `Moodboard`,
`SaveMoodboard`, `Item` and `namespace` stay. Gone from it: the `operations` list, each `run` and `bootstrap`, core's.

### `sdk:plugin`

`publr.plugin` holds a plugin's registration and what its options take: `define`, `Role`,
`UserType`, `Limits`, `Page`, `Panel`, `RowAction`, `Blank`, `Translation`, `Grammar` and
`Word`, as before. Core's half of the module is no longer in it: `Bind`, `guest`, `Merged`,
`validate`, the `*_of` readers, `testing`, `state`, `depends_on`, `dimensions`,
`admin_slots`, `types`, `PluginCtx`, `ContentTypeDef`, `InternalCollection`, `Entry`,
`HookIn`, `HookOut` and the `Owned*` shapes. The rest moved before: `Route`,
`OperatorCommand`, `route`, `Process`, `SignInProvider` and `AdminBrand` are
`publr.Host.*`; a test uses `publr.testing.Site`.

```zig
// Before
pub fn route(host: *publr.Host) publr.Error!void { try host.route(publr.plugin.Route{ ... }); }
const Harness = publr.plugin.testing.Harness;
// After
pub fn route(host: *publr.Host) publr.Error!void { try host.route(publr.Host.Route{ ... }); }
var site: publr.testing.Site = undefined;
```

### `sdk:sdk`

`publr.sdk`, core's operation machinery, is no longer in `publr`. The names plugins used
through it are public: `publr.Ctx`, `publr.Error`, `publr.operation.{Json, Kind, Failure,
Problem, Docs, page_limit_max, operations_max, namespace}`, `publr.Deprecated`,
`publr.messaging`, `publr.testing.Site` (for `sdk.testing.Harness`).

```zig
// Before
const Json = publr.sdk.operation.Json;
fn run(ctx: *publr.sdk.Ctx, in: In) publr.sdk.Error!Out
// After
const Json = publr.operation.Json;
fn run(ctx: *publr.Ctx, in: In) publr.Error!Out
```

### `sdk:registry`

`publr.registry` (the registered operations and `SDK.dispatch`) is no longer in `publr`. A
test calls through `publr.testing.Site` (`site.call(Operation, who, in)`, `site.json`); a
built-in plugin finds an operation by name with `publr.Host.find_operation(name)`.

```zig
// Before
_ = try publr.registry.SDK.dispatch(&ctx, Get, .{ .id = id });
// After
_ = try site.call(Get, .admin, .{ .id = id });
```

### `sdk:model`

`publr.model`, core's model files, is no longer in `publr`. What plugins read from it is
public: `publr.role`, `publr.money` (`Entry`, `format`), `publr.currency`,
`publr.dimension` (`Pair`, `split`, `parse`), `publr.device`, `publr.app`,
`publr.sign_on_token`, `publr.files`.

```zig
// Before
const Entry = publr.model.money.Entry;
// After
const Entry = publr.money.Entry;
```

### `sdk:lib`

`publr.lib`, Publr's own libraries, is no longer in `publr`. Use `publr.environment.get`
(for `lib.environment`), `publr.html.escape`, `publr.text`, `publr.Host.timed`.

```zig
// Before
const token = publr.lib.environment.get("TOKEN");
// After
const token = publr.environment.get("TOKEN");
```

### `sdk:http`

`publr.http`, the server's HTTP types, is no longer in `publr`. A route or operator command
takes `publr.Host.Request`, `Response` and `Context`; a query or form field is
`request.query_param(arena, name)` / `request.form_field(arena, name)`; in app middleware
`request.query(name)` / `request.form_field(name)`; a field of a query string held as text
is `try publr.text.query_param(ctx, text, name)`.

```zig
// Before
const code = publr.http.Form.query_param(arena, body, "code") orelse "";
// After
const code = request.form_field("code") orelse "";
```

### `sdk:report`

`publr.report`, the server's error reports, is no longer in `publr`. A built-in plugin
reports through `publr.Host.processes.report_error`; any plugin's failure reaches the Error
log by itself (`publr.errors.Failed`).

### `sdk:store`

`publr.store`, core's SQL, is no longer in `publr`. Read and write core's data through
operations (`ctx.call(publr.operations.<namespace>.<Operation>, in)`); a built-in plugin's
own tables through `ctx.database()`.

### `sdk:cli`

`publr.cli`, the command line's adapter, is no longer in `publr`. A built-in plugin adds a
command with `publr.Host.operator_command`; every operation is a command already.

### `sdk:server`

`publr.server`, the server's modules, is no longer in `publr`. What a built-in plugin
reaches of the server is `publr.Host` (routes, middleware, `Serving`, `processes`).

### `sdk:routes`

`publr.routes`, the server's own routes, is no longer in `publr`. A built-in plugin adds
its own with `publr.Host.route`.

### `sdk:rest`

`publr.rest`, the REST adapter, is no longer in `publr`. Every operation is at
`/api/<operation>` already; code calling another Publr uses `publr.api_client`.

### `sdk:plugin_routes`

`publr.plugin_routes` is no longer in `publr`. In a route, who sent the request is
`try context.caller(request, response)` and the session is `context.set_session(...)`
(`publr.Host.Context`).

```zig
// Before
const found = try publr.plugin_routes.caller_context(request, response, ctx) orelse return;
// After
const found = try ctx.caller(request, response) orelse return;
```

### `sdk:plugin_states`

`publr.plugin_states` is no longer in `publr`. A plugin's state is `ctx.state(Plugin)`, in
a route `context.state(Plugin)`, while serving `served.state(Plugin)`.

```zig
// Before
const state = publr.plugin_states.from(publr.project.Project.of(ctx).plugin_states.?, Plugin);
// After
const state = ctx.state(Plugin);
```

### `sdk:plugin_hooks`

`publr.plugin_hooks`, the server's running of plugin hooks, is no longer in `publr`. A
plugin declares hooks with `publr.before`, `publr.after`, `publr.on` and `publr.hook.*`.

### `sdk:admin`

`publr.admin`, the admin adapter, is no longer in `publr`. A built-in plugin's admin pages
use `publr.Host.admin_pages` (`require`, `accept`, `Page.screen`, `ctx()`, `compare`,
`row_actions`, `Page.route_of` for which route of an app draws a URL).

```zig
// Before
const core: *const publr.admin.Session = @ptrCast(@alignCast(session));
const matched = core.project.find(app_name).?.program.?.match(url);
// After
const pattern = page.route_of(app_name, url);
```

### `sdk:project`

`publr.project`, the server's running project, is no longer in `publr`. A plugin's state is
`ctx.state(Plugin)`; another copy's database is `publr.Host.Process.databases()`.

### `sdk:split`

`publr.split`, the server's admin-origin split, is no longer in `publr`; a plugin never
needed it.

### `sdk:apps`

`publr.apps`, the apps adapter, is no longer in `publr`. An app's middleware takes
`publr.Request` and answers `publr.Response`; a hook on apps loading is
`publr.after(publr.AppsLoaded, run)`.

### `sdk:template`

`publr.template`, the template compiler, is no longer in `publr`; a plugin never needed it.
Pages are `.publr` templates in an app; a plugin's own pages are views
(`publr.views.render`).

### `sdk:serve`

`publr.serve` is no longer in `publr`. A built-in plugin hears the server start through
`publr.Host.Serving` (`served()`: `system`, `reload_apps`, `set_session_cookie`).

### `sdk:build`

`publr.build`, the static build, is no longer in `publr`; a plugin never needed it.

### `sdk:plugin_sdk`

`publr.plugin_sdk` (`publr plugin sdk`) is no longer in `publr`; it is a command.

### `sdk:plugin_build`

`publr.plugin_build` (`publr plugin build` and `prepare`) is no longer in `publr`; it is a
command.

### `sdk:plugin_check`

`publr.plugin_check` (`publr plugin check`) is no longer in `publr`; it is a command.

### `sdk:operator`

`publr.operator`, the operator's commands, is no longer in `publr`. A built-in plugin adds
one with `publr.Host.operator_command`.

### `sdk:database`

`publr.database` (`publr db`) is no longer in `publr`; it is a command. A built-in plugin's
own tables are `ctx.database()` (`publr.Database`).

### `sdk:bundle`

`publr.bundle`, a site's archive, is no longer in `publr`; it is the `publr site` commands.

### `sdk:gate_backup`

`publr.gate_backup`, the backup before an update, is no longer in `publr`; a plugin never
needed it.

### `sdk:update`

`publr.update`, updating Publr, is no longer in `publr`; it is `publr upgrade` and the
operations `publr.operations.update`.

### `sdk:agents`

`publr.agents`, the agents' guide, is no longer in `publr`. A built-in plugin hands it out
with `publr.Host.agents_guide`.

### `sdk:apps_load`

`publr.apps_load` (`publr apps load`) is no longer in `publr`; a hook on apps loading is
`publr.after(publr.AppsLoaded, run)`.

### `sdk:seed`

`publr.seed`, a new site's first records, is no longer in `publr`; a plugin's own first
records are made by its `bootstrap` (`publr.Host.bootstrap`).

### `sdk:clone_pack`

`publr.clone_pack`, `publr clone`'s packing, is no longer in `publr`; it is a command.

### `sdk:queue_worker`

`publr.queue_worker` (`publr queue-run`) is no longer in `publr`. A plugin queues work with
`ctx.enqueue(Job, in)` and `publr.job.define`.

### `sdk:queued_jobs`

`publr.queued_jobs`, the queue's passes, is no longer in `publr`. A plugin queues work with
`ctx.enqueue(Job, in)`; a test runs it with `site.drain()` (`publr.testing.Site`).

### `sdk:agent_script`

`publr.agent_script`, the agent's script runner, is no longer in `publr`; a plugin never
needed it.

### `sdk:agent`

`publr.agent` (`publr agent`) is no longer in `publr`; it is a command.

## 0.8.4 (2026-11-26)
