# Admin components

## Layouts

Every page returns one layout from `layouts/` and fills its slots; `docs/admin.md` lists
them. `Chrome` (rail, sidebar, crumbs, top bar) and `Document` (the HTML document) are
drawn only by the layouts, from `Publr.request`, which the admin fills from the session
(`ui/request.zig` is its shape). Their parts live in `components/`: `IndexHeader` (the
title band), `IndexSection` (one of several lists, or a part of a form), `FormBody` (a
FormPage's body, which the record editor also draws in drawers), `EditorAside` and
`EditorAsideSection` (the aside), `ConfirmAction` (a danger zone's confirm), `HubGroup`.
`render.page` refuses a page whose root is not a layout; `pjsx_gen` refuses the chrome
outside the layouts and spacing on a page's top-level elements.

## Parts

Pages and adapters keep their existing props. The larger components coordinate
their sections and pass props explicitly; their parts live in a directory with
the parent's name.

| Parent | Parts |
| --- | --- |
| `ContentList` | Header, saved-view actions, creation menu, filters, table and empty state |
| `RecordEditor` | Header, problems, actions, single values, lists, groups and repeaters |
| `FieldPanel` | Problems, multiplicity, settings, child fields and footer |
| `FieldRules` | Individual validation rules and their controls |
| `FieldLook` | Boolean, number and container appearance settings |

`RecordValue` renders a value and its select or radio options. `RecordReferenceAdd`
renders the link/create controls used by both single and multiple references.

Client state, refs, effects and event handling stay in the existing parent
components. Extracted parts are presentational; portaled controls import their
parent's actions and bind them where the events occur. Keep form ownership, input names,
IDs, `data-part` hooks and the order of elements when extracting another section:
the client behavior and the server adapters depend on them.

Each part declares a literal PJSX prop schema for the props it receives. The
compiler reads these schemas independently; schema spreads and imported schema
objects are not supported. Keep forwarded array field shapes consistent. The Zig
target converts arrays into the receiving component's item types using the render
arena, including nested arrays. Reducing those copies and consolidating the
schemas can be a separate optimization.

`zig build verify-full` in `publr/` checks generated Zig, tests, formatting, tidy rules,
HTTP smoke and operation parity. Its configured `PUBLR_VERIFY_HOOK` also runs the
browser smoke. PTSX files must also compile with `pjsx dom` for the SPA target.

## Client behavior

The layout loads `/admin/stores.js` as a normal module script, without `async`.
Its hydration must run after the document is parsed, and DOM readiness must wait
for the module graph. Browser checks use this page entry point rather than
importing the admin module from test code.

Use `TypeHead`, `FieldHead`, and `HelpText` as the small-component examples:
seed `Publr.reactive` state from props and express values, conditions, classes and
events in JSX. For example, `class={state.busy ? "opacity-70" : ""}` and
`onWindowPopState={onPopState}`. Never author low-level `:class`, `@event`,
`data-p-*` bindings or equivalent direct wire syntax in PTSX. That protocol is
compiler output. Missing JSX support belongs in the compiler/runtime.

Use `Publr.ref` for owned elements. Do not locate them with `querySelector`,
`querySelectorAll`, `getElementById`, `closest`, DOM position or text matching.
Bind actions to their actual controls and use `event.currentTarget`. An external
library's DOM may require querying; the admin components currently have no such
exception. Native focus, input selection, form serialization and history are
browser effects; displayed state belongs in JSX.

Refs and undeclared event props forward through components and slots, composing
with their own refs and handlers. `Publr.ref(element => cleanup)` supports setup
for each referenced element and teardown with its owning scope. This also lets
an owner collect refs for a repeated set of controls using explicit JSX keys.
Window events written as `onWindowPopState` belong to the island's lifecycle.
`Publr.effect` accepts a cleanup function: return it to release resources before
the next effect run and when the island is destroyed. Dialog and Drawer use the
focus extension's returned cleanup to release their traps and restore focus.

`ContentList` retains its owning island across requests. Links and GET forms
also work without JavaScript. The server response replaces the referenced
`ContentListBody` island; destroying it retires child handlers, refs and portals
before the replacement is hydrated. This is the existing HTML response boundary;
list markup remains declared by its PTSX components. New requests cancel previous
ones, and unmount cancels pending navigation/search. Menu and search focus use
refs registered by their JSX controls, including portaled items.

The chrome's `Navigation` component creates the shared `Publr.stores.navigation`
store. Reference and structure levels are the source of truth; `open` and breadcrumb
`levels` are computed getters. Read shared values directly in JSX, for example
`{Publr.stores.navigation.levels.map(level => <BreadcrumbItem key={level.depth}>…</BreadcrumbItem>)}`,
and bind shared actions with `onClick={Publr.stores.navigation.back}`. Do not mirror
another component's state through CustomEvents, observers, or copied local arrays.
Keep drafts local to their editor; pass callbacks for operations such as delivering
a chosen reference to that editor.

Field forms register their refs with navigation and publish serialized drafts through
JSX input/change handlers. FormPreview reacts to the active draft; the saved preview
is shared so TypeColumns can update it after a write. Closing the form restores the
saved preview. Replacing a form unregisters its ref before the next form mounts.

Use `innerHTML={state.html}` only at an existing trusted server HTML boundary.
The runtime retires previous child islands before hydrating the response. A null
value preserves the initial JSX children until the first response. Use JSX for
application-authored markup; do not build client UI with HTML strings. Drawer
levels are keyed JSX rows, with `focusScope={!level.inactive}` for keyboard focus
and refs for focus restoration. Pending drawer and preview requests are aborted
when superseded or unmounted.

## Requests and writes

`ContentList`, `ReferenceDrawer`, `TypeColumns` and `FormPreview` use the public
callback form of `awaited`. Read `value`, `isPending`, `isLoaded`, `isError` and
`error`; call `refresh()` to retry. A row's awaited resource belongs to its ref
scope, so removing the row aborts its HTTP operation and ignores late responses.
Preview posts also cancel their debounce and fetch when the draft changes.

GET fragments use `httpOperation` and explicit JSON response envelopes. Content
lists return `{html, title, address}`, field panels `{html, title}`, reference
panels `{html}`, and structure refreshes `{list, preview}`. HTML fields are the
existing trusted server-rendered regions. HTTP cache policy controls freshness;
query tags connect successful writes to affected readers.

Record saves and actions, and field writes, use `mutation`. Autosave drains one
write at a time, snapshots the edit revision, and acknowledges only that revision.
Typing during a save remains dirty and is sent with the acknowledged version.
Creation finishes saving later edits before replacing the blank editor. Failures
keep the draft and expose retry. Status and reshape writes wait for autosave.

The admin currently builds through `pjsx.targets.zig.Program`, which supports
family stores and JSX conditions/maps. The demo's component-local `state`,
native `awaited(operation(...))`, `Loading`, `Show` and `For` use `pjsx.compiled`.
Porting the admin to that backend still requires its design-system slot, Dynamic
and prop-schema integration. Do not treat callback-resource adoption as completion
of that compiler migration, or add aliases that silently change intrinsic semantics.
