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
            /// The signed-in user's picture, served from the admin's own address.
            avatar: []const u8,
        },
        admin: struct {
            /// What the project's addresses start with when it is served under a path
            /// (`/environments/dev`); empty at the root.
            base: []const u8,
            /// The address asked for, without the query.
            path: []const u8,
            /// The rail section the page is in: `overview`, `content`, `media`, `settings`, or
            /// `section` (a plugin's, its sidebar heading in `sidebar_heading`).
            area: []const u8,
            /// Structure, for whoever may change a content type.
            can_structure: bool,
            /// Settings, for whoever may manage the accounts.
            can_settings: bool,
            /// What plugins put in the top bar for this viewer.
            top_bar: ?Node,
            /// The pages the person pinned, after the admin's own.
            rail: ?Node = null,
            /// One of the pinned pages is the one shown: it is lit, not its area's.
            pinned_lit: bool = false,
            /// The area's sidebar, drawn only when the chrome reaches it.
            sidebar: ?Node,
            /// The sidebar's heading, for a plugin's section; the admin's own otherwise.
            sidebar_heading: ?Node = null,
            /// The plugin's section the page is in, and where it opens: the crumbs' first.
            section: []const u8 = "",
            section_href: []const u8 = "",
            /// The page is shown inside another (the AI workspace follows the agent in a
            /// frame): the sheet alone, without the rail and the sidebar.
            framed: bool = false,
            /// The language the admin speaks to the person (`pl`): `<html lang>`, and the
            /// catalogue the page's script loads; `en` needs none.
            locale: []const u8 = "en",
            /// Where the catalogue's script is, with its version; empty for English.
            messages: []const u8 = "",
            /// The variant content opens in, the person's choice (`pl`); empty for the main
            /// one. `<html data-variant>`, read by the editors' switches.
            variant: []const u8 = "",
            /// The account menu's languages, while a plugin translates the admin.
            language_menu: ?Node = null,
        },
        /// What runs the views' compiled expressions for their first values
        /// (`runtime.Expressions`), set by the render; not something a view reads.
        publr_expressions: ?*const anyopaque = null,
        /// The catalogue `Publr.t` reads the person's language from (`runtime.Translator`),
        /// set by the admin; null renders the source text.
        publr_translations: ?*const anyopaque = null,
        /// The same catalogue as a script, for the expressions the script engine runs.
        publr_catalogue: []const u8 = "",
        /// The class book the page's classes are written with (`publr_jit.Book`): a site's,
        /// built when its app loaded; null writes the admin's.
        publr_classes: ?*const anyopaque = null,
        /// The templates the page has written a prototype for (`runtime.Templates`), set
        /// by the render: a prototype of fixed text goes out once per page.
        publr_templates: ?*anyopaque = null,
    };
}

pub const Request = Shape(@import("runtime").Node);
