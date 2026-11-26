/// What a type is for: `record` types hold any number of records (posts, hotels), a
/// `settings` type holds exactly one (the homepage, the header, general options), a
/// `component` holds none: it is a set of fields other types will reuse. A `media` type's
/// records are files: the library's own (`media`) or another set core or a plugin keeps
/// apart from it (pictures pasted into a chat). A media type shows only where its owner
/// draws it, never in Content.
pub const Kind = enum { record, settings, component, media };
