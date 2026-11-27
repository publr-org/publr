//! Liveness: `heartbeat.check` answers who is calling and which Publr runs, touching no data.
const operation = @import("../operation.zig");

/// The Publr version answering.
pub const version = @import("../version.zig").version;

pub const namespace: operation.Namespace = .{
    .name = "heartbeat",
    .label = "Liveness",
    .area = .background,
    .summary = "Liveness and version checks",
    .details =
    \\Operations that never touch data: use them to check that Publr is up, which
    \\version is running, and who you are calling as.
    ,
};

/// The longest echo `heartbeat.check` sends back.
pub const echo_len_max: u32 = 256;

pub const Check = struct {
    pub const name = "heartbeat.check";
    pub const description = "Check that Publr is alive; reports version and caller";
    pub const details =
        \\The simplest operation there is: it never touches the database and anyone
        \\may call it. Use it to check a deployment, to see which version runs, and
        \\to confirm who you are calling as (`--as`, `--as-admin`, or a session
        \\cookie over HTTP, where it backs `GET /api/health`).
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        echo: []const u8 = "",
    };
    pub const Out = struct {
        version: []const u8,
        echo: []const u8,
        caller: []const u8,
    };
    pub const example: In = .{
        .echo = "hello",
    };
    pub const example_out: Out = .{
        .version = version,
        .echo = "hello",
        .caller = "system",
    };
    pub const field_docs: operation.Docs(In) = .{
        .echo = "Any text; it comes back unchanged, handy for tracing a request",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .version = "The Publr version answering",
        .echo = "The echo you sent",
        .caller = "Who you are: `anonymous`, `system`, or a user id",
    };
};
