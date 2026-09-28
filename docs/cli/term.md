# CLI: `term`

A term is one document of one taxonomy in one status, with the lifecycle of a
record: a JSON document shaped by the taxonomy's fields and validated on every
write, a `version` and `--expected_version`, statuses moved by `term
transition` (`publish`, `delete` as shortcuts), pending edits parked by `term
save` on a live term and applied by `term publish`, revisions in `snapshot
list`. In a hierarchical taxonomy a term may have a `parent` of the same
taxonomy, up to 16 levels; a record filed under a term is a member of every
ancestor as well, so `record list --filter_field topics --filter_value <A>`
finds records filed under A's descendants. Anonymous callers see live terms of
public taxonomies. Back to the [CLI reference](../cli.md).

| Command | What |
|---|---|
| `term create --taxonomy <t> --document <json> [--status <s>] [--parent <id>]` | Create; title from the taxonomy's `title_field`, slug from the slug field's source, unique per taxonomy; `parent` puts it under a term of the same, hierarchical, taxonomy |
| `term get --id <id> [--purpose delivery\|edit] [--slot <s>]` | Read one term with its document and its parent |
| `term save --id <id> --document <json> [--expected_version <n>] [--parent <id>]` | Write the document; `--parent` moves the term (an empty string makes it a root, omitted keeps it), and every record filed under it or a descendant follows; refused while more than 10 000 assignments would change |
| `term list [--taxonomy <t>] [--taxonomies a,b] [--filters k:op:v,...] [--search] [--slug] [--filter_field --filter_value] [--order] [--limit] [--offset]` | List terms as `record list` lists records; `title_asc` by default |
| `term tree --taxonomy <t>` | Every term in tree order, parents first, siblings by title, each with its depth |
| `term publish --id <id>`, `term discard_changes --id <id>`, `term transition --id <id> --to <status>` | The lifecycle, as for records |
| `term delete --id <id>` | Move to `deleted` (reversible) |
| `term purge --id <id>` | Remove for good (admins); refused while the term has children or records filed under it |
| `term validate --taxonomy <t> --document <json>` | Report every problem without saving |

```
$ publr --as ada@example.com term create --taxonomy topics --document '{"name":"Technology"}'
{ "id": "f607…", "status": "draft", "slug": "technology", "version": 1, "parent": null }
$ publr --as ada@example.com term create --taxonomy topics \
    --document '{"name":"Engineering"}' --parent f607…
{ "id": "e5f6…", "status": "draft", "slug": "engineering", "version": 1, "parent": "f607…" }
$ publr --as ada@example.com term tree --taxonomy topics
{ "terms": [ { "id": "f607…", "parent": null, "title": "Technology", "depth": 0 },
             { "id": "e5f6…", "parent": "f607…", "title": "Engineering", "depth": 1 } ] }
```
