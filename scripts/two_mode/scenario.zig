//! The calls the two-mode check makes of both projects: every operation, hook, event,
//! permission, type, field group and role the fixture plugins declare, as each kind of
//! caller, the refusals and failures included.
const admin = "admin@example.com";
const editor = "editor@example.com";
const password = "two mode password";
const points = "[{\"across\":1,\"down\":2}]";
const mottoed = "{\"handle\":\"mottoed\",\"name\":\"Mottoed\",\"kind\":\"component\"," ++
    "\"title_field\":\"\",\"group\":{\"location\":[{\"rules\":[{\"field\":\"destination\"," ++
    "\"value\":\"user\"},{\"field\":\"sampler.has_motto\",\"value\":\"yes\"}]}]}," ++
    "\"fields\":[{\"name\":\"since\",\"label\":\"Since\",\"kind\":\"string\"}]}";

/// A place is kept as its JSON text.
const visit = "{\"note\":\"Lunch\",\"place\":" ++
    "\"{\\\"name\\\":\\\"Warsaw\\\",\\\"lat\\\":52.23,\\\"lng\\\":21.01}\"}";
const lost = "{\"note\":\"Lost\",\"place\":" ++
    "\"{\\\"name\\\":\\\"Nowhere\\\",\\\"lat\\\":95,\\\"lng\\\":0}\"}";

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
    // A `define` operation untrusted callers reach, its ready answer letting in the signed in.
    &.{ "sampler", "wave", "--who", "stranger" },
    &.{ "--as", editor, "sampler", "wave", "--who", "Ada" },
    // Its `.validate` refusing: every problem beside its field, the same both ways.
    &.{ "--as", editor, "sampler", "wave", "--who", "" },
    // A type's own flow, moved by name: the same in both builds.
    &.{ "--as", admin, "sampler", "submit", "--text", "Looks good" },
    // The record's own `validate`, run by its plugin's hooks wherever the plugin runs.
    &.{ "--as", admin, "sampler", "submit", "--text", "spam" },
    // A value applied under a name and changed by a `*` modifier: 3 doubled to 6 both ways.
    &.{ "--as", admin, "sampler", "measure", "--text", "abc" },
    // A job the plugin's code queues, listed for the operator the same in both builds.
    &.{ "--as", admin, "sampler", "later", "--note", "Remember" },
    &.{ "--as", admin, "job", "list" },
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
    // A page of its own: refused the same both ways. What it draws differs until the
    // sandbox gets the admin's layouts through the host.
    &.{ "--as", editor, "sampler", "page" },
    &.{ "--as", admin, "sampler", "reference", "--query", "api=before" },
    // A display hook: how people see the notes, never what is stored.
    &.{ "--as", admin, "record", "shown", "--type", "sampler.sample_note" },
    &.{ "--as", admin, "record", "list", "--type", "sampler.sample_note" },
    &.{ "--as", admin, "sampler", "note", "--help" },
    // What the plugins declared, as the project now holds it.
    &.{ "--as", admin, "record", "list", "--type", "greeter.salutation" },
    &.{ "--as", admin, "record", "list", "--type", "sampler.sample_note" },
    &.{ "--as", admin, "content_type", "get", "--handle", "sampler.sample_note" },
    &.{ "--as", admin, "custom_fields", "get", "--group", "sampler" },
    &.{ "--as", admin, "role", "list" },
    &.{ "--as", admin, "secret", "list" },
    &.{ "--as", admin, "content_type", "get", "--handle", "greeter.salutation" },
    // Its own field group written, and a group its location rule places on accounts with a
    // motto: the rule runs where the plugin runs.
    &.{ "--as", admin, "sampler", "motto", "--user", admin, "--motto", "Keep notes" },
    &.{ "--as", admin, "custom_fields", "create", "--group", "mottoed", "--definition", mottoed },
    &.{ "--as", admin, "user", "get", "--user", admin },
    &.{ "--as", admin, "user", "get", "--user", editor },
    &.{ "--as", admin, "user", "list" },
    // A type whose field is the sampler's own kind: its `.validate` runs where the plugin runs.
    &.{ "--as", admin, "record", "create", "--type", "sampler.sample_visit", "--document", visit },
    &.{ "--as", admin, "record", "create", "--type", "sampler.sample_visit", "--document", lost },
    &.{ "--as", admin, "record", "list", "--type", "sampler.sample_visit" },
    &.{ "greeter", "--help" },
    &.{ "sampler", "--help" },
};
