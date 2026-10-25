Update testing has not started: no release has an upgrade site yet, so `zig build upgrade`
checks nothing.

It starts at a release Dawid names. Put that version in `START` (`0.6.0`); from then on the
Release workflow attaches two assets to every release: `upgrade-<version>.tar.gz`, a site that
release made, never changed afterwards, and `upgrade-lived.tar.gz`, the site carried through
every release. They are never files in this repository. CI fetches them into
`.zig-cache/upgrade-sites/` (`.github/actions/upgrade-sites`), and `zig build upgrade` updates
each with the current build. Until then a release may change stored data freely. See
`../.agents/specs/upgrade-testing.md`.
