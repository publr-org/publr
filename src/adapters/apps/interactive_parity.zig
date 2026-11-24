//! The render as JavaScript held to the Zig lowering's: every interactive component of the
//! fixture app `www`, drawn both ways with the same props, writes the same markup. The
//! JavaScript is the build's (`gen.script_render`), only in core's tests.
const std = @import("std");
const engine = @import("../../template.zig");
const spec_module = @import("spec.zig");
const scripted = @import("../../ui/scripted.zig");

const Prop = engine.Prop;

fn drawn(arena: std.mem.Allocator, render: engine.PjsxRender, props: []const Prop) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);

    try render.draw(render.context, &out.writer, arena, props, null, .{});

    return out.written();
}

test "an interactive component's render as JavaScript writes what its Zig render writes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spec = spec_module.find("www") orelse return error.SkipZigTest;
    const bundle: scripted.Bundle = .{
        .bytecode = @embedFile("interactive_parity"),
    };
    const cases = [_][]const Prop{
        &.{},
        &.{
            .{
                .name = "label",
                .value = "Shipping & <returns>",
            },
            .{
                .name = "body",
                .value = "\"Quoted\" 'text'",
            },
            .{
                .name = "classes",
                .value = "mt-4 p-2",
            },
        },
    };

    try std.testing.expect(spec.pjsx_components.len > 0);

    for (spec.pjsx_components, spec.pjsx_renders) |component, render| {
        const script: scripted.Component = .{
            .bundle = &bundle,
            .name = component.name,
        };

        for (cases) |props| {
            const zig = try drawn(arena, render, props);
            const javascript = try drawn(arena, script.pjsx_render(), props);

            try std.testing.expectEqualStrings(zig, javascript);
        }
    }
}

test "components of one program drawn on one page share its heap and write the same" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spec = spec_module.find("www") orelse return error.SkipZigTest;
    const bundle: scripted.Bundle = .{
        .bytecode = @embedFile("interactive_parity"),
    };
    var held: engine.Held = .{};
    defer held.release();

    try std.testing.expect(spec.pjsx_components.len > 1);

    for (0..2) |_| {
        for (spec.pjsx_components) |component| {
            const script: scripted.Component = .{
                .bundle = &bundle,
                .name = component.name,
            };
            const render = script.pjsx_render();
            var page: std.Io.Writer.Allocating = .init(arena);

            try render.draw(render.context, &page.writer, arena, &.{}, null, .{
                .held = &held,
            });
            try std.testing.expectEqualStrings(try drawn(arena, render, &.{}), page.written());
        }
    }

    try std.testing.expectEqual(@as(usize, 1), held.items.items.len);
}
