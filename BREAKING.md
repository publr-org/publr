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
