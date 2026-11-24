//! The parts of a move between two layouts (`transfer.zig`) whose shape is not the layout's
//! to say: a value whose shape comes with the data, and a union.
const std = @import("std");
const free_json = @import("../../sdk/free_json.zig");
const free_value = @import("../../sdk/free_value.zig");
const given_module = @import("given.zig");
const laid_module = @import("laid.zig");
const transfer = @import("transfer.zig");

const Given = given_module.Given;
const Layout = laid_module.Layout;
const Error = transfer.Error;

/// A value whose shape comes with the data on either side: copied as it is when both are;
/// built from one, or made into one, through the tree it stands for otherwise.
pub fn move_free(
    layout: *Layout,
    to: u32,
    at: u32,
    given: *Given,
    from: u32,
    bytes: []const u8,
) Error!void {
    const want = layout.described.nodes[to];
    const have = given.described.nodes[from];

    std.debug.assert(want.kind == .free or have.kind == .free or have.kind == .optional);

    if (have.kind == .optional) {
        if (given.present(from, bytes)) {
            return transfer.move(layout, to, at, given, have.child, bytes);
        }

        return layout.free(at, &.{@backingInt(free_value.Kind.null)});
    }

    if (have.kind == .free) {
        const held = try given.free(bytes);

        if (want.kind == .free) {
            return layout.free(at, held);
        }

        return layout.write(to, try free_json.tree_of(layout.scratch, .{
            .bytes = held,
        }), at);
    }

    const text = try given.json_of(from, bytes, .left_out);

    return layout.free(at, (try free_json.from_text(layout.scratch, text)).bytes);
}

/// A union to a union: the alternative of the same name, its payload moved. A union one
/// side has and the other does not goes through the JSON it stands for.
pub fn move_choice(
    layout: *Layout,
    to: u32,
    at: u32,
    given: *Given,
    from: u32,
    bytes: []const u8,
) Error!void {
    const want = layout.described.nodes[to];
    const have = given.described.nodes[from];

    std.debug.assert(want.kind == .choice or have.kind == .choice);

    if (want.kind != .choice or have.kind != .choice) {
        const text = try given.json_of(from, bytes, .left_out);
        const tree = std.json.parseFromSliceLeaky(std.json.Value, layout.scratch, text, .{}) catch {
            return error.Invalid;
        };

        return layout.write(to, tree, at);
    }

    const held = try given.chosen(from);
    const name = given.described.alternatives_of(from)[held.index].name;
    const index = layout.described.field_named(to, name, held.index) orelse return error.Invalid;
    const where = try layout.chosen(to, index);

    try given.enter();
    defer given.leave();

    const payload = layout.described.alternatives_of(to)[index].node;

    return transfer.move(layout, payload, where, given, held.node, held.bytes);
}
