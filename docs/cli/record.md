# CLI: `record`

A record is one **document** of one type in one status. The document is the
record's data: one JSON object whose keys are the type's field names and whose
values follow each field's kind (`{"title":"Hello","body":"…","views":3}`),
validated on every write; title, slug, status, `changed` and `version` sit
beside it. Every write bumps `version`, and `--expected_version` refuses to
overwrite a change you have not seen.

Two axes. **Status** is publication: `draft`, `published`, `archived`,
`trashed`, changed by `record transition` (and `publish`/`delete` as shortcuts);
every transition is reversible, `record purge` is the only thing that removes. **Changed**
is editing: `record save` writes the fields its document gives (the others keep their
values); on a live record (or one that already has pending edits) it parks them in a
*pending copy* and sets `changed`; the live document is untouched until `record publish`
applies the copy or `record discard_changes` drops it. A new record starts in its flow's
first status, and neither create nor save changes the status: only a transition does. Unpublish, archive and delete keep pending edits as they are. Whenever a live
document is replaced, the old one is kept as a revision (`snapshot list`).
Anonymous callers see live records of public types; signed-in users see and
change what their role allows. Back to the [CLI reference](../cli.md).

| Command | What |
|---|---|
| `record create --type <t> --document <json>` | Create, in the flow's first status; title from the type's `title_field`; when the type has a `slug` field it is taken from the document or generated from the field's `source` (or the title), unique per type. A record lives where its type does; only a design record (template, part, pattern, moodboard card) takes `--app`, the app it is for |
| `record get --id <id> [--purpose delivery\|edit] [--slot <s>] [--<dimension> <code>...]` | Read one record: its latest copy (the pending changes when it has some, else the live document); a visitor reads the live one. `purpose` shapes virtual fields: worked out (`delivery`, default) or as the editor keeps them (`edit`); `slot` names a copy |
| `record save --id <id> --document <json> [--expected_version <n>]` | Write the fields given: straight in for drafts, parked as pending edits on live records; never the status; `conflict` if `version` moved; `outcome` says what it did (`saved`, `changes_saved`, `changes_discarded`, `unchanged`) |
| `record publish --id <id> [--expected_version <n>]` | Make the latest document live: draft → published (the type's transition event too), or apply pending edits |
| `record publish --id <id> --changes <json> [--held_back <combinations>]` | Publish only these fields onto what is live (`{"title":"Deal"}`, null empties one), and what goes live with them; pending edits stay parked, each field they left as it was live taking the change. What a scheduled publish runs |
| `record transition_at --id <id> --transition <name> [--at <ms>] [--base <n>]` | Schedule a change for a moment, made then as you with your rights then; any number per record, each on a base: what is live, or scheduled change `--base` it builds on (never earlier). `publish` on a live record schedules its changes: the pending ones on what is live, or those waiting on `--base`; only those fields go live at its moment. Changes on the same base never share a field: change it again on top of the one that has it. Nothing changed is refused. Any other transition is a status change. No `--at` cancels every one of that transition. Answers `entry`. One refused when due stays `failed`, with why |
| `record unschedule --id <id> --entry <n>` | Drop one scheduled entry (a failed one too); a scheduled publish's changes go with it |
| `record get --id <id> --purpose edit --version <n>` | Read the record as scheduled change `n` will make it: what is live with its chain of bases and itself laid over, and the edits waiting on top of it |
| `record save_version --id <id> --version <n> --document <json>` | Keep edits made on top of scheduled change `n` as a draft on it: the whole document as it should read; schedule them with `record transition_at --base <n>` or put them into it with `record save_into_scheduled` |
| `record save_into_scheduled --id <id> --version <n>` | Put the edits waiting on top of scheduled change `n` into it; refused when another change on the same base already changes one of those fields |
| `record publish_version --id <id> --version <n>` | Put scheduled change `n` live now, as you, with the changes it builds on; changes beside it and on top of it keep their moments, now on what is live |
| `record run_scheduled --id <id> --entry <n>` | Make the next scheduled entry now (only the next one) |
| `record reschedule --id <id> --entry <n> --at <ms>` | Move a waiting entry to another moment |
| `record discard_changes --id <id>` | Drop pending edits, keep the document |
| `record transition --id <id> --transition <name> [--expected_version <n>]` | Move by a transition of the type's flow, named (`publish`, `archive`, a type's own like `submit`, `trash`, `restore`); refused unless the record is where it starts and you pass its `authorize`; into a live status applies pending edits, out of one keeps them. If you may not publish (`record publish`), a transition into or out of a live status, `destroy`, and `publish` of a live record's changes are asked for instead: `pending: true`, the record as it was, the request kept as `requested`/`requested_by` until someone who may runs that transition or declines it |
| `record hold_back --id <id> [--combinations <combination> ...]` | Choose what of a record goes live: each combination listed (`language=pl`, `language=pl,variation=b`) is held back, the rest go live; none puts every one live. A live record's choice waits as pending changes until `record publish` (answers `changed`); any other record's takes effect at once. Answers `held_back`, `;` between |
| `record decline_request --id <id>` | Drop the transition asked for on a record: the asker withdrawing it, or someone who may publish declining it; answers `declined`, the transition's name |
| `record transition_many --transition <name> (--ids a,b \| --matching true [--type <t>] [--types a,b] [--filters k:op:v,...] [--search <q>])` | Move many at once: the records named, or every one the conditions keep, in one call whatever their number; each checked as `record transition` checks it, one that may not move reported (`not_moved`, the first 100 in `failed`), the rest moved |
| `record list [--type <t>] [--types a,b] [--filters k:op:v,...] [--search] [--slug] [--filter_field --filter_value \| --filter_values a,b] [--ids a,b] [--order] [--sort] [--limit] [--offset] [--<dimension> <code>...]` | List one type's records, several types', or, with no type, every readable regular content type's. Settings require an explicit type selection. `--filters` are clauses of the registered filters, `key:operator:value` each: `status:is:draft`, `status:not:archived`, `changed:is:pending` (or `none`), `requested:is:waiting` (or `none`: a transition someone asked for waits), `created:by:me` (a user id or `me`; `updated:by` alike), `updated:within:7d` (`24h`, `7d`, `30d`, `90d`), `created:after:2026-01-01`, `created:before:2026-02-01`, `app:is:www` (a design record's app), `app:none`; a plugin's filters take the same shape. Within one type, a clause on a filterable field: `field.total:more:4999`, `field.title:contains:tea`, `field.placed:in_the_past:7d`, `field.size:any_of:["s","m"]`, `field.total:between:100..500`; `--sort total` (`-total` descending) orders by a sortable field instead of `--order` (`updated_desc`, `updated_asc`, `created_desc`, `created_asc`, `title_asc`, `title_desc`, `status_asc`, `status_desc`). Filter on any field by path within one type (`views`, `seo.title`, `tags` by target id), full text over `searchable` ones, `--slug` the one record with that slug, `--ids` only those records, `--filter_values` any of several values of the field; documents show virtual fields worked out (`--expand false` to read what they keep); live values only |
| `record delete --id <id>` | Move to `deleted` (reversible: `record transition --transition restore`); answers the record's `type` too, whose list a person deleting it goes back to |
| `record purge --id <id>` | Remove for good, snapshots included (admins) |
| `record referrers --id <id>` | Who points at this record (or media item), and through which field |
| `record shown (--ids a,b \| --type <t> [--limit])` | Titles as people see them: each record's own, then what modifiers of `<type>.title` make of it (what the admin lists show). Never changes what is stored or what `record list` answers |
| `record query --query <groq> [--params <json>] [--perspective published\|all] [--trashed true]` | Read content with a GROQ query, nested records included, in one read; see [Queries](../queries.md). Records in the trash are left out unless `--trashed true`. Answers `result` and `problems` (references made `null` because their record is not published yet); a reference you may not read stands as `{ restricted, type, reason }` |
| `record validate --type <t> --document <json>` | Report every problem without saving |
| `record reach --id <id>` | Why a record is out of the caller's reach: `reason` `access`, `not_shared` or `deleted` (null when nothing stands in the way, or it is not published yet) and its `type`; nothing else of it. What a page shows for a reference it may not follow |

```
$ publr --as ada@example.com record create --type post \
    --document '{"title":"Hello, world","body":"First post"}'
{ "id": "a1b2…", "status": "draft", "slug": "hello-world", "version": 1 }
$ publr --as ada@example.com record publish --id a1b2…
{ "status": "published", "changed": false, "version": 2 }
$ publr --as ada@example.com record save --id a1b2… --document '{"title":"Hello again","body":"…"}'
{ "version": 3, "slug": "hello-world", "changed": true, "outcome": "changes_saved" }  # parked
$ publr --as ada@example.com record publish --id a1b2…
{ "status": "published", "changed": false, "version": 4 }    # now it says "Hello again"
$ publr record list --type post            # anonymous: live records of public types
$ publr --as ada@example.com record list --filters status:is:draft,created:by:me   # every type, Ada's drafts
```

On a site with dimensions (a plugin's languages, an A/B test's variations), `get` and `list`
take a flag per dimension, named by it: `record get --id <id> --language pl --variation b`
reads each field in that combination, falling back as
[Content](../content.md#languages-and-other-dimensions) says; over JSON, `"language": "pl"`
beside the operation's own fields. A name the site has no dimension of is refused.
