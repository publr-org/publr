//! What an admin view reads as `Publr.request` while it renders on the server: who is
//! signed in and where the page stands. The admin fills it once per page from the
//! session; pjsx hands it down through every component call, so no page forwards it.
//! `Shape` takes the node type so the build tool can read the fields without the
//! render runtime.

pub fn Shape(comptime Node: type) type {
    return struct {
        session: struct {
            /// Empty on the pages before sign-in.
            name: []const u8,
            email: []const u8,
            csrf: []const u8,
        },
        admin: struct {
            /// What the project's addresses start with when it is served under a path
            /// (`/environments/dev`); empty at the root.
            base: []const u8,
            /// The address asked for, without the query.
            path: []const u8,
            /// The rail section the page is in: `overview`, `content` or `settings`.
            area: []const u8,
            /// Structure, for whoever may change a content type.
            can_structure: bool,
            /// Settings, for whoever may manage the accounts.
            can_settings: bool,
            /// What compiled-in plugins put in the top bar for this viewer.
            top_bar: ?Node,
            /// The area's sidebar, drawn only when the chrome reaches it.
            sidebar: ?Node,
        },
    };
}

pub const Request = Shape(@import("runtime").Node);
