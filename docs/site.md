# The site

Publr serves a public site from a **theme**: a folder of `.publr` templates
whose file structure is the route table. The site is static first: `publr
build` writes every page to a file, `publr serve` serves the files, and every
publish rewrites exactly the files it affects. What must be fresher than a
file is an **island**: a fragment of a page fetched after the page loads,
rendered at build or per request. Templates and generated client code live in the binary. Public files stay on disk: a
site build copies `themes/<name>/public/` into `output/theme/` unchanged.

## The theme

```
themes/default/
  content/                 the routes: one page per file
    index.publr            /
    greetings/index.publr  /greetings
    greetings/[slug].publr /greetings/<slug>, one page per live greeting
    visit.dynamic.publr    /visit, rendered per request
    404.publr              every unmatched path
  layouts/, components/, dynamic/   templates the pages import; the names are the theme's own
  interactive/*.ptsx       PJSX components with client state (optional)
  public/                  served as-is under /theme/ (style.css is prepended to the stylesheet)
  theme.zon                design tokens over the JIT's defaults (optional)
  middleware.zig           runs before every site request (optional; see Middleware)
```

Only `content/` means anything to the engine: its files are pages, and
`[slug]` in a name is a route parameter. Every other folder holds templates a
page imports. `public/` and `interactive/` are not templates. The theme templates are
chosen at build time (`zig build -Dtheme=<name>`, default `default`) and
embedded. A template that does not load fails `publr build`, naming the template
and construct. `publr serve` keeps the CMS and API available even when the public
site cannot load or build; unavailable public pages return a non-cacheable 503.

## A template

A `.publr` file is JS frontmatter over an HTML body with JSX constructs:

```astro
---
import Base from '../../layouts/base.publr';
import LatestGreetings from '../../components/latest-greetings.publr';
const greeting = Publr.build.getEntry();
---
<Base title={greeting.title}>
  <article>
    <h1>{greeting.title}</h1>
    <time>{greeting.created_at}</time>
  </article>
  <LatestGreetings heading="More greetings" island prerender eager />
</Base>
```

The frontmatter is declarative: imports, and constants read through the
Publr API. The body may use `{value}` (escaped by type), `set:html={value}`
(raw), `{items.map((item) => (...))}`, `{test ? (...) : (...)}`, template
literals, and `<Component prop="..." />` with children filling the
component's `<slot />`. A layout or component reads its props as
`props.name`, or in the frontmatter with a fallback, `const mode = props.mode
?? 'card';`. A component that takes a record declares it in the
frontmatter, `const section = props.entry.section;`, and every call site
passes one, `<Section section={item} />`; from there it follows the record's
own references one level down, so a page, its sections and their blocks are
one component per level, never a recursion. In a `{...}` block a conditional
comes first: `{items.length === 0 ? null : (<ul>{items.map(...)}</ul>)}` is a
conditional whose branch loops. Anything outside that subset fails the build
with a message naming the template and the construct.

## The homepage

The homepage is not a page record: every page has page fields, and the homepage has its
own. They live on the **Website** settings singleton (`/admin/settings/website`), which
Publr declares with the fields the theme's homepage renders. An administrator fills them
in and publishes; the route stays the theme's `content/index.publr`.

The homepage reads the published settings from its context:

```astro
---
const home = Publr.context.entry;
const cards = home.data.products;
---
<h1>{home.data.hero_title}</h1>
<ul>{cards.map((card) => (<li>{card.data.title}</li>))}</ul>
```

`Publr.context.entry` supplies the Website singleton at `/`, during static builds and
live rendering, with `title` empty and `data` its published document. A repeater field
read without a fallback (`home.data.products`) is its rows, each an entry with no
identity whose `data` is the row. Ordinary nested layouts/components share that context;
pass the entry as a prop to an island, whose separate render has no page context. Other
routes keep their existing `getEntry()` queries. Themes with a self-contained homepage
need not read it.

A homepage template that reads the context requires published settings. Unpublished
settings stop the build with a diagnostic naming the template and explaining how to fix
it. Publishing the settings invalidates the built homepage through the normal `type:website`
dependency.

For initial setup, `publr serve --static` keeps the admin available even if the settings
are not published yet. Open Settings > Website, fill in the fields and publish, and the
server retries the full build after the change. Until a build succeeds, public pages
return 503; partial output is not served. A repeated failure is reported once per
attempted content/settings revision. The standalone `publr build` command still exits
unsuccessfully when the settings are missing. The CLI writes them like any record:

```sh
publr --as-admin record create --type website --document @home.json --status published
```

## The Publr API

| Static, `Publr.build.*` | Dynamic, `Publr.request.*` |
|---|---|
| `getEntry()`: the live record this `[slug]` page is for; `getEntry({ type: 'post' })` another type at this slug, or, off a `[slug]` route, the type's one record; `getEntry({ type: 'page', slug: 'home' })` one record by slug | `session`: who is signed in (`.email`, or null) |
| `getCollection({ type, limit, offset })`: live records, newest first | `header('name')`, `cookie('name')` |
| `getReferences(entry, 'field')`: the live records a reference field points at, in the order stored; `getReference(entry, 'field')` the first as an entry, blank when none; `entry.data.rows` with no fallback: a repeater's rows as entries | `now()`: the clock, per request, the same shape |
| `now()`: the clock of the build, `YYYY-MM-DD HH:MM:SS` UTC | `random(n)`: a number in `[0, n)` |
| | `getCollection(...)`, `getReferences(...)`: records, read per request |
| | `userField('<group>.<field>')`: a custom field of the signed-in user, as text; null when signed out or empty |
| | `call('<namespace>.<verb>')`: runs an operation that allows frontmatter calls, as the visitor; its output is the entry's `data` |
| | `redirect(path)`: a page answers `303 See Other` to `path` instead of rendering; an empty path renders the page |

A page redirects from its frontmatter, with any string expression over what it read
before, and does it under a condition:

```astro
---
const session = Publr.request.session;
if (!session) {
  Publr.request.redirect('/login');
}
---
```

The path must be on this site (`/…`, never `//…` or another host). Only a page redirects,
never a layout, a component or a build. `if (<condition>) {`, an optional `} else {` and
`}` wrap actions (`redirect`, `call`), one level deep; a declaration never goes inside,
since its name would be missing on the path that skips it. Conditions and template
expressions take `!`, `&&` and `||`, which read truthiness and give true or false.

A page can also run an operation when it is opened, `Publr.request.call('cloud.welcome');`:
onboarding marking itself seen, a page view counted. Both are actions, statements of their
own among the declarations, in order; name one (`const seen = Publr.request.call(…)`) to
read what it returns, as `seen.data`. A read on its own does nothing and is refused.
It runs as the visitor, through the same pipeline and policies as the API, so a page can
do nothing its visitor could not. Only an operation that declares
`allow_frontmatter_calls` runs this way; it says that being triggered by merely opening a
page is fine, since a page's GET has no CSRF check and a link from anywhere opens it.
Anything else fails the render. A prefetch (`Sec-Purpose: prefetch`) runs nothing:
opening the page is the event. A call that is refused or fails is a blank entry, and the
page renders; one placed after a redirect never runs for a visitor sent away.

Records come through the same `record.list` and `record.get` operations the
API offers, and a template only ever sees live records. Who reads them depends
on who the render is for. Anything shared by every visitor (a built page, a
static island, a prerender) reads as an anonymous caller: live records of
public types and nothing else. A render made for one request (a dynamic page, a
dynamic island) reads as the signed-in visitor, within that user's role and
the plugins' policies, so a dashboard can list the visitor's own private
records; for a visitor who is not signed in it is anonymous again. An entry is
`id`, `type` (the handle), `slug`, `title`, `created_at`, `updated_at` (dates as
`YYYY-MM-DD`) and `data`, the document: `post.data.body` is the field `body`,
text or null. A reference field is followed with `getReferences(post,
'sections')`: a collection of the records it points at, in the order stored; a
target that is not live and public is left out. `getReference(post, 'seo')`
is the first of them as an entry, blank (empty id and type, no fields) when the
field points at nothing live, so `seo.data.description ?? ""` reads either way.
Every target is a dependency of the page, so its arrival or change rebuilds it,
and a render reads each record once however many fields point at it.

A page that follows a tree of references costs one `record.get` per record it
reaches, and each of those is tens of kilobytes of arena: a page reaching five
hundred records needs more memory than a live request has. Such a theme is
built (`publr build`, or `serve --static`) and its pages served as files; the
shared chrome (a header and footer read from the site's settings) is a static
island, built once. Rendering the same page live, under `--dev` or before a
build, fails with an out-of-memory response.
The type of `getEntry()` and of a bare `getCollection()` comes from the
template's place in `content/` (`greetings/[slug].publr` reads `greeting`); a
component names it (`{ type: 'greeting' }`). The default theme reads the
`greeting` type the hello plugin declares: public, titled by `note`, with a
slug from it, so a fresh install has a site the moment someone says hello
(`publr --as you@example.com hello record --note "Hello"`). A type the site does not have yet
(a fresh install, or one that is not public) is an empty collection, and its
entries are not found: the site builds before the content exists, and the
type's arrival rebuilds what read it.

**A template that reads `Publr.request` is dynamic; one that reads only
`Publr.build` is static.** Nothing is declared. A dynamic template's name
must say so, `<name>.dynamic.publr`, or the build refuses it naming the
rename; the `.dynamic` never appears in a route. A template may carry the
marker without reading the request, to be rendered per request anyway.

## Pages, components, islands

| | HTML is made | reaches the visitor |
|---|---|---|
| static page | at build, to a file | the file |
| dynamic page | per request | the response, rendered now |
| static island | at build, to a file | fetched by the page on every view, kept 60 s |
| dynamic island | per request | fetched by the page on every view, never kept |

`<X />` embeds a component into the page at the page's time. `<X island />`
makes a static component a fragment of its own, built once per distinct set
of literal props to `output/_islands/<key>.html` and shared by every page
that names it. `<X dynamic />` places a dynamic component as a fragment
rendered per request; a dynamic component is always placed with `dynamic`
(embedding it in a static page is refused), and on a dynamic page it is
rendered straight into the response. Islands nest without limit.

What is between an island's tags is its fallback, shown until the fragment
arrives. `prerender` makes the placeholder the build's own render of the
fragment instead (for a dynamic island: rendered as a visitor nobody knows;
for a static one: a stale copy the page is not subscribed to). `eager`
fetches at once; without it a fragment is fetched when it comes within a
viewport of the fold. `cache="<seconds>"` sets how long a visitor keeps the
fragment (60 for a static island, 0 for a dynamic one); two call sites naming
the same fragment must agree.

### Dynamic only for some visitors: `dynamic-if`

A dynamic island is a request to the server on every view. When most visitors would get
the same answer (a greeting that only a signed-in visitor sees differently), the browser
can decide whether to ask at all:

```astro
<SignedIn dynamic-if="signedIn" prerender />
<Cart dynamic-if="hasCart" />

<script>
  Publr.islands.condition('hasCart', () => document.cookie.includes('cart='));
</script>
```

`dynamic-if="<name>"` places a dynamic island that is fetched only if the browser's
condition of that name holds, decided on each view once every script on the page has run.
When it is fetched, it is a dynamic island like any other: rendered per request, the
server checking everything; the condition only decides whether to ask. Otherwise the
visitor sees what any island shows before it arrives: the build's render with
`prerender`, else the children, else nothing. A page names its conditions with
`Publr.islands.condition(name, fn)`, plain JavaScript returning true or false. `signedIn`
is already there: Publr's own hint (`publr_signed_in`), set with the session at sign-in,
cleared at sign-out, and set again by the server whenever a valid session arrives without
it. A condition that is not there, or throws, fetches the island anyway, with a warning in
the console: a mistake costs a request, never the wrong content. The name is a letter,
then letters, digits or `_`; `dynamic` and `dynamic-if` on one placement is a build error,
and so is `dynamic-if={…}` (braces always mean the build or the server). A conditional
island is never preloaded.

A page carries its stylesheet inline, preloads the static islands it will
place (nested ones included), and links the island loader and, when it will
hold an interactive component, the theme's client stores, each as its own
low-priority module script.

## Interactive components

Interactivity is a client concern and says nothing about when a component
renders. A theme's `interactive/*.ptsx` are PJSX components, compiled by the
same toolchain as the admin: the server renders them with PublrJS wire
attributes, the client half lands in `/theme/stores.js`, and a `.publr`
component wraps the call site (`<Disclosure label={props.label} />`) so the
theme still decides whether it is embedded or an island.

## The toolbar

Every page links `/theme/toolbar.js`. For someone signed in to the site it shows a small bar
with a link to the admin and, on a page that renders one record (a route whose
`Publr.build.getEntry()` reads it by slug, or the homepage), a link to that record's editor
named by its type ("Edit Greeting"). It wears the admin rail's colours and mark, whatever
the site looks like. The bar can be dragged by the mark, and the browser remembers where.
Hiding it is remembered too; a small triangle then appears when the pointer reaches the
page's bottom-right corner, and clicking it brings the bar back.

Anonymous visitors pay for one cookie read. Signing in sets a readable `publr_signed_in=1`
beside the HttpOnly session cookie, and signing out clears both. Without that cookie the
script stops and PublrJS is never fetched. With it, `GET /_publr/toolbar?path=<page>`
answers `{ signed_in, name, admin, edit, edit_label }` as the session sees it. If the
session has ended, the script clears the cookie.

A theme whose visitors should never see it (an app built on Publr, like the Cloud
dashboard) opts out in its `<head>`:

```html
<meta name="publr-toolbar" content="off" />
```

## Middleware

A theme's `middleware.zig` sees every request for the site before anything else does,
whatever its method: pages, not-found pages, islands. It answers the request or lets it
through. `/admin`, `/api`, `/auth` and the theme's assets are core's and never reach it.

```zig
const std = @import("std");
const publr = @import("publr");

pub fn middleware(request: *publr.Request) !?publr.Response {
    if (!request.starts_with("/members")) return null;
    if (request.user() == null) return request.redirect("/login");
    return null;
}
```

`null` lets the request through; a `publr.Response` is the answer, sent
`Cache-Control: private, no-store`. The request gives `method()`, `path()`,
`starts_with()`, `query(name)`, `header(name)`, `cookie(name)`, `host()`, `user()`, the
signed-in visitor or null, and `user_field('<group>.<field>')`, as `userField` in a
template. `call(Operation, in)` runs any operation as the visitor,
through the same pipeline and policies as the API. `print()` formats text that lives as
long as the request. The answers are `redirect(url)` (a `303` to a path on the site or
any URL), `respond(status, html)` and `json(value)`.

The file is Zig, compiled into the binary with the theme: it imports `publr` and every
compiled-in plugin by name (`@import("hello")`). A theme without one builds as before,
and nothing runs. A built site served as files elsewhere (`publr build` to a CDN) has no
middleware.

## Delivery gates

Plugins decide who sees the public site. A plugin declares `delivery_gates`, functions
from `sdk.delivery`, and before a page, a not-found page or an island goes out, each is
asked about it with the system's context, the visitor and the path. A gate stays silent
(`.open`), lets it through for this visitor only (`.private`: sent
`Cache-Control: private, no-store`, never from a built file a shared cache might hold), or
answers in the page's place (`.refuse`, a 4xx or 5xx status and a page). The first refusal
wins; a gate that fails ends the request. The theme's assets are never gated. A paywall, a
members-only area and Publr Cloud's preview mode are all gates in plugins; the core has
none of its own. Built files are gated like renders: the gates are asked first, whatever
answers the request.

## Building and serving

```
publr build [--out <dir>] [--url <base>]     the site as files (default: ./output): only what
                                             changed since the last build; --full for everything
publr serve                                  serves ./output when it exists, renders the rest
publr serve --static                         brings ./output up to date at startup, then serves
publr serve --dev                            renders everything live, caches nothing, tints islands
publr serve --edge-max-age <s>               built files may stay at a CDN for <s> seconds
publr check-theme                            compiles the embedded theme; exits 1 with the reason
```

`zig build` runs `check-theme` on the binary it just built, so a template the engine refuses
fails the build with the engine's message instead of the first `serve`. A binary built for
another machine is checked where it runs.

`serve` prefers built files over rendering: a page or static island that has a
file is served with an `ETag` (`public, max-age=60, stale-while-revalidate`),
a dynamic island or a live page is rendered per request (`no-store`), assets
generated by Publr under `/theme/` carry a fingerprint (`?v=<token>`) and are
immutable for a year. Public files retain their literal URLs and are served from disk
with revalidation, without content hashes. Every build copies public files and removes
stale copies independently of page generation; changing an image or a public script
requires no Zig compilation and does not invalidate generated pages. `public/style.css`
is the exception: it is an input to the compiled theme stylesheet. Without a build everything renders on request, which is what
development wants.

Behind a CDN that is purged whenever the site changes, `--edge-max-age <s>` lets it keep
built pages and static islands far longer than browsers do: they also carry
`CDN-Cache-Control: max-age=<s>`, which CDNs read before `Cache-Control`. Anything a
delivery gate made private carries `CDN-Cache-Control: no-store` instead, and what is
rendered per request (dynamic pages and islands) never carries one. So at the edge only
dynamic requests reach the server; each dynamic island a page places is one of them on
every view.

Behind such a CDN the purge is as surgical as the rebuild. Each built page and static
island also carries `Cache-Tag`: the dependency keys its build recorded (`record:<id>`,
`type:<handle>`, `records`, `template:<path>`, …; any other byte written `%XX`), or `any`
for what has none (the 404 page) or too many to list. Every request that may write
answers with `X-Publr-Changed`: the keys it raised, the same way written; empty when it
changed nothing a page reads; `*` when too many changed to name. Whatever purges the CDN
purges those tags and `any`, so the edge drops exactly what the site rebuilds on disk,
and every other page stays cached.

## What a publish rebuilds

Every render records what it read in the dependency index, tables in the
site's own database (`deps_*`): `record:<id>` for an entry, `type:<handle>`
and `records` for a query, `template:<path>` for every template it went
through, `asset:theme` for the stylesheet it carries inline. Every `record.*`
notice raises the record's keys, from whichever door the change came (admin,
API, CLI). The server takes the batch once it has been quiet for a quarter
second and rebuilds exactly the artifacts the index names: a changed post
rewrites its own page and whatever lists it; a rebuild that produces the same
bytes is not written; a page whose record is gone is removed. Record a
greeting and the home page, the listing, the shared fragment and the
greeting's own page change; no other greeting page is touched.

The queue lives in the database, so a change made while no server ran (a CLI
publish, a migration script) waits there. The next `publr build` or
`serve --static` replays it during public-site initialization and builds nothing
more; when the queue is empty and the folder's marker (`.publr-build`)
carries the stamp of the theme in the binary, it does nothing at all. A
folder another theme built, or one built for another `--url`, is built whole,
and so is one whose queue is too wide to plan. `--full` forces that.

`publr site impact --type <handle> [--id <record>]` reads the index back: the
keys a change raises and every artifact that recorded one of them. The admin
shows the same, with what the theme's templates say about the type, in the
record editor's "What depends on this" dialog under `serve --dev`; see
[Admin](admin.md).
