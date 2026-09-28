# Laying out a Publr app

An app is its own repository. It builds the Publr binary with the app's plugin and theme
compiled in, and never contains a copy of Publr's source.

```
my-app/
  build.zig            the Publr dependency, with this app's theme and plugins
  build.zig.zon        Publr pinned (a path during development, a commit or release)
  plugins/my_app/      the app's plugin: main.zig and its parts
  themes/my_app/       the app's theme
  README.md            how to run, test and deploy
  .gitignore           zig-out/, .zig-cache/, data/, output/, .env*
```

## build.zig

Publr's build takes the theme and plugin folders as options (`-Dtheme-dir`,
`-Dplugins`), relative to the Publr checkout. The app passes its own folders and gets the
Publr binary back.

```zig
const std = @import("std");

/// Where build.zig.zon points the `publr` dependency, relative to this repository.
const core_path = "../publr";

pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});
    const core = builder.dependency("publr", .{
        .target = target,
        .optimize = optimize,
        .@"theme-dir" = from_core(builder, "themes/my_app"),
        .plugins = from_core(builder, "plugins"),
    });
    const exe = core.artifact("publr");

    builder.installArtifact(exe);

    // The plugin's tests, run inside Publr's test harness.
    const test_step = builder.step("test", "Run the app's tests");
    test_step.dependOn(&core.builder.top_level_steps.get("test-plugins").?.step);

    // The built binary compiles its own theme, so a template error fails the build.
    if (target.query.isNative()) {
        const check = builder.addRunArtifact(exe);
        check.addArg("check-theme");
        check.expectExitCode(0);
        builder.getInstallStep().dependOn(&check.step);
    }
}

/// A folder of this repository, as the Publr build sees it (relative to its own root).
fn from_core(builder: *std.Build, sub_path: []const u8) []const u8 {
    const core_root = builder.pathFromRoot(core_path);
    const wanted = builder.pathFromRoot(sub_path);

    return std.fs.path.relativePosix(builder.allocator, "/", core_root, wanted) catch
        @panic("OOM");
}
```

`build.zig.zon` names the dependency: `.publr = .{ .path = "../publr" }` while
developing against a checkout, a pinned URL and hash for anything shipped.

## The plugin

`plugins/my_app/main.zig` imports only `publr` and declares what the app brings. The
build finds it, checks the contract (manifest, documented operations, unique names) and
wires it into every adapter: CLI, REST, admin, templates.

```zig
const publr = @import("publr");
const sdk = publr.sdk;

pub const manifest: publr.plugin.Manifest = .{
    .name = "my_app",
    .version = "0.1.0",
    .summary = "What the app does, in one line",
};

pub const namespaces = [_]sdk.operation.Namespace{.{
    .name = "my_app",
    .summary = "...",
    .details = "...",
}};

pub const content_types = [_]publr.plugin.ContentTypeDef{ ... };   // data
pub const custom_fields = [_]publr.plugin.ContentTypeDef{ ... };   // values on accounts
pub const operations = [_]type{ ... };                              // behaviour
pub const policies = [_]sdk.Policy{ ... };                          // who may do what
pub const delivery_gates = [_]sdk.delivery.Gate{ ... };             // who sees the site
```

- **Data:** a private content type per kind of record the app keeps. Settings the admin
  edits are a type with `.kind = .settings`. Values on accounts are a custom field group
  (`destination` user), read in templates with `Publr.request.userField('group.field')`.
- **Operations:** one per action, named `my_app.<verb>`, with `description`, `details`,
  `kind` (`.read`/`.write`), `In`, `Out`, `example`, `example_out`, `field_docs`,
  `output_docs` and `run(ctx, in, grant)`. `open = true` lets anonymous visitors call it
  (sign-up, a contact form); `allow_frontmatter_calls = true` lets a page run it on open.
- **Policies:** decide per caller and operation. A member typically reads and writes only
  their own records (`created_by`), and the app's records change only through the app's
  operations, never the raw record API.
- **Acting as the system:** when an operation must do what its caller may not (create an
  account from an open sign-up), switch `ctx.caller` to `.system` for that call only and
  restore it with `defer`.
- **Outside services:** behind one small module, configured from a settings type, with
  secrets from the environment. Tests replace the service with a fake (write emails to an
  outbox file, answer a daemon's socket with a local listener).

## The theme

```
themes/my_app/
  theme.zon             design tokens
  public/               files served as they are (style.css feeds the compiled stylesheet)
  layouts/base.publr    the page shell; places global stores and the icon sprite once
  components/*.publr    server components (cards, headers)
  content/              one template per route: index.publr, posts/[slug].publr,
                        login.dynamic.publr, spaces/[slug].dynamic.publr
  dynamic/*.publr       dynamic islands: per-visitor fragments inside static pages
  interactive/*.ptsx    interactive components (PublrJS, @publr/ui)
  middleware.zig        logic before every site request: redirects, logic-only routes
```

- A template that reads only `Publr.build.*` is static and built to a file. One that reads
  `Publr.request.*` must be named `<name>.dynamic.publr`; one named dynamic that reads
  nothing is refused. Keep pages static and put the per-visitor part in a dynamic island.
- A dynamic island is a request to the server on every view of every page that places it,
  even when the page itself comes from a CDN's cache; on Publr Cloud it wakes the site.
  Place one only where the part is truly per visitor or per request, never in a layout
  every page shares; `defer` fetches it only when the reader scrolls near it. A part that
  only some visitors see differently is `dynamic-if="signedIn"` (or a condition the page
  registers with `Publr.islands.condition`): everyone else gets the build's copy and no
  request. Everything else is a static page or a static island, which a CDN serves
  without the server.
- Redirect and gate from the frontmatter:
  `if (!session) { Publr.request.redirect('/login'); }`.
- A route that is only logic (issue a token and redirect elsewhere, handle a webhook-like
  GET or POST) is middleware, never a page with a spinner: `middleware.zig` at the theme
  root checks `request.path()` and returns `request.redirect(url)`, `respond()` or
  `json()`, or `null` to let the site answer. It runs operations with `request.call()`.
- `getEntry()` on a `[slug]` page answers 404 when nothing is there: do not guard it.
- Interactive parts: a PTSX component with a PublrJS store, the design system's parts
  (`Button`, `Field`, `Input`, `Status`, `Callout`) and the app's REST operations at
  `/api/<namespace>/<verb>`, writes carrying the session's CSRF token.

## Tests

Tests live next to the plugin code and run with `zig build test`:

```zig
test "a member creates a thing and nobody else sees it" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try publr.registry.SDK.bootstrap(&system);

    var ada = harness.ctx(.{ .user = .{ .id = "ada", .role = .editor } });
    // dispatch the app's operations as ada, as someone else, as .anonymous; assert
    // what each may do and see.
}
```

Test access rules from both sides: what the owner may do, and what another member and an
anonymous caller may not.
