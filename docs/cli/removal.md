# `removal`

An agent never removes anything for good. When a device runs an operation that destroys
(purging a record or term; deleting a content type, taxonomy, field group, user, media or
an app's file; removing a plugin; pruning snapshots; forgetting a secret), nothing is
removed: the removal goes on the device's list, in words, for its person, and the call
fails with `ListedForRemoval`, saying where the list is. A conversation's agent shows it as
a "To remove" step. The person reviews the list in the admin (`/admin/removals`) or here,
keeps what should stay, and removes the rest: the removal is theirs, run as them under their
own permissions and logged as theirs. A conversation's turn pauses (`waiting`) once its
agent listed removals; when the person has removed, the agent is told what they removed and
carries on with what is left. `--trash true` moves records and terms to the trash instead.
Moving something to the trash can be undone and stays the device's to do.

Some things never go from a list: your own account. Its item is `blocked`, and says how to
do it by hand (another administrator, or `publr --as-admin` on the server).

| Command | What it does |
|---|---|
| `removal list [--all true]` | The caller's lists, newest first; only those waiting unless `--all` |
| `removal get --id <id>` | One list: each item in words, what goes with it, and where it stands (`waiting`, `removed`, `kept`, `failed`, `blocked`) |
| `removal confirm --id <id> [--keep <positions>]` | Remove every waiting item but the positions kept, each as the caller through its own operation; a failure says why and the rest go on. A person only, never a device |
| `removal decline --id <id>` | Keep everything; the list is done. A person only |

```
$ publr --as ada@example.com removal confirm --id 01a1195c89620000310db909 --keep 2
```

Back to the [CLI reference](../cli.md).
