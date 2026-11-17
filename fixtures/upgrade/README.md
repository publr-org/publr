Update testing starts at the release in `START` (0.7.5): every release from it on updates to
any later one, and its `schema.sql` is the baseline of core's migrations.

From that release on the Release workflow attaches two assets to every release:
`upgrade-<version>.tar.gz`, a site that release made, never changed afterwards, and
`upgrade-lived.tar.gz`, the site carried through every release. They are never files in this
repository. CI fetches them into `.zig-cache/upgrade-sites/` (`.github/actions/upgrade-sites`),
and `zig build upgrade` updates each with the current build. See
`../.agents/specs/upgrade-testing.md`.
