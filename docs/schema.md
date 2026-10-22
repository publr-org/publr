# Database schema

Publr keeps everything in one SQLite file (`data/publr.db` by default), in
strict tables created by `src/lib/db/schema.sql` when the database opens. `schema.sql` is
the shape of a new database; a database made by any earlier release since 0.3.0 reaches
it through the chain of migrations (`src/lib/db/migrations/`, recorded in `migrations`),
run by the gate every open goes through ([Updates](updates.md)). A database from before
0.3.0 is brought to the shape once: missing tables made, columns added since a table first
shipped added in place (`added_columns` in `src/lib/db/schema.zig`), drifted tables
rebuilt, rows kept. Ids are 24 hex
characters, times are Unix milliseconds, booleans are `0`/`1`. A record's, term's, user's,
internal record's or saved view's id is time-ordered: the millisecond it was made (12
characters), a counter within that millisecond (4), random (8). Sorted by id, rows are in
the order they were made; copies of a database merged later cannot collide.

The shape is deliberately small. Two tables carry the content of the whole
site, whatever a plugin adds: `records` (one row per thing: a record, an
author, later a media item) and `record_values` (one row per field value, in
a named *slot*: `live`, `pending`, or a plugin's own copy). A content type
says which fields a record has; the type is data (`content_types`), plugins
declare their own types in code and they are created when the database
opens. Plugins therefore extend storage by adding **types and fields, not
tables**. History is the other storage shape: `snapshots`, frozen read-only
copies of documents (revisions and whatever else a plugin archives). The rest
is authentication (`users`, `sessions`), site settings (`settings`), and the
full-text index (`record_search`).

Classification is the same shape once more, on its own tables: `taxonomies`
are the schemas of terms as `content_types` are of records, `terms` hold the
identity and lifecycle of a term (plus its parent), `term_values` its field
values per slot, `term_search` its full-text index. One store implementation
serves both domains; only the table names differ. `record_terms` joins the
two: every term a record is assigned to, in a slot, with its ancestors.

```mermaid
erDiagram
    settings {
        text key PK
        text value
    }
    users ||--o{ sessions : "signs in as"
    users {
        text id PK
        text email UK
        text role
        text password_hash
    }
    sessions {
        text id PK
        blob secret_hash
        text user_id FK
        integer expires_at
    }
    content_types ||--o{ records : "shapes"
    content_types {
        text id PK
        text handle UK
        integer public
        text definition
    }
    records ||--o{ record_values : "has values (per slot)"
    records ||--o{ record_search : "indexed by"
    records ||--o{ snapshots : "frozen copies of"
    records {
        text id PK
        text type_id FK
        text status
        integer changed
        integer version
        text created_by
        text updated_by
    }
    record_values }o--o| records : "points at (kind = ref)"
    record_values {
        text record FK
        text slot
        text type_id
        text field
        integer ordinal
        text kind
        any value
    }
    record_search {
        text text
        text record
        text slot
        text type_id
        text field
    }
    snapshots {
        text record
        integer seq
        text kind
        integer at
        text by
        text document
    }
    taxonomies ||--o{ terms : "shapes"
    taxonomies {
        text id PK
        text handle UK
        text definition
    }
    terms ||--o{ term_values : "has values (per slot)"
    terms ||--o{ terms : "parent of"
    terms {
        text id PK
        text type_id FK
        text parent_id FK
        text status
    }
    term_values {
        text record FK
        text slot
        text field
        any value
    }
    records ||--o{ record_terms : "assigned to"
    terms ||--o{ record_terms : "members"
    record_terms {
        text record FK
        text slot
        text field
        text term FK
        integer explicit
    }
```

`settings` stands alone: a key/value table the core and plugins read one row
at a time; it is not a record.

## `settings`

Site-wide key/value settings, one row per setting, written by the core
(`site.init` records `site.initialised_at`), later by the settings operations
and by plugins under their own dotted prefix (`seo.default_image`).

| Column | Type | Meaning |
|---|---|---|
| `key` | text, primary key | Setting name, dotted (`site.initialised_at`) |
| `value` | text | The value as text |
| `updated_at` | integer | Last write |

Publr keeps two of its own here. `publr.release` is the release that last opened the
database; when another one opens it, the whole site is backed up first. The gate writes it
([updates.md](updates.md)).

## `migrations`

Every migration this database has been through, core's and each compiled-in plugin's. A
fresh database records every migration its release knows, since `schema.sql` already has
their result. A row the opening release does not know means a newer release migrated it.

| Column | Type | Meaning |
|---|---|---|
| `source` | text | `publr`, or the plugin the migration belongs to |
| `name` | text | The release it reaches (`0.4.0`), or `unreleased` during development |
| `sha256` | text | The migration file's SHA-256 when it ran; an unreleased one runs again when it changes |
| `one_way` | integer 0/1 | It dropped, renamed or rewrote: the release before cannot run on the result |
| `applied_ms` | integer | When it ran |

Primary key `(source, name)`.

## `users`

Accounts. What an account may do is its roles (`user_roles`). An account
without a password hash and without an identity (`identities`) is inactive: it
was created with a set-password link and cannot sign in until the link is
redeemed.

| Column | Type | Meaning |
|---|---|---|
| `id` | text, primary key | Account id |
| `email` | text, unique | Sign-in email, lowercased and trimmed |
| `display_name` | text | Name shown in the admin |
| `password_hash` | text, nullable | Argon2id PHC string; null while inactive, or when a provider is the only way in |
| `password_token_hash` | blob, nullable | SHA-256 of the current set-password token |
| `password_token_expires_at` | integer, nullable | When that token stops working |
| `created_at`, `updated_at` | integer | Timestamps |

## `user_roles`

The roles an account holds, one row each, at most 16 per account. A name with
no row in `roles` grants nothing. Deleting a user removes their rows; removing a
role removes its holders' rows.

| Column | Type | Meaning |
|---|---|---|
| `user_id` | text, references `users` | Whose role; cascades on delete |
| `role` | text | The role's name |

Primary key `(user_id, role)`. Index `user_roles_role (role, user_id)`: how
many accounts hold `admin` (the last one stays).

## `roles`

Every role: core's `admin`, `editor` and `contributor`, the ones plugins declare,
and the ones the site makes. At most 64. `admin` grants `*` and never changes.

| Column | Type | Meaning |
|---|---|---|
| `name` | text, primary key | `[a-z][a-z0-9_]*`, 1 to 32 characters |
| `label` | text | As the admin names it |
| `description` | text | One sentence, up to 200 characters |
| `owner` | text | `core`, the plugin that declared it first, or empty for the site |
| `created_at`, `updated_at` | integer | Timestamps |

## `role_grants`

What a role lets its holders call, one grant each, at most 128 per role: an
operation (`record.save`), a namespace (`record.*`), `*`, or any of these after
`!` to take names back.

| Column | Type | Meaning |
|---|---|---|
| `role` | text, references `roles` | Whose grant; cascades on delete |
| `pattern` | text | The grant |

Primary key `(role, pattern)`.

## `role_declarations`

What each owner's code declared, as last applied: the row with an empty
`pattern` records that the owner declared the role, the others its grants. A
later declaration adds only the grants the previous one lacked, so what the site
took away stays away; `role reset` puts a role back to what its declarations
grant.

| Column | Type | Meaning |
|---|---|---|
| `owner` | text | `core` or a plugin's name |
| `role` | text | The role's name |
| `pattern` | text | A declared grant, or empty for the role itself |

Primary key `(owner, role, pattern)`. Index `role_declarations_role (role, owner)`.

## `sessions`

Signed-in sessions. The client holds `id.secret`; only the hash of the
secret is stored. Rows slide (expiry extends on use) and are removed by
sign-out, expiry cleanup, or the per-user cap (32 newest kept). Deleting a
user removes their sessions.

| Column | Type | Meaning |
|---|---|---|
| `id` | text, primary key | Session id (the public half of the token) |
| `secret_hash` | blob | SHA-256 of the secret half |
| `user_id` | text, references `users` | Whose session; cascades on delete |
| `expires_at` | integer | Absolute expiry |
| `created_at` | integer | When it was created |

Indexes: `sessions_user_id (user_id)`, `sessions_expires_at (expires_at)`.

## `views`

A user's saved views of the content list: a name over a view, kept as the JSON
`view create` takes: types, filter clauses, search, order, columns, page size and the
fields offered to filter and order by (`{"types":["order"],"type_view":true,
"clauses":[{"key":"field.total","operator":"more","value":"4999"}],"order":"-number"}`),
`me` and relative days resolved when the list is drawn.
Private: listed, read and changed by the owner alone. Deleting a user removes
their views. Up to 64 per user.

| Column | Type | Meaning |
|---|---|---|
| `id` | text, primary key | View id |
| `user_id` | text, references `users` | Whose view; cascades on delete |
| `name` | text | The name the sidebar shows, up to 80 characters |
| `query` | text | The filters, as JSON |
| `created_at`, `updated_at` | integer | Timestamps |

Indexes: `views_user (user_id, name)`.

## `rail_pins`

The pages a person pinned to their rail, below the fixed Overview, Content and Media, in
the order pinned. Each is a reference: a core page (`plugin` empty, `page` like
`settings/users`) or a plugin's page or section (`plugin` and its `page`,
`section/<handle>` for a section). Drawn only while the page exists and the person may see
it. Up to 16 per person. Deleting a user removes their pins.

| Column | Type | Meaning |
|---|---|---|
| `user_id` | text, references `users` | Whose rail; cascades on delete |
| `plugin` | text | The plugin whose page it is; empty for a core page |
| `page` | text | The page |
| `position` | integer | Its place on the rail, from the top |
| `pinned_at` | integer | When it was pinned |
| `hidden` | integer | 1: not a pin but the person's note that they hid a pin made for everyone |

Primary key: `(user_id, plugin, page)`.

## `shared_rail_pins`

The pages administrators pinned to everyone's rail, drawn on each person's rail before
their own pins unless they hid one (`rail_pins.hidden`). Up to 16.

| Column | Type | Meaning |
|---|---|---|
| `plugin` | text | The plugin whose page it is; empty for a core page |
| `page` | text | The page |
| `position` | integer | Its place among everyone's pins |
| `pinned_at` | integer | When it was pinned |

Primary key: `(plugin, page)`.

## `shared_views`

Saved views administrators made for everyone: listed under their type for every person,
copied by anyone, changed and deleted by administrators. The same JSON as `views`. Up to
64.

| Column | Type | Meaning |
|---|---|---|
| `id` | text, primary key | View id |
| `name` | text | The name the sidebar shows, up to 80 characters |
| `query` | text | The view, as JSON |
| `created_by` | text | The administrator who made it |
| `created_at`, `updated_at` | integer | Timestamps |

## `default_views`

The view a type's list starts at, as saved over its plugin's (`.data_view`): a person's
own, or everyone's when `user_id` is empty, which administrators save. A person's wins over
everyone's; Reset to default removes the row. The same JSON as `views`. Deleting the user
or the type removes it.

| Column | Type | Meaning |
|---|---|---|
| `user_id` | text, references `users` | Whose default; null for everyone's; cascades |
| `type_id` | text, references `content_types` | The type whose list; cascades |
| `query` | text | The view, as JSON |
| `updated_by` | text | Who saved it |
| `updated_at` | integer | When |

Indexes: `default_views_owner (ifnull(user_id, ''), type_id)`, unique.

## `ai_conversations`

A person's conversations with a model from the admin's Overview, one per prompt: what
they asked, the provider and model that answered, the access the agent ran with, where
the turn is, and its last words. Private: listed and read by the person alone. Deleting a
user removes their conversations and steps.

| Column | Type | Meaning |
|---|---|---|
| `id` | text, primary key | Conversation id |
| `user_id` | text, references `users` | Whose conversation; cascades on delete |
| `prompt` | text | What the person asked, up to 16 KiB |
| `provider`, `model` | text | Who answered, as the provider names its model |
| `scope` | text | The agent's access: `read`, `drafts` or `write` |
| `state` | text | `running`, `stopping`, `finished`, `stopped` or `failed` |
| `answer` | text | The model's last words, once the turn is over |
| `device_id` | text | The device the turn ran as, revoked when it ended; empty before it began |
| `input_tokens`, `output_tokens` | integer | What the conversation cost so far, every turn added, as the provider counted |
| `created_at`, `updated_at` | integer | Timestamps |
| `draft` | text | The words the model is writing, so far, while it writes them; empty once they are a step |
| `cached_tokens` | integer | Of the input tokens, how many the provider read from its cache (at a fraction of the price) |

Indexes: `ai_conversations_user (user_id, created_at)`.

## `ai_steps`

A conversation's steps in order: each follow-up the person asked, each time the model
said something on the way, each command it ran, and its answer to each ask. Up to 512 per
conversation.

| Column | Type | Meaning |
|---|---|---|
| `conversation_id` | text, references `ai_conversations` | Whose step; cascades on delete |
| `position` | integer | Its place, from 1 |
| `kind` | text | `asked`, `said`, `ran` or `answered` |
| `summary` | text | One line, up to 300 bytes: what a command did ("Created content type Recipe"), or the first line said |
| `detail` | text | The whole of it, up to 16 KiB: what was said, what the command answered |
| `failed` | integer | 1 when the command failed |
| `href` | text | The admin page that shows what it changed; empty for none |
| `at` | integer | When it happened |

Primary key: `(conversation_id, position)`.

## `ai_pictures`

The pictures the person attached to an ask, which the model sees with it: each a chat
picture (a file of the `ai_picture` media type, private, never in the library), uploaded
as it was attached. Up to 8 per ask.

| Column | Type | Meaning |
|---|---|---|
| `conversation_id` | text, references `ai_conversations` | Whose; cascades on delete |
| `asked` | integer | The ask it came with: 0 for the first, else the `asked` step's position |
| `ordinal` | integer | Its place among that ask's pictures, from 0 |
| `media_key` | text | The file's key (`ai_picture/2026/10/pasted-5d3752.png`) |

Primary key: `(conversation_id, asked, ordinal)`. A picture whose file is gone is left
out of the turns after.

## `ai_activity`

What a running turn's agent is doing right now, between the steps: waiting for the model,
or running one call. The workspace shows it with how long it has taken, so a long model
reply never looks like a stall. One row per conversation, removed when the turn ends.

| Column | Type | Meaning |
|---|---|---|
| `conversation_id` | text, references `ai_conversations` | Whose; cascades on delete |
| `doing` | text | One line, up to 120 bytes: "Thinking", "Running publr media import" |
| `since` | integer | When it began |

Primary key: `conversation_id`.

## `ai_browsers`

The person's browser lending the agent its hands: one row per conversation whose workspace
has the Publr extension, holding the one browser call in flight. Calls go one at a time,
so only the latest is kept; the row is emptied when the turn ends.

| Column | Type | Meaning |
|---|---|---|
| `conversation_id` | text, references `ai_conversations` | Whose; cascades on delete |
| `ready_at` | integer | When the workspace last said the extension is there; 0 when it never did |
| `number` | integer | The latest call's number, from 1 |
| `state` | text | `idle`, `pending` (waiting for the browser) or `answered` |
| `call` | text | The call as the agent made it: a JSON object with its `action` |
| `answer` | text | What the browser answered, up to 48 KiB |
| `failed` | integer | 1 when the browser could not do it |
| `picture` | text | A screenshot with the answer: a base64 JPEG, up to 176 KiB; empty for none |

Primary key: `conversation_id`.

## `removals`

What an agent asked to remove for good, gathered for its person to review: one list per
device while it waits (a conversation's agent, or a person's own). The person keeps what
should stay and removes the rest, as themselves; then the list is done.

| Column | Type | Meaning |
|---|---|---|
| `id` | text | Its id |
| `user_id` | text, references `users` | Whose list: the person the device acts for; cascades on delete |
| `device_id` | text | The device that listed it |
| `conversation_id` | text | The conversation whose agent listed it; empty for another device |
| `state` | text | `waiting` or `done` |
| `created_at`, `updated_at` | integer | Timestamps |

Index: `(user_id, state, created_at)`.

## `removal_items`

One thing on a removal list: the removal as it was asked for, in words, and what came of it.
Up to 100 per list.

| Column | Type | Meaning |
|---|---|---|
| `removal_id` | text, references `removals` | Its list; cascades on delete |
| `position` | integer | Its place, from 1 |
| `operation` | text | The operation that removes it (`record.purge`) |
| `input` | text | The operation's input as it was asked, JSON: what runs when the person confirms |
| `label` | text | What goes, in words ("Content type Product") |
| `detail` | text | What goes with it ("and its 12 records") |
| `blocked` | text | Why it never goes this way, and how to do it by hand; empty when it may |
| `state` | text | `waiting`, `removed`, `trashed` (moved to the trash instead), `kept`, `failed` or `blocked` |
| `message` | text | Why a removal failed |

Primary key: `(removal_id, position)`.

## `trash`

A copy of what a removal took, kept until the trash empties it: anything removed (a
content type, taxonomy, field group, plugin, media file, user, secret or app file) and
everything a delete of it takes along. Restoring writes the copy
back and drops the entry.

| Column | Type | Meaning |
|---|---|---|
| `id` | text | Its id |
| `kind` | text | `content_type`, `taxonomy`, `field_group`, `plugin`, `media`, `user`, `secret` or `app_file` |
| `key` | text | What it was: the definition's id, the group's handle, the plugin's name |
| `label` | text | In words ("Content type Recipe, and its 12 records") |
| `removed_by` | text | The person who removed it, or whose agent did; empty for the operator |
| `device_id` | text | The device that removed it; empty for a person |
| `conversation_id` | text | The conversation whose agent removed it; empty otherwise |
| `removed_at` | integer | When |
| `keep_until` | integer | When it goes for good (`trash.keep_days` after) |
| `copy` | text | The rows, JSON: each table's rows, parents first, blobs as hex; for an app file, its path and text |
| `files` | text | The media files it set aside in the library's `.trash/` folder, by key, one per line |

Index: `(removed_at)`.


## `health_kept`

Site Health's "Keep as is": a broken reference someone chose to leave. Everything else
Site Health lists is worked out from the references themselves. A row keeps its case out
of the list until something about it changes (the reason, or how many records point).

| Column | Type | Meaning |
|---|---|---|
| `target` | text | The record pointed at, by id |
| `app` | text | For a type no longer shared, the app whose records point at it; empty otherwise |
| `reason` | text | `deleted`, `gone` or `not_shared`, as it was when kept |
| `holders` | integer | How many records pointed at it then |
| `kept_at` | integer | When |

Primary key `(target, app)`.

## `secrets`

Values plugins name but never hold (API keys and the like), pasted under Settings ›
Secrets. Each is sealed with the project's key (XChaCha20-Poly1305, bound to its name), a
key kept outside the database: `PUBLR_SECRET_KEY`, else `secret.key` beside the database
file (mode 0600, made when the first secret is kept). The database alone reveals nothing;
losing the key loses what was pasted. An environment variable of the same name wins over
what is kept here. A value is never read back out, only filled into a plugin's request as
it leaves.

| Column | Type | Meaning |
|---|---|---|
| `name` | text, primary key | `STOCKS_API_KEY`: capitals, digits and underscores |
| `sealed` | blob | The nonce, the encrypted value and its tag |
| `updated_at` | integer | When it was last set |

## `internal_records`

What a plugin keeps for itself and nobody edits (carts, reservations, stock movements,
logs), one JSON document per row, in collections the plugin declares
(`internal_records`). Never content: no statuses, drafts, revisions or search. Every read
and write is held to one plugin, one app and one collection: from a plugin's code, its own
and the request's app; with no plugin running, an administrator names them. Up to 64 KiB
per document.

| Column | Type | Meaning |
|---|---|---|
| `id` | text, primary key | Record id |
| `plugin` | text | Whose: the plugin that keeps it |
| `app` | text | The app it belongs to (`app.zon`'s `.name`); empty for the project's own |
| `kind` | text | The collection, as the plugin declares it |
| `document` | text | The record, a JSON object |
| `version` | integer | Bumped on every write; `expected_version` refuses a stale one |
| `created_at`, `updated_at` | integer | Timestamps |

Indexes: `internal_records_scope (plugin, app, kind, created_at)`: a collection's records,
newest first.

## `internal_record_values`

The fields an internal record is found by: each field its collection declares as indexed
that the record holds as text, an integer or a flag, kept as text (`42`, `true`). Written
with the record; deleting the record deletes them.

| Column | Type | Meaning |
|---|---|---|
| `record` | text, references `internal_records` | The record; cascades on delete |
| `field` | text | The indexed field |
| `value` | text | Its value, as text |

Primary key `(record, field)`. Indexes: `internal_record_values_lookup (field, value,
record)`: the records whose field holds a value.

## `sign_on_tokens`

Sign-on tokens already redeemed (`sign_on.redeem`), so each works once. A row
lives until the token's own expiry; after that the token is refused by its date
and the row is removed.

| Column | Type | Meaning |
|---|---|---|
| `id` | text, primary key | The token's `jti`, as the issuer set it |
| `expires_at` | integer | The token's expiry, Unix milliseconds |

## `devices`

Devices a person let act for their account: an agent, a CLI on another machine. The
device holds `id.secret`; only the hash of the secret is stored. A device never expires;
revoking it keeps the row, so the activity log (`token:<id>`) can still name it. Deleting
the user removes their devices.

| Column | Type | Meaning |
|---|---|---|
| `id` | text, primary key | Device id (the public half of the token) |
| `secret_hash` | blob | SHA-256 of the secret half |
| `user_id` | text, references `users` | Whose account it acts for; cascades on delete |
| `name` | text | What the person approved it as ("An agent on Ada's laptop") |
| `scope` | text | `read`, `drafts` or `write` |
| `created_at` | integer | When it was approved |
| `last_used_at` | integer | When it last made a request, to the minute |
| `revoked_at` | integer, null | When it was revoked; null while it works |

Index: `devices_user_id (user_id, created_at)`.

## `device_requests`

Devices waiting for a person to approve them (`device.start`), until they collect their
token (`device.poll`) or ten minutes pass. The device holds the device code; only its hash
is stored. The person types the user code.

| Column | Type | Meaning |
|---|---|---|
| `code_hash` | blob, primary key | SHA-256 of the device code |
| `user_code` | text, unique | `WXYZ-1234`, what the person types or follows |
| `name` | text | The name the device asked for |
| `scope` | text | The scope asked for, then the one approved |
| `state` | text | `pending`, `approved` or `denied` |
| `user_id` | text, references `users`, null | Who approved or denied it |
| `expires_at` | integer | When the request lapses, Unix milliseconds |
| `created_at` | integer | When the device asked |

Index: `device_requests_expires_at (expires_at)`.

## `identities`

Who a sign-in provider says an account is (`identity.sign_in`, `identity.link`).
An account may hold up to 16, a provider's user belongs to one account. Deleting
a user removes their rows. The account is keyed on the provider and its id,
never on the email, which is only what the provider last said.

| Column | Type | Meaning |
|---|---|---|
| `provider` | text | The provider's name, as its plugin declares it (`github`) |
| `provider_id` | text | The provider's stable id for the person |
| `user_id` | text, references `users` | Whose identity; cascades on delete |
| `email` | text, nullable | The email the provider last reported |
| `created_at` | integer | When it was linked |
| `last_used_at` | integer | The last sign-in through it |

Primary key `(provider, provider_id)`; index `identities_user_id` on `user_id`.

## `sandboxed_plugins`

The installed plugins added to the project, one row each: whether it runs, what the
administrator granted and denied, which content it may reach, a newer version waiting to
be applied, and the version the last update replaced, kept to roll back to. Each module
is a file on the data drive named by its hash (`plugins/<hash>.wasm` beside the
database), swept once no row names it; the manifests are kept here as the modules
carried them, so listing plugins never reads a module. Reloading, updating or waking a
project reads this table again. See [Plugins](plugins.md#installed-plugins-dlp).

| Column | Type | Meaning |
|---|---|---|
| `name` | text, primary key | The plugin's name, from its manifest |
| `version`, `hash`, `manifest` | text | The current version: its version, the SHA-256 of its module, its manifest as JSON |
| `enabled` | integer | 1 while it runs; 0 when added and not yet enabled, or disabled |
| `granted` | text | The permission keys granted, as a JSON array; kept while it is disabled |
| `denied` | text | The keys an administrator refused, as a JSON array |
| `grants` | text | JSON list, one per permission key: `{"key","records","taxonomies","domains","drafts","private","internal","publish"}`, the flags as an administrator left them (never more than asked) and `http.fetch`'s domains as they listed them; a key with none stored holds its flags and domains as asked |
| `next_version`, `next_hash`, `next_manifest` | text, nullable | A newer module uploaded for it, waiting to be applied |
| `previous_version`, `previous_hash`, `previous_manifest` | text, nullable | The version the last update replaced |
| `installed_at`, `updated_at` | integer | Timestamps |
| `remove_data` | text | What of the plugin's data goes into the trash with it when it is removed: keys of its pieces (`type:<handle>`, `internal:<collection>`, `fields:<group>`), as a JSON array; `[]`, keeping everything, until an administrator chooses |

## `content_types`

Content types are data: the schemas of records. The full definition (kind and
fields included) is stored as JSON in `definition`; a few properties are also
columns for listing. A type's id is derived from its handle (SHA-256, first 24
hex characters), so a type declared in code has the same id in every database.
Types created through `content_type create` and types declared by plugins
(`publr.record.define` in the plugin's `.records`, applied by `SDK.bootstrap` when the
database opens) live side by side in this table.

| Column | Type | Meaning |
|---|---|---|
| `id` | text, primary key | Type id, from the handle |
| `handle` | text, unique | Machine name (`post`) |
| `name` | text | Display name |
| `icon` | text | Icon name for the admin |
| `public` | integer | `1` if anonymous callers may read its live records |
| `system` | integer | `1` when a plugin owns the type (`owner` in the definition names it): its declared fields are locked, fields added by hand on top are kept across redeclarations |
| `editor` | text | How its records are edited: `form` (the default) or `visual` |
| `editor_config` | text | The editor's configuration as JSON: `{"field": …}`, the rich text field a visual type writes |
| `definition` | text | The complete definition as JSON (source of truth) |
| `created_at`, `updated_at` | integer | Timestamps |

## `records`

One row per record: identity, status and the columns every list needs. A
record's field values live in `record_values`, not here; the title shown in
lists is the value of the type's `title_field`, joined in. `version` grows on
every write and status change and is the optimistic-concurrency token.
Deleting a type deletes its records; deleting a record deletes its values.

Two axes: `status` is publication (`draft`, `published`, `archived`,
`trashed`; moved by transitions; `trashed_from` keeps the status a trashed record had,
for `restore`), `changed` is editing: `1` while a live
record has edits parked in its `pending` slot, whatever the status. Unpublish,
archive and delete leave `changed` and the pending copy alone.

| Column | Type | Meaning |
|---|---|---|
| `id` | text, primary key | Record id |
| `type_id` | text, references `content_types` | Its type; cascades on delete |
| `status` | text | A status id from the registry (`draft`, `published`, ...) |
| `changed` | integer | `1` when a pending copy holds unpublished edits |
| `version` | integer | Version, starts at 1 |
| `created_at`, `updated_at` | integer | Timestamps |
| `created_by` | text, nullable | The user who created it (a fact, not a byline) |
| `updated_by` | text, nullable | The user of the last save or transition |
| `app` | text, nullable | A design record's app (template, part, pattern, moodboard card), by the `.name` in its `app.zon`; null for every other record, which lives where its type does |
| `trashed_from` | text | The status a record in the trash had before it, where `restore` takes it back (a live one goes where records start); empty otherwise |
| `requested` | text | A transition asked for by someone who may not publish (`publish`, `archive`, `destroy`), waiting for someone who may; empty otherwise. Cleared when the status changes, the changes are published or discarded, or it is declined |
| `requested_by` | text, nullable | The user who asked |

Indexes: `records_list (type_id, status, updated_at)`; `records_changed
(type_id, updated_at) WHERE changed = 1`; `records_app (app, updated_at)`.

## `record_values`

Every field value of every record, one row per value, under a slot. There is
no JSON document in the database; reads assemble one from these rows, and
every scalar field of the live slot is filterable and sortable through the
index.

A slot is a named copy of the document. The core uses `live` (what everyone
reads) and `pending` (edits parked on a live record, promoted to `live` by
`record publish`, dropped by `record discard_changes`); a plugin may keep its
own (`release:<id>`) and promote it the same way. Only `live` is indexed:
filters, sorting, slug uniqueness, referrers and delivery search never see
other slots; `record get --slot` reads one explicitly (previews).

| Column | Type | Meaning |
|---|---|---|
| `record` | text, references `records` | The record; cascades on delete |
| `slot` | text | Which copy: `live`, `pending`, or a plugin's own |
| `type_id` | text | The record's type (a copy of `records.type_id`, so filters hit the index without a join) |
| `field` | text | Dotted path to the leaf field (`title`, `seo.description`, `faq.question`) |
| `ordinal` | integer | Position inside the nearest repeated ancestor (many reference, repeater item); `0` otherwise |
| `kind` | text | Storage kind, from the field kind: `int` (integer, datetime ms, boolean `0`/`1`), `real` (number), `text` (string, slug, email, url, select), `ref` (reference and image target ids), `long` (text, richtext) |
| `value` | any | The value in the storage class its kind requires (a `CHECK` enforces it) |

Primary key `(record, slot, field, ordinal)`. Indexes: `record_values_lookup
(type_id, field, value, record) WHERE slot = 'live' AND kind <> 'long'` makes
every scalar field filterable and sortable and answers uniqueness probes
(slugs); `record_values_referrers (value) WHERE slot = 'live' AND kind = 'ref'`
answers "who points at this id" (`record referrers`). Long text is stored in the same table but kept
out of both indexes. Uniqueness within a type (a slug) is checked by the
write inside its transaction through the lookup index.

## `record_search`

FTS5 index over the values of fields marked `searchable`, one row per value,
rebuilt for a record on every save; `record list --search` joins it.

| Column | Meaning |
|---|---|
| `text` | The indexed text |
| `record`, `slot`, `type_id`, `field` | Unindexed identifiers; delivery search matches `slot = 'live'` |

## `snapshots`

Frozen, read-only copies of a record's document, numbered per record. The
other storage shape: records are queryable content, snapshots are a sealed
archive, so the document is stored whole as JSON here (never queried by
field, never edited, may number in the millions: one row each, no index load
on content). The core takes one of kind `revision` whenever a live document
is replaced (a draft save, a publish of pending edits); plugins take their
own kinds (`snapshot take`). Restore is a normal `record save` of the stored
document. `snapshot prune` keeps the newest N of a kind; purging a record
removes its snapshots.

| Column | Type | Meaning |
|---|---|---|
| `record` | text | The record it is a copy of |
| `seq` | integer | Sequence within the record, from 1 |
| `kind` | text | Why it exists: `revision`, or a plugin's name for it |
| `at` | integer | When it was taken |
| `by` | text, nullable | The acting user |
| `document` | text | The frozen document as JSON |

Primary key `(record, seq)`; index `snapshots_kind (record, kind, seq)`.

## `activity`

What was done: one row per top-level write that completed, appended in the write's own
transaction (a rolled-back write leaves none). The calls it set off inside are listed in
it, not rows of their own. Append-only: triggers refuse every `UPDATE` and `DELETE`, so a
rollback, revert or merge in Cloud is a row of its own, never a change to these. Kept
forever; no index beyond the id, which is the order things happened. Inputs are stored
with secrets masked (`model/secret.zig`). Read with `activity list`.

| Column | Type | Meaning |
|---|---|---|
| `id` | integer | Increasing: the order things happened |
| `at` | integer | When, milliseconds |
| `actor` | text | A user id, `system`, `anonymous`, `plugin:<name>`, `token:<id>` |
| `app` | text | The app it came through, empty for none |
| `operation` | text | `plugin.disable`, `record.save` |
| `input` | text | The input as JSON, secrets replaced by `•` |
| `units` | text | JSON array of what it changed: `record:<id>`, `plugin:<name>` |
| `calls` | text | JSON array of the operations it set off inside, in order |

Triggers `activity_kept`, `activity_never_removed`.

## `errors`

What was refused or failed: one row per top-level call that was denied, given invalid
input, refused (a dependency, a contract) or failed, reads included. Written after the
call's rollback, in a transaction of its own. Append-only and kept forever like
`activity`. Read with `errors list`.

| Column | Type | Meaning |
|---|---|---|
| `id` | integer | Increasing: the order things happened |
| `at` | integer | When, milliseconds |
| `actor` | text | Who called, as in `activity` |
| `app` | text | The app it came through, empty for none |
| `operation` | text | The top-level operation |
| `input` | text | The input as JSON, secrets replaced by `•` |
| `calls` | text | JSON array of the operations it set off inside before failing |
| `error` | text | The error's name: `Denied`, `Invalid`, `Failed`; `Logged` for a call that answered but whose plugin logged an `.err` line |
| `message` | text | What went wrong, in words, when there is a message |
| `failed_in` | text | The inner operation the failure came from; empty when its own |

Triggers `errors_kept`, `errors_never_removed`.

## `plugin_log`

What plugins logged with `ctx.log`: one row per line, at most 100 a call. Written with the
call's `activity` row inside its transaction, with its `errors` row after a rollback, or
on its own when a read answered or a queued run ended. Append-only and kept forever like
`activity`. Read with `plugin log`, and under each entry of `activity list` and
`errors list`.

| Column | Type | Meaning |
|---|---|---|
| `id` | integer | Increasing: the order lines were logged |
| `at` | integer | When, milliseconds |
| `plugin` | text | The plugin that logged it |
| `level` | text | `info`, `warn` or `err` |
| `line` | text | The line, up to 1 KiB |
| `call` | text | What it ran in: an operation, `job:<plugin>.<name>`, `event:<name>`, a provider's exchange `sign_in:<provider>` |
| `activity` | integer | The `activity` row it went with; 0 for none |
| `error` | integer | The `errors` row it went with; 0 for none |

Indexes `plugin_log_by_plugin`, `plugin_log_by_activity`, `plugin_log_by_error`. Triggers
`plugin_log_kept`, `plugin_log_never_removed`.

## `taxonomies`

The schemas of terms, exactly as `content_types` are the schemas of records:
same columns, same JSON definition (a content type definition with
`hierarchical` set when terms may have a parent), same derived id. A
taxonomy is enabled on a content type by giving the type a field of kind
`terms` that names the taxonomy; see [Content](content.md).

| Column | Type | Meaning |
|---|---|---|
| `id` | text, primary key | Taxonomy id, from the handle |
| `handle` | text, unique | Machine name (`topics`) |
| `name` | text | Display name |
| `icon` | text | Icon name for the admin |
| `public` | integer | `1` if anonymous callers may read its live terms |
| `system` | integer | `1` when a plugin owns the taxonomy |
| `editor` | text | How its records are edited: `form` (the default) or `visual` |
| `editor_config` | text | The editor's configuration as JSON: `{"field": …}`, the rich text field a visual type writes |
| `definition` | text | The complete definition as JSON (source of truth) |
| `created_at`, `updated_at` | integer | Timestamps |

## `terms`

One row per term: `records` for the term domain, with one column more, the
parent. A term belongs to exactly one taxonomy; its title and slug are field
values in `term_values`, joined in by the lists. The same lifecycle as a
record: status, pending edits (`changed`), version, revisions in `snapshots`
(ids are unique across both domains, so they share the snapshot table).

| Column | Type | Meaning |
|---|---|---|
| `id` | text, primary key | Term id |
| `type_id` | text, references `taxonomies` | Its taxonomy; cascades on delete |
| `parent_id` | text, nullable, references `terms` | The parent term in the same taxonomy (hierarchical taxonomies); a term with children cannot be purged |
| `status` | text | A status id from the registry |
| `changed` | integer | `1` when a pending copy holds unpublished edits |
| `version` | integer | Version, starts at 1 |
| `created_at`, `updated_at` | integer | Timestamps |
| `created_by`, `updated_by` | text, nullable | The acting users |
| `app` | text, nullable | Always null: a term lives where its taxonomy does |
| `trashed_from` | text | As on `records`: the status a term in the trash had |
| `requested`, `requested_by` | text | As on `records`: a transition waiting for someone who may publish, and who asked |

Indexes: `terms_list (type_id, status, updated_at)`; `terms_changed (type_id,
updated_at) WHERE changed = 1`; `terms_parent (parent_id)`.

## `term_values`

`record_values` for terms: the same columns, indexes and slot rules, over
`terms`. The `record` column holds the term id and `type_id` the taxonomy
id; the names are those of the shared store.

## `term_search`

`record_search` for terms: the FTS5 index over searchable term values.

## `user_values`

`record_values` for users: the same columns, indexes and slot rules, over
`users`. Every account has at most one document, in the `live` slot under the
type id `user`, holding the values of its custom fields; each custom field
group that applies to the account is one top-level group in that document,
so a field's path is `<group handle>.<field name>` (`basic.bio`). Deleting
the account cascades to its rows.

## `user_search`

`record_search` for users: the FTS5 index over searchable user values.

## `record_terms`

Which terms a record is assigned to, per slot and per `terms` field. The
editor's explicit selections are also stored as `ref` values in
`record_values` (so a document assembles and referrers resolve as for any
reference); this table is the membership index the lists filter on. It holds
every selected term **and every ancestor** of it, up to the root: a record
assigned to `A > B > C` is a member of A, B and C, so filtering by A finds
it. `explicit` marks the terms the editor chose; the rest are there because a
descendant was. Rows are rewritten with the values on every save, promoted
with the slot on publish, and rebuilt for the affected records when a term
is moved under another parent.

| Column | Type | Meaning |
|---|---|---|
| `record` | text, references `records` | The record; cascades on delete |
| `slot` | text | Which copy: `live`, `pending`, or a plugin's own |
| `field` | text | The `terms` field of the record's type |
| `term` | text, references `terms` | The term; cascades on delete |
| `ordinal` | integer | Position among the explicit selections; `0` for an ancestor |
| `explicit` | integer | `1` when selected, `0` when included as an ancestor |

Primary key `(record, slot, field, term)`; index `record_terms_reverse (term,
slot, record)` answers "which records are in this term".

## `media`

The facts of each file in the media library, one row per record of the `media`
type: what only the library writes. What people write about a file (title, alt
text, caption, credit, focal point) is the record's document, and its folder and
tags are its `media_folders` and `media_tags` terms. The bytes are kept outside
the database under `storage_key`.

| Column | Type | Meaning |
|---|---|---|
| `record` | text, references `records` | The file's record; cascades on delete |
| `filename` | text | The name it was uploaded with, or had in the media folder |
| `mime_type` | text | What it is, decided by its extension and checked against its bytes |
| `size` | integer | Bytes |
| `width`, `height` | integer, nullable | Pixels, for images stb reads |
| `storage_key` | text, unique | Where the bytes are: `YYYY/MM/<stem>-<random>.<ext>`, or the path a file put into the media folder by hand already had |
| `hash` | text | SHA-256 of the bytes, hex |
| `private` | integer | `1`: served only to signed-in users, never cached by others |
| `created_at` | integer | Upload time, ms |
| `unreviewed` | integer | `1`: taken in from the media folder by `media sync`; `0` once someone changes the file |
| `missing` | integer | `1`: the last `media sync` found its bytes gone from the media folder |

Index `media_created (created_at, record)` serves the newest-first list;
`media_hash (hash)` finds an upload of the same bytes.

## `deps_edges`, `deps_artifacts`, `deps_pending`, `deps_meta`

The dependency index, owned by the `publr_deps` library and created by it in
the same database (`Server.init` opens it), shared by every app. `deps_edges (artifact,
key)` is what
every built page or fragment read; `deps_artifacts (artifact, hash)` the hash
of its last bytes, so an unchanged rebuild writes nothing; `deps_pending
(key, batch)` the changed keys waiting to be planned, `batch` 0 while
collecting; `deps_meta (name, value)` the batch counter and the time of the
last change. Keys are `record:<id>`, `type:<handle>`, `records`,
`template:<app>/<path>` and `asset:<app>`; artifacts are an app and a URL inside it
(`www:/posts/hello`, `www:/_islands/latest-posts`). See [Apps](apps.md).

## `job_queue`

The jobs plugins queued (see [Plugin API](plugin-api.md)): the `plugin` and the job's
`name`, its `input` as JSON, and `due_at`, when it may run. A write queues them in its own
transaction, so a write rolled back queues nothing. The server's worker process runs a job
once `due_at` has come and removes it when it is done. A job that fails waits again: `attempts` counts the
runs, and each failure moves `due_at` later, from a minute doubling up to a day. After the
last attempt `state` is `failed` and `problem` says why; the row stays for the plugin's
page. Each `on` hook's run is a job too, queued in the write that emitted the event, as
its plugin's (`core` for core's own) under `on:<event>` (`#2` for the plugin's second hook
on it), the event's payload as `input`; one whose payload is over 64 KiB is kept failed
without a run. `claimed_until` holds a job while it runs: a run lost to a crash is taken up again
once it passes. `queued_at` is when it was queued. Indexed on `(state, due_at)`, the read
each pass makes.

## `scheduled_transitions`

A status transition someone scheduled for a record: `record_id` (one per record), the status it goes to
(`to_status`), when (`due_at`), who scheduled it (`scheduled_by`, an account id, empty for
the system) and when they did (`scheduled_at`). The server's worker makes the transition once
`due_at` has come, as that person with their rights then, and removes the row. Indexed on
`due_at`.

## Coming with later gates

API token tables come with the tokens gate. A built-in plugin that truly needs its own table names it
`<plugin>_<table>` and creates it with `host.table` in `.extend` when the database opens;
the default, for every plugin, is a declared content type.

Custom-field schemas use `field_groups` with scope `custom_fields` and the group handle as owner.
Each stores its name, fields and location rules with a private component shape. No corresponding `content_types` or `records` rows are created. Settings
sections continue to use `content_types.kind = settings` and their existing singleton records.

The built-in Website definition (`handle = website`, `kind = settings`, owner `publr`) stores the
homepage's fields in the singleton's `record_values`, using the normal live/pending slots. Site
rendering depends on `type:website`, so publishing settings uses normal record invalidation.

## `field_groups`

The shared field schema for a content type, taxonomy, settings section, component,
user or media destination. `scope` names the owner domain and `owner` identifies it;
together they form the primary key. `definition` stores the fields and group options
as JSON. Document values stay with their owning entity.

Schema writes update the owner and its field group in one transaction. A one-time transaction
on database open moves existing inline fields and legacy custom-field settings into this table;
record values and owner IDs are preserved. The API still returns a complete definition with fields.
