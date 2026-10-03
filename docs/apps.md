# Apps

A Publr project is one binary, one database and one domain. What visitors see comes
from its **apps**: a marketing site, a newsletter, a members area, a product people
pay for. Each app is a folder of templates, read by the running server from the project's
`apps/` folder, and each is a frontend over the same plugins, which hold the data and the
operations. Two
domains, or two separate sets of accounts, are two projects.

An app is static first: `publr build` writes every page to a file, `publr serve` serves
the files, and every publish rewrites exactly the files it affects. What must be fresher
than a file is an **island**: a fragment of a page fetched after the page loads,
rendered at build or per request. Templates and generated client code live in the
binary; public files stay on disk.

A project with no apps is valid: `/` opens the admin. Publr ships none; a project starts
from a preset (a website, a SaaS, a multi-tenant product) or from scratch.

## An app

```
apps/www/
  app.zon                  its name, where it is mounted, its design tokens, who may sign in
  content/                 the routes: one page per file
    index.publr            /
    posts/index.publr      /posts
    posts/[slug].publr     /posts/<slug>, one page per live post
    visit.dynamic.publr    /visit, rendered per request
    404.publr              every unmatched path
  layouts/, components/, dynamic/   templates the pages import; the names are the app's own
  interactive/*.ptsx       PJSX components with client state (optional)
  public/                  served as-is at the mount: public/robots.txt is /robots.txt
                           (style.css is prepended to the stylesheet instead)
  middleware.zig           runs before every request for the app (optional; see Middleware)
```

Only `content/` means anything to the engine: its files are pages, and `[slug]` in a
name is a route parameter. Every other folder holds templates a page imports.
`public/` and `interactive/` are not templates. An app with no templates at all is
valid: its `middleware.zig` answers every request (a webhook receiver, an API facade).

### Templates the apps share

An import may leave the app, by `../`, to any template in the project's apps folder:
another app's, or one in a folder of shared templates, a folder there with no `app.zon`.

```
apps/
  shared/components/navbar.publr      no app.zon: templates any app imports
  www/layouts/base.publr              import Navbar from '../../shared/components/navbar.publr'
  waitlist/layouts/base.publr         import Base from '../../www/layouts/base.publr'
```

What an app imports from outside joins it, with what that imports in turn: its classes
reach the app's stylesheet, and changing it rebuilds every app that imports it. An
import never leaves the apps folder.

`serve` reads every folder under `apps/` that has an `app.zon`: `--apps <dir>` when named,
else the project's own `apps/` beside where Publr runs, else where the build's apps came from
(a binary built from a preset reads the preset's), checking what the build used to check (names, mounts, roles, templates), and
`publr apps load` reads them again into the running server: a changed or new template is
served when the command returns, never after a rebuild. What still needs compiling comes
from a build of Publr: `-Dapps=<dir>` compiles that folder's apps in, and an app of the
same name takes its interactive components and middleware from there; an app the build
does not have may have neither. With no `apps/` folder, `serve` serves the build's own.
`-Dapps-max` (32 by default) bounds how many apps a project holds. A template that does not load fails
`publr build`, naming the app, the template and the construct. `publr serve` keeps the
admin and the API available even when the apps cannot load or build; their pages then
answer a non-cacheable 503.

## Where an app answers

`app.zon` names the app and says where it is mounted, on the project's one domain:

```zig
.{
    .name = "www",                      // the app's id
    .label = "Website",                 // what the admin shows; the name when left out
    .plugins = .{ "newsletter" },       // whose content types it reaches; every plugin's when left out
    .mount = .{ .path = "/" },          // the root of the domain
    // .mount = .{ .path = "/newsletter" },   everything below /newsletter
    // .mount = .{ .subdomain = "app" },      app.example.com
    .tokens = .{
        .{ .name = "color-accent", .value = "#2f5d54" },
    },
}
```

`.plugins` names the plugins the app uses. Every read and call the app makes (its
templates, islands, frontmatter calls and middleware) reaches the project's own content
types and those plugins' types, never a type another plugin owns: a site that names
`.{ "newsletter" }` cannot list the shop's orders, whoever is signed in. Left out, the app
reaches every plugin's types. A name is `[a-z][a-z0-9_]*`, at most 64 of them; a plugin not
installed yet is no error.

`.name` is the app's id: what its records, its built pages (`www:/posts/hello`), its
build folder (`output/www/`) and the CLI know it by. The folder the app sits in is only
where it is read from, and may be renamed at will; two apps of one name fail the load.
Renaming the app itself is changing `.name`, and `publr project move_app --from www --to
site` hands its records to the new name.

A request goes to the app mounted on its subdomain, else to the path mount with the
longest prefix; with nothing there, `/` opens the admin and anything else is not found.
At most one app sits at the root; two apps in the same place, or a path under `/admin`,
`/api`, `/auth` or one starting with `_`, fail the build. The domain is the host of the
project's address (`--url`, `http://127.0.0.1:8080` by default); in development
`app.localhost:8080` reaches a subdomain app when the address is
`http://localhost:8080`.

Inside an app everything is seen from its mount. Its routes, `content/` and its
middleware's `request.path()` start at `/` whether the app answers at the root, under
`/newsletter` or on `app.example.com`. What the engine writes follows the mount: an
island is fetched from `<mount>/_islands/<key>` and a generated asset from
`<mount>/_app/<file>`. Links a template writes by hand are its own, public files
included: an app under `/newsletter` writes `/newsletter/issues` and
`/newsletter/logo.svg`. `/_app/` holds only what Publr generates; a template naming
anything else there fails the build.

`.tokens` are the app's design tokens, layered over the stylesheet's defaults: every
`color-*` token is a utility family (`bg-canvas`, `text-ink`, `border-line`).

## Signed-in visitors and roles

A project has one set of accounts and one session for all its apps. With an app on a
subdomain, the session cookie is set for the whole domain, so one sign-in holds on every
app. What an account may do is its roles ([Auth](auth.md#roles)): an app's visitors hold
a role its plugin declares, whose grants reach the app's operations (`app.<feature>.*`)
and nothing of the admin's, so they can never enter the admin.

An app that names roles in `app.zon` sees a signed-in account holding none of them as
nobody: in its templates (`Publr.request.session`), its dynamic islands and its
middleware (`request.user()`).

```zig
.{
    .mount = .{ .subdomain = "app" },
    .roles = .{ "customer" },
}
```

A role named there that neither core nor a built-in plugin declares fails the build.

## Calling operations from a page

An app's pages call what its plugins mark safe for its users, `app.<plugin>.<verb>`, at
`<mount>/_api/<plugin>/<verb>` (`/_api/cart/add` on the root app, `/shop/_api/cart/add`
on one mounted at `/shop`). Nothing else is reachable there: core's own operations and a
plugin's other ones answer not found, and a plugin the app does not list in `.plugins`
is denied. The call runs as the visitor, for the app, through the same authorization,
rules, transaction and logs as any other.

- **An island** posts JSON with the header `Publr-Request: 1` and reads the JSON answer.
- **A plain form** posts its fields, named as the operation's input; it is sent back with
  a `303` to its `redirect` field (a path on this site), or to the page it came from,
  with `?error=<name>` added when the call was refused.

```html
<form method="post" action="/_api/cart/add">
  <input type="hidden" name="variant" value="{variant.id}">
  <input type="hidden" name="redirect" value="/cart">
  <button>Add to cart</button>
</form>
```

The request must come from the app's own site (`Origin`); a page elsewhere is refused.

A refused form comes back with the refusal's name, `?error=NotEnoughStock` when the
plugin refused in its own words, and the page says what it wants to about it:

```
const refused = Publr.request.param('error');
```

An island's JSON call gets the plugin's message too: `{ "error": "NotEnoughStock",
"message": "Only 2 left." }`.

## Visitors

Every visitor has a stable id, the `publr_visitor` cookie (HttpOnly, SameSite=Lax), set
by the first dynamic page, dynamic island or `_api` call that finds none; a static page
never sets it, so built pages stay cacheable. Signed in or not, it stays the same.
Operations read it as the visitor (`ctx.visitor()` in a plugin): what a cart keys on, or
a segment a page shows. The activity log names an anonymous visitor `visitor:<id>`.

## Which records are an app's

Every record belongs to one app or to none: the project's own. A record made through
an app (its middleware's `call`, a page's `Publr.request.call`, its `_api`) belongs to
that app;
one made anywhere else belongs to the app it names (`record create --app`), else to
the project. `record set_app` changes it. It decides where the admin shows the record,
never who may read it: every app still reads every record its access allows, so a site
can list what the newsletter published. `record list` narrows to one app with
`app:is:<name>` and to the project's own with `app:none`.

## A template

A `.publr` file is JS frontmatter over an HTML body with JSX constructs:

```astro
---
import Base from '../../layouts/base.publr';
import LatestPosts from '../../components/latest-posts.publr';
const post = Publr.build.getEntry();
---
<Base title={post.title}>
  <article>
    <h1>{post.title}</h1>
    <time>{post.created_at}</time>
  </article>
  <LatestPosts heading="More posts" island prerender eager />
</Base>
```

Frontmatter supports synchronous JavaScript: functions, destructuring, arrays,
objects, `Math`, `Set`, loops, and seeded generators. TypeScript annotations are
stripped using the same parser as PJSX; no type checking runs during rendering.
Frontmatter and body expressions share one lexical scope:

```astro
---
const { seed = 7919 } = props;
let state = seed;
const random = () => ((state = (state * 16807) % 2147483647) - 1) / 2147483646;
const dots = Array.from({ length: 20 }, () => ({ x: random() * 100, y: random() * 100 }));
---
<svg viewBox="0 0 100 100">
  {dots.map(dot => <circle cx={dot.x} cy={dot.y} r="1" />)}
</svg>
```

Imports may name a `.publr` component or a relative `.js` / `.ts` helper. Helpers
use ES module imports and exports, including live bindings and reexports. Imports
stay inside the project's apps folder and participate in dependency tracking.
Named npm packages, Node APIs, filesystem access, network access, dynamic imports,
and asynchronous rendering are not available.

Simple templates keep the native Zig renderer. A template needing JavaScript is
compiled to embedded QuickJS-NG bytecode when the app loads; it runs once per
component invocation in a fresh, bounded JavaScript heap for each page render.
Nested components share that heap and its module instances. Static pages save the
resulting HTML/SVG, so serving them adds no JavaScript execution or client script.
JavaScript computation has an interpreter cost during rebuilding or live rendering.

Zig writes the output: interpolated text and attributes are escaped, arrays flatten,
and computed `null`, `undefined`, and boolean children emit nothing. `set:html` prints
markup, always sanitized: headings, lists, links, images, tables and inline SVG drawings
are kept; scripts, styles, frames, embeds, `on…` attributes and `javascript:` or `data:`
addresses are removed. In an SVG, references point only at its own parts (`#id`,
`url(#id)`), its ids are prefixed `svg-`, an animation never targets an address, a style or
a handler, and `<style>` or `style` never reach the page. Nothing skips it. A page that needs a script gets it from an
island or an approved plugin script, never from printed markup. Components receive `props`; children fill `<slot />`.
Data reads use the existing `Publr.build` / `Publr.request` context and permissions.
Request access requires a dynamic template, including when reached through an alias.
Use a seeded generator for repeatable patterns and `Publr.build.now()` or
`Publr.request.now()` for tracked time; ambient time and `Math.random()` are disabled.

The engine bounds its heap to 32 MiB and stack to 512 KiB, interrupts runaway
execution, and limits each computed output block to 8 MiB and 64 nested levels.
Errors retain the template or helper filename. Keep PJSX components and island
directives in the outer template markup; computed JSX may embed static `.publr`
components. JSX-bearing helper modules are not supported; put JSX in `.publr` files.

## Settings an app reads

An app's own settings are a settings type (`kind: settings`, one record) that the app's
plugin declares or an administrator creates under Structure. A template reads it like
any type's one record, off a route without a slug:

```astro
---
const home = Publr.build.getEntry({ type: 'homepage' });
const cards = home.data.products;
---
<h1>{home.data.hero_title}</h1>
<ul>{cards.map((card) => (<li>{card.data.title}</li>))}</ul>
```

A repeater field read without a fallback (`home.data.products`) is its rows, each an
entry with no identity whose `data` is the row. Until the record is published the page
is not found and the build stops, naming the template and the type; publishing it
rebuilds what read it through the usual `type:<handle>` dependency.

## The Publr API

| Static, `Publr.build.*` | Dynamic, `Publr.request.*` |
|---|---|
| `getEntry()`: the live record this `[slug]` page is for; `getEntry({ type: 'post' })` another type at this slug, or, off a `[slug]` route, the type's one record; `getEntry({ type: 'page', slug: 'home' })` one record by slug | `session`: who is signed in (`.email`, or null) |
| `getCollection({ type, limit, offset })`: live records, newest first | `header('name')`, `cookie('name')` |
| `getReferences(entry, 'field')`: the live records a reference field points at, in the order stored; `getReference(entry, 'field')` the first as an entry, blank when none; `entry.data.rows` with no fallback: a repeater's rows as entries | `now()`: the clock, per request, the same shape |
| `now()`: the clock of the build, `YYYY-MM-DD HH:MM:SS` UTC | `random(n)`: a number in `[0, n)` |
| `get('order', id)`: the live record by id, null when there is none or it is of another type; `findOne('product', 'sku', 'EG-50')` the one whose field holds the value; `find('variant', { product: id }, { limit, offset })` live records, newest first, filtered on at most one field by equality | `param('error')`: a value from the address's query string, null when absent |
| `query('*[_type == "variant" && product == $id] \| order(price.GBP) { _id, title, price }', { id: product.id })`: a [GROQ query](queries.md) over what the visitor may read, its answer plain JSON (`variant.title`, not `.data`); a static page that queries rebuilds when any record changes | `query(...)`: the same, per request |
| | `call('app.inventory.levels', { product: id })`: a plugin's `app.*` read, with its input, as the visitor; the answer is `.data`, plain JSON |
| `money(entry.data.price)`: a money field in the site's default currency as the site writes it (`£9.25`); `money(entry.data.price, 'EUR')` in that one; empty when the field holds none | `money(...)`: the same, per request |
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

The path must be on this domain (`/…`, never `//…` or another host). Only a page redirects,
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
dynamic island) reads as the signed-in visitor, within that user's roles and
the plugins' policies; a visitor whose roles grant no record reads (an app's
visitor) reads what anyone may, live records of public types. What is private to
a visitor (their orders, their projects) a page reads through its feature's own
operation, `Publr.request.call('app.<feature>.<verb>')`, which decides what the
visitor may see. An entry is
`id`, `type` (the handle), `slug`, `title`, `created_at`, `updated_at` (dates as
`YYYY-MM-DD`) and `data`, the document: `post.data.body` is the field `body`,
text or null. A reference field is followed with `getReferences(post,
'sections')`: a collection of the records it points at, in the order stored; a
target that is not live and public is left out. `getReference(post, 'seo')`
is the first of them as an entry, blank (empty id and type, no fields) when the
field points at nothing live, so `seo.data.description ?? ""` reads either way.
Every target is a dependency of the page, so its arrival or change rebuilds it,
and a render reads each record once however many fields point at it.

A money field is written with `money(product.data.price)`: the amount in the site's
default currency, with the symbol, format and separators the site set for it
(`project set_currencies`), `£1,234.56` or `1 234,56 €`. A second argument names
another of the site's currencies. A page that writes money depends on the
currencies, so changing them rebuilds it.

A page that follows a tree of references costs one `record.get` per record it
reaches, and each of those is tens of kilobytes of arena: a page reaching five
hundred records needs more memory than a live request has. Such an app is
built (`publr build`, or `serve --static`) and its pages served as files; the
shared chrome (a header and footer read from the app's settings) is a static
island, built once. Rendering the same page live, under `--dev` or before a
build, fails with an out-of-memory response.
The type of `getEntry()` and of a bare `getCollection()` comes from the
template's place in `content/` (`posts/[slug].publr` reads `post`); a
component names it (`{ type: 'post' }`). A type the project
does not have yet (a fresh install, or one that is not public) is an empty
collection, and its entries are not found: the app builds before the content
exists, and the type's arrival rebuilds what read it.

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
of literal props to `output/<app>/_islands/<key>.html` and shared by every page
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
hold an interactive component, the app's client stores, each as its own
low-priority module script.

## Interactive components

Interactivity is a client concern and says nothing about when a component
renders. An app's `interactive/*.ptsx` are PJSX components, compiled by the
same toolchain as the admin: the server renders them with PublrJS wire
attributes, the client half lands in `<mount>/_app/stores.js`, and a `.publr`
component wraps the call site (`<Disclosure label={props.label} />`) so the
app still decides whether it is embedded or an island.

## The toolbar

Every page links `<mount>/_app/toolbar.js`. For someone signed in who may use the admin, it
shows a small bar with a link to the admin and, on a page that renders one record (a
route whose `Publr.build.getEntry()` reads it, by slug or as its type's one record), a
link to that record's editor named by its type ("Edit Post"). It wears the admin rail's
colours and mark, whatever the app looks like. An app's visitor, whose roles reach none of
the admin's operations, never sees it. The bar can be dragged by the mark, and the browser remembers where.
Hiding it is remembered too; a small triangle then appears when the pointer reaches the
page's bottom-right corner, and clicking it brings the bar back.

Anonymous visitors pay for one cookie read. Signing in sets a readable `publr_signed_in=1`
beside the HttpOnly session cookie, and signing out clears both. Without that cookie the
script stops and PublrJS is never fetched. With it, `GET /_publr/toolbar?path=<page>`
answers `{ signed_in, name, admin, edit, edit_label }` as the session sees it. If the
session has ended, the script clears the cookie.

An app that should never show it, even to administrators, opts out in its `<head>`:

```html
<meta name="publr-toolbar" content="off" />
```

## Middleware

An app's `middleware.zig` sees every request for the app before anything else does,
whatever its method: pages, not-found pages, islands. It answers the request or lets it
through. `/admin`, `/api`, `/auth` and the app's assets (`/_app/`) never reach it.

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
`Cache-Control: private, no-store`. The request gives `method()`, `path()` (inside the
app, as its routes see it), `base()` (what the app's URLs start with, `/newsletter` or
nothing), `query(name)`, `header(name)`, `cookie(name)`, `host()`, `user()`, the signed-in
visitor (with its `roles`) or null, and `user_field('<group>.<field>')`, as `userField` in a
template. `call(Operation, in)` runs any operation as the visitor,
through the same pipeline and policies as the API. `print()` formats text that lives as
long as the request. The answers are `redirect(url)` (a `303` to a path on the domain or
any URL), `respond(status, html)` and `json(value)`.

The file is Zig, compiled into the binary with the app: it imports `publr` and every
built-in plugin by its name (`@import("<name>")`). An app without one builds as before,
and nothing runs. An app built to files and served elsewhere (`publr build` to a CDN) has
no middleware.

## Delivery gates

Plugins decide who sees the apps. A plugin declares `delivery_gates`, functions
from `sdk.delivery`, and before a page, a not-found page or an island goes out, each is
asked about it with the system's context, the visitor and the path. A gate stays silent
(`.open`), lets it through for this visitor only (`.private`: sent
`Cache-Control: private, no-store`, never from a built file a shared cache might hold), or
answers in the page's place (`.refuse`, a 4xx or 5xx status and a page). The first refusal
wins; a gate that fails ends the request. The apps' assets are never gated. A paywall, a
members-only area and Publr Cloud's preview mode are all gates in plugins; the core has
none of its own. Built files are gated like renders: the gates are asked first, whatever
answers the request.

## Building and serving

```
publr build [--out <dir>] [--url <base>]     every app as files, one folder each (default:
                                             ./output/<app>/): only what changed since the last
                                             build; --full for everything
publr serve                                  serves ./output where it exists, renders the rest
publr serve --static                         brings every app's build up to date, then serves
publr serve --dev                            renders everything live, caches nothing, tints islands
publr serve --edge-max-age <s>               built files may stay at a CDN for <s> seconds
publr check-apps                             compiles every app; exits 1 naming the app and why
```

`zig build` runs `check-apps` on the binary it just built, so a template the engine
refuses fails the build with the engine's message instead of the first `serve`. A binary
built for another machine is checked where it runs.

An app's build is a folder of its own: `output/www/index.html`, its islands under
`_islands/`, its generated assets and compiled stylesheet (`_app/app.css`), its public
files copied to the folder's root, its `sitemap.xml` at its own address (served by
`serve` too), and the marker that says what built it. A public file may not take a path
the build writes itself: `index.html` in any folder, `404.html`, `sitemap.xml`, `_app/`
or `_islands/`. Deployed alone, `output/www/` is a static site for the root; `output/docs/`
belongs under `/docs`. An app whose build fails answers 503 until a build after the next
publish succeeds; the other apps and the admin stay up.

`serve` prefers built files over rendering: a page or static island that has a file is
served with an `ETag` (`public, max-age=60, stale-while-revalidate`), a dynamic island or a
live page is rendered per request (`no-store`), assets generated by Publr under `/_app/`
carry a fingerprint (`?v=<token>`) and are immutable for a year. Public files keep
their literal URLs and are served from disk with revalidation, without content hashes,
and are never gated. A page at a fixed path wins over a public file of the same path;
any other path is a public file before it is a `[slug]` page or the 404. Every build
copies public files and removes the copies it made of files since deleted, independently
of page generation; changing an image or a public script requires no Zig compilation and does
not invalidate generated pages. `public/style.css` is the exception: it is an input to
the app's compiled stylesheet. Without a build everything renders on request, which is
what development wants. A running server reads an app's public files from
`apps/<folder>/public` beside it (`--apps <dir>` names another folder).

Behind a CDN that is purged whenever the project changes, `--edge-max-age <s>` lets it keep
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
purges those tags and `any`, so the edge drops exactly what the apps rebuild on disk,
and every other page stays cached.

## What a publish rebuilds

Every render records what it read in the dependency index, tables in the
project's own database (`deps_*`) that every app shares: `record:<id>` for an entry,
`type:<handle>` and `records` for a query, `template:<app>/<path>` for every template it
went through, `asset:<app>` for the stylesheet it carries inline. A built page or island
is named with its app, `www:/posts/hello`, so the same path in two apps is two artifacts. Every `record.*`
notice raises the record's keys, from whichever door the change came (admin,
API, CLI). The server takes the batch once it has been quiet for a quarter
second and rebuilds exactly the artifacts the index names, each by its own app: a changed post
rewrites its own page and whatever lists it; a rebuild that produces the same
bytes is not written; a page whose record is gone is removed. Publish a
post and the home page, the listing, the shared fragment and the post's own
page change; no other post page is touched.

The queue lives in the database, so a change made while no server ran (a CLI
publish, a migration script) waits there. The next `publr build` or
`serve --static` replays it and builds nothing more; when the queue is empty and
an app's folder's marker (`.publr-build`) carries the stamp of the app in the binary, it
does nothing for that app. A folder another version of the app built, or one built for
another `--url`, is built whole, and so is every app when the queue is too wide to plan.
`--full` forces that.

`publr project impact --type <handle> [--id <record>]` reads the index back: the
keys a change raises and every artifact that recorded one of them. The admin
shows the same, with what the apps' templates say about the type, in the
record editor's "What depends on this" dialog under `serve --dev`; see
[Admin](admin.md).
