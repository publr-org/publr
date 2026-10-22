Update testing has not started: no fixtures yet, so `zig build upgrade` checks nothing.

It starts at a release Dawid names. Put that version in `START` (`0.6.0`); from then on the
Release workflow adds one fixture per release, never changed afterwards, and `lived.tar.gz`,
the site carried through every release, and `zig build upgrade` updates each with the current
build. Until then a release may change stored data freely. See
`../.agents/specs/upgrade-testing.md`.
