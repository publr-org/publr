//! A response read piece by piece, as it arrives: `http.stream` sends the request and
//! answers once its head is in, `http.read` hands over what has come since. How a model
//! provider shows a reply as it is written. Only where a process holds the open responses
//! across a plugin's calls: an agent's.
const operation = @import("../../operation.zig");
const http = @import("../http.zig");

pub const Stream = struct {
    pub const name = "http.stream";
    pub const plugins_only = true;
    pub const description = "Send a request out and read its answer as it arrives";
    pub const details =
        \\As `http.fetch`, under the same grant and domains, but answers once the response's
        \\head is in: its status and a `handle` that `http.read` reads the body through, a
        \\piece at a time, as it comes (a model's reply as it is written). A status other
        \\than 200 answers with the body at once and no handle. Queued work only, as
        \\`http.fetch` is: an agent's turn, or a job that holds open responses.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = http.Fetch.In;
    pub const Out = struct {
        status: u16,
        handle: u32 = 0,
        body: []const u8 = "",
    };
    pub const example: In = http.Fetch.example;
    pub const example_out: Out = .{
        .status = 200,
        .handle = 1,
    };
    pub const field_docs = http.Fetch.field_docs;
};

pub const Read = struct {
    pub const name = "http.read";
    pub const plugins_only = true;
    pub const description = "Read what has arrived of a streamed response";
    pub const details =
        \\The next piece of the body `http.stream` opened, as much as has arrived (at least a
        \\byte, up to 16 KiB), waiting until some has; `done` once it has all come, and the
        \\handle is closed.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        handle: u32,
    };
    pub const Out = struct {
        data: []const u8,
        done: bool,
    };
    pub const example: In = .{
        .handle = 1,
    };
    pub const example_out: Out = .{
        .data = "event: ping\ndata: {}\n\n",
        .done = false,
    };
    pub const field_docs: operation.Docs(In) = .{
        .handle = "What `http.stream` answered",
    };
};
