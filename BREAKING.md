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
`Read` keep their names, inputs and answers, and calls are unchanged. Gone from it: the
namespace's `namespace` and `operations` list and each operation's `run`, which are core's.

Before: `publr.operations.money.operations`, `publr.operations.money.Text.run(...)`.
After: call the operation, `ctx.call(publr.operations.money.Text, .{ .amount = price })`.

## 0.8.4 (2026-11-26)
