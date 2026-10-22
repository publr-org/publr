# CLI: `view`

A view is how the content list looks: which types, which filters, a search, an order, the
columns shown and the page size. A saved view is the user's own, or made by an administrator
for everyone (`--for_everyone true`): listed for all, copied by anyone, changed and deleted
by administrators. A type's **default view** is where its list starts: its plugin's
(`.data_view`), then the one administrators saved for everyone, then the person's own. The
view travels as JSON, every key optional:
`types` (handles; with `type_view` when the view is one type's own, shown without the
type pill), `clauses` (one per filter, each a `key`, an `operator` and a
`value` of a filter the registry knows, exactly what `record list --filters`
takes: `{"key":"status","operator":"is","value":"draft"}`,
`{"key":"updated","operator":"within","value":"7d"}`; a filter may have several clauses
when their operators settle different things, `created by me` and `created within 7d`
together; on a field of a one-type view, `{"key":"field.total","operator":"more","value":"4999"}`),
`search`, `order` (`title`, `-updated` descending, or a field the type sorts by: `-total`),
`columns` (in order: fields and `slug`, `status`, `updated`, `created`, `type`),
`per_page` (10, 20, 50, 100). `me` and durations are resolved
when the list is drawn, so a saved view stays current. The admin's sidebar lists them under Private views and
saves them from the content list's View menu. Up to 64 per user. Back to the
[CLI reference](../cli.md).

| Command | What |
|---|---|
| `view list` | The caller's own views by name, then the ones made for everyone (`shared`) |
| `view get --id <id>` | One view; not found unless it is the caller's or everyone's |
| `view create --name <n> [--query <json>] [--for_everyone true]` | Save a view under a name (up to 80 characters); the empty query is the whole content; for everyone: administrators only |
| `view update --id <id> [--name] [--query]` | Rename, or give a new view, or both; fields left out keep their value |
| `view delete --id <id>` | Remove the view; nothing else is touched |
| `view default --type <t>` | Where the type's list starts for the caller (`layer`: `mine`, `everyone`, `plugin`, `core`), and what it offers: columns, the fields to filter by with their operators, the orders |
| `view save_default --type <t> --query <json> [--for_everyone true]` | Save where the type's list starts, for the caller, or for everyone (administrators) |
| `view reset_default --type <t> [--for_everyone true]` | Forget the caller's default (or everyone's): the list starts a layer down |

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
