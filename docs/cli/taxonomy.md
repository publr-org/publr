# CLI: `taxonomy`

A taxonomy is the schema of its terms, as a content type is the schema of its
records: a handle, a name, whether it is public (anyone may read its live
terms), and the fields a term carries (a name, a slug, a colour, a cover
image: any kind but `terms`). A `hierarchical` taxonomy lets a term have a
parent term; a flat one does not. `applies_to` names the content types the
taxonomy classifies: each gains an implicit `terms` field named after the
taxonomy, and its records select terms there; `single` makes them take one
term instead of several. Definitions are JSON with the keys of a content type
definition (`publr content_type create --help`) plus `hierarchical`,
`applies_to` and `single`; the kind is always `record`, there is no `url`. Signed-in
users may read taxonomies; changing them needs an admin. Back to the
[CLI reference](../cli.md); how classification is modelled is in
[Content](../content.md#taxonomies).

| Command | What |
|---|---|
| `taxonomy create --definition <json>` | Create a taxonomy; admins only |
| `taxonomy update --taxonomy <handle\|id> --definition <json> [--drop_content true]` | Change a taxonomy; existing terms follow as records follow a type change; turning `hierarchical` off is refused while any term has a parent; a type dropped from `applies_to` loses its records' terms of this taxonomy |
| `taxonomy get --taxonomy <handle\|id>` | Read the full definition |
| `taxonomy list` | List taxonomies |
| `taxonomy delete --taxonomy <handle\|id> [--force true]` | Delete; refuses while terms exist unless forced |
| `taxonomy validate --definition <json>` | Report every problem without saving |

```
$ publr --as-admin taxonomy create --definition '{"handle":"topics","name":"Topics",
    "public":true,"hierarchical":true,"title_field":"name","applies_to":["post"],
    "fields":[{"name":"name","label":"Name","kind":"string","required":true},
    {"name":"slug","label":"Slug","kind":"slug","options":{"source":"name"}}]}'
{ "id": "d4e5…", "handle": "topics" }
```
