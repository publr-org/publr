# CLI: `ai`

A conversation with a model, from the admin's Overview or the CLI. A person asks for
something in plain words; an agent then works on the project in a process of its own
beside the server (`publr agent`), as a **device** of that person named "Publr agent",
with their access (`write`, the default; a script may ask for `drafts`, writing but not
publishing, or `read`). What it removes goes to the trash, and what is final waits for the
person ([`removal`](removal.md)). It runs `publr` commands and reads the agents guide, the same two tools Publr
Cloud's MCP server offers, until the model is done. Each step lands in the conversation
as it happens, and the device is revoked when the turn ends. Conversations are
**private**: each belongs to the person who asked. Back to the [CLI reference](../cli.md).

| Command | What |
|---|---|
| `ai ask --prompt <text> [--scope write\|drafts\|read] [--pictures <keys>] [--page <path>]` | Start a conversation; answers at once, `running`. Signed-in people only, on a running server with a model provider connected. `--pictures` (JSON list, up to 8) names chat pictures (`media upload --type ai_picture`) the model looks at with the words. `--page` names the page it was asked on (an admin path or a site's address, one line, up to 512 bytes), added under the words as `Asked on <page>` so "this" means what is on it |
| `ai conversation --id <id> [--before <position>] [--limit <n>]` | The conversation and its steps, the newest 50 at a time (`--limit` up to 512, `--before` for the ones before a position; `earlier` says how many are left): `asked` (a follow-up), `said` (the model's words on the way), `ran` (an action, as a readable line with what it answered and the admin page that shows it, `href`) and `answered` |
| `ai conversations` | The caller's latest 50, newest first |
| `ai reply --id <id> --prompt <text> [--pictures <keys>]` | A follow-up once the last turn is over: another turn starts and carries on from the last turn's own messages (what each command answered, word for word), kept by the agent in `data/agents/<id>.history.json`; without them (a restart mid-turn), reminded of every ask, what was done and what was answered |
| `ai stop --id <id>` | Ask the agent to stop before its next step; what it did stays |
| `ai transcribe --audio <base64> --format <type>` | What was said in a recording (up to 768 KiB; WebM, Ogg, MP4, WAV or MP3), by the provider chosen when it hears, else the first connected one that does; nothing is kept. `NoHearer` when none does. What the admin's talk key sends |

Model providers are plugins (see [plugins](../plugins.md#model-providers)); these are an
administrator's:

| Command | What |
|---|---|
| `ai providers` | Every provider installed, with its models, whether its key is set, and the one chosen |
| `ai choose --provider <plugin> [--model <id>]` | The provider conversations use, and its model (empty for its default) |
| `ai test --provider <plugin>` | One short call: `ok` and what the model answered, or what went wrong |
| `ai catalog` | The official providers that can be set up in a click, from Publr's plugin server (`https://plugins.publr.app`, or the folder or address `PUBLR_PLUGIN_CATALOG` names); `reached` false when it could not be read |
| `ai set_up --names <plugin>...` | Fetch each one's built module and add it as an installed plugin, as uploading it does, then enable it, granting its requests out, its key and its raised limits; anything else it asks for waits under Plugins |

A conversation is answered by the provider in use: the one chosen while it is installed,
else the first installed with its key set; else by the script below. Its agent runs the provider's `complete` in its own process, with the project
opened there, so the server keeps answering while the model works.

The agent keeps the books over the operator channel, as the local operator: `ai begin`
(the device it runs as, made once), `ai step` (each step; answers whether to go on) and
`ai finish` (how the turn ended; revokes the device). Nothing else may call them.

`PUBLR_AI_SCRIPT`, set where `serve` starts, names a file of scripted answers (a JSON
list of responses) that every conversation is answered from: for checking a whole turn
with no network and no key. `PUBLR_AI_SCRIPT_PACE_MS` makes it wait before each answer, so
a turn can be watched. With it and no provider that hears, `ai transcribe` answers
`PUBLR_AI_SCRIPT_HEARD` (else "Scripted words") for every recording.

```
$ publr --as ada@example.com ai ask --prompt "Add a recipes section with a page listing them"
{ "id": "6a7b…", "state": "running", "scope": "write", … }
$ publr --as ada@example.com ai conversation --id 6a7b…
{ "conversation": { "state": "finished", "answer": "Added Recipe and its page…", … },
  "steps": [ { "position": 1, "kind": "ran", "summary": "publr content_type create …" }, … ] }
```

## What the agent sees

Besides `run` (a command) and `guide`, the agent has `show`, which opens a page of this
project in the workspace's preview, and `fetch`, which reads a web page: its words, each
link, image and stylesheet with its address. Both answer with a screenshot when the
machine can take one: the Chrome, Chromium, Edge or Brave on it, run headless in a
profile of its own under `data/agents/screens/` (`PUBLR_CHROME` names another). A page of
the site is pictured as a visitor sees it; an admin page is not. Without a browser the
agent reads words alone and says so. Pictures the person attaches are chat pictures,
private and kept apart from the media library; they come with their ask, read as the
person (`media read`) at up to 1568 pixels; each call sends the newest six pictures, an
older one named instead. `media import --url` brings a site's images into the library.

## The person's browser

With the Publr extension in the workspace, the agent also has `browser`: the person's own
Chrome, in a tab group of its own they watch (open a page, screenshot it, read it as a tree
of elements with refs, click and type by ref, read the console and network). The agent
never reaches the browser itself. It asks for one call at a time (`ai browse`, the local
operator's); the call rides on `ai conversation` as `browser_call`; the workspace page
hands it to the extension and answers with what came back (`ai browser_answer`, the
person's, with a screenshot of up to 176 KiB); the agent takes the answer (`ai browsed`).
The page says the extension is there with `ai browser_ready`. A call waits 10 seconds when
no workspace ever said so, a minute when one did; then the agent gives up on the browser
for the rest of the turn and uses `show` and `fetch`.

| Command | What |
|---|---|
| `ai browser_ready --id <id>` | The workspace has the extension |
| `ai browser_answer --id <id> --number <n> --answer <text> [--failed true] [--picture <base64>]` | Answer the call waiting; an older or answered one is a conflict |
| `ai browse --id <id> --call <json>`, `ai browsed --id <id> --number <n> [--give_up true]` | The agent's, over the operator channel only |

## How a turn works

The agent works like a careful person would: it looks at what exists, keeps a plan the
person sees as a checklist (its `plan` tool), builds a page at a time, and before it ends
looks at every page it changed; a turn that changed pages and never looked is reminded to,
once. How hard the model thinks is chosen per turn from the ask (a site to move or copy:
`high`; a short follow-up: `medium`; else the model's default). A call failing the same way
three times in a row ends the turn, saying so; there is no other limit on its length. A
provider that is down or limiting is asked again after 3, 10 and 30 seconds. A command that
fails with too little to go on comes back with its own usage. Pictures in the history are
trimmed in batches, so each request starts as the last one did and the provider's cache
holds; the conversation records how much was read from it (`cached_tokens`).

## As it happens

A provider that streams passes the model's words on as they come (`ai.progress`, which
plugins granted it call); the agent keeps them on the conversation a few times a second
(`ai.draft`, the local operator's), until they are a step. The workspace listens on a
WebSocket (`/admin/ai/<id>/live`): each change (a step, the words so far, the end) is
told the moment it lands, and the page asks for what is new (`ai conversation --after`).
Between steps the agent says what it is doing (`ai.activity`, the local operator's):
"Thinking" while the model writes its reply, "Running publr media import" while a call
runs. The workspace shows that line with how long it has taken, so a long reply never
looks like a stall; the end of the turn clears it.
A turn whose agent listed removals for good ([`removal`](removal.md)) pauses as
`waiting` without an answer; the person removes what they agree to, and the agent carries on
from what they removed. The agent runs the turn in a worker process; when the worker dies
before it is done, the conversation ends as failed, never left working. A turn that falls
silent for 5 minutes (no step, no word streamed) is ended the same way, as stuck. Every
request Publr sends out (an import, a plugin's `http.fetch`) gives up after 20 seconds, so a
server that never answers cannot hold the site. Stop is kept: a worker still running a
minute after the person asked it to stop is ended, and the turn ends stopped, with what it
did kept. A turn ends once.

