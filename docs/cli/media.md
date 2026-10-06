# CLI: `media`

The media library: files people upload, filed in folders and under tags. Every file
is a published record of the core `media` type, whose document holds what people
write about it (title, alt text, caption, credit, focal point); its folder is its
`media_folders` term (one, nested up to five levels) and its tags its `media_tags`
terms. The file's own facts (name, type, size, dimensions, key, SHA-256) are the
library's, written on upload and kept in the `media` table. The bytes are kept beside
the database in `media/` and served at `/media/<key>` (see [REST API](../rest.md#media)).
Signed-in callers only, except `media file`. Back to the [CLI reference](../cli.md).

| Command | What |
|---|---|
| `media upload --upload <token> --filename <name> [--folder <id>]` | Add the file `POST /media/upload` streamed in under `token`: the bytes are checked against the extension (an SVG is cleaned of scripts), kept under `YYYY/MM/<stem>-<random>.<ext>` and added as a record. Up to 32 MiB |
| `media add --file <path> [--filename <name>] [--folder <id>]` | The local operator's (`--as-admin`): add a file on this machine, checked and kept as an upload is |
| `media list [--folder <id>\|unsorted] [--tags <id> ...] [--search <text>] [--year <y> [--month <m>]] [--kind image\|video\|audio\|pdf\|other] [--size small\|medium\|large] [--visibility public\|private] [--limit <n>] [--offset <n>]` | The files a filter keeps, newest first, with the folder tree and each folder's count under the rest of the filter, each tag's count with it added, the upload months, and what All files and Unsorted hold |
| `media get --id <id>` | One file: its facts, alt text, caption, credit, focal point, folder and tags |
| `media update --id <id> [--title] [--alt] [--caption] [--credit] [--focal_x <0-100>] [--focal_y <0-100>] [--folder <id>\|""] [--tags <name> ...] [--private true\|false]` | Change what is given; tags by name, made when missing; moving the focal point drops the resized copies |
| `media move --ids <id> ... [--folder <id>]` | File several files in a folder, or none |
| `media tag --ids <id> ... --tag <name> [--remove true]` | Add a tag to several files, or take it off |
| `media delete --ids <id> ...` | Remove files for good, with their bytes and copies |
| `media folder_delete --folder <id>` | Remove a folder; its folders and files move up a level (admins: it purges the term) |
| `media file --key <key>` | What serving a file needs; a private file is not found for anyone not signed in |

Folders and tags themselves are terms: `term create --taxonomy media_folders
--document '{"name":"Photos"}' --status published [--parent <id>]`, `term save
--id <id> --document '{"name":"…"}'` to rename, `--parent` to move.

```
$ publr --as-admin media add --file harbour.jpg
{ "id": "0190…", "title": "harbour", "key": "2026/10/harbour-a1b2c3.jpg", … }
$ publr --as ada@example.com media list --folder unsorted --limit 2
{ "items": [ … ], "total": 1, "all": 3, "unsorted": 1, "folders": [ … ], "tags": [ … ], "periods": [ … ] }
```
