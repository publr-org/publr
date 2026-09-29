# Plugins

Publr has two ways to run a plugin. Both use the same SDK. The difference is
where the plugin lives and who decides that it is there: every plugin is either
**built-in** (compiled into the binary, locked: it cannot be disabled) or **installed**
(loaded at runtime into the sandbox: enabled, disabled and removed from the admin). The same
source builds either way. In the code a plugin's mode is `native` or `sandboxed`, and what
its operations and hooks take (`*PluginCtx`) is `HostApi` for a native one (direct calls,
full access) or `SandboxApi` for a sandboxed one (every call a message to the host).

```mermaid
flowchart LR
    subgraph Binary["Publr binary"]
        Core[Publr core]
        CI1[Built-in plugin]
        CI2[Built-in plugin]
    end
    subgraph Sandboxes["WebAssembly sandboxes"]
        subgraph S0["sandbox"]
            SDK[SDK proxy]
        end
        subgraph S1["sandbox"]
            RP1[Installed plugin]
        end
        subgraph S2["sandbox"]
            RP2[Installed plugin]
        end
    end
    Core --- CI1
    Core --- CI2
    Core <--> SDK
    SDK <--> RP1
    SDK <--> RP2
```

## Built-in plugins

A built-in plugin is placed into the Publr binary by a developer or a
build tool. The result is a tailored Publr: one binary with every battery
someone decided to put inside.

From the user's point of view these plugins are core features. They cannot
be disabled, removed or updated from the admin. Updating one means updating
the plugin source and building a new binary.

This is sometimes called **agency mode**: a software agency prepares the
build for a client, so what the client gets is stable, has every feature they
need, and just works. Only a competent operator decides what goes in, which
makes this setup very safe and resilient.

Two things follow from being inside the binary:

- **Full access.** A built-in plugin can reach the whole Publr API and any
  internals. Whoever builds the binary is responsible for checking it.
- **Deep integrations are possible.** Some plugins must be compiled in because
  they need things the SDK does not expose to the outside: swapping the
  database, adding database extensions, replacing the cache layer, and other
  advanced hooks.

A plugin that uses only the public SDK can be shipped both ways: compiled in,
or as an installed plugin.

## Installed plugins (DLP)

Installed plugins are the opposite. They are added from the admin, without
recompiling anything. Think of them as dynamically linked plugins, in the
spirit of DLLs, hence DLP.

```mermaid
flowchart LR
    Core["Publr core (precompiled)"]
    subgraph S0["sandbox"]
        Proxy[SDK proxy]
    end
    subgraph S1["sandbox"]
        P1[Plugin A]
    end
    subgraph S2["sandbox"]
        P2[Plugin B]
    end
    subgraph S3["sandbox"]
        P3[Plugin C]
    end
    Core <--> Proxy
    Proxy <--> P1
    Proxy <--> P2
    Proxy <--> P3
```

Each installed plugin is a precompiled WebAssembly module running in its own
sandbox. It never touches Publr directly: every call goes through the SDK
proxy, which dispatches through the same operation pipeline everything else uses. That gives:

- **An enforced boundary.** The plugin can only do what the SDK exposes and
  what an administrator granted it.
- **Isolation.** A buggy plugin cannot crash Publr or read another plugin's
  memory. A call that loops or grows past its limits stops, and only that call fails.
- **No recompilation.** Install, update or remove a plugin from the admin or
  the CLI, and it just works. Publr stays one binary.

Installed plugins are managed under Settings > Plugins in the admin, and with `publr plugin`
([CLI](cli/plugin.md)). The Built-in tab lists the built-in plugins beside them, read
only: a build puts those there, and only a new build changes them. Added, an installed plugin
is listed and runs nothing; **enabling** it shows what it asks
for and starts it; disabling stops it and keeps what it was granted. What it does, it
does as itself: every call it makes is authorized as the plugin, with the permissions it
holds now. When it acts for someone (an editor calling its operation, a hook on their
save), each call gets the narrower of its permissions and that person's roles.

A newer module for a plugin already there does not replace it: it waits as the
plugin's next version. **Updating** shows what the new version asks for beside what the
plugin holds, then runs it; the version it replaces is kept, and **rolling back** returns
to it (and keeps the other in turn). A module that does not load in the sandbox is never
added.

### Permissions

A plugin asks for permissions by key, each with its own reason. The administrator sees
the sentence, the reason, the key and a tier before enabling it:

| Tier | On enabling | Examples |
|---|---|---|
| Low | granted | `content.read`, `schema.read`, `users.names`, a hook that sees an event |
| Medium | granted, listed | `content.write`, `content.drafts`, `release.manage`, a hook that changes an input |
| High | pending until approved | `users.read`, `users.write`, `content.purge`, `settings.global`, a raised limit |

Some operations no permission names, so no plugin ever reaches them: signing in and out,
passwords and set-password links, who may sign people in, setup, roles, saved views. A
plugin always reaches its own operations (`<name>.*`, `app.<name>.*`) and its own content
types' records without asking. Content permissions are held to its **content access**:
public types (the default), every type, or the ones the administrator ticks.

Anything granted can be revoked at any time, one at a time; the plugin's next call
answers `Denied` and it must carry on without. A key nothing installed provides is shown
as unavailable: the plugin runs without it.

### Limits

Every call into a plugin runs within limits: 100 ms of CPU (counted in instructions),
16 MiB of memory, 1,000 calls of its own, 1 MiB of output. A plugin that needs more asks
in its manifest, with a reason; each raised limit is a high-tier request.

## Writing an installed plugin

An installed plugin is written exactly like a built-in one, against the same SDK, with
`*PluginCtx` operations and hooks. On top, it declares what it asks for:

```zig
pub const permissions = [_]publr.plugin.Permission{
    .{ .key = "users.names", .reason = "Greets the people on the site by name" },
};
pub const limits: publr.plugin.Limits = .{ .cpu_ms = 2000, .reason = "Resizes images" };
pub const content_access: publr.plugin.ContentAccess = .{
    .recommend = .all,
    .note = "Indexes every type for search",
};
pub const requires = [_][]const u8{"newsletter"};
```

Each hook carries its reason (`pub const reason = "..."`); an event hook names the event
it sees (`pub const event = "record.published"`), an operation or a notice. A plugin never
writes `export fn`.

In a project, a plugin's source is `sandboxed-plugins/<name>/main.zig`, and
`publr plugin build --name <name>` builds it with the compiler Publr carries, so no Zig is
needed: its manifest is read from the module itself and written into it, then it is added
and enabled (a new plugin) or applied as its next version (one already there, the previous
kept to roll back to). What it asks for is granted by tier; high requests wait for an
administrator. Built again unchanged, it is up to date. `zig build sandboxed-plugins` builds
every plugin under `-Dsandboxed-plugins` with the same command into
`zig-out/sandboxed-plugins/<name>.wasm`, as the tests build the fixture plugins; see
[Build](build.md#the-plugins).

What a plugin calls is checked as it compiles: a `ctx.call` of an operation that none of
its declared permissions opens fails the build, naming the permission to add ("plugin
peek calls `user.list`, which needs `users.read`"). Its own namespace, the harmless
operations and record operations pass: a record operation may reach its own types, which
need nothing, and one that names another type without a permission is refused when it
runs, as `Denied`.

Not everything a built-in plugin declares runs in the sandbox yet: operations,
before, after and event hooks, content types, custom fields and roles do; a role from a
plugin grants only its own operations. Policies, pre hooks, field kinds, statuses,
filters and delivery gates come later; `schema_sql`, `bootstrap`, sign-in providers and
`native_only` never do. The build says which one stops it.

## Which one to pick

| | Built-in | Installed (DLP) |
|---|---|---|
| Added by | developer or build tool | admin, marketplace, repository |
| Needs a rebuild | yes | no |
| Access | full, trusted | SDK only, within its permissions |
| Isolation | none, it is part of the binary | sandboxed |
| Can be disabled or removed by the user | no | yes |
| Deep integrations (database, cache, ...) | yes | no |
| Uses only the public SDK | works | works |

## Writing a built-in plugin

A plugin is one directory under `native-plugins/` with a `main.zig`. It imports one
thing, `publr`, and declares what it brings: a manifest (name, version,
summary), documented namespaces, operations exactly like the core's, policies,
hooks, statuses, field kinds, content types, roles (see below), delivery gates (who
sees the apps, see [Apps](apps.md#delivery-gates)), filters (a `filters` array of
`model.filter.Definition`: a key, a label, operators, and how a clause constrains the
list; the admin's content list grows a pill for each) and a sign-in provider (see below). `zig build` finds it, compiles it in and
wires it up; nothing is registered anywhere else. Its operations appear in the
CLI and every other adapter, documented like the core's.

Storage is content types and snapshots. A plugin that needs to keep things
declares a type (`pub const content_types = [_]publr.plugin.ContentTypeDef{...}`,
usually private) and works with it through the record operations. The type is
created, or brought up to date, when the database opens, owned by the plugin:
it shows in the types manager as a system type, its declared fields are
locked, and editors can add fields of their own that survive the next
redeclaration. Its records get validation, permissions, listing, filtering
and the admin for free. History goes into
snapshots (`snapshot take/list/prune`, kinds of the plugin's own); parked
copies of a document go into slots (`record get --slot`), like the core's
`pending`. Only a built-in plugin that truly needs its own table
(`native_only`) may ship `schema_sql`.

A plugin can declare roles (`pub const roles = [_]publr.plugin.Role{...}`): a name, a
label and grants, each an operation or a namespace ending in `.*`. A name of its own is
a new role, such as the visitors of an app, granted `app.<feature>.*`; the name of one
there already adds grants to it, so a plugin whose operations editors should call
declares `editor` with `<feature>.*`. Only an admin gives an account a role; a plugin's
open sign-up creates accounts with its own. See [Auth](auth.md#roles).

A plugin can declare one **sign-in provider** (`pub const sign_in_provider:
publr.plugin.SignInProvider`): a name (`github`, in URLs and identity rows), a label
("Continue with GitHub"), its mark as one SVG path on a 24 by 24 canvas (brand marks are
the plugin's, never the icon set's), and three functions: `available`, whether its
credentials are in the environment (an unavailable provider is compiled in but not
offered); `authorize_url`, where to send the browser given the callback URL, the `state`
and the PKCE challenge the core made; and `identity`, which exchanges the callback's
code for who the person is (their stable id at the provider, their email and whether the
provider vouches for it, a name, an avatar). The core does the rest: the routes, the
cookie, the buttons, and whose account it is ([Auth](auth.md#signing-in-with-a-provider)).

A plugin can run once the database opens (`pub fn bootstrap(ctx: *sdk.Ctx) sdk.Error!void`),
as the system, after every declared type and field is in place: a setting the product
needs, a record that must exist. It runs at every start, so it checks before it writes.

A plugin can also keep values on the accounts themselves: `custom_fields` declares
custom field groups the way `content_types` declares types, each with its location
(`destination` user or media). They are created or brought up to date when the database
opens, their fields locked; a template reads the signed-in user's with
`Publr.request.userField('<group>.<field>')`.

The contract is checked when the binary compiles: a missing manifest, a bad
name, an undocumented operation, a hook on an operation that does not exist,
two plugins with the same name, all stop the build with a message naming the
plugin. Plugins are applied in name order, always. Tests live next to the code
and run with `zig build test`. The `native-plugins/` directory is yours: Publr's own
repository does not track it, so a fork can commit its plugins alongside the
core. `-Dnative-plugins=<dir>` builds from another folder instead; a link in it counts,
so one folder can gather plugins kept elsewhere.
