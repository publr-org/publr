//! A sign-in session core made for one account (`ctx.start_session`).

pub const Session = struct {
    /// The session's cookie value: what `publr.Host.Context.set_session` signs the browser
    /// in with.
    token: []const u8,
    user_id: []const u8,
    expires_at_ms: i64,
};
