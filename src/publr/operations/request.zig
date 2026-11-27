//! What a plugin reads of the visitor's requests (`request.read`): the query parameters it
//! declares as the visitor brought them, first and latest, where they landed and from where,
//! their address now and the cookies it declares, from a call the visitor makes.
const operation = @import("../operation.zig");

/// One query parameter or cookie as a visitor brought it.
pub const Value = struct {
    name: []const u8,
    value: []const u8,
};

/// A landing: where the visitor arrived, from where, when, and the parameters it brought.
pub const Touch = struct {
    landing: []const u8 = "",
    referrer: []const u8 = "",
    at_ms: i64 = 0,
    values: []const Value = &.{},
};

pub const namespace: operation.Namespace = .{
    .name = "request",
    .label = "Visitors' requests",
    .area = .system,
    .summary = "What plugins read of visitors' requests",
    .details =
    \\A plugin declares the query parameters and cookies it reads (`.request`) and asks for
    \\`request.read`: core keeps, for each visitor, the first and the latest landing that
    \\brought one, where it was and the page that sent them. `request read` answers its own
    \\names of them, with the visitor's address and cookies now. A plugin declaring path
    \\prefixes and holding `request.redirect` answers the addresses under them.
    ,
};

pub const Read = struct {
    pub const name = "request.read";
    pub const plugins_only = true;
    pub const description = "What the visitor brought: the plugin's query parameters, " ++
        "landing, referrer, address, cookies";
    pub const details =
        \\Plugins holding `request.read`, for the visitor of the call. Only the names the
        \\plugin declares (`.request`): the query parameters of the visitor's first and latest
        \\landing that brought any (empty when none did), and the cookies of this call. The
        \\address is the visitor's, behind the site's proxy (`X-Forwarded-For`).
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        first: Touch,
        last: Touch,
        address: []const u8,
        cookies: []const Value,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .first = .{
            .landing = "/products/tea",
            .referrer = "https://news.example.com/",
            .at_ms = 1789640000000,
            .values = &.{.{
                .name = "ref",
                .value = "ada",
            }},
        },
        .last = .{},
        .address = "203.0.113.7",
        .cookies = &.{},
    };
    pub const output_docs: operation.Docs(Out) = .{
        .first = "The first landing that brought a parameter the plugin reads",
        .last = "The latest such landing",
        .address = "The visitor's address now",
        .cookies = "The cookies the plugin declares, as this call brought them",
    };
};
