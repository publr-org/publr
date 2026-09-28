# CLI: `build`

The public site as files. Public theme files copy unchanged on every invocation,
independently of the generated-page cache. Back to the [CLI reference](../cli.md); how the
site works is in [The site](../site.md).

```
publr [--db <path>] build [--full] [--out <dir>] [--url <base>]
```

Loads the embedded theme (a template that does not load fails here, naming
it) and brings the output folder up to date with the least work:

- **No build there, or one another theme made:** renders every static route
  to `<url>/index.html`, every static island to `_islands/<key>.html`, writes
  the theme's assets under `theme/`, the 404 page, `sitemap.xml` and a marker
  (`.publr-build`, the stamp of the theme's templates, stylesheet, generated client code and
  `--url`). Records what every page read in the dependency index. While it
  renders, one line per route on stderr says how far it is
  (`publr: building /products/fry-pan (120/300)`).
- **A build by this theme, changes since:** every publish, from whichever
  door (admin, API, CLI, a migration script), queued its keys in the index,
  server or no server. The queue is replayed: only the pages and islands
  that read a changed record are rendered again, and only those whose bytes
  differ are written. The sitemap is refreshed.
- **A build by this theme, nothing since:** no generated page is rendered or written;
  public files are copied unchanged and removed public files are pruned.

`--full` builds everything again regardless. Use it after anything that
changed records behind the index's back (a database replaced by hand), or
when a file under the output folder was removed by hand.

| Flag | Meaning |
|---|---|
| `--full` | Render and write every page again, whatever the marker and the queue say. |
| `--out <dir>` | Where to write (default `output`, the folder `serve` reads). |
| `--url <base>` | The site's public address, for the sitemap (default `http://127.0.0.1:8080`). Part of the marker: a build for another address is a full build. |

```
$ publr build
publr: built 6 pages, 3 static islands and 6 assets (61234 bytes) into output/
$ publr build
publr: output/ is current: nothing changed since the last build (--full builds it again)
$ publr --as ada@example.com record publish --id a1b2c3d4e5f60718293a4b5c
$ publr build
publr: output/ brought up to date: 4 pages and islands rewritten, 0 removed, the rest unchanged
```
