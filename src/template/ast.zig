//! What a `.publr` template is once it has been read: typed expressions, the frontmatter
//! as declarations, the body as nodes. Everything here lives in the app's arena.

const std = @import("std");

/// The static type every expression carries: a string is written escaped, a number
/// printed, and `??` needs an optional on its left.
pub const Type = enum {
    javascript,
    string,
    opt_string,
    int,
    boolean,
    /// `Publr.build.getEntry()`: the row a `[slug]` template renders.
    entry,
    /// `Publr.build.getCollection(...)`: a slice of entries.
    collection,
    /// `<entry>.data`: its fields.
    data,
    /// The `props` of a layout.
    props,
    /// `Publr.request.session`: who is signed in, if anyone (`.email`).
    session,
    null,

    pub fn is_optional(kind: Type) bool {
        return kind == .opt_string;
    }
};

pub const Expr = struct {
    type: Type,
    node: Form,

    pub const Form = union(enum) {
        javascript: u32,
        /// The characters between the quotes, exactly as written.
        string: []const u8,
        int: i64,
        boolean: bool,
        null,
        /// A frontmatter constant or a loop variable, by name.
        local: []const u8,
        props,
        member: Member,
        /// `a ?? b`: `a` is optional; the result is `b`'s type.
        nullish: Binary,
        /// `test ? a : b`: both arms the same type, or one of them `null` and the other
        /// a string (the result is then an optional string).
        ternary: Ternary,
        /// `a === b`, `a !== b` and the loose forms.
        equality: Equality,
        /// `<`, `<=`, `>`, `>=` between numbers.
        relational: Relational,
        /// `!value`: true when the value is not truthy.
        not: *const Expr,
        /// `a && b`, `a || b`: true or false, the right side read only when needed.
        logical: Logical,
        /// A template string: literal runs and string or number holes.
        template: []const TemplatePart,
    };

    pub const Member = struct {
        object: *const Expr,
        kind: Access,

        pub const Access = union(enum) {
            entry_title,
            entry_created_at,
            entry_updated_at,
            entry_slug,
            entry_id,
            entry_type,
            entry_data,
            /// `<entry>.data.<name>`
            data_text: []const u8,
            session_email,
            /// `.length` of a collection or a string.
            length,
            /// `props.<name>`
            prop: []const u8,
        };
    };

    pub const Binary = struct { left: *const Expr, right: *const Expr };

    pub const Logical = struct {
        left: *const Expr,
        right: *const Expr,
        operator: Operator,

        pub const Operator = enum { @"and", @"or" };
    };

    pub const Ternary = struct {
        condition: *const Expr,
        consequent: *const Expr,
        alternate: *const Expr,
    };

    pub const Equality = struct {
        left: *const Expr,
        right: *const Expr,
        negated: bool,
        mode: Mode,

        pub const Mode = enum { strings, ints, booleans, null_check };
    };

    pub const Relational = struct {
        left: *const Expr,
        right: *const Expr,
        operator: Operator,

        pub const Operator = enum { lt, le, gt, ge };
    };

    pub const TemplatePart = union(enum) {
        text: []const u8,
        hole: *const Expr,
    };
};

/// One `const name = ...;` of the frontmatter, evaluated in order before the body.
pub const Decl = struct {
    name: []const u8,
    type: Type,
    value: Value,
    /// An action inside `if (…) { … }`: it runs only when the condition holds (or, in the
    /// `else` branch, when it does not).
    when: ?When = null,

    pub const When = struct { condition: Expr, otherwise: bool = false };

    pub const Value = union(enum) {
        /// `Publr.build.now()`: `YYYY-MM-DD HH:MM:SS`, UTC.
        build_now,
        /// `Publr.request.now()`: the same shape, per request.
        request_now,
        /// `Publr.request.session`
        session,
        /// `Publr.request.header('<name>')`
        header: []const u8,
        /// `Publr.request.cookie('<name>')`
        cookie: []const u8,
        /// `Publr.request.random(<bound>)`
        random: u32,
        /// `Publr.request.userField('<group>.<field>')`: a custom field of the signed-in
        /// user, as text; null when nobody is signed in or the field is empty.
        user_field: []const u8,
        /// `Publr.request.call('<namespace>.<verb>')`: runs an operation that allows
        /// frontmatter calls, as the visitor; its output is the entry's `data`.
        call: []const u8,
        /// `Publr.request.redirect(<expression>)`: the page answers `303 See Other` to the
        /// path the expression gives, or renders as usual when it gives nothing.
        redirect: Expr,
        /// `Publr.build.getEntry()`: the type its position in content/ selects, or the one
        /// named; the slug from the route, or the one named.
        entry: EntryQuery,
        /// `Publr.build.getCollection({ ... })`
        query: Query,
        /// `<entry>.data.<key> ?? '<fallback>'`
        data_text: DataText,
        /// `<entry>.data.<key>` with no fallback: a repeater's rows, each read as an entry.
        data_items: References,
        /// `Publr.build.getReferences(<entry>, '<field>')`: the live records the field
        /// points at, in the order stored.
        references: References,
        /// `props.entry.<name>`: an entry the call site passes.
        entry_prop: []const u8,
        /// `props.<name> ?? '<fallback>'`: a string prop, the fallback when not passed.
        prop_text: PropText,
        /// `Publr.build.getReference(<entry>, '<field>')`: the one record a reference field
        /// points at, blank when it points at nothing live.
        reference: References,
    };

    pub const EntryQuery = struct {
        type_id: []const u8,
        slug: ?[]const u8 = null,
        /// The type's one (newest) record, from a template that is no route for it.
        first: bool = false,
    };

    pub const Query = struct { type_id: []const u8, limit: ?u32 = null, offset: ?u32 = null };
    pub const DataText = struct { object: []const u8, key: []const u8, fallback: []const u8 };
    pub const References = struct { object: []const u8, key: []const u8 };
    pub const PropText = struct { key: []const u8, fallback: []const u8 };
};

/// A prop at a component call site: a literal, or an expression whose value is a string,
/// an optional string, or an entry (for a prop the component declares as one).
pub const PropArg = struct {
    name: []const u8,
    value: Value,

    pub const Value = union(enum) {
        literal: []const u8,
        expr: Expr,
    };
};

pub const Node = union(enum) {
    /// Markup, exactly as authored (or collapsed, when the app is minified).
    text: []const u8,
    /// `{expr}`: written escaped by type.
    value: Expr,
    /// `set:html={expr}`: written raw.
    raw: Expr,
    /// ` name="..."` from an `={expr}` attribute: strings escaped, an optional only when
    /// present, a boolean as a bare attribute, a number printed.
    attr: Attr,
    /// An `/_app/...` URL, written under the app's mount with the asset fingerprint.
    asset: []const u8,
    /// `</head>` is about to be written: the stylesheet, the preloads, the loader.
    head_assets,
    /// `{items.map((item) => ( ... ))}`
    loop: Loop,
    /// `{test ? ( ... ) : ( ... | null)}`
    cond: Cond,
    /// `<slot />`: the caller's children, written raw.
    slot,
    /// `<X ... />`: a template embedded here, at this template's time.
    embed: Embed,
    /// `<X ... island />` / `<X ... dynamic />`: a `<publr-island>` placeholder.
    island: Island,
    /// `<X ... />` where X is a PJSX component: a call into its lowered module.
    pjsx: Pjsx,

    pub const Attr = struct { name: []const u8, expr: Expr };
    pub const Loop = struct { collection: []const u8, param: []const u8, body: []const Node };
    pub const Cond = struct { condition: Expr, consequent: []const Node, alternate: []const Node };
    pub const Embed = struct {
        callee: u32,
        props: []const PropArg,
        /// The children between the tags, or null when self-closing.
        children: ?[]const Node,
    };
    pub const Island = struct {
        callee: u32,
        /// The fragment's name under /_islands/.
        key: []const u8,
        /// Literal props only: the fragment is built once and shared.
        props: []const PropArg,
        /// Rendered per request (flattened into a live render), else a file.
        dynamic: bool,
        /// The placeholder is the build's own render of the fragment.
        prerender: bool,
        /// Fetched when scrolled near (the default) rather than at once (`eager`).
        deferred: bool,
        /// `dynamic-if="<name>"`: fetched only when the browser's condition of that name
        /// holds (`Publr.islands.condition`); empty for an island fetched on every view.
        condition: []const u8 = "",
        /// The fallback markup inside the placeholder (empty with `prerender`).
        fallback: []const Node,
    };
    pub const Pjsx = struct {
        component: u32,
        props: []const PropArg,
        children: ?[]const Node,
    };
};

pub const Kind = enum { page, layout, module };

/// One template, with everything the compiler learned about it: the route table, the
/// islands table, and what a page's `<head>` owes it, kept beside the template.
pub const Template = struct {
    /// App-relative path with forward slashes: "content/posts/[slug].publr".
    rel: []const u8,
    source: []const u8,
    kind: Kind,
    /// Where the source came from: the app's files, or an override.
    origin: Origin,
    decls: []const Decl = &.{},
    body: []const Node = &.{},
    /// Compiler-produced bytecode; its closures share frontmatter's lexical scope.
    javascript: ?[]const u8 = null,
    javascript_embeds: []const u32 = &.{},
    javascript_modules: []const u32 = &.{},
    /// Computed data queries have conservative pre-build impact; actual reads are tracked.
    javascript_reads: bool = false,
    /// A layout's props besides `children`, discovered from `props.<name>` references
    /// in its body. Null until compiled.
    props: ?[]const []const u8 = null,
    /// The props among `props` that are entries (`const item = props.entry.item;`): every
    /// call site has to pass each one.
    entry_props: []const []const u8 = &.{},
    /// Whether the frontmatter reads `Publr.request` (or the name, or the whole site,
    /// says so): rendered per request, never built.
    dynamic: bool = false,
    uses_build: bool = false,
    reads_request: bool = false,
    has_static_islands: bool = false,
    has_dynamic_islands: bool = false,
    has_head: bool = false,
    /// Whether anything rendered inline reads any data, its own or an embedded
    /// template's. False means a pure function of its props.
    reads_data: bool = false,
    /// Whether this template, anything it embeds, or anything an island of its will
    /// bring, renders a PJSX component.
    has_interactive: bool = false,
    /// Every static island key this template places, directly or through anything it
    /// embeds, nested fragments included; sorted.
    static_island_keys: []const []const u8 = &.{},
    /// The static islands whose placeholder is a prerender.
    static_idle_keys: []const []const u8 = &.{},
    /// The dynamic islands, by the tier the loader resolves them in.
    dynamic_eager_keys: []const []const u8 = &.{},
    dynamic_idle_keys: []const []const u8 = &.{},
    /// Every utility class the template's markup names.
    classes: []const []const u8 = &.{},
    compiled: bool = false,
    compiling: bool = false,

    pub const Origin = enum { app, override, added };

    /// Whether this page will render island placeholders, and so needs the loader: a
    /// static island always is one; a dynamic island is one unless the page is live,
    /// which flattens it.
    pub fn page_islands(template: *const Template) bool {
        return template.has_static_islands or
            (template.has_dynamic_islands and !template.dynamic);
    }
};

test "an entry id and its dates are strings; only opt_string is optional" {
    try std.testing.expect(Type.opt_string.is_optional());
    try std.testing.expect(!Type.string.is_optional());
    try std.testing.expect(!Type.entry.is_optional());

    const page: Template = .{
        .rel = "content/a.publr",
        .source = "",
        .kind = .page,
        .origin = .app,
    };
    try std.testing.expect(!page.page_islands());

    var with_dynamic = page;
    with_dynamic.has_dynamic_islands = true;
    try std.testing.expect(with_dynamic.page_islands());

    with_dynamic.dynamic = true;
    try std.testing.expect(!with_dynamic.page_islands());
}
