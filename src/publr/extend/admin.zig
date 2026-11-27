//! What a built-in plugin says about the admin around it: whose admin it is
//! (`host.admin_brand`) and where someone who must sign in goes instead of the form
//! (`host.sign_in_at`).
const Ctx = @import("../ctx.zig").Ctx;
const Error = @import("../operation.zig").Error;

/// Whose admin it is: its name in the window's title and its mark in the rail. Empty is
/// Publr's.
pub const AdminBrand = struct {
    name: []const u8 = "",
    /// The mark's address, an image any page may load.
    mark: []const u8 = "",
};

/// `host.admin_brand`: the brand for the person signed in, asked as them.
pub const Brand = fn (ctx: *Ctx) Error!AdminBrand;

/// `host.sign_in_at`: where to send someone who must sign in, given the admin page they
/// asked for (`wanted`, a path on this site); null to show the form. Asked as the system.
pub const SignInAt = fn (ctx: *Ctx, wanted: []const u8) anyerror!?[]const u8;
