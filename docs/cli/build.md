# CLI: `build`

Every app as files, one folder each. Public files copy unchanged on every invocation,
independently of the generated-page cache. Back to the [CLI reference](../cli.md); how
the apps work is in [Apps](../apps.md).

```
publr [--db <path>] build [--full] [--out <dir>] [--url <base>] [--apps <dir>]
```

Loads every app the binary carries (a template that does not load fails here, naming the
app and the template) and brings each app's folder under the output folder up to date
with the least work:

- **No build there, or one another version of the app made:** renders every static
  route to `<app>/<url>/index.html`, every static island to
  `<app>/_islands/<key>.html`, writes the app's assets and its compiled stylesheet under
  `<app>/_app/`, the 404 page, `sitemap.xml` and a marker (`.publr-build`, the stamp of
  the app's templates, stylesheet, generated client code and address). Records what every
  page read in the dependency index. While it renders, one line per route on stderr says
  how far it is (`publr: building /products/fry-pan (120/300)`).
- **A build by this version, changes since:** every publish, from whichever door
  (admin, API, CLI, a migration script), queued its keys in the index, server or no
  server. The queue is replayed: only the pages and islands that read a changed record
  are rendered again, each by its own app, and only those whose bytes differ are
  written. The sitemaps are refreshed.
- **A build by this version, nothing since:** no generated page is rendered or written;
  public files are copied unchanged and removed public files are pruned.

An app that fails to build (a page reads a record that is not published yet) is named on
stderr and the command exits 1; the other apps are built. An app with no pages has no
folder. A project with no apps has nothing to build.

`--full` builds everything again regardless. Use it after anything that
changed records behind the index's back (a database replaced by hand), or
when a file under the output folder was removed by hand.

| Flag | Meaning |
|---|---|
| `--full` | Render and write every page again, whatever the marker and the queue say. |
| `--out <dir>` | Where to write, one folder per app (default `output`, the folder `serve` reads). |
| `--url <base>` | The project's public address, for the sitemaps (default `http://127.0.0.1:8080`). An app's own is derived from it and its mount. Part of the marker: a build for another address is a full build. |
| `--apps <dir>` | Where each app's public files are read from, `<dir>/<app>/public` (default `apps`). |

```
$ publr build
publr: built 6 pages, 3 static islands and 6 assets (61234 bytes) into output/
$ publr build
publr: output/ is current: nothing changed since the last build (--full builds it again)
$ publr --as ada@example.com record publish --id a1b2c3d4e5f60718293a4b5c
$ publr build
publr: output/ brought up to date: 4 pages and islands rewritten, 0 removed, the rest unchanged
```
