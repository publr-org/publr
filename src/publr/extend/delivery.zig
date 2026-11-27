//! Delivery gates, as a built-in plugin declares one with `host.delivery_gate`: who may see
//! the public site. Before a page, a not-found page or an island is delivered, every gate is
//! asked about it, in plugin order. A gate may stay silent, keep what it lets through out of
//! shared caches, or answer in the page's place: a paywall, a members-only area, a site
//! still being built. The theme's assets are never gated: they show nothing of the content.
const Ctx = @import("../ctx.zig").Ctx;
const caller = @import("../caller.zig");
const Error = @import("../operation.zig").Error;

pub const gates_max: u32 = 16;
pub const body_bytes_max: u32 = 64 << 10;

/// What a gate is asked about.
pub const Delivery = struct {
    /// The system's: what the gate needs to decide (its own settings, the visitor's
    /// account) it reads through operations, as the system.
    ctx: *Ctx,
    /// Who asks: nobody signed in when `visitor.signed_in()` is false.
    visitor: caller.View,
    /// The path asked for, `/` and on; an island's is its `/_islands/…` path.
    path: []const u8,
};

/// What the visitor gets instead: a status from 400 to 599 and a page, HTML.
pub const Refusal = struct {
    status: u16,
    body: []const u8,
};

pub const Verdict = union(enum) {
    /// Nothing to say: deliver as usual.
    open,
    /// Deliver, but never from or into a shared cache: the answer is for this visitor.
    private,
    /// Answer this instead.
    refuse: Refusal,
};

pub const Gate = *const fn (delivery: *const Delivery) Error!Verdict;
