# CLI: `media`

The media library: files people upload, filed in folders and under tags, and the files
of the other media types core and plugins declare, kept apart from it (`--type`; see
[Content](../content.md)). Every library file is a published record of the core `media`
type, whose document holds what people
write about it (title, alt text, caption, credit, focal point); its folder is its
`media_folders` term (one, nested up to five levels) and its tags its `media_tags`
terms. The file's own facts (name, type, size, dimensions, key, SHA-256) are the
library's, written on upload and kept in the `media` table. The bytes are kept beside
the database in `media/` and served at `/media/<key>` (see [REST API](../rest.md#media)).
A file of another media type is kept under `<type>/YYYY/MM/…`, never in folders or under
tags. Signed-in callers only, except `media file` and `media view`. Back to the [CLI reference](../cli.md).

| Command | What |
|---|---|
| `media upload --upload <token> --filename <name> [--folder <id>] [--type <handle>]` | Add the file `POST /media/upload` streamed in under `token` (its `?type=` names the type): the bytes are checked against the extension (an SVG is cleaned of scripts) and the type's families, kept under `YYYY/MM/<stem>-<random>.<ext>` and added as a record of the type, `media` unless `--type` names another. A file of a Private type other than the library is private. Up to 32 MiB |
| `media add --file <path> [--filename <name>] [--folder <id>] [--type <handle>]` | The local operator's (`--as-admin`): add a file on this machine, checked and kept as an upload is |
| `media import --url <address> [--filename <name>] [--folder <id>]` | Download a file from a public address on the web (never this machine or its network) and add it as an upload is; named after the address's last part unless `--filename` says |
| `media list [--type <handle>] [--folder <id>\|unsorted\|unreviewed] [--tags <id> ...] [--search <text>] [--year <y> [--month <m>]] [--kind image\|video\|audio\|pdf\|other] [--size small\|medium\|large] [--visibility public\|private] [--limit <n>] [--offset <n>]` | The files a filter keeps, newest first, with the folder tree and each folder's count under the rest of the filter, each tag's count with it added, the upload months, and what All files, Unsorted and Unreviewed hold. One media type's files: the library's unless `--type` names another, whose list has no folders or tags |
| `media sync [--check true]` | Take in the files put into the media folder by hand: each becomes a record marked unreviewed, kept where it lies when its path can be a key (lowercase letters, digits, `.-_`, up to four parts), else moved under a dated key; its directories name its folder (`Photos/Trips/a.jpg` goes in Photos › Trips, made when missing; a top directory of four digits names none). Unknown types, empty files and bytes that are not what the extension says are skipped with the reason; files whose bytes are gone are marked missing. `--check` only reports. A server only |
| `media get --id <id>` | One file: its facts, alt text, caption, credit, focal point, folder and tags |
| `media update --id <id> [--title] [--alt] [--caption] [--credit] [--focal_x <0-100>] [--focal_y <0-100>] [--folder <id>\|""] [--tags <name> ...] [--private true\|false]` | Change what is given; tags by name, made when missing; moving the focal point drops the resized copies |
| `media move --ids <id> ... [--folder <id>]` | File several files in a folder, or none |
| `media tag --ids <id> ... --tag <name> [--remove true]` | Add a tag to several files, or take it off |
| `media delete --ids <id> ...` | Remove files into the trash, each with its record and bytes (`trash restore` brings it back); resized copies go |
| `media folder_delete --folder <id>` | Remove a folder; its folders and files move up a level (admins: it purges the term) |
| `media import_many --urls <a>,<b>,… [--folder <id or name>]` | Several files from the web in one call, up to 20, as `media import` takes one; each that cannot be added is listed in `failed` with why, the rest are added. `--folder` takes a folder's id or its name (made when there is none of that name; also for `media import`) |
| `media read --key <key> [--width <n>] [--height <n>] [--fit crop\|cover] [--format webp\|jpeg\|png] [--quality <1-100>]` | A file's bytes, base64, as uploaded or resized as `/media/<key>` resizes: of any media type, private ones included, for whoever may read the type. Up to 8 MiB; read a larger image smaller. How the agent looks at chat pictures |
| `media file --key <key>` | What serving a file needs; a private file is not found for anyone not signed in |
| `media view --id <id>` | What a page needs to show the file a media field holds: its address (`/media/<key>`), alt text, title and size; anyone for a public file, a private one is not found for anyone not signed in. Templates read it as `Publr.build.media(id)` and `mediaUrl(id, { w, h, fit })` |

Folders and tags themselves are terms: `term create --taxonomy media_folders
--document '{"name":"Photos"}' [--parent <id>]` then `term publish --id <id>`, `term save
--id <id> --document '{"name":"…"}'` and `term publish` to rename, `--parent` to move.

```
$ publr --as-admin media add --file harbour.jpg
{ "id": "0190…", "title": "harbour", "key": "2026/10/harbour-a1b2c3.jpg", … }
$ publr --as ada@example.com media list --folder unsorted --limit 2
{ "items": [ … ], "total": 1, "all": 3, "unsorted": 1, "folders": [ … ], "tags": [ … ], "periods": [ … ] }
```
