# Changing Publr core

Core may change only to become more generic: a capability every kind of project could use,
or an extension point that lets a plugin do what it could not. Every change is a pull
request to `publr-org/publr`. The app never depends on a core it edited in place.

## 1. Prove core is the only way

Write down, before touching core:

- **What the app needs**, in one sentence.
- **Why each lower rung fails:** it does not exist (you checked `--help` and the docs),
  it cannot be data, a template cannot do it, and a plugin cannot do it because of a
  specific missing capability or closed list in core. Name the file and the limit.

If you cannot name the specific limit, it is not a core change. Go back to the plugin.

## 2. The generic test

The change must pass **all** of these. When in doubt, it fails.

1. **No app in it.** It makes sense in a Publr install with no plugins and none of your
   app's concepts. It names no product or business idea: no spaces, plans, tenants,
   customers, verification, orders, subscriptions.
2. **Two apps, two uses.** You can describe a second, unrelated app using it differently.
3. **Smallest thing that unblocks.** Prefer a hook or an extension point over a feature,
   and opening a closed list over adding your entry to it.
4. **Core's own rules.** It follows `CLAUDE.md` and `.claude/STYLE.md` of the Publr repo
   and passes `zig build verify` there.

Red flags that mean the change belongs in a plugin:

- Adding your operation, error, status or setting to a list in core.
- A comment in core that mentions your app, or core code that only your plugin calls.
- An error or HTTP status only your app returns.
- Behaviour switched on for your deployment (a mode, a flag) rather than a hook that any
  plugin can use.

## 3. Split a need that is only partly generic

Most needs have a generic half and an app half. Core gets the smallest generic half,
usually a hook; the plugin gets the rest.

**Worked example.** A project wants unverified accounts' projects visible only to
signed-in people ("preview mode").

- Wrong: a `project.set_preview` operation, a preview setting and a "This project is in
  preview" page in core. Preview is the app's product rule.
- Right: core offers one hook, "before delivering a page or island, ask the plugins
  whether this visitor may see it". The app's plugin implements preview on top: its
  setting, its operation, its page. Another app uses the same hook for a paywall or a
  members-only area.

Other shapes of the same move:

- A plugin needs its own error: core lets plugins declare errors (name, HTTP status,
  message) instead of adding the app's error to core's set.
- A plugin needs a secret: core offers a read of the environment to compiled-in code
  (sandboxed plugins get secrets only through the gateway, once the core allows it),
  not a setting holding the key.

## 4. Search before you write

Look for an existing issue or pull request in `publr-org/publr` covering the same limit.
If one exists, add your use case to it (and your patch, if theirs is missing a piece)
instead of opening another. Duplicates for the same gap are the main cost of this process.

## 5. Make the change

- Branch from the exact Publr version the app pins; keep the change in its own commits,
  touching only core.
- Include tests and documentation (the relevant `docs/*.md`, and operation docs for any
  new operation). Run `zig build verify` in the Publr repo.
- Keep it minimal: no refactors, no drive-by fixes. Those are separate pull requests.

## 6. Open the pull request

Title: what core can now do, not what your app does. Body:

```markdown
## What core could not do
<the specific limit: file, list or missing capability>

## The generic capability
<what this adds, in terms any site could use>

## Two uses
1. <your app's use>
2. <an unrelated app's use>

## Why not a plugin
<why the extension point has to be in core>

## Alternatives considered
<smaller or different shapes, and why not>
```

Opening the PR needs the user's GitHub account: ask them before pushing or opening it,
and never send their code or data anywhere else.

## 7. Until it is merged

- The app builds against the PR's branch at a pinned commit (in `build.zig.zon`), never
  against a core edited inside the app's checkout.
- The app-specific half lives in the app's plugin, so dropping the core patch later only
  means bumping the pin.
- If review changes the shape, adapt the app to what is merged. If it is rejected, the
  app goes back to what released core allows, and the gap is recorded in the app's
  README.
- When a release contains it, move the pin to the release and delete the branch
  reference.

## On Publr Cloud

A Publr Cloud project is its own Publr instance, the same as a self-hosted one: its owner
may add compiled-in plugins and change core. Every rule above applies unchanged, for the
same reason: a project whose core is edited in place stops taking Publr's updates. What
Cloud keeps out of the instance's reach is the platform around it (routing, isolation
from other projects, resource limits, the rules of the owner's plan), so nothing inside
the project needs to be protected from its own owner. Never try to work around those
limits from inside the project.
