//! The render runtime's one seam: a stack of `class` attributes merged and written as the
//! page sends it. The merge reads the class book the sheet was built with (the JIT's
//! `book.zig`): every class is the declarations it is made of, each a short name, and a
//! later declaration of a property in the same context removes an earlier one (`max-w-xl`
//! after `max-w-md`). A class the book does not hold (styled by hand-written CSS) is
//! written as it is. No parse, no allocation, no cache: the book was made when the sheet
//! was.
//!
//! The admin's book is built in. A site's own book (its sheet is built when its app loads)
//! is put in place for its render with `use`.
const std = @import("std");
const jit = @import("publr_jit");
const data = @import("class_book");

/// A class Zig code names (`listed("pl-4")`), as it is, for a view's props: the build reads
/// every `listed("…")` in `src/` into the sheet's classes, so it has a rule and a name.
pub fn listed(comptime classes: []const u8) []const u8 {
    comptime std.debug.assert(classes.len > 0);

    return classes;
}

/// The admin's book, as the build wrote it.
pub const admin: jit.Book = .{
    .classes = &data.classes,
    .marker_names = &data.marker_names,
    .atom_starts = &data.atom_starts,
    .class_atoms = &data.class_atoms,
    .class_slots = &data.class_slots,
    .atom_names = &data.atom_names,
    .atom_scopes = &data.atom_scopes,
    .atom_properties = &data.atom_properties,
    .cover_starts = &data.cover_starts,
    .covers = &data.covers,
};

/// The merged class list, owned by `arena`, with the admin's book.
pub fn merge_classes(arena: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return merge_classes_in(arena, null, parts);
}

/// The merged class list, owned by `arena`, with `book` (a `jit.Book`; null is the admin's).
pub fn merge_classes_in(
    arena: std.mem.Allocator,
    book: ?*const anyopaque,
    parts: []const []const u8,
) ![]const u8 {
    std.debug.assert(parts.len <= jit.book.classes_max);

    return jit.book.text(book_of(book), arena, parts);
}

/// The merged class list written into an attribute value the caller has opened, escaped.
pub fn write_classes(writer: *std.Io.Writer, parts: []const []const u8) !void {
    try write_classes_in(writer, null, parts);
}

pub fn write_classes_in(
    writer: *std.Io.Writer,
    book: ?*const anyopaque,
    parts: []const []const u8,
) !void {
    std.debug.assert(parts.len <= jit.book.classes_max);

    try jit.book.write(book_of(book), writer, parts);
}

fn book_of(book: ?*const anyopaque) *const jit.Book {
    const chosen: *const jit.Book = if (book) |held| @ptrCast(@alignCast(held)) else &admin;

    std.debug.assert(chosen.atom_starts.len == chosen.classes.len + 1);

    return chosen;
}

/// `classes` as the admin writes them, sorted: what a merge is compared with.
fn names_of(arena: std.mem.Allocator, classes: []const u8) ![]const u8 {
    return sorted(arena, try merge_classes(arena, &.{classes}));
}

fn sorted(arena: std.mem.Allocator, written: []const u8) ![]const u8 {
    std.debug.assert(written.len < 1 << 16);

    var names: std.ArrayList([]const u8) = .empty;
    var tokens = std.mem.tokenizeScalar(u8, written, ' ');

    while (tokens.next()) |name| try names.append(arena, name);

    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.less);

    return std.mem.join(arena, " ", names.items);
}

test "a later conflicting utility wins the merge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const written = try merge_classes(arena.allocator(), &.{ "max-w-md px-4", "max-w-xl" });

    try std.testing.expectEqualStrings(
        try names_of(arena.allocator(), "max-w-xl px-4"),
        try sorted(arena.allocator(), written),
    );
}

test "design-system scale tokens resolve as font-size utilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const written = try merge_classes(arena.allocator(), &.{ "text-body-sm", "text-xs" });
    const body = try names_of(arena.allocator(), "text-body-sm");
    var tokens = std.mem.tokenizeScalar(u8, try names_of(arena.allocator(), "text-xs"), ' ');

    // text-xs's size and line height replace body-sm's.
    while (tokens.next()) |name| {
        try std.testing.expect(std.mem.indexOf(u8, written, name) != null);
    }

    try std.testing.expect(!std.mem.eql(u8, body, try sorted(arena.allocator(), written)));
}

test "a class the book does not hold is written as it is" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_classes(&writer, &.{ "drawer-enter", "flex" });

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "drawer-enter") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "flex") == null);
}

test "a merge allocates only its answer" {
    var buffer: [256]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const merged = try merge_classes(fixed.allocator(), &.{ "flex px-2", "px-6" });

    try std.testing.expectEqual(merged.len, fixed.end_index);
}
