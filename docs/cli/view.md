# CLI: `view`

A view is a name over a set of filters for the content list: which types,
which status, whose records, since when, a search, an order. Views are
**private**: each belongs to the user who saved it, and nobody else lists,
reads or changes it. The filters travel as JSON, every key optional:
`types` (handles; with `type_view` when the view is one type's own, shown without the
type pill), `clauses` (one per filter, each a `key`, an `operator` and a
`value` of a filter the registry knows, exactly what `record list --filters`
takes: `{"key":"status","operator":"is","value":"draft"}`,
`{"key":"updated","operator":"within","value":"7d"}`; a filter may have several clauses
when their operators settle different things, `created by me` and `created within 7d`
together), `search`, `order`
(`updated_desc`, `created_desc`, `title_asc`). `me` and durations are resolved
when the list is drawn, so a saved view stays current. The admin's sidebar lists them under Private views and
saves them from the content list's View menu. Up to 64 per user. Back to the
[CLI reference](../cli.md).

| Command | What |
|---|---|
| `view list` | The caller's own views, by name |
| `view get --id <id>` | One view; not found unless it is the caller's |
| `view create --name <n> [--query <json>]` | Save filters under a name (up to 80 characters); the empty query is the whole content |
| `view update --id <id> [--name] [--query]` | Rename, or give new filters, or both; fields left out keep their value |
| `view delete --id <id>` | Remove the view; nothing else is touched |

```
$ publr --as ada@example.com view create --name "My drafts" \
    --query '{"clauses":[{"key":"status","operator":"is","value":"draft"},{"key":"created","operator":"by","value":"me"}]}'
{ "id": "5e6f…", "name": "My drafts", "query": "{\"types\":[],…}", … }
$ publr --as ada@example.com view list
{ "views": [ { "id": "5e6f…", "name": "My drafts", … } ] }
$ publr --as ada@example.com view update --id 5e6f… --name "Drafts"
$ publr --as ada@example.com view delete --id 5e6f…
{ "deleted": true }
```
