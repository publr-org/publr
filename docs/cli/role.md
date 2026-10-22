# CLI: `role`

What each role lets its accounts call, and changing it. A role is a row: a name, a label
and grants. A grant names an operation (`record.save`), a namespace and everything under
it (`record.*`, `app.newsletter.*`) or everything (`*`); a grant starting with `!` takes
names back from the role. Core declares `admin`, `editor` and `contributor` (an editor
who may not publish); each plugin declares its own or adds grants to one that exists.
The site changes them, makes its own and removes them; a plugin's update adds only the
grants new in it. `admin` holds `*` and never changes. How roles decide who gets into the
admin is in [Auth](../auth.md#roles). Back to the [CLI reference](../cli.md).

Every command is for administrators only. A plugin never reaches them.

## `list`

Every role, in the order they were made: what `user create --roles` and `user update
--roles` accept. Nothing is written.

Output: `{ "roles": [ { "name", "label", "description", "owner", "grants", "declared",
"holders", "changed", "locked" } ] }`. `owner` is `core`, the plugin that declared it, or
empty for one the site made; `declared` is what code declares for it; `changed` says its
grants are not that; `locked` marks `admin`.

```
$ publr --as ada@example.com role list
{
  "roles": [
    { "name": "admin", "label": "Administrator", "owner": "core", "grants": ["*"], "locked": true, ... },
    { "name": "editor", "label": "Editor", "owner": "core", "grants": ["!record.purge", "record.*", ...], ... }
  ]
}
```

## `get --name <role>`

One role, as `list` gives it. Not found for a name no role has.

## `create --name <role> --label <label> [--description <text>] [--grants <list>] [--copy <role>]`

A role of the site's own. `--copy` starts it with another role's grants; `--grants` adds
to them. Invalid for a bad name (`[a-z][a-z0-9_]*`, up to 32), label, description or grant,
a name taken, or 64 roles already.

```
$ publr --as ada@example.com role create --name reviewer --label Reviewer --copy contributor
```

## `update --name <role> --label <label> [--description <text>] --grants <list>`

Its label, description and the whole list of grants, in place of the old one. Invalid for
`admin`.

## `reset --name <role>`

Its grants back to what core and every plugin declare for it; the label and description
stay. Invalid for `admin` and for a role the site made.

## `remove --name <role>`

Removes it and takes it from its holders, into the trash: `trash restore --id` brings the
role and its holders back. Code never makes it again. Invalid for `admin`; a conflict
while it is any account's only role.
