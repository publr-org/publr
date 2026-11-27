//! Records read as core stores them: content types, their fields and internal collections.
const std = @import("std");
const record_define = @import("../../../publr/plugin/record_define.zig");
const plugin_define = @import("../../../publr/plugin/define.zig");
const words = @import("../../../publr/plugin/words.zig");
const records = @import("../records.zig");

const define = record_define.define;
const content_type_of = records.content_type_of;
const collection_of = records.collection_of;

test "a list of structs is a repeater, its rows' fields declared alike; text defaults" {
    const Line = struct {
        title: []const u8,
        quantity: u32,
    };
    const Order = struct {
        fulfilment: []const u8 = "Placed",
        lines: []const Line = &.{},
    };
    const Docs = plugin_define.Words(.{
        .{ @typeName(Order), "Order" },
        .{ @typeName(Order) ++ ".fulfilment", "Fulfilment" },
        .{ @typeName(Order) ++ ".lines", "Lines" },
        .{ @typeName(Line) ++ ".title", "Product" },
        .{ @typeName(Line) ++ ".quantity", "Quantity" },
    });
    const Orders = define(Order, .{
        .name = "shop.order",
        .fields = .{
            .lines = .{
                .fields = .{
                    .quantity = .{
                        .validation = .{
                            .required = false,
                        },
                    },
                },
            },
        },
    });
    const def = comptime content_type_of(Orders, Docs);
    const lines = def.fields[1];

    try std.testing.expectEqualStrings("Placed", def.fields[0].default);
    try std.testing.expect(!def.fields[0].validation.required);
    try std.testing.expectEqualStrings("repeater", lines.kind);
    try std.testing.expect(!lines.many);
    try std.testing.expectEqualStrings("Product", lines.fields[0].label);
    try std.testing.expectEqualStrings("integer", lines.fields[1].kind);
    try std.testing.expect(!lines.fields[1].validation.required);
}

test "a decimal keeps its places and a list of text is one field holding several" {
    const Weight = @import("../../../publr/plugin/decimal.zig").Decimal(3);
    const Line = struct {
        title: []const u8,
        weight: Weight,
        codes: []const []const u8 = &.{},
    };
    const Docs = plugin_define.Words(.{
        .{ @typeName(Line), "Line" },
        .{ @typeName(Line) ++ ".title", "Title" },
        .{ @typeName(Line) ++ ".weight", "Weight" },
        .{ @typeName(Line) ++ ".codes", "Codes" },
    });
    const Lines = define(Line, .{
        .name = "shop.line",
    });
    const def = comptime content_type_of(Lines, Docs);

    try std.testing.expectEqualStrings("decimal", def.fields[1].kind);
    try std.testing.expectEqual(@as(?u32, 3), def.fields[1].options.number.decimals);
    try std.testing.expectEqualStrings("string", def.fields[2].kind);
    try std.testing.expect(def.fields[2].many);
}

test "a field says how it holds a dimension's values through its owner's field option" {
    const Product = struct {
        name: []const u8,
        sku: []const u8,
    };
    const Docs = plugin_define.Words(.{
        .{ @typeName(Product), "Product" },
        .{ @typeName(Product) ++ ".name", "Name" },
        .{ @typeName(Product) ++ ".sku", "SKU" },
    });
    const Products = define(Product, .{
        .name = "shop.product",
        .fields = .{
            .name = .{
                .translatable = .required,
                .searchable = true,
            },
        },
    });
    const def = comptime content_type_of(Products, Docs);

    try std.testing.expectEqual(1, def.fields[0].wrapped.len);
    try std.testing.expectEqualStrings("translatable", def.fields[0].wrapped[0].option);
    try std.testing.expectEqualStrings("required", def.fields[0].wrapped[0].value);
    try std.testing.expect(def.fields[0].searchable);
    try std.testing.expectEqual(0, def.fields[1].wrapped.len);
}

test "a struct field is a group; yes/no, number and choice defaults reach the form" {
    const Size = struct {
        width: u32 = 0,
        height: u32 = 0,
    };
    const Mood = enum { calm, loud };
    const Item = struct {
        size: Size = .{},
        available: bool = true,
        days: u32 = 20,
        mood: Mood = .loud,
    };
    const Docs = plugin_define.Words(.{
        .{ @typeName(Item), "Item" },
        .{ @typeName(Item) ++ ".size", "Size" },
        .{ @typeName(Item) ++ ".available", "Available" },
        .{ @typeName(Item) ++ ".days", "Days" },
        .{ @typeName(Item) ++ ".mood", "Mood" },
        .{ @typeName(Size) ++ ".width", "Width" },
        .{ @typeName(Size) ++ ".height", "Height" },
    });
    const Items = define(Item, .{
        .name = "shop.item",
        .title_field = .mood,
    });
    const def = comptime content_type_of(Items, Docs);

    try std.testing.expectEqualStrings("group", def.fields[0].kind);
    try std.testing.expectEqualStrings("Height", def.fields[0].fields[1].label);
    try std.testing.expectEqualStrings("true", def.fields[1].default);
    try std.testing.expectEqualStrings("20", def.fields[2].default);
    try std.testing.expectEqualStrings("loud", def.fields[3].default);
}

test "a content type and an internal record from their document structs" {
    const Entry = struct {
        name: []const u8,
        message: []const u8,
        visits: u32 = 0,
        seen_at: ?words.Time = null,
    };
    const Docs = plugin_define.Words(.{
        .{ @typeName(Entry), "Guestbook entry\n\nWhat visitors leave." },
        .{ @typeName(Entry) ++ ".name", "Name\nWho signed" },
        .{ @typeName(Entry) ++ ".message", "Message" },
        .{ @typeName(Entry) ++ ".visits", "Visits" },
        .{ @typeName(Entry) ++ ".seen_at", "Seen" },
    });
    const Entries = define(Entry, .{
        .name = "guestbook.entry",
        .public = true,
        .fields = .{
            .message = .{
                .validation = .{
                    .max_len = 500,
                },
            },
        },
    });
    const def = comptime content_type_of(Entries, Docs);

    try std.testing.expectEqualStrings("guestbook.entry", def.handle);
    try std.testing.expectEqualStrings("Guestbook entry", def.name);
    try std.testing.expectEqualStrings("name", def.title_field);
    try std.testing.expectEqualStrings("string", def.fields[0].kind);
    try std.testing.expectEqualStrings("Who signed", def.fields[0].help);
    try std.testing.expect(def.fields[0].validation.required);
    try std.testing.expectEqual(500, def.fields[1].validation.max_len.?);
    try std.testing.expectEqualStrings("integer", def.fields[2].kind);
    try std.testing.expect(!def.fields[2].validation.required);
    try std.testing.expectEqualStrings("datetime", def.fields[3].kind);

    const Tally = define(Entry, .{
        .name = "guestbook.tally",
        .internal = true,
        .indexed = &.{.name},
    });
    const collection = comptime collection_of(Tally);

    try std.testing.expectEqualStrings("tally", collection.kind);
    try std.testing.expectEqualStrings("name", collection.indexed[0]);
    try std.testing.expect(collection.shared);
}
