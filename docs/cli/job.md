# CLI: `job`

The work plugins queued. A plugin queues a job with `ctx.enqueue`, or declares one that
repeats; the server's worker process runs each once it is due, as its plugin, and removes
it when it is done. A job that fails runs again later, up to eight times; after the last it
stays, failed, with why. An `on` hook that fails runs the same way, listed as its plugin's
`on:<event>`. Core's own outside work (a download, a model's answer, the marketplace) is
queued the same way, as `publr`'s: what someone waits on answers at once with an id, read
with `job answer`. Back to the [CLI reference](../cli.md).

| Command | What |
|---|---|
| `job list` | The jobs waiting to run, soonest first, then the ones that failed for good |
| `job answer --id <id>` | What queued work someone waits on answered: `waiting` until it lands, then `done` with its answer, or `failed` with why. Only whoever asked reads it; kept a day |
