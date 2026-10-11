# `trash`

Every removal keeps a copy first, and the copy waits here: a content type, taxonomy or field
group with everything a delete of it takes along (a type's records with their values, terms
and media rows; their search text and snapshots); a plugin with its grants and versions; a
media file with its record and the file itself (set aside in the library's `.trash/`
folder); a user with their roles, fields and conversations (never their sessions or
devices: a restored account signs in afresh); a secret's sealed value; an app file's text.
`trash restore` writes it all back as it was. Records and terms keep their own trash, their
`deleted` status, and are purged from there.

The trash keeps a copy for `trash.keep_days` days (a setting; 30 unless set). What it has
held longer goes for good whenever something new is removed. Removing one entry for good
(`trash remove`) and emptying the trash (`trash empty`) are final: a device lists them for
its person instead ([`removal`](removal.md)).

| Command | What it does |
|---|---|
| `trash list [--conversation <id>]` | What the trash holds, newest first, with who removed it, when, and when it goes for good; one conversation's only, when named |
| `trash restore --id <id>` | Bring it back as it was; refused when something new took its name meanwhile |
| `trash remove --id <id>` | Remove one entry for good |
| `trash empty [--expired true]` | Remove everything for good, or only what it has held past its time |
| `trash keep --days <n>` | How long the trash keeps things (1 to 3650 days), for what is in it and what comes; the Trash page sets it too |

A removal answers its entry (`"trash": "<id>"`), so whoever removed it can restore it at once:

```
$ publr --as ada@example.com content_type delete --type recipe --force true
{ "deleted": true, "records_removed": 12, "trash": "01a1196e2c4b0000…" }
$ publr --as ada@example.com trash restore --id 01a1196e2c4b0000…
```

Back to the [CLI reference](../cli.md).
