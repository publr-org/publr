---
name: build-on-publr
description: Build on Publr (a site and app platform run by one `publr` binary): content types, plugins with operations and roles, apps with .publr templates, on a project here or on a Publr elsewhere (self-hosted or Publr Cloud). Use whenever the task is to make something with Publr rather than to work on Publr itself, including when the work seems to need a change in Publr core: this skill decides whether core may change and how (only generic extension points, always as a pull request to publr-org/publr).
---

# Building on Publr

Publr is a small core plus everything else as plugins on the same SDK a third party uses.
A project is **content** people manage in the admin, **plugins** (content types,
operations, roles: what is stored and done) and **apps** (what people use at an address:
templates read at runtime, never compiled). It is never a modified core.

## Start here, every time

1. **Use the site's own binary.** A site is a folder `publr` runs in (`publr.zon`,
   `apps/`, `plugins/`, `data/publr.db`); run every command from it. Its binary is the one
   its `publr.zon` names in `.binary`, else the first of `./publr`, `../publr`,
   `./zig-out/bin/publr`, `../zig-out/bin/publr` that exists: sites sit beside a shared
   binary (`sites/publr`, `sites/blog/`), and a Publr checkout is a site with its own
   build. Every `publr` in this skill and in the guide means that binary, by its path.
   Never a `publr` on the PATH. With none found, ask; `./publr new <name>` beside a binary
   makes a new site.
2. **Read the guide the binary carries:** `publr agents`. It describes
   exactly the Publr in front of you (its SDK, its permissions, how plugins and apps are
   built), so where it and this skill differ, it wins. Read it whole before changing
   anything.
3. **Find where the project runs.**
   - Here: `publr agents` ends by saying whether this site's server runs and at which
     address (what to open in a browser). If none runs, start `publr serve` once. While it runs, every other command from this folder
     goes to it: no address or flag needed.
   - Elsewhere (a server, Publr Cloud): `publr login <address>` prints a link its owner
     approves in that Publr's admin; then `publr --site <address> <command>`. Never ask for a password or a token.
4. **Plan before code.** Say what the people running the site will see in the admin and
   what visitors will see. Agree it with the person you work for.

## Decide where each need goes

Walk this ladder for every requirement. Stop at the first rung that works.

1. **It already exists.** `publr --help`, `publr <namespace> --help`, `publr <namespace>
   <verb> --help`, and the plugins installed (`publr --as-admin plugin list`).
2. **It is content.** A content type, a field, a settings type: declared in a plugin and
   edited in the admin. Never a table of your own.
3. **It is a page.** A template in an app, a dynamic island for what is per visitor. A new
   frontend is a new app in the same project.
4. **It is behaviour.** An operation in a plugin, built with `publr plugin build`. What an
   app's visitors call is `app.<plugin>.<verb>`; what the admin's people call is
   `<plugin>.<verb>`.
5. **Only core can make it possible.** A missing capability or extension point, never a
   missing feature of your project. Name the gap to the person, then follow
   [references/core-changes.md](references/core-changes.md).

Most needs stop at 2, 3 or 4. Reaching rung 5 is rare and must be justified in writing.

## Never

- Edit Publr core to make the project work, or ship a patched copy of it.
- Grant a plugin a permission yourself, or approve anything for the person: they approve
  in the admin. Finish by saying what waits and where.
- Delete anything for good on someone's behalf (a content type, a user, a plugin, records
  purged). A device is refused it anyway; say what should go.
- Keep a secret in the database, an app, a plugin's source or the repository.
- Weaken a check, a test or a permission to make something pass.

## Checklist before finishing

- [ ] Every requirement sits on the lowest rung of the ladder that works.
- [ ] No file of Publr core changed, or each change is a pull request per
      [references/core-changes.md](references/core-changes.md).
- [ ] The rules in `publr agents` ("How to build well") hold for every plugin and app.
- [ ] Every operation documented; a call without permission is denied and changes nothing.
- [ ] The admin and the pages match what was agreed, checked in a browser.
- [ ] What waits for the person (permissions, drafts to publish) is listed for them.
