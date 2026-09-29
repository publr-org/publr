# Building on Publr: a guide for agents

You are working in a Publr project for someone. This guide is built into the `publr`
binary they run (`publr agents` prints it), so it describes exactly the Publr in front of
you. Read it whole before changing anything.

## The project

A project is the folder `publr` runs in:

```
data/publr.db                       the database: content, users, installed plugins
plugins/<name>/main.zig             the source of each plugin you write
apps/<name>/                        each app: the pages people see (see Pages); the
                                    project's own `apps/` is read when it has one
```

A feature is usually both: a **plugin** for what is stored and done, and pages in an
**app** that show it.

`publr serve` runs the site and the admin (`http://127.0.0.1:8080/admin`). While it runs,
every other `publr` command is sent to it and takes effect at once: you never restart it.
`publr --help` lists Publr's own commands; installed plugins bring namespaces of their own
(`publr --as-admin plugin list` names the plugins). `publr <namespace> --help` lists a
namespace's commands, either kind, and `publr <namespace> <verb> --help` explains one.

## Plugins

A feature is a **plugin**: a Zig file that declares operations (what can be done) and
content types (what is stored). It runs in a sandbox and can only do what the project's
administrator allowed. This one is complete:

```zig
const std = @import("std");
const publr = @import("publr");

const sdk = publr.sdk;
const PluginCtx = publr.plugin.PluginCtx;
const record = publr.operations.record;

pub const manifest: publr.plugin.Manifest = .{
    .name = "guestbook",
    .version = "0.1.0",
    .summary = "A guestbook visitors sign from the site",
};

pub const namespaces = [_]sdk.operation.Namespace{.{
    .name = "app.guestbook",
    .summary = "What the site's visitors do with the guestbook",
    .details = "`app.guestbook sign` adds an entry, published at once; anyone may call it.",
}};

pub const content_types = [_]publr.plugin.ContentTypeDef{.{
    .handle = "guestbook_entry",
    .name = "Guestbook entry",
    .public = true,
    .title_field = "name",
    .fields = &.{
        .{ .name = "name", .label = "Name", .kind = "string", .required = true },
        .{ .name = "message", .label = "Message", .kind = "string", .required = true },
    },
}};

pub const operations = [_]type{Sign};

pub const Sign = struct {
    pub const name = "app.guestbook.sign";
    pub const description = "Sign the guestbook";
    pub const details = "Anyone may call it. A name is 1 to 80 characters, a message 1 to 500.";
    pub const open = true;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { name: []const u8, message: []const u8 };
    pub const Out = struct { id: []const u8 };
    pub const example: In = .{ .name = "Ada", .message = "Lovely site!" };
    pub const example_out: Out = .{ .id = "3f9c1e0a5b7d2c4e6f8a9b0c" };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "Who signs",
        .message = "What they write",
    };

    pub fn run(ctx: *PluginCtx, in: In, _: *const sdk.Grant) sdk.Error!Out {
        if (in.name.len == 0 or in.name.len > 80 or in.message.len == 0 or in.message.len > 500) {
            return error.Invalid;
        }

        const document = std.json.Stringify.valueAlloc(ctx.arena(), .{
            .name = in.name,
            .message = in.message,
        }, .{}) catch return error.OutOfMemory;
        const created = try ctx.call(record.Create, .{
            .type = "guestbook_entry",
            .document = document,
            .status = "published",
        });

        return .{ .id = created.id };
    }
};
```

- **Names.** An operation is `<namespace>.<verb>`. Use the plugin's name as its namespace
  (`notes.add`) for what the site's people do from the admin or the command line, and
  `app.<name>` (`app.guestbook.sign`) for what the site's visitors call from its pages.
- **Document everything.** Every namespace, operation and field gets its text: an
  operation its `description`, `details` (who may call it, what it changes, how it fails),
  `example`, `example_out` and `field_docs`. `publr <namespace> --help` shows them to the
  people who use the plugin, and to the next agent.
- **State lives in records.** The plugin's instance may be dropped and made again at any
  time; keep nothing in globals.
- **Reach Publr through `ctx.call`,** with an operation's type (`record.Create`,
  `record.List`, `record.Get`, ...): every one `publr --help` lists is there, under
  `publr.operations`. The plugin's own content types and operations need no permission.

## Build, install, change

```sh
publr plugin build --name guestbook
```

This compiles `plugins/guestbook/main.zig` with the compiler inside `publr` (no
Zig needed), then installs it: a new plugin is added and enabled, one already there gets
this as its next version, the previous kept to roll back to. When the compiler reports an
error, fix the source and run it again. To change a plugin, edit it, raise `.version`, and
build again. Built again unchanged, it says it is up to date. When it says it builds
"without" something (a `schema_sql`, an operation that takes the host's context), that part
does not run in the sandbox; calls to it answer unavailable.

Check it:

```sh
publr --as-admin plugin get --name guestbook     # version, what it asked for, what waits
publr guestbook --help                           # a plugin's own commands, when its
                                                 # namespace is not `app.*`
curl -X POST http://127.0.0.1:8080/api/app.guestbook/sign \
  -H 'content-type: application/json' -H 'origin: http://127.0.0.1:8080' \
  -d '{"name":"Ada","message":"hi"}'             # an `app.*` operation, as a visitor
```

## Pages: apps

The site people visit is made of apps: folders of templates, never compiled. An app
answers at a mount and shows what the plugins store.

```
apps/courses/app.zon                      .{ .mount = .{ .path = "/learn" } }
apps/courses/layouts/base.publr           the page around every page
apps/courses/content/index.publr          /learn
apps/courses/content/lessons/[slug].publr /learn/lessons/<slug>, one per lesson
apps/courses/components/*.publr           parts pages import
apps/courses/public/                      files served as they are, at /learn/_app/
```

A template is frontmatter (imports and reads through `Publr`, nothing else) over HTML:

```astro
---
import Base from '../../layouts/base.publr';
const lesson = Publr.build.getEntry({ type: 'lesson' });
const lessons = Publr.build.getCollection({ type: 'lesson', limit: 100 });
---
<Base title={lesson.title}>
  <h1>{lesson.title}</h1>
  <div>{lesson.data.body ?? ""}</div>
  <ul>
    {lessons.map((item) => (
      <li><a href={`/learn/lessons/${item.slug ?? ""}`}>{item.title}</a></li>
    ))}
  </ul>
</Base>
```

- **What a page can read.** Built pages see live records of **public** types only: give
  the plugin's content type `.public = true`, and for pages per record a slug field,
  `.{ .name = "slug", .label = "Slug", .kind = "slug", .options = .{ .source = "title" } }`.
  An entry is `id`, `type`, `slug`, `title`, `created_at`, `updated_at` and `data`, its
  fields (`lesson.data.body`).
- **The body** takes `{value}` (escaped), `set:html={value}` (raw), `{items.map((item) =>
  (...))}`, `{test ? (...) : null}`, and `<Component prop="..." />` with `<slot />`. A
  layout or component reads `props.name`. Anything else is refused, naming the template
  and the construct.
- **Two rules that trip people up.** `a ?? b` falls back to a string only
  (`{lesson.data.body ?? ""}`). Each branch of a conditional is `null` or one element in
  parentheses, never a bare `.map`: wrap it, `{items.length === 0 ? null :
  (<ul>{items.map((item) => (<li>{item.title}</li>))}</ul>)}`.
- **Per request.** A page named `<name>.dynamic.publr` renders for each visitor and may
  read `Publr.request` (`session`, `getCollection`, `call('app.<plugin>.<verb>')` for an
  operation that allows it). A form posts to the plugin's `app.*` operations through
  `/api/<namespace>/<verb>`.
- **Links** are the app's own: an app at `/learn` writes `/learn/...`.
- **Interactive components** (`interactive/*.ptsx`) and `middleware.zig` still need a build
  of Publr: an app of yours has neither. Put code in a plugin.

After changing an app:

```sh
publr apps load
```

The running server reads the apps again and serves the change at once; a template it
refuses is named with the reason, and the apps answer 503 until a load succeeds.

## Permissions: declare, never grant

Anything beyond its own types and operations, a plugin asks for, with a reason:

```zig
pub const permissions = [_]publr.plugin.Permission{
    .{ .key = "content.read", .reason = "Lists the posts on the notes page" },
};
```

The build tells you when one is missing: calling an operation none of the plugin's
permissions opens fails to compile, naming the key to add. `publr agents` ends with every
key there is, its tier, and the operations it opens. Low
and medium ones are granted when the plugin is installed; high ones wait for a person.
**Never grant anything yourself** (`plugin grant`): that decision is the administrator's.
When something waits, finish by telling them what it is, why the plugin needs it, and that
they approve it in the admin under Settings > Plugins. A call the plugin was not granted
answers `Denied`; handle it, so the plugin still works without it.

## Where to read more

- `publr --help`, and `--help` on any namespace or command.
- The SDK's source, as this binary builds plugins against it: `publr agents` ends with
  where it is on this machine. Start at `publr.zig` and `sdk/plugin/`.
