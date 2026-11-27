//! Core's own event when an app is loaded from the folder, as the server starts or the folder
//! changes, emitted outside any operation: `publr.after(publr.AppsLoaded, run)`.

pub const AppsLoaded = @import("plugin/hook_define.zig").event(.{
    .name = "apps.loaded",
    .payload = struct {
        /// The app's name
        app: []const u8,
    },
});
