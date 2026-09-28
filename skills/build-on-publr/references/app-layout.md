# Laying out a Publr project

A project is its own repository. It builds the Publr binary with its apps and plugins
compiled in, and never contains a copy of Publr's source. One project is one domain and
one set of accounts; its apps are the frontends, its plugins the data and the operations
every app shares.

```
my-project/
  build.zig            the Publr dependency, with this project's apps and plugins
  build.zig.zon        Publr pinned (a path during development, a commit or release)
  apps/www/            the marketing site, at the root of the domain
  apps/members/        the members area, under /members or on members.example.com
  plugins/newsletter/  a feature: its types, roles and operations, used by any app
  README.md            how to run, test and deploy
  .gitignore           zig-out/, .zig-cache/, data/, output/, .env*
```

## build.zig

Publr's build takes the apps and plugins folders as options (`-Dapps`, `-Dplugins`),
relative to the Publr checkout. The project passes its own folders and gets the Publr
binary back.

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
        .apps = from_core(builder, "apps"),
        .plugins = from_core(builder, "plugins"),
    });
    const exe = core.artifact("publr");

    builder.installArtifact(exe);

    // The plugins' tests, run inside Publr's test harness.
    const test_step = builder.step("test", "Run the project's tests");
    test_step.dependOn(&core.builder.top_level_steps.get("test-plugins").?.step);

    // The built binary compiles its own apps, so a template error fails the build.
    if (target.query.isNative()) {
        const check = builder.addRunArtifact(exe);
        check.addArg("check-apps");
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
developing against a checkout, a pinned URL and hash for anything shipped. The running
binary reads each app's public files from `apps/<app>/public` beside it.

## A plugin

`plugins/newsletter/main.zig` imports only `publr` and declares what the feature brings.
The build finds it, checks the contract (manifest, documented operations, unique names,
valid roles) and wires it into every adapter: CLI, REST, admin, templates.

```zig
const publr = @import("publr");
const sdk = publr.sdk;

pub const manifest: publr.plugin.Manifest = .{
    .name = "newsletter",
    .version = "0.1.0",
    .summary = "What the feature does, in one line",
};

pub const namespaces = [_]sdk.operation.Namespace{
    .{ .name = "newsletter", .summary = "...", .details = "..." },       // the admin's
    .{ .name = "app.newsletter", .summary = "...", .details = "..." },   // the apps'
};

pub const roles = [_]publr.plugin.Role{
    // The apps' visitors: they call what apps call, never what the admin does.
    .{ .name = "subscriber", .label = "Subscriber", .grants = &.{"app.newsletter.*"} },
    // Editors run the newsletter from the admin.
    .{ .name = "editor", .label = "Editor", .grants = &.{"newsletter.*"} },
};

pub const content_types = [_]publr.plugin.ContentTypeDef{ ... };   // data
pub const custom_fields = [_]publr.plugin.ContentTypeDef{ ... };   // values on accounts
pub const operations = [_]type{ ... };                              // behaviour
pub const policies = [_]sdk.Policy{ ... };                          // finer rules
pub const delivery_gates = [_]sdk.delivery.Gate{ ... };             // who sees which pages
```

- **Roles:** a role is a name, a label and grants: an operation (`newsletter.send`), a
  namespace and everything under it (`app.newsletter.*`), or `!` to take a name back. A
  new name is a new role; `editor` or another existing name adds grants to it. An account
  holds one or more roles. An account whose roles reach only `app.*` operations never
  gets into the admin, and never sees the toolbar that leads there.
- **Operations:** one per action. What an app calls is `app.<feature>.<verb>`
  (`app.newsletter.subscribe`), what the admin's people call is `<feature>.<verb>`; any
  app may call the first, since it names the feature, not an app. Each has
  `description`, `details`, `kind` (`.read`/`.write`), `In`, `Out`, `example`,
  `example_out`, `field_docs`, `output_docs` and `run(ctx, in, grant)`. `open = true`
  lets anonymous visitors call it (sign-up, a contact form); `allow_frontmatter_calls =
  true` lets a page run it on open.
- **Data:** a private content type per kind of record the feature keeps. Settings the
  admin edits (an app's homepage content) are a type with `.kind = .settings`, read by
  the app with `Publr.build.getEntry({ type: 'homepage' })`. Values on accounts are a
  custom field group (`destination` user), read in templates with
  `Publr.request.userField('group.field')`.
- **Private data:** an app's visitors hold roles granting only `app.<feature>.*`, so they
  read live public records like anyone and nothing private through the record API. What
  is theirs (their orders, their projects) comes from the feature's operations: a read
  with `allow_frontmatter_calls = true` that a page calls
  (`Publr.request.call('app.shop.orders')`, its output the entry's `data`), reading on
  the member's behalf (`.plugin` with `on_behalf_of`) filtered to what they made
  (`created:by:<id>`). Writes go the same way, so the records are the member's
  (`created_by`) though they may not touch records directly.
- **Policies:** narrow what roles grant, per caller and record.
- **Acting as the system:** when an operation must do what its caller may not (create an
  account from an open sign-up, with the plugin's own role), switch `ctx.caller` to
  `.system` for that call only and restore it with `defer`.
- **Outside services:** behind one small module, configured from a settings type, with
  secrets from the environment. Tests replace the service with a fake (write emails to an
  outbox file, answer a daemon's socket with a local listener).

## An app

```
apps/members/
  app.zon               where it is mounted, its design tokens, the roles it signs in
  public/               files served as they are under /_app/ (style.css feeds the stylesheet)
  layouts/base.publr    the page shell; places global stores and the icon sprite once
  components/*.publr    server components (cards, headers)
  content/              one template per route: index.publr, posts/[slug].publr,
                        login.dynamic.publr, spaces/[slug].dynamic.publr
  dynamic/*.publr       dynamic islands: per-visitor fragments inside static pages
  interactive/*.ptsx    interactive components (PublrJS, @publr/ui)
  middleware.zig        logic before every request for the app: redirects, logic-only routes
```

```zig
// app.zon
.{
    .mount = .{ .subdomain = "members" },      // or .{ .path = "/members" }, or "/"
    .tokens = .{ .{ .name = "color-accent", .value = "#2f5d54" } },
    .roles = .{ "subscriber" },                // signed in here only with one of these
}
```

- Inside an app everything starts at `/`: `content/index.publr` is the app's home
  whether it is mounted at `/`, `/members` or `members.example.com`, and middleware's
  `request.path()` is the path inside the app. Assets are written `/_app/logo.svg` and
  land under the mount. Links a template writes by hand include the mount
  (`/members/account`).
- An app with no templates is valid: its `middleware.zig` answers everything (a webhook,
  an API facade).
- A template that reads only `Publr.build.*` is static and built to a file. One that reads
  `Publr.request.*` must be named `<name>.dynamic.publr`; one named dynamic that reads
  nothing is refused. Keep pages static and put the per-visitor part in a dynamic island.
- A dynamic island is a request to the server on every view of every page that places it,
  even when the page itself comes from a CDN's cache; on Publr Cloud it wakes the project.
  Place one only where the part is truly per visitor or per request, never in a layout
  every page shares; `defer` fetches it only when the reader scrolls near it. A part that
  only some visitors see differently is `dynamic-if="signedIn"` (or a condition the page
  registers with `Publr.islands.condition`): everyone else gets the build's copy and no
  request. Everything else is a static page or a static island, which a CDN serves
  without the server.
- Redirect and gate from the frontmatter:
  `if (!session) { Publr.request.redirect('/members/login'); }`.
- A route that is only logic (issue a token and redirect elsewhere, handle a webhook-like
  GET or POST) is middleware, never a page with a spinner: `middleware.zig` at the app's
  root checks `request.path()` and returns `request.redirect(url)`, `respond()` or
  `json()`, or `null` to let the app answer. It runs operations with `request.call()`.
- `getEntry()` on a `[slug]` page answers 404 when nothing is there: do not guard it.
- Interactive parts: a PTSX component with a PublrJS store, the design system's parts
  (`Button`, `Field`, `Input`, `Status`, `Callout`) and the feature's REST operations at
  `/api/app.<feature>/<verb>`, writes carrying the session's CSRF token. An app's sign-in
  form posts to `/api/auth/sign-in`; with an app on a subdomain, the session holds on
  every app of the domain.

## Tests

Tests live next to the plugin code and run with `zig build test`:

```zig
test "a subscriber subscribes, and never reaches the admin" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try publr.registry.SDK.bootstrap(&system);

    var ada = harness.ctx(.{ .user = .{ .id = "ada", .roles = &.{"subscriber"} } });
    // dispatch the feature's operations as ada, as someone else, as .anonymous; assert
    // what each may do and see, and that `publr.registry.SDK.reaches_admin(&ada)` is false.
}
```

Test access rules from both sides: what the owner may do, and what another member and an
anonymous caller may not.
