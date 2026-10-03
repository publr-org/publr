//! The calls the two-mode check makes of both projects: every operation, hook, event,
//! permission, type, field group and role the fixture plugins declare, as each kind of
//! caller, the refusals and failures included.
const admin = "admin@example.com";
const editor = "editor@example.com";
const password = "two mode password";
const points = "[{\"across\":1,\"down\":2}]";

/// The same in both modes before any step: the first admin and an editor.
pub const setup = [_][]const []const u8{
    &.{ "init", "--email", admin, "--display_name", "Admin", "--password", password },
    &.{
        "--as",           admin,    "user",       "create", "--email", editor,
        "--display_name", "Editor", "--password", password, "--roles", "editor",
    },
};

pub const steps = [_][]const []const u8{
    // greeter: a write and a read an editor's role grants, a permission, an after hook.
    &.{ "--as", admin, "greeter", "greet", "--note", "hello" },
    &.{ "--as", editor, "greeter", "greet", "--note", "hi from the editor" },
    &.{ "--as", editor, "greeter", "count" },
    &.{ "greeter", "count" },
    &.{ "--as", admin, "greeter", "greet", "--note", "nobody" },
    &.{ "--as", admin, "greeter", "greet", "--note", "" },
    &.{ "--as", admin, "greeter", "people" },
    &.{ "--as", editor, "greeter", "people" },
    &.{ "--as-admin", "greeter", "count" },
    &.{ "greeter", "greet", "--help" },
    // farewell: nothing asked for.
    &.{ "--as", admin, "farewell", "say", "--who", "Ada" },
    &.{ "--as", admin, "farewell", "last" },
    &.{ "--as", editor, "farewell", "say" },
    // sampler: an open operation, every field shape, a before hook, an event hook.
    &.{ "sampler", "hello", "--who", "stranger" },
    &.{ "--as", editor, "sampler", "hello" },
    &.{
        "--as",
        admin,
        "sampler",
        "echo",
        "--text",
        "words",
        "--count",
        "-3",
        "--ratio",
        "2.5",
        "--flag",
        "true",
        "--tags",
        "a,b",
        "--mood",
        "loud",
        "--maybe",
        "7",
        "--points",
        points,
    },
    &.{ "--as", admin, "sampler", "echo" },
    &.{ "--as", admin, "sampler", "echo", "--mood", "angry" },
    &.{ "--as", admin, "sampler", "echo", "--count", "many" },
    &.{ "--as", admin, "sampler", "echo", "--maybe", "null" },
    &.{ "--as", admin, "sampler", "echo", "text" },
    &.{ "--as", admin, "sampler", "echo", "--nope", "x" },
    &.{ "--as", admin, "sampler", "note" },
    &.{ "sampler", "echo", "--help" },
    &.{ "--as", editor, "sampler", "note", "--note", "not mine" },
    &.{ "--as", admin, "sampler", "note", "--note", "quiet words" },
    &.{ "--as", admin, "sampler", "note", "--note", "more" },
    &.{ "--as", admin, "sampler", "logs" },
    // A display hook: how people see the notes, never what is stored.
    &.{ "--as", admin, "record", "shown", "--type", "sample_note" },
    &.{ "--as", admin, "record", "list", "--type", "sample_note" },
    &.{ "--as", admin, "sampler", "note", "--help" },
    // What the plugins declared, as the project now holds it.
    &.{ "--as", admin, "record", "list", "--type", "salutation" },
    &.{ "--as", admin, "record", "list", "--type", "sample_note" },
    &.{ "--as", admin, "content_type", "get", "--handle", "sample_note" },
    &.{ "--as", admin, "custom_fields", "get", "--group", "sampler_profile" },
    &.{ "--as", admin, "role", "list" },
    &.{ "greeter", "--help" },
    &.{ "sampler", "--help" },
};
