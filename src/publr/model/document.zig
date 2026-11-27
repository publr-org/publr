//! A document (a record, a term) as the operations over documents answer it.

/// One thing wrong with a document or a definition, at its path.
pub const Problem = @import("field.zig").Problem;

/// Why a document is read: `delivery`, the live copy; `edit`, the pending copy when there
/// are unpublished changes, else the live one.
pub const Purpose = enum { delivery, edit };

/// The order a list of documents answers in.
pub const Order = enum {
    updated_desc,
    updated_asc,
    created_desc,
    created_asc,
    title_asc,
    title_desc,
    status_asc,
    status_desc,
};

/// A check of a document without saving it.
pub const Report = struct {
    valid: bool,
    problems: []const Problem,
};

/// One document with what every reader wants next to it: its definition's handle, and the
/// live title and slug.
pub const Record = struct {
    id: []const u8,
    type_id: []const u8,
    type: []const u8,
    status: []const u8,
    changed: bool,
    version: i64,
    title: []const u8,
    slug: ?[]const u8,
    created_by: ?[]const u8,
    updated_by: ?[]const u8,
    created_at: i64,
    updated_at: i64,
    /// The app it belongs to (`app.zon`'s `.name`); null for the project's own.
    app: ?[]const u8 = null,
    /// A transition asked for by someone who may not publish; empty when none waits.
    requested: []const u8 = "",
    /// Who asked for it.
    requested_by: ?[]const u8 = null,
    /// The combinations of its dimensions it keeps from going live, `;` between them;
    /// empty when every one goes live.
    held_back: []const u8 = "",
    /// What it holds back once its pending changes are published; null when that is
    /// `held_back`.
    pending_held_back: ?[]const u8 = null,
};
