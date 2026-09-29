# CLI: `role`

What each role lets its accounts call. A role is data: a name, a label and grants. A
grant names an operation (`record.save`), a namespace and everything under it
(`record.*`, `app.newsletter.*`) or everything (`*`); a grant starting with `!` takes
names back from the role. Core declares `admin` and `editor`; each built-in plugin
declares its own or adds grants to one that exists. How roles decide who gets into the
admin is in [Auth](../auth.md#roles). Back to the [CLI reference](../cli.md).

## `list`

Every role, core and plugins together, with its grants: what `user create --roles` and
`user update --roles` accept. Administrators only; nothing is written.

Output: `{ "roles": [ { "name", "label", "description", "grants" } ] }`.

```
$ publr --as ada@example.com role list
{
  "roles": [
    { "name": "admin", "label": "Administrator", "grants": ["*"], ... },
    { "name": "editor", "label": "Editor", "grants": ["record.*", "!record.purge", ...], ... }
  ]
}
```
