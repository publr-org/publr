# Admin

The admin, served by the same binary at `/admin`, is a thin adapter over the
operations, like the CLI and the REST API: every form posts to a handler that
calls one operation with the signed-in user's grant, then redirects. Its pages
are authored in PTSX under `ui/` (`layouts/`, `pages/`, `components/`) on the
design system's components (`../ui`), lowered to Zig by the PJSX compiler at
build time, and styled by one stylesheet the JIT compiles from the classes those
pages use (`/admin/styles.css`; the palette lives in `ui/styles/base.css`, its
tokens in `ui/styles/theme.zon`). Pages carry short class names, one per declaration: the build
names every declaration the pages' classes make, a class is written as its declarations'
names (`size-4` is two, `px-4` one), and the sheet holds each declaration once
(`/admin/class-book.js` hands the same names to the browser). A class Zig code
hands a page is named through `class_merge.listed("pl-4")`, which the build reads.
`jit decode --book=<class book json> <page.html>` reads a page's names back as Tailwind. The icon sprite holds every icon the pages
name in their source, plus those named at runtime (a field's kind icon), listed
one per line in `ui/icons.txt`. Every action is a form, and every step of a
longer flow (creating a type, then its fields one by one) is a page of its own,
never a dialog. The one script is the client half of the few components that
keep state in the browser (`/admin/stores.js`, generated from the PTSX, beside
the PublrJS runtime at `/admin/publr.js`): today the type's head, where the
handle and the address follow the name as it is typed.

The chrome is two levels deep, like the design-system library and the PublrJS docs: a
dark icon rail (the mark, one icon per area, then the pages the person pinned, in their
order, each lit instead of its area while it is shown; at the bottom the signed-in user, whose avatar
(their Gravatar, fetched once and served from `/admin/avatar/<md5>`, initials until then)
opens a menu with their name, email and "Log out", and under it the settings), the area's
own light sidebar, and the sheet, which opens with the crumbs (the area, the page's
parents, the page) and the plugins' top bar items. There are five areas: the overview
(`/admin`), the content (`/admin/content` and below), the media library (`/admin/media`
and below, with no sidebar of its own), Design (`/admin/design` and below, no sidebar
either; it opens on the site theme, `/admin/design/system`, whose own nav holds the
templates, patterns and moodboard; Templates and Patterns also have list pages with
Reset) and Settings (everything else:
system settings, users, structure, plugins and every page a plugin adds). The area, the
sidebar and the entry lit in it follow from the address, so a page never names them, and
a refused action stays in the area it was refused in. Who is signed in reaches the chrome
as the request (`Publr.request` in PTSX), never as props a page forwards.

Every page is drawn by one of nine layouts and fills its slots; the layout owns the
chrome, the bands, the gutters and the empty states, and a page sets no spacing of its
own. The build refuses a page whose root is not one of them.

| Layout | For | Slots |
|---|---|---|
| `IndexPage` | A page that lists things: types, users, plugins, the logs, the content | title, parents, description, actions (the primary one last), meta (a row of facts), tabs and a menu at their end, a notice, filters, the list edge to edge, empty (fills the sheet instead of the list), a footer band |
| `FormPage` | A page about one thing: a type's settings, a user, a plugin, a record, a refusal | title, parents, description, actions, meta, problems (an error callout), a notice, the column (one width, at the gutter; centred in focus), an aside (save first, then what is known), danger (last in the aside, each asks first), focus (no sidebar: a content record only) |
| `HubPage` | A page of ways to other pages: Structure, the overview | title, description, the cards, titled groups of more; the overview opens with its own hero |
| `CardPage` | Before sign-in: log in, set up | title, a line, a notice, the form, a footer |
| `ListDetailPage` | Working through a set of things one at a time: a merge's conflicts, a deployment's changes, a media library | title, parents, a header band across the top, the list on the left (`ListDetailGroup`s of `ListDetailItem`s, the open one marked, done ones checked; it takes the section sidebar's place unless `sidebar` keeps it, as a library on a Settings page does), the open thing's detail on the right. A page whose band, list and detail are one island (the media library) leaves the list out and draws them inside it from the layout's own parts: `ListDetailBand`, `ListDetailColumns`, `ListDetailList`, `ListDetailDetail` |
| `FramePage` | A page a plugin brings, drawn by its own read in the plugin frame | title, parents; the frame fills the sheet and grows with what it shows |
| `WorkspacePage` | Something done and watched at once: the AI workspace | title, parents; one island drawing `WorkspaceMain` (the work, filling the sheet) and `WorkspaceAside` (a narrow column on the right); no section sidebar |
| `AroundPage` | The admin in a frame filling the window, under something that must not reload while the frame moves: the corner chat while the agent works | title; one island drawing the frame and what is above it; no chrome of its own, the admin in the frame has it |
| `PanelPage` | A plugin's panel on an edit form, drawn by its own read in the plugin frame | title (the panel's label); what the panel shows and nothing around it; the edit form draws its heading and sizes the frame to it |

Two versions of something are compared side by side: `CompareSides` heads the two columns
(any content: the copies merged, Before and After), then one `CompareField` per field, each
version's values drawn by `CompareValues` (a document pointed at as its card, a field of a
content type, a plugin or a request it makes as its `DefinitionCard`, anything else as text) with what that version changed
read beside the field's label. `publr.admin.compare` turns values into what they draw and
works out what changed: a text word by word, a field's definition line by line, a list
item by item, nothing for a value new whole.

A page's primary action is always in its title band, never repeated in its empty state;
there are no back links, the crumbs lead back. Several lists on one page, or the parts of a
form, are `IndexSection`s: a heading row with its own actions, then the list or the
content.

```
publr serve --port 8080      # then open http://127.0.0.1:8080/admin
```

| Path | What |
|---|---|
| `/admin` | Setup or login when needed; otherwise the overview, "What do you want to build?", with two ways, Your keys and Your agent (`?mode=keys` or `?mode=agents`, remembered in a cookie; Your keys first once a provider is connected). **Your keys**: the prompt, pictures attached to it (the picture button, a paste, or a drop on the box; each goes into the media library as it comes, up to 8), the access the agent gets (Drafts, Read only, Write) and Build, which starts a conversation ([`ai ask`](cli/ai.md)) and opens its workspace; earlier conversations below, each leading to its own. With no provider connected: the official providers from Publr's plugin server to tick and Install (`ai set_up`), then each installed one's key field; once a key is saved the prompt shows (the first provider with a key is used until one is chosen). When the plugin server cannot be reached, a note saying so. **Your agent**: how to set your own agent to work on this site, step by step. Opened at an address on this machine (`localhost`, `*.localhost`, `*.local`, a loopback address): `cd` into the site's folder, install the skill with its own binary, then ask. Opened anywhere else, or on a hosted project (`hosted`, Publr Cloud): one command to run in the folder the agent works in, `curl -fsSL <site>/api/agent/<code> | sh`, carrying a one-time sign-in offered to the person looking (`device offer`, ten minutes), which installs the `publr` command on the PATH, signs the computer in and installs the skill; then ask. Where the host sends an agent's changes to a branch (`work_start`), step 2 says so. Under it, **Copy agent prompt** copies the same as a prompt for an agent to run itself (not shown on the page). Every command has a copy button |
| Every page (asking anywhere) | While a provider is connected and the person may ask, a paste with nothing to paste into (no field, editable region or frame focused; a real paste, never a script's) is an ask: what a dictation app does when it stops listening. The words show in a glowing pill at the bottom centre and are sent after 2 seconds; Enter sends now, Esc or the X cancels. Pictures pasted without words are kept for the next words (up to 8). The ask names the page it came from ([`ai ask --page`](cli/ai.md)), so "this" means what is on it. Sent, the pill gives way to the conversation in a chat at the bottom right, Intercom-like: the ask, the agent's words and steps (Undo on what it moved to the trash), what it does now, Stop while it works, then a reply box. It stays from page to page in the browser tab (Make small leaves a pill in the corner, X closes it), and words pasted or said while it is open and idle are a reply to it. The moment the agent works on a page, the page wraps itself: it goes to `/admin/ai/<id>/around`, which draws the whole admin in a frame filling the window, the chat above it on a page that never reloads. The frame follows the agent (a pointer glides to the link and clicks it, the same page is shown again when it changed) and takes no clicks while it works; the address and title follow the frame. When the turn ends the frame comes off: its last page loads for real, with the chat on it. Back returns to the page it was asked on; clicks the person makes in the frame (while it waits for them) are steps Back takes the frame through, the agent's moves are not, as browsers skip steps a page adds without a click. A page in a frame keeps the whole admin around it unless it asks for `framed=1` (the workspace's preview), and never shows a chat of its own. On a workspace the same paste goes into its reply box and is sent at once; while the agent works, the words wait in the box for the turn to end. **Talking**: hold the talk key (Right Option by default; Settings › AI › Talking picks another for the browser, or turns it off), speak, let go. The pill listens, then shows the words as a paste would; in a field they are typed at the cursor instead, and on a workspace they are its reply. A key held under 250 ms, or with another key (Right Option + A types ą), records nothing. The words come from [`ai transcribe`](cli/ai.md): a connected provider that hears. A dictation app's paste arriving while ours is written down wins. `/admin?ask=<words>&page=<address>` opens the Overview with the words in the prompt and the page sent with them: the site toolbar's hand-off |
| `/admin/ai/ask` | The Overview's prompt, posted: starts the conversation and opens its workspace |
| `/admin/ai/<id>` | A conversation's workspace. On the left, the admin page the agent works on, in a frame: the content type it creates or changes, the content list it adds records to, the plugin it builds, the site when it writes an app's files. While the agent works, the frame follows it as steps land and takes no input, a swirl over its edges; once it stops, the frame is the person's to browse, through its links or the address bar. When the work ends, the frame keeps the last page the agent opened. With no page to show (before the agent opens one, or when it never did), the frame says it shows what Publr is working on, and a page appears there once there is one. The AI is never drawn inside its own preview: the overview (`/admin`, whose prompt starts a conversation) and every `/admin/ai/…` page are never shown there. Following the agent to one shows the placeholder; typed in the address bar or reached through a link, the address bar says "The AI workspace can't open inside its own preview" and the frame stays where it was. A page shown in a frame (`?framed=1`, or a browser loading a frame) draws only its sheet, no rail, sidebar or crumbs; the overview drawn in one has no prompt and no earlier conversations, and a workspace or an ask in one is refused with the same words. On the right, the conversation, live: what was asked, the agent's words as it writes them, each action as one readable line ("Created content type Product") with Show for its page, and its answer; Stop while it works, then a reply box that carries the conversation on ([`ai reply`](cli/ai.md)), taking pictures as the prompt does. The pictures sent with each message show under it |
| `/admin/ai/<id>/around?page=<path>` | The corner chat's frame while the agent works: `page` (an admin page, never a workspace) in a frame filling the window, the conversation in the bottom right corner above it. The person's own conversations only; another page, or one asked for inside a frame, opens the workspace instead |
| `/admin/setup` | First run, in two steps: the site's language (skipped when the admin speaks only English), then the first administrator, who speaks it (`project init`), signed in |
| `/admin/login`, `/admin/logout` | Session cookie in, session cookie out (the rail's avatar menu posts the latter). An account whose roles reach none of the admin's operations (an app's visitor) is refused here, and every other admin URL sends it back here, saying so |
| `/admin/settings` | The settings area, opening on System settings. Its sidebar lists System settings, Users, Structure (for whoever may change structure), Plugins, then every settings section defined under Structure |
| `/admin/settings/ai` | Models on the project's own keys, for administrators. Each model provider installed (a plugin, [`ai providers`](cli/ai.md)) as a card: whether it waits for approval (with Approve, leading to its permissions), is in use, and has its key; where to get a key and a field to paste it (kept as its secret, never shown again); its model and "Use this provider"; Test, one short call; Permissions. Below, the official providers from Publr's plugin server (`https://plugins.publr.app`, or `PUBLR_PLUGIN_CATALOG`), ticked and installed together: each added from its built module as uploading it does, enabled, and granted its requests out, its key and its raised limits. A note when the plugin server cannot be reached, and another when the site's host keeps it offline (`PUBLR_EGRESS=off`) |
| `/admin/settings/updates` | Updating this site's Publr, for administrators ([`update`](cli/update.md)): the release running; Check for updates, listing each newer release with its kind (patch, minor, major) and what it means, and Update, which a major asks twice for; the update's step while it runs, followed to the restart; what the last one did and Go back to the release before; the backups taken before each update. Where Publr Cloud runs the site, a note that it keeps Publr up to date, and no buttons |
| `/admin/trash` | The trash, in Settings ([`trash`](cli/trash.md)): everything removed (content types, taxonomies, field groups, plugins, media, users, secrets, app files), with who removed it (a person or an agent), when, and when it goes for good; Restore (back with everything it held), Remove for good and Empty trash (each confirmed first); a link to the records in the trash. A conversation's removals show in it as "… (in the trash)" with Undo, and Undo all removals once the turn is over |
| `/admin/health` | Site Health, in Settings for administrators, with the number of open cases beside it in the sidebar ([`health`](cli/health.md)): one row per broken reference, the record pointed at (its title and type, leading to it; "Removed record" when gone for good), why ("Deleted, in the trash", "Deleted for good", "No longer shared with <app>") and the records still pointing at it, each opening in the editor. Per row: Restore (in the trash) or "Share with <app> again" (no longer shared), "Remove the reference" (taken out of every record of the case) and "Keep as is" (out of the list until its reason or the number of records pointing changes; "Show N kept as they are" lists them again); the band's "Keep ticked as they are" and "Remove ticked references" act on the ticked rows. `POST /admin/health/act` takes them all: `one` (`<action>\|<target>\|<app>`) or `bulk` with the ticked `case`s |
| `/admin/health/translations` | Site Health's Translations tab: where installed translations disagree on a message, each plugin's version with "Use this" (`POST` here with `locale`, `context`, `id`, `provider`), and each language's coverage per domain, the untranslated messages at `/admin/health/translations/missing?locale=&domain=` as a `.pot` |
| `/admin/removals` | Removal lists, in Settings: what agents asked to remove for good, each waiting for you or done ([`removal`](cli/removal.md)) |
| `/admin/removals/<id>` | One list to review, under a red warning that what you remove is gone for good: every item in words (what goes, what goes with it), all ticked; untick what should stay, then Remove ticked for good, Move ticked to the trash instead (when they are records or terms), or Keep everything. The removal is yours, run as you; the agent's conversation, paused meanwhile (Waiting for you, with a Review button), carries on after, told what you removed. What can never go from a list (your own account) is greyed out with how to do it by hand. After confirming, each item says Removed, Kept or why it was not removed. A conversation's "To remove" steps open it in the workspace's preview |
| `/admin/settings/secrets` | The secrets plugins name but never hold, for administrators ([`secret`](cli/secret.md)): each secret declared or set, the plugins that declare it (installed and built in), whether its value comes from the environment, is set, or is missing; a field to set or replace it (never shown back) and Remove; a row to add one; and, when values are kept with `secret.key` beside the database, a reminder to back it up with the database |
| `/admin/settings/system` | The system's own settings: a placeholder until there is something to configure |
| `/admin/settings/users` | Every account, oldest first: name (yours marked), email, roles, Active or Invited; "Add user" |
| `/admin/settings/users/<tab>` | A tab a plugin adds to Users (`roles`): Users' header and tabs, the tab's sections, and its own primary action in place of "Add user". Users shows tabs only while a plugin adds one |
| `/admin/settings/users/new` | Create an account: name, email, its roles (a checkbox per role the project has, core's and the plugins', with what each lets it do), and a password. Left empty, the account is created invited and the page shows its one-hour set-password link, once, to send to the person |
| `/admin/settings/users/<id>` | One account: rename it, change its roles (never your own), and fill its custom fields: every custom field group whose location rules match (destination User, and one of the account's roles when a rule names one) is drawn as its own group under the account's own fields, each field named `<group handle>.<field>`, with the record editor's controls; repeaters and lists reshape through the same form. "New set-password link" or "Reset password by link" shows a fresh link once; "Delete user" asks first, in a dialog. Deleting yourself, demoting or deleting the last admin, a taken email, and values the fields refuse (listed by path) keep the form up |
| `/admin/structure` | Structure hub: large links to Content Types and Taxonomies, with smaller Components and Custom Fields links under Advanced. Settings sidebar's Structure entry and the Structure breadcrumbs lead here; the rail has no Structure icon, and the Settings icon stays lit on every Structure page. Components and Custom Fields open placeholder pages until implemented |
| `/admin/types` | The content types: name, handle, kind, visibility, owner, field count; links to each type's fields and content |
| `/admin/types/new` | Create a type from its head alone: name (up to 50 characters), handle (made from the name as it is typed, until edited; up to 64) and description (up to 500), each with a live count of the room used and its own error under it when refused; and, for a record type, "Accessible via URL": a switch; on, an address under the site's own (`<site>/posts/{slug}`) where each record has its page, the type starting with a slug field; off, no pages, starting with no fields. Once the project has apps, "App" (Global, or the app it lives in; the app the switcher is on to start with) and "Shared with", two cards: All apps (including ones added later) or Selected apps, which reveals a checkbox per app, the type's own app left out since it always reaches it; for every type but a component, Access, two cards: Public (any visitor reads what is published) or Private (only people signed in, as their roles allow), either with or without a URL; and its Editor, Form or Visual (edited with the block editor, starting with a Body rich text field). Settings schemas and components have their own authoring destinations. Continues to the fields page |
| `/admin/types/<handle>` | The type's page, under Settings with its sidebar: its fields, one row each (the taxonomies that apply to the type appear as locked Terms rows at the end): kind icon, label (a star when required), a summary of the kind; move up or down, edit, and a child for groups and repeaters; the title band's split button adds a field, its arrow opens the records ("See content") and the settings. Preview, beside it, frames the fields and the preview side by side over the page, the preview being how a record of the type looks in the editor, drawn from the definition with every default filled in, inert; the field levels open in the frame as on the page, and Escape, the dimmed area or the close button leave it. Empty until the first field is added. Plugin-declared (system) types show their declared fields locked and accept added fields
| `/admin/types/<handle>/settings` | The head again: name, handle, description, the URL, where it lives, who it is shared with and its access (changing any moves no record), and for a record type its Editor (Form, or Visual: the block editor over a rich text field, chosen from the type's own when it has several; refused with the reason when it has none); "Delete type" asks first, in a dialog with "also delete its records" |
| `/admin/types/<handle>/fields/new` | Add a field in two steps, each a page of its own drawn as a level over the fields, on the type's page (the list dims behind it and leads back; the preview stays on the right and follows the form as it is typed): pick the kind from a grid of cards, then the form, in sections. Label and name (the name follows the label as it is typed, until edited; both with a live count); Single or Multiple values (any kind but slug, group and repeater); Settings: "This field represents the record's title" (a top-level text field; one per type, ticking it moves it), searchable, the record types a reference points at (none for any; the types the type's app reaches: its own, Global ones, then another app's shared with it as `Warehouse › Stock`, or for a Global type the Global ones; one chosen before and no longer reached stays ticked, marked "not shared with" the app) and what purging a linked record does to the pointer (keep, block, clear), a slug's source field, a select's choices (`value | Label` per line); Validation: each rule a checkbox that reveals its bounds and a custom error message while ticked (required, not on a group or a boolean; unique, for a single text, email, url or integer field; the number of values and "no value twice" on any list or repeater; character count, word count and a shape (a preset or a `*` `?` `#` `@` pattern) on text; a number range with a step, or only listed values; a date range as days and "not before today"; reserved slugs; email domains; url schemes and hosts; only published records for a reference; for a media field the file size with a unit, the accepted file families, the image dimensions); Default value: the kind's own control, the moment of creation for a date, or a note when the kind (media, reference, slug, rich text) or the unique rule allows none; Appearance: help text shown under the control (up to 280), a placeholder, rows and plain or Markdown for long text, the formatting a rich text field's editor will offer (bold, italic, links), the date format, a boolean's labels and control (switch, checkbox, radios), a number's unit, decimal places and control (input, slider, rating), a select as a dropdown or radios and checkboxes, a slug locked once published, an email lowercased on save, whether a reference or media field lets editors create new items and link existing ones, and for a group or repeater "collapsed by default", the item label field and the add button's label. Rules that depend on another choice on the form follow it as it is made: the number of values and "no value twice" appear for Multiple, unique and the title for Single, the default control gives way to a note while Unique is ticked or the date takes the moment of creation. The actions sit in the panel's footer: "Finish" returns to the fields page, "Add another field" to the picker, Cancel leaves. A group or repeater continues to its own page to take the fields inside it |
| `/admin/types/<handle>/fields/<path>` | Edit one field in the same kind of level, the preview following: Single or Multiple is fixed after creation; a group or repeater lists the fields inside it here, with add, move and edit. A field inside one (`gallery.caption`) opened from the parent's own page stacks one level deeper: the parent stays under it, dimmed, one small step less inset, and Back (or the dimmed strip) returns to the parent; opened from the fields list or by its address it is one level, and Back returns to the list. The picker for a field inside opens the same way. A change inside a group or repeater lands one level back, on the parent when it is open. "Delete field", in the footer, asks first, in a dialog with "also delete its values in every record". A refused post comes back to the same form with what was wrong listed above it, the values kept |
| `/admin/structure/taxonomies` | The taxonomies, under Structure, as the content types are listed: name, handle, visibility, owner, field count; each opens its fields, and Terms leads to its terms |
| `/admin/structure/taxonomies/new` | Create a taxonomy from its head: name, handle, description as for a type, then "Hierarchical" (terms may have a parent), "One term per record", "Assign taxonomy to content types" (the record types it classifies, ticked: the types whose records have pages of their own, read from the loaded apps' `content/` trees, are listed under Content types; "Show all types" reveals the others) and "Public" (anyone may read its live terms). A new taxonomy starts with a name, a slug and a description field for its terms. Continues to its terms page |
| `/admin/structure/taxonomies/<handle>` | The fields of the taxonomy's terms, as a type's fields page |
| `/admin/structure/taxonomies/<handle>/terms` | The taxonomy's terms as a tree: parents before children, each row indented by its depth with title, slug and status; "New term" at the root, "Add child" on every term of a hierarchical taxonomy; "Settings" leads to the head |
| `/admin/structure/taxonomies/<handle>/settings` | The head again; "Delete taxonomy" asks first, in a dialog with "also delete its terms" |
| `/admin/terms/new?type=<handle>[&parent=<id>]`, `/admin/terms/<id>` | Create or edit a term in the record editor: one input per term field, the same status actions and pending-edit behaviour as a record; in a hierarchical taxonomy the aside holds "Parent", a dropdown over the other terms (never the term itself nor what is below it), and moving a term there re-files every record under it |
| `/admin/content` | The content list: regular content records the signed-in user may read, across types, newest first; settings and other special entries are excluded; the filter bar over it holds the type pill (any type, one, or several ticked in its menu), one pill per filter in force (`Content type is Post`, `Status is Draft`, `Created by Me`, `Updated in the last 7 days`, `Changes are Pending`; the operator opens a menu of the filter's operators, the value a menu of its choices or a day to pick), the search box (`q`, full text over searchable fields) and the Filter menu that adds a pill; the rows sort by title or last update (`order`). Every state is an address: `?type=<handle>` is one type's own view (its name as the title, no type pill; a settings type goes to its editor under Settings without creating a record on first visit; a component has no records and goes to its fields), `?types=<handle>` (repeatable) the content narrowed to some types with the type pill kept, and each filter in force one parameter, `<key>=<operator>:<value>` (`status=is:draft`, `created=by:me`, `updated=within:7d`, `created=before:2026-01-01`; the pills keep the order the filters were added in, and a filter may be added again while one of its operators still settles something no clause of it has, `Created by Me` beside `Created in the last 7 days`; a bare value takes the filter's first operator, an empty one shows the pill with nothing chosen). Which filters exist, their operators, what each takes and how it narrows the list come from one registry (`model/filter.zig`: the core set, plus what plugins declare), which the pills, the Filter menu, saved views and `record list --filters` all read. The sidebar lists the ways in: Recent (updated in the last seven days), the private views (Created by me, Updated by me, then the user's saved views), All, the content by status, the content by type, and the record types: once the project has apps, grouped by where they live, under each group's name (the app the admin is narrowed to first, then Global, then other apps' types shared with it). The list uses the shared `DataTable` component. The initial GET renders the table and filter controls from PTSX with hydration seeds. Filter, search, and sort changes fetch the same address with `Accept: application/json`; the response contains table data and page-header context, never HTML. PublrJS `awaited` drives keyed row/filter updates, retaining matching controls and open menus, while `pushState` and `popstate` keep history in sync. Failed requests retain the current rows and offer Retry. Without JavaScript, links and GET forms still navigate normally |
| `/admin/content?view=<id>` | A saved view: the user's own name over a set of filters (`view create`). Filters added on top of it show as changes: the View menu offers to save them to the view, to create a new view from them, or to clear them; a saved view is renamed from the pencil beside its title and deleted from the same menu. On any other view the menu copies it, filters included, into a new view. Views are private to the user who saved them |
| `/admin/content/new?type=<handle>` | Create a record: a form built from the type's fields, each starting with its default value. Under `serve --dev` the aside also holds "What depends on this" (see below) for a record of the type that does not exist yet |
| `POST /admin/app` | Which app the admin shows, chosen from the switcher in the top bar of every page once the project has apps: All apps or one app by its `.label`. The choice is the viewer's, kept in a cookie (`publr_admin_app`, under `/admin`), and brings them back to the page they chose it on. Narrowed to an app, the whole admin reaches what the app does: the types living in it and the ones shared with it (Global ones among them), and of a plugin's only those of the plugins its `.plugins` names (core's own, the media library's and the Design pages' among them, are always in reach); the sidebar lists no other type, and their records are not found. A new content type or taxonomy starts in that app. It never changes what the viewer's roles allow. An app no longer in the project falls back to All apps |
| `/admin/preview/<id>`, `/admin/preview/new?type=` | The site in preview mode, opened on the record's page, in a new tab from the editor's Preview: the record shows the form as it stood, saved or not, and every read the pages make (entries, collections, references, queries) sees the site as it will be once everything edited is published: drafts included, pending changes applied. Links stay in the preview; the tab's address follows the page (`?path=`) and a reload comes back to it. The tab frames `/admin/preview/<pass>/site/<path>`, sandboxed: the pass (signed for the user and record, an hour) stands in for the session, which never reaches the frame, and opens only preview reads. Rendered on request, never written to the built site, without the toolbar, never cached; reloading resends nothing |
| `/admin/content/<id>/revisions`, `…/revisions/<seq>` | Every version of a record (newest first: kind, title, when, by); one version field by field, with "Restore this version" (a normal save, so parked as pending changes on a live record) |
| `/admin/content/<id>` | Edit a record: one input per field (a reference shows its record as a card; one the record's type no longer reaches says "No longer shared with <app>" and still leads to it, one deleted says "Deleted, in the trash" with its title and leads to it there, or "Deleted for good" and leads nowhere) (a `terms` field authored on the type draws as checkboxes or a dropdown over its taxonomy's terms); Save (straight in for drafts, "Save as pending changes" on live records); Publish / Publish changes, Discard changes; Unpublish, Archive, Delete, Restore; Purge for administrators. The aside holds one section per taxonomy that applies to the type: a tree of checkboxes for a hierarchical taxonomy (ticking a term ticks its ancestors, unticking one unticks what was filed below it), a combobox for a flat one, a dropdown when the field takes one term; every control posts and autosaves with the form. Under `serve --dev` the aside ends with a Dependencies section whose "What depends on this" opens the dependency dialog |
| `/admin/design/templates` | Design › Templates, for the app the admin is narrowed to (else every app): every route whose file marks a template region and every template part a file places, each Default or Overridden, with Reset (asks first) on an override. See [Apps](apps.md#templates-parts-and-patterns) |
| `/admin/design/patterns` | Design › Patterns: the app's pattern files and pattern records, each File, Overridden (Reset) or Added (Remove) |
| `/admin/design/system` | Design › Design system: the block editor's design system builder over the app's tokens and fonts (`data-design-system`, `data-fonts`, `data-editor-site`), filling the sheet; Publish writes them into `app.zon` ([`design save_system`](cli/design.md)). The app is the one the admin is narrowed to, else the only one, else `?app=<name>` from a choice of the apps |
| `/admin/design/moodboard` | Design › Moodboard: the app's board filling the sheet under the crumbs, with its own bar and no tabs (`data-moodboard`, `data-site-label`, `data-items`), saved whole a moment after each change ([`design save_moodboard`](cli/design.md)); images and font files go to the media library; the app chosen as for the design system |
| `POST /admin/design/override` | What the block editor saves, and what Reset and Remove take away: `csrf`, `kind` (`template`, `part`, `pattern`, `reset-template`, `reset-part`, `remove-pattern`), `name` (the route's file for a template, else the part's or pattern's name), `html` (what the editor reopens), `output` (what pages print; not for a pattern), and for a pattern `label`, `category`, `description`, its variants as `variant_<n>_name`, `variant_<n>_label`, `variant_<n>_description` and `variant_<n>_html` from 0 up (none, or two to sixteen), `default_variant`, `default_color_context` and the contexts its copies may not wear as `disabled_color_context_<n>`; they are kept as the pattern record's `variants` repeater and its own fields, and handed back to the editor with the pattern. `app` (a form field or in the address) names the app, else the one the admin is narrowed to, else the project's only one. The server checks the route marks a region, the part is placed by a file, a template keeps a `content` slot; the record is made or saved, and published, in the app, as the signed-in user; Reset and Remove move it to the trash. With `Publr-Fragment: json` it answers `{ "saved": true }` or `{ "saved": false, "reason": "…" }`; a plain form goes back to its Design page |

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
unit, as a slider or a rating. A media field shows its files as tiles (the image, or
the file's type for anything else, with its name and facts): one file, or a gallery
reordered by dragging or by the arrows on a tile, above a dashed area. Files dropped on the
field upload into the media library and join it. A click on the area (its button reads
"Select or upload media"), or on a single file, opens the media library over the page,
nearly full screen: the library's Type, search, Filter (size, visibility) and View, its
folders, tags and upload months, Upload and dropping files, but nothing of managing it.
Type and every listing keep to the families the field's rules take; its rules can turn
upload off. Ticked files are added (a single file field keeps one, a double click picks
it). Inside a group or repeater a media file is still its id. Clearing a field saves it
empty. A field's help text sits under its control, its placeholder inside; a
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

## The media library

`/admin/media` is the library. Across the top is the filter bar Content's list draws, from
the same parts, for what the files themselves are: Type (images, videos, audio, PDFs,
other files) always, and from its Filter menu Size (under 1 MB, 1 to 10 MB, over 10 MB)
and Visibility (public or private), each `is` a value chosen from its menu and dropped
with its ×; custom fields join it later. Then Type to search, View (always show each
tile's name and facts, not only on hover; small, medium or large tiles, kept by the
browser) and Upload. On the left: All files, Unsorted, Unreviewed (files taken in from
the media folder that no one has changed yet, listed while there are any), the folder
tree (each folder with what it holds, itself and below, under the rest of the filter; new
folder, rename, move and delete on its row), the tags (choosing several narrows to files
carrying them all; a tag that would leave nothing is inert; a new one made in place), the
upload year and month, and on a server On the server: Check looks at the media folder for
files put there by hand and says how many are new, missing or skipped (the first few
skipped with why), and Add takes the new ones in (`media sync`). Beside it the files fill
the sheet as
square tiles with nothing between them: an image as a cropped copy, a video as its first
frame with its type in the corner, any other file as its kind's icon over its type (PDF,
MP3), a file whose bytes are gone with Missing in the corner, its name and facts over
the bottom on hover. Ticking tiles brings the
bulk bar: tag, move to a folder, delete. Files dropped anywhere on the tiles upload into
the open folder, each one request whose body is the file. Following a filter, a page or Back asks
`media list` for that page and draws it in place; every one is a link that works
without scripts too.

`/admin/media/:id` is one file, the library's explorer still on the left: its preview
(an image, where clicking places the focal point the crops keep in view; a video or a
sound to play; a PDF to read in the page), title, alt text, caption,
credit, folder, tags by name, and Private; Save posts the form, Delete asks first. A
folder's delete moves what it held up a level.

## The admin's language

The admin speaks English, and any language a plugin brings PO files for (a language pack
such as `language_pl`, or a plugin's own words); people cannot add languages, only
administrators, by installing them. Each person picks theirs on the welcome screen
(`/admin/welcome`), which everyone new sees once before anything else: an invited person
chooses their password there too (the invitation link is `/admin/welcome?token=…`). The
page is written in, and preselects, the browser's language when the admin speaks it;
under the list, a person missing theirs is told to ask an administrator and carry on in
English. Later, the account menu changes it (Language, under their name: Site default,
then each language, `user set_language`). The site's default for everyone who picked none
is under Settings › System › General (`project set_admin_language`). A message no
catalogue has is shown in English.

The content language is apart from it. Where a plugin declares variants with a picker
(the languages plugin: Content language), it is top right, before the app picker: the
person's own choice (`user variant`, `user set_variant`), the main language until they
pick. Lists show titles in it, falling back to the main language's; the editor, the
media, user and settings forms and the visual editor open in it (`<html data-variant>`);
their own switches still flip one page. Every record is listed in every language, also
those of types that leave untranslated records out of the site.

Text is marked where it is written, in English, which is the key: `Publr.t("Empty trash")`,
`Publr.t("Kept for {days} days", { days })`, `Publr.tn("{count} record", "{count}
records", count)`, `Publr.tx("verb", "Post")` in PTSX, and `session.translated("Saved.", .{})`
(placeholders in `.values`), `translated_in` and `translated_count` in the adapters. The compiler
turns a PTSX message into a lookup in the request's catalogue on the server; in the browser
the same calls read the catalogue the page loads (`/admin/messages/<locale>.js`, kept by its
version). A message is a literal string, one sentence, its variable parts named
placeholders; counts go through the plural form, whatever English needs.

`zig run scripts/i18n.zig -- ui src/adapters ...` writes the template (`.pot`) of every
marked message, with where it is written, for any PO editor. A plugin brings translations
with `pub const translations = [_]publr.plugin.Translation{ .{ .locale = "pl", .label =
"Polski", .domain = "publr", .po = @embedFile("i18n/publr/pl.po") } }`. `domain` says whose
words the file translates: `publr` for the core's, a plugin's name for that plugin's (its
own name when left out). Every file of a language is merged when the server starts. A
message is keyed by its English text, so an edited message simply stops matching until
translated again. When files disagree on a message, the first-party one wins: the words'
owner's own file, or a `publr` file marked `.official = true`. Otherwise the first plugin's
wins. A file whose `Plural-Forms` disagrees with the language's plural rule stops the
server, naming it.

Site Health's Translations tab (`/admin/health/translations`) lists every disagreement,
each plugin's version side by side, with "Use this" on each. A pick replaces the winner for
that message from the next page on, and clearing it goes back to the first-party one. The
tab also shows how much of each domain's messages each language covers, which plugins
translate them, and "Missing (.pot)": a template of the untranslated ones, ready for a PO
editor and a plugin of translations. The build embeds every message the core and the
compiled-in plugins mark (`scripts/i18n.zig --lines`), so the count needs no source.

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
