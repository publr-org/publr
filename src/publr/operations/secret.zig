//! Secrets plugins name but never hold: `secret.list`, `secret.set`, `secret.remove`, and
//! `secret.digest`, a hash of text holding them, made by core.
const operation = @import("../operation.zig");

/// A hash of text holding a plugin's secrets, made by core.
pub const Digest = digest.Digest;
pub const Algorithm = digest.Algorithm;
pub const Encoding = digest.Encoding;
const digest = @import("secret/digest.zig");

/// A secret as `secret.list` answers it; its value never.
pub const Listed = struct {
    name: []const u8,
    /// `environment` (the variable wins), `kept` (set here), or `missing`.
    source: []const u8,
    /// The plugins that declare it, installed and built in.
    used_by: []const []const u8,
    updated_at: i64,
};

const example_listed: Listed = .{
    .name = "STOCKS_API_KEY",
    .source = "kept",
    .used_by = &.{},
    .updated_at = 1789650000000,
};

pub const namespace: operation.Namespace = .{
    .name = "secret",
    .label = "Secrets",
    .area = .system,
    .summary = "Secrets plugins name but never hold: API keys, set by an administrator",
    .details =
    \\A plugin declares the secrets it uses in `.secrets` (not a permission) and writes
    \\`{secret:NAME}` where the value goes in a request it sends out; the value is filled in
    \\as the request leaves, so the plugin never sees it. Names are site-wide: plugins
    \\naming the same one share its value. A value comes from the environment variable of
    \\the same name when a built-in plugin declares it or `PUBLR_SECRETS_FROM_ENVIRONMENT`
    \\lists it (names separated by spaces or commas), else from what an administrator set
    \\here, kept sealed
    \\with the project's key: `PUBLR_SECRET_KEY`, else `secret.key` beside the database.
    \\A value is never answered back. `PUBLR_SECRET_KEY` and
    \\`PUBLR_SECRETS_FROM_ENVIRONMENT` are never a secret's name. Administrators only,
    \\but for `secret.digest`: a plugin's code hashing text that holds its own secrets
    \\(a gateway's signature), the value filled in by core.
    ,
};

pub const List = struct {
    pub const name = "secret.list";
    pub const description = "List the secrets: those plugins declare and those set";
    pub const details =
        \\Each with where its value comes from (`environment`, `kept` or `missing`) and the
        \\plugins that declare it; never a value. `key` says where the project's key is:
        \\`environment`, `file`, or `none` until a secret is first set.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        limit: u32 = 50,
        offset: u32 = 0,
    };
    pub const Out = struct {
        secrets: []const Listed,
        key: []const u8,
        total: u32 = 0,
    };
    pub const field_docs: operation.Docs(In) = .{
        .limit = "How many at most; 50 when omitted, up to 200",
        .offset = "How many to pass over first: the set ones by name, then the declared",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .secrets = &.{example_listed},
        .key = "file",
    };
};

pub const Set = struct {
    pub const name = "secret.set";
    pub const description = "Set a secret's value, replacing any";
    pub const details =
        \\Kept sealed with the project's key, made beside the database the first time when
        \\`PUBLR_SECRET_KEY` is not set. An environment variable of the same name still wins.
        \\The value is up to 8 KiB and never shown again.
    ;
    pub const kind: operation.Kind = .write;
    pub const secret = .{"value"};
    pub const In = struct {
        name: []const u8,
        value: []const u8,
    };
    pub const Out = Listed;
    pub const example: In = .{
        .name = "STOCKS_API_KEY",
        .value = "sk-example",
    };
    pub const example_out: Out = .{
        .name = "STOCKS_API_KEY",
        .source = "kept",
        .used_by = &.{},
        .updated_at = 1789650000000,
    };
    pub const field_docs: operation.Docs(In) = .{
        .name = "Capitals, digits and underscores: STOCKS_API_KEY",
        .value = "The value; never shown again",
    };
};

pub const Remove = struct {
    pub const name = "secret.remove";
    pub const description = "Forget a secret's value";
    pub const details =
        \\The plugins that use it then send their requests without it, and are told it is
        \\missing. An environment variable of the same name is left as it is.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
    };
    pub const Out = struct {
        removed: bool,
    };
    pub const example: In = .{
        .name = "STOCKS_API_KEY",
    };
    pub const example_out: Out = .{
        .removed = true,
    };
    pub const field_docs: operation.Docs(In) = .{
        .name = "The secret's name",
    };
};
