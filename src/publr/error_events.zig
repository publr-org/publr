//! `publr.errors.Failed`: everything that lands in the Error log as an error (a failed or
//! crashed call, an `.err` log line, a failed job or `on` run), for error trackers and
//! alerts. Kept outside the write that rolled back, like the Error log entry, and heard by
//! `on` hooks only. Refusals a caller is told about raise nothing.
const event = @import("plugin/hook_define.zig").event;

pub const Failed = event(.{
    .name = "errors.failed",
    .payload = struct {
        /// What failed: an operation (`orders.place`), a job's run (`job:<plugin>.<name>`), a
        /// hook's run on an event (`event:<name>`), a sign-in provider's step
        /// (`sign_in:<provider>`)
        what: []const u8,
        /// The plugin it belongs to; empty for core's
        plugin: []const u8 = "",
        /// The error's name (`Unavailable`, `OutOfMemory`); `Logged` for an error line
        error_name: []const u8,
        /// What the error or the line says; empty when nothing does
        message: []const u8 = "",
        /// Who called: `user`, `token`, `machine`, `plugin`, `anonymous`, `system`, or `job`
        /// for queued work
        caller: []const u8,
        /// When, in milliseconds since 1970
        at: i64,
        /// The Error log entry's id
        entry: i64,
    },
});
