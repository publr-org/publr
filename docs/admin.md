# Admin

The admin, served by the same binary at `/admin`, is a thin adapter over the
operations, like the CLI and the REST API: every form posts to a handler that
calls one operation with the signed-in user's grant, then redirects. Its pages
are authored in PTSX under `ui/` (`layouts/`, `pages/`, `components/`) on the
design system's components (`../ui`), lowered to Zig by the PJSX compiler at
build time, and styled by one stylesheet the JIT compiles from the classes those
pages use (`/admin/styles.css`; the palette lives in `ui/styles/base.css`, its
tokens in `ui/styles/theme.zon`). The icon sprite holds every icon the pages
name in their source, plus those named at runtime (a field's kind icon), listed
one per line in `ui/icons.txt`. Every action is a form, and every step of a
longer flow (creating a type, then its fields one by one) is a page of its own,
never a dialog. The one script is the client half of the few components that
keep state in the browser (`/admin/stores.js`, generated from the PTSX, beside
the PublrJS runtime at `/admin/publr.js`): today the type's head, where the
handle and the address follow the name as it is typed. The chrome is two levels deep, like the design-system
library and the PublrJS docs: a dark icon rail (the mark, one icon per section; at the
bottom the signed-in user, whose avatar opens a menu with their name, email and
"Log out", and under it the settings), the section's own light sidebar
when the section has a second level (under Content, the views of the content: the
recent, the user's private and saved views, the content by status and by type; under Settings,
System settings and Users first, then the modeled settings sections), and the sheet, which
opens with a breadcrumb bar (section, parent, page) and a link to the site. The
overview has no second level, so its sheet starts at the rail. Each page then
has its title band (the title, the page's actions); lists run edge to edge, and
the filters are pills in one bar. The pages that edit one thing (a
record, a type's settings and fields, a field) drop the section sidebar: the
rail alone, the form centred in the sheet at a capped width, and an aside on
the right that stays in view with the actions first (save, the status actions),
then what is known about the thing (status, versions; a field's kind), then
what cannot be undone.

```
publr serve --port 8080      # then open http://127.0.0.1:8080/admin
```

| Path | What |
|---|---|
| `/admin` | Setup or login when needed; otherwise the overview (a placeholder for the dashboard) |
| `/admin/setup` | First run: create the administrator (`project init`) and sign in |
| `/admin/login`, `/admin/logout` | Session cookie in, session cookie out (the rail's avatar menu posts the latter). An account whose roles reach none of the admin's operations (an app's visitor) is refused here, and every other admin URL sends it back here, saying so |
| `/admin/settings` | The settings area, opening on System settings. Its sidebar lists System settings, Users, then every settings section defined under Structure |
| `/admin/settings/system` | The system's own settings: a placeholder until there is something to configure |
| `/admin/settings/users` | Every account, oldest first: name (yours marked), email, roles, Active or Invited; "Add user" |
| `/admin/settings/users/new` | Create an account: name, email, its roles (a checkbox per role the project has, core's and the plugins', with what each lets it do), and a password. Left empty, the account is created invited and the page shows its one-hour set-password link, once, to send to the person |
| `/admin/settings/users/<id>` | One account: rename it, change its roles (never your own), and fill its custom fields: every custom field group whose location rules match (destination User, and one of the account's roles when a rule names one) is drawn as its own group under the account's own fields, each field named `<group handle>.<field>`, with the record editor's controls; repeaters and lists reshape through the same form. "New set-password link" or "Reset password by link" shows a fresh link once; "Delete user" asks first, in a dialog. Deleting yourself, demoting or deleting the last admin, a taken email, and values the fields refuse (listed by path) keep the form up |
| `/admin/structure` | Structure hub: large links to Content Types and Taxonomies, with smaller Components and Custom Fields links under Advanced. The rail and Structure breadcrumbs lead here. Components and Custom Fields open placeholder pages until implemented |
| `/admin/types` | The content types: name, handle, kind, visibility, owner, field count; links to each type's fields and content |
| `/admin/types/new` | Create a type from its head alone: name (up to 50 characters), handle (made from the name as it is typed, until edited; up to 64) and description (up to 500), each with a live count of the room used and its own error under it when refused; and, for a record type, "Accessible via URL": a switch; on, an address under the site's own (`<site>/posts/{slug}`) where each record has its page, the type is public and starts with a slug field; off, an internal type read by signed-in users only, starting with no fields. Settings schemas and components have their own authoring destinations. Continues to the fields page |
| `/admin/types/<handle>` | The type's page in two columns that scroll on their own. Left, its fields, one row each (the taxonomies that apply to the type appear as locked Terms rows at the end): kind icon, label (a star when required), a summary of the kind; move up or down, edit, and a child for groups and repeaters; the title band's one split button adds a field, its arrow opens the records ("See content") and the settings. Right, the preview: how a record of the type looks in the editor, drawn from the definition with every default filled in, inert. Empty until the first field is added. Plugin-declared (system) types show their declared fields locked and accept added fields
| `/admin/types/<handle>/settings` | The head again: name, handle, description, the URL; "Delete type" asks first, in a dialog with "also delete its records" |
| `/admin/types/<handle>/fields/new` | Add a field in two steps, each a page of its own drawn as a level over the fields, on the type's page (the list dims behind it and leads back; the preview stays on the right and follows the form as it is typed): pick the kind from a grid of cards, then the form, in sections. Label and name (the name follows the label as it is typed, until edited; both with a live count); Single or Multiple values (any kind but slug, group and repeater); Settings: "This field represents the record's title" (a top-level text field; one per type, ticking it moves it), searchable, the record types a reference points at (none for any) and what purging a linked record does to the pointer (keep, block, clear), a slug's source field, a select's choices (`value | Label` per line); Validation: each rule a checkbox that reveals its bounds and a custom error message while ticked (required, not on a group or a boolean; unique, for a single text, email, url or integer field; the number of values and "no value twice" on any list or repeater; character count, word count and a shape (a preset or a `*` `?` `#` `@` pattern) on text; a number range with a step, or only listed values; a date range as days and "not before today"; reserved slugs; email domains; url schemes and hosts; only published records for a reference; for a media field the file size with a unit, the accepted file families, the image dimensions); Default value: the kind's own control, the moment of creation for a date, or a note when the kind (media, reference, slug, rich text) or the unique rule allows none; Appearance: help text shown under the control (up to 255), a placeholder, rows and plain or Markdown for long text, the date format, a boolean's labels and control (switch, checkbox, radios), a number's unit, decimal places and control (input, slider, rating), a select as a dropdown or radios and checkboxes, a slug locked once published, an email lowercased on save, whether a reference or media field lets editors create new items and link existing ones, and for a group or repeater "collapsed by default", the item label field and the add button's label. Rules that depend on another choice on the form follow it as it is made: the number of values and "no value twice" appear for Multiple, unique and the title for Single, the default control gives way to a note while Unique is ticked or the date takes the moment of creation. The actions sit in the panel's footer: "Finish" returns to the fields page, "Add another field" to the picker, Cancel leaves. A group or repeater continues to its own page to take the fields inside it |
| `/admin/types/<handle>/fields/<path>` | Edit one field in the same kind of level, the preview following: Single or Multiple is fixed after creation; a group or repeater lists the fields inside it here, with add, move and edit. A field inside one (`gallery.caption`) opened from the parent's own page stacks one level deeper: the parent stays under it, dimmed, one small step less inset, and Back (or the dimmed strip) returns to the parent; opened from the fields list or by its address it is one level, and Back returns to the list. The picker for a field inside opens the same way. A change inside a group or repeater lands one level back, on the parent when it is open. "Delete field", in the footer, asks first, in a dialog with "also delete its values in every record". A refused post comes back to the same form with what was wrong listed above it, the values kept |
| `/admin/taxonomies` | The taxonomies, as the content types are listed: name, handle, visibility, owner, field count; each links to its terms |
| `/admin/taxonomies/new` | Create a taxonomy from its head: name, handle, description as for a type, then "Hierarchical" (terms may have a parent), "One term per record", "Assign taxonomy to content types" (the record types it classifies, ticked: the types whose records have pages of their own, read from the loaded apps' `content/` trees, are listed under Content types; "Show all types" reveals the others) and "Public" (anyone may read its live terms). A new taxonomy starts with a name, a slug and a description field for its terms. Continues to its terms page |
| `/admin/taxonomies/<handle>` | The taxonomy's terms as a tree: parents before children, each row indented by its depth with title, slug and status; "New term" at the root, "Add child" on every term of a hierarchical taxonomy; "Settings" leads to the head |
| `/admin/taxonomies/<handle>/settings` | The head again; "Delete taxonomy" asks first, in a dialog with "also delete its terms" |
| `/admin/terms/new?type=<handle>[&parent=<id>]`, `/admin/terms/<id>` | Create or edit a term in the record editor: one input per term field, the same status actions and pending-edit behaviour as a record; in a hierarchical taxonomy the aside holds "Parent", a dropdown over the other terms (never the term itself nor what is below it), and moving a term there re-files every record under it |
| `/admin/content` | The content list: regular content records the signed-in user may read, across types, newest first; settings and other special entries are excluded; the filter bar over it holds the type pill (any type, one, or several ticked in its menu), one pill per filter in force (`Content type is Post`, `Status is Draft`, `Created by Me`, `Updated in the last 7 days`, `Changes are Pending`; the operator opens a menu of the filter's operators, the value a menu of its choices or a day to pick), the search box (`q`, full text over searchable fields) and the Filter menu that adds a pill; the rows sort by title or last update (`order`). Every state is an address: `?type=<handle>` is one type's own view (its name as the title, no type pill; a settings type goes to its editor under Settings without creating a record on first visit; a component has no records and goes to its fields), `?types=<handle>` (repeatable) the content narrowed to some types with the type pill kept, and each filter in force one parameter, `<key>=<operator>:<value>` (`status=is:draft`, `created=by:me`, `updated=within:7d`, `created=before:2026-01-01`; the pills keep the order the filters were added in, and a filter may be added again while one of its operators still settles something no clause of it has, `Created by Me` beside `Created in the last 7 days`; a bare value takes the filter's first operator, an empty one shows the pill with nothing chosen). Which filters exist, their operators, what each takes and how it narrows the list come from one registry (`model/filter.zig`: the core set, plus what plugins declare), which the pills, the Filter menu, saved views and `record list --filters` all read. The sidebar lists the ways in: Recent (updated in the last seven days), the private views (Created by me, Updated by me, then the user's saved views), All, the content by status, the content by type, and the record types. The list uses the shared `DataTable` component. The initial GET renders the table and filter controls from PTSX with hydration seeds. Filter, search, and sort changes fetch the same address with `Accept: application/json`; the response contains table data and page-header context, never HTML. PublrJS `awaited` drives keyed row/filter updates, retaining matching controls and open menus, while `pushState` and `popstate` keep history in sync. Failed requests retain the current rows and offer Retry. Without JavaScript, links and GET forms still navigate normally |
| `/admin/content?view=<id>` | A saved view: the user's own name over a set of filters (`view create`). Filters added on top of it show as changes: the View menu offers to save them to the view, to create a new view from them, or to clear them; a saved view is renamed from the pencil beside its title and deleted from the same menu. On any other view the menu copies it, filters included, into a new view. Views are private to the user who saved them |
| `/admin/content/new?type=<handle>` | Create a record: a form built from the type's fields, each starting with its default value. Under `serve --dev` the aside also holds "What depends on this" (see below) for a record of the type that does not exist yet |
| `/admin/content/<id>/revisions`, `…/revisions/<seq>` | Every version of a record (newest first: kind, title, when, by); one version field by field, with "Restore this version" (a normal save, so parked as pending changes on a live record) |
| `/admin/content/<id>` | Edit a record: one input per field (a `terms` field authored on the type draws as checkboxes or a dropdown over its taxonomy's terms); Save (straight in for drafts, "Save as pending changes" on live records); Publish / Publish changes, Discard changes; Unpublish, Archive, Delete, Restore; Purge for administrators. The aside holds one section per taxonomy that applies to the type: a tree of checkboxes for a hierarchical taxonomy (ticking a term ticks its ancestors, unticking one unticks what was filed below it), a combobox for a flat one, a dropdown when the field takes one term; every control posts and autosaves with the form. Under `serve --dev` the aside ends with a Dependencies section whose "What depends on this" opens the dependency dialog |

Under `serve --dev` the record editor's aside carries one more section,
Dependencies, with a button, "What depends on this", that opens a dialog
explaining what a change to the record reaches. It starts with the keys the
save raises, then two lists. "Needs a rebuild": every page built to a file and
every static fragment whose render reads the record's type, itself or through
a template it embeds, which is what the next quiet moment rewrites; a page or
fragment the index recorded that no template explains is listed too, since the
plan over-approximates and never misses. "Rendered per request": the live pages
and dynamic fragments that read the type, shown for the whole picture, with
nothing to rebuild. Each row is the route or fragment address (a page's is a
link that opens it in its app in a new tab, when there is one to open: a route
with a parameter in it, `/posts/:slug`, is not, except as the record's own
page, shown beside it; a fragment's address only ever serves bare HTML, so it
is never a link), its kind, and its status (in the last build, not built yet,
rendered per request, or, for a new record's own page, once it has a slug),
green in the first list and purple in the second, the colours the `--dev`
island tint uses. A row's "Why", folded by default, is the chain that leads to it: the
template and how it reads (renders the record, or lists the type's records),
the template it embeds when the read is one step down, for a fragment the
pages that place it (marked when the placeholder is a prerender, which stays a
stale copy until that page is next built) and the fragments it sits inside,
and what the last build recorded it reading (`project impact`). With several apps, each
app's pages and fragments are listed, addressed under its own mount. A new record shows
the same for its type, without a `record:` key. Outside `--dev` the section
does not exist.

The type's page keeps its levels itself, and the stack is the way the editor
came: a link to a field page under the list opens one level, a link inside a
level opens one over it (the picker and the form take each other's place), and
Back, the dimmed area and Escape drop one level, Cancel and the breadcrumb drop
to a page already open. Each panel is fetched alone (`Publr-Fragment: panel`,
with `Publr-Below` naming the level it slides over, which its Back reads); the
address follows with `pushState`, so every level is a deep link that opens by
itself, and the history buttons walk the stack. A form inside a level posts with the same header: a
refusal comes back as the panel drawn again with the problems, put in place; a
write that went through answers `Publr-Location` with an empty body, and the
page draws the list and the preview again from its own address before going
there. Without the script every link and form still works as a page.

The type's preview is the record editor drawn for the type (no title band, no
status strip, no aside) inside an inert host. While a field form is open, its
client half posts the form to its own action after every input, with
`Publr-Fragment: preview`, and the answer, the editor drawn for the definition
with that field as typed (an unnamed field reads "Untitled field"), replaces the
preview; nothing is saved by such a post.

The record editor is a fragment (`/admin/content/<id>/editor`,
`/admin/content/new/editor?type=`) the page wraps in its shell and the drawer
fetches bare; its client half autosaves: every input marks the form dirty and,
after a pause, posts it with `Publr-Fragment: json`, which answers `{ saved,
id, version, title, status, changed }` or `{ saved: false, reason }` (the
status strip under the title shows which). A new record is created by its
first autosave and the address changes to its page. There is no Save button:
the aside holds one split button: its face is Publish (or Publish changes)
when publishing is on offer, else the first status action that can be undone;
its arrow opens a menu with every other action, the destructive ones last. Every other submit inside the editor (a
reshape, a status action) is posted with `Publr-Fragment: editor` and the
answer, the editor drawn again, replaces it in place, so the page never
reloads.

Fields render by their kind's descriptor, one control per value: text, email
and url as inputs, a slug behind the address it completes, long text as a
textarea, a boolean as a switch, integer and number as number inputs (with the
field's range), a date and time as a `datetime-local` input, or a `date` input for a field
shown as days (milliseconds in the document, UTC either way), a select as a
select, or as radios and checkboxes when the field says so, a boolean as a
switch, a checkbox or two radios with the field's labels, a number with its
unit, as a slider or a rating, a media file as its id until the media library
lands. A field's help text sits under its control, its placeholder inside; a
group or repeater folds when the field says so, and a repeater item's header
reads its label field. A new record starts with every default. A
reference is a card (the record's type and status, its title as the open
row); opening it slides the record's own editor in from the right as a level
of the reference drawer, a panel over the sheet alone (the rail and the topbar
stay in view) with Back and Close beside its title, where it autosaves like the
page. A reference inside it opens one level deeper: a panel inset one step
further from the left, the level under it dimmed and inert; Back, the dimmed
area and Escape drop the top level, Close drops them all. The topbar's
breadcrumb follows the stack: each level's title is a crumb after the page's,
and a crumb under the top one brings that level (or the page) back. Under the cards,
"Link existing item" opens the picker as a level (`/admin/content/pick?type=&q=`,
the target type's records searched, a Link button each) and "Create new
item" opens a blank editor of the target type there; the picked or created
record is added to the field that asked, in the editor that opened the level. A
reference names the record types
it may point at (ticked on the field's page; none ticked means any record
type): with one type the two buttons act at once, with more each opens a menu
of types, and past eight types the menu carries a search box. A field that
holds many values is a
list: one control per value with move up, move down and remove, "Add value"
appending a blank one. A group draws its fields inline in a box as
`group.child`; a repeater draws one box per item with add, remove and move,
posted as `name[index].child`. A list inside a group or repeater, and a kind
without a control, are edited as JSON. Saves carry
`expected_version`, so a stale edit answers `Conflict`; an invalid document
lists its problems (`record validate`). The edit form shows the pending copy
when the record has unpublished changes, and the list marks such records
*changed*.

Every POST is same-origin only and carries the session's CSRF token as a
hidden field; anonymous requests are sent to the login page. Private types
and their records never appear to anyone who may not read them.

Interactive reads are owned PublrJS `awaited` resources. Lists and structure
refreshes use query tags; successful `mutation` writes invalidate those readers.
Panels show pending and error states and can retry failed reads. Closing a panel
disposes its request, and a late response cannot reopen it. The structure stack
is rendered as keyed JSX rows, including a panel opened through a direct URL.

Autosave serializes writes and tracks the revision of the submitted draft.
Typing while a save is pending triggers another save with the returned version;
only the latest acknowledged draft is reported as saved. Failed saves retain the
form and offer Retry save. New-record creation drains later edits before replacing
the form. Status and reshape actions wait for those saves and expose failures in
the status strip. Forms being replaced by a pending action are temporarily inert.

The MPA routes remain the native fallback. Enhanced reads request JSON with
`Accept: application/json`: lists return HTML, title and canonical address; field
panels return HTML and title; reference panels return HTML. A request to the type
page with `Publr-Fragment: columns` returns list and preview HTML together, without
parsing a complete page. These remain trusted server-rendered HTML regions, with
child islands disposed before each replacement is hydrated.

### Reusing the data table

`ui/components/ContentList.ptsx` composes `@publr/ui/DataTable.ptsx` with the
content-specific header. The shared component owns requests, filters, search,
keyed rows, loading/errors, and history. The content adapter projects authorized
records into the generic schema in `src/adapters/admin/content/table.zig`.
Other list pages can provide the same schema; they do not need a client renderer
or an HTML-fragment endpoint. See `../ui/docs/data-table.md` for the contract.

## Settings and custom fields

Structure places Content Types, Taxonomies and Settings together. Components and Custom Fields
are under Advanced. Each schema editor reuses the field kinds, validation, nested fields and live
preview. Its kind is fixed by the destination; changing the submitted kind cannot move a schema
between these areas.

- `/admin/structure/settings` defines singleton settings sections. Each section has its own name,
  handle and fields. New sections are private; Public explicitly enables anonymous delivery of
  published values.
- `/admin/settings` opens System settings; Users follows, then every settings section.
  The sections come from settings definitions and appear at `/admin/settings/<handle>`
  (`system` and `users` are taken by the fixed pages). They use the
  existing record editor and publishing lifecycle. Visiting a section does not create a record;
  the first valid save does. Existing singleton definitions remain available without migration.
- `/admin/components` authors reusable component field schemas.
- `/admin/custom-fields` lists named custom field groups. Create a group, add fields and choose
  User or Media through AND/OR location rules. Multiple groups may share a destination.
  `custom_fields.list/create/get/update/validate/delete` expose the same operations through CLI
  and REST; `group` identifies a group by its handle.

Custom fields do not create content types, singleton records or routes. Their schemas are stored
in the same `field_groups` table as content types, taxonomies, settings and components. Only
administrators may read or modify them. A user's page under Settings draws every group that
applies to the account and stores the values in `user_values`, one document per account with
one object per group (`user get`, `user update --document`). Media management remains to be done. Onboarding recipes are outside this change.

Settings sections are singletons: an app's settings (its homepage's content, its
navigation) are a settings type its plugin declares or an administrator creates under
Structure, one record edited under Settings. Save creates a draft or pending edit; Publish
makes the document the one templates read. Editors cannot read or modify singleton
settings values; a role needs `settings.edit`.

Field authoring has General, Validation, Presentation and Conditional Logic tabs. Conditional
rules use AND within a group and OR between groups, with at most eight groups of eight rules.
Rules refer to sibling fields; missing references and cycles are rejected on the server. Hidden
fields retain their stored values, and supplied values still undergo validation. Requiredness
only applies while a field's condition matches.

Custom field groups combine their fields with Location Rules, Presentation and Group Settings
on one builder page. Content Types, Taxonomies, Settings and Components keep their dedicated
authoring UI and do not expose a separate Field group page. Custom locations can match User,
Media, user role (any role the project has) or media type. Presentation controls position, label alignment and instruction placement. Disabling
a group preserves values. User/media destination rules are ready for their future entity editors.

The shared catalogue includes color, time, masked text, user references, links, locations, embed
URLs, messages, tabs and accordions. Links and locations use ordinary nested fields. Location is
address and coordinates; embed is a validated URL, without a provider-specific map or preview.
Choice fields offer dropdown, list and button presentations; media multiplicity covers galleries.
Layout elements have no stored value. Masked text is ordinary field data, not a secret vault.
