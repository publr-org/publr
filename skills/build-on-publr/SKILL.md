---
name: build-on-publr
description: Build an app or site on top of Publr (a CMS in Zig): content types, custom fields, operations, policies, themes with .publr templates and PTSX components, compiled-in plugins, tests and deployment. Use whenever the task is to make something with Publr rather than to work on Publr itself, including when the app seems to need a change in Publr core: this skill decides whether core may change and how (only generic extension points, always as a pull request to publr-org/publr).
---

# Building on Publr

Publr is a small core plus everything else as plugins that use the same SDK a third
party would. An app is **data** (content types, fields, settings), **operations**
(behaviour, in a plugin), **policies** (who may do what) and a **theme** (pages). It is
never a modified core.

## The one rule

**The app's code lives in the app. Core changes only to become more generic, and only
through a pull request.** Your app must keep working when the user updates Publr. A core
edited in place breaks on the next update, and core code that names your app's concepts
never gets merged. When core truly lacks something, follow
[references/core-changes.md](references/core-changes.md) exactly.

## Decide where each need goes

Walk this ladder for every requirement. Stop at the first rung that works.

1. **It already exists.** Check before building: `publr --help`, `publr <namespace>
   --help`, `publr <namespace> <verb> --help`, and the docs in the Publr checkout
   (`docs/sdk.md`, `docs/plugins.md`, `docs/site.md`, `docs/cli.md`, `docs/content.md`).
2. **It is data.** A content type, a field, a custom field group on users, a settings
   type. Declare it in the plugin; never hand-write tables.
3. **It is a page.** A template in the theme (`content/`, `layouts/`, `components/`),
   an island, or an interactive PTSX component using PublrJS and `@publr/ui`.
4. **It is behaviour.** An operation in the app's plugin, gated by the plugin's policy.
   Prefer the public SDK only, so the plugin could one day run sandboxed.
5. **Only core can make it possible.** A missing capability or a missing extension
   point, never a missing feature of your app. Go to
   [references/core-changes.md](references/core-changes.md).

Most needs stop at 2, 3 or 4. Reaching rung 5 is rare and must be justified in writing.

## Workflow

1. **Model the app before writing code.** List the content (types and fields), the
   people (roles, what each may see and change), the pages (public, per-visitor, admin),
   the actions (each becomes an operation) and the outside services (email, payments).
2. **Lay out the app** as in [references/app-layout.md](references/app-layout.md): its
   own repository, Publr pinned as a dependency, `plugins/<app>/` and `themes/<app>/`.
3. **Data first:** declare content types, custom fields and settings types in the plugin.
4. **Operations and policies:** one operation per action, fully documented (description,
   details, kind, examples, field docs), its access decided by the plugin's policy.
5. **Theme:** pages that read only `Publr.build` are static; anything per visitor is
   `.dynamic.publr`. Interactive parts are PTSX with PublrJS and `@publr/ui`, never
   hand-written DOM scripts.
6. **Tests next to the code**, with `sdk.testing.Harness`; outside services behind a fake
   (an outbox file for email, a local socket for a daemon).
7. **Build and check:** `zig build` (it also compiles the theme and fails on any template
   error), `zig build test`, and try the app end to end in a browser.
8. **Before finishing, run the checklist below.**

## Never

- Edit Publr core in the app's checkout to make the app work, or vendor a patched core.
- Put the app's names, errors, statuses, settings or lists into core.
- Import core internals (`publr.store`, `publr.lib`, adapters) from a plugin when the SDK
  covers it. A compiled-in plugin that must, says why in a comment and files an issue.
- Keep secrets in the database, the theme or the repository. Compiled-in plugins read
  them from the environment (`publr.lib.environment`); a sandboxed plugin never does.
- Weaken tests, tidy rules or policies to make something pass.

## Checklist before finishing

- [ ] Every requirement sits on the lowest rung of the ladder that works.
- [ ] No file of Publr core changed, or each change is a PR per core-changes.md, and the
      app builds against a pinned commit of it.
- [ ] Every operation documented; every write is reachable only by those who may.
- [ ] `zig build` and `zig build test` pass; the app was exercised in a browser.
- [ ] No secret in the repository; `.env*` ignored.
- [ ] The app's README says how to run, test and deploy it.
