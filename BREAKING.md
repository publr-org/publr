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

## 0.8.4 (2026-11-26)
