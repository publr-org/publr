# Breaking changes before 1.0

Before 1.0, any release may change what plugins and apps build on, without notice. Each
release lists here what it broke and what to do instead, newest first. Upgrading a project:
read the sections after its release, or run `publr upgrade --prompt`, which keeps only what
the project uses.

Each entry is a `###` heading holding the item in backticks, named as `publr plugin surface`
names it (`call:money.texts`, `event:role.created` for an event a plugin emits or hooks,
`mod:media.base`, `host:publr_call_shaped`, `template:…`, `sdk:…`, `cli:…`, `config:…`),
then what changed and what to do, with a before and after where it helps. A change of
behaviour under the same name is an entry too. New entries go under `## Unreleased`; a
release renames it to its version and day.

## Unreleased
