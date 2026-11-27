//! The installation itself: first-run setup, what a change rebuilds, an app's types handed
//! on, and anything it stores put exactly as another copy of it keeps it.
const operation = @import("../operation.zig");

pub const namespace: operation.Namespace = .{
    .name = "project",
    .label = "Project",
    .area = .site,
    .summary = "The installation itself: first-run setup",
    .details =
    \\What a fresh Publr project needs before it can be used. `project init` sets it
    \\up: it creates the first admin and marks the project as
    \\initialised, exactly once. `project impact` says what a change rebuilds in the
    \\apps' builds. `project put` puts anything it stores exactly as another copy of the
    \\project keeps it, ids kept: what keeps copies (environments, branches) in sync.
    \\`project set_clock` moves a test site's clock, to try time-driven work.
    ,
};

/// The keys of the dependency index a change raises.
pub const changes = @import("project/changes.zig");
pub const impact = @import("project/impact.zig");
pub const move_app = @import("project/move_app.zig");
pub const Put = @import("project/put.zig").Put;

pub const Init = struct {
    pub const name = "project.init";
    pub const open = true;
    /// Never written to the logs.
    pub const secret = .{"password"};
    pub const description = "Set up a fresh installation: creates the first admin, exactly once";
    pub const details =
        \\Run this once, right after the first `serve` (or before). It creates the first
        \\account with the `admin` role and records that the project is set up, so it can
        \\never run again: not after deleting users, not with `--as-admin`. Anyone may
        \\call it, which is why running it early matters. Later accounts are created
        \\with `user create`.
        \\
        \\Omit `--password` to have a strong one generated and printed once, or set the
        \\`PUBLR_PASSWORD` environment variable to keep it out of your shell history.
        \\
        \\`--language` is the site's: the language the admin speaks to everyone who chose
        \\none (one of `user language`'s choices; empty keeps English). It is the first
        \\account's own choice too, so the admin never asks it; later accounts choose theirs
        \\on their first visit.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        email: []const u8,
        display_name: []const u8,
        password: ?[]const u8 = null,
        language: []const u8 = "",
    };
    pub const Out = struct {
        user_id: []const u8,
        roles: []const []const u8,
        password: ?[]const u8,
    };
    pub const example: In = .{
        .email = "ada@example.com",
        .display_name = "Ada",
    };
    pub const example_out: Out = .{
        .user_id = "3f9c1e0a5b7d2c4e6f8a9b0c",
        .roles = &.{"admin"},
        .password = "k7pm2xq9rt4wnb8vhc3z",
    };
    pub const field_docs: operation.Docs(In) = .{
        .email = "Sign-in email; stored lowercased and trimmed",
        .display_name = "Name shown in the admin",
        .password = "8 to 256 characters; generated and shown once when omitted",
        .language = "The site's language (`pl`), one of `user language`'s choices; " ++
            "empty keeps English",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .user_id = "The new account's id",
        .roles = "Always `admin` for the first account",
        .password = "The generated password, only when you did not pass one; shown exactly once",
    };
};

/// Whether `project init` has happened: the admin sends a fresh installation to setup.
pub const Status = struct {
    pub const name = "project.status";
    pub const open = true;
    pub const description = "Whether the project has been initialised (its first admin created)";
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        initialised: bool,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .initialised = true,
    };
};
