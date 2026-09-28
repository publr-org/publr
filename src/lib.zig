//! Mechanisms that know nothing about content: SQLite, HTTP, authentication primitives,
//! ids, text, HTML escaping, error reporting, the process environment.

pub const db = @import("lib/db.zig");
pub const http = @import("lib/http.zig");
pub const auth = @import("lib/auth.zig");
pub const deps = @import("lib/deps.zig");
pub const id = @import("lib/id.zig");
pub const text = @import("lib/text.zig");
pub const time = @import("lib/time.zig");
pub const json = @import("lib/json.zig");
pub const html = @import("lib/html.zig");
pub const report = @import("lib/report.zig");
/// Compiled-in code only: never part of the plugin SDK.
pub const environment = @import("lib/environment.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
