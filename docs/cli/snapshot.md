# CLI: `snapshot`

A snapshot is a read-only, point-in-time copy of a record's document,
numbered per record (`seq`). The core takes one of kind `revision` whenever a
live document is replaced (a draft save, a publish of pending edits);
plugins take their own kinds. Snapshots are never edited: restoring one is
a normal `record save` of its document. Signed-in callers only. Back to the [CLI reference](../cli.md).

| Command | What |
|---|---|
| `snapshot list --id <record> [--kind <k>] [--before <seq>] [--limit <n>] [--documents]` | Newest first, 50 a page (`--limit` up to 200, `--before` a page's `next_before`), each with its title; documents only with `--documents`; every kind when `--kind` is omitted |
| `snapshot get --id <record> --seq <n>` | One snapshot with its document |
| `snapshot take --id <record> --kind <k>` | Freeze the record's live document under your own kind (`order.completed`) |
| `snapshot restore --id <record> --seq <n> [--expected_version <v>]` | Write that document back through `record save` (pending changes on a live record) |
| `snapshot prune --id <record> --kind <k> --keep <n>` | Keep only the newest `n` of that kind |

```
$ publr --as ada@example.com snapshot list --id a1b2… --kind revision
{ "snapshots": [ { "seq": 1, "kind": "revision", "at": 1789650000000, "by": "3f9c…", "document": "{…}" } ] }
$ publr --as ada@example.com snapshot restore --id a1b2… --seq 1
```
