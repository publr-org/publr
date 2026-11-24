//! A plugin type's name declined in a language, as the language's PO file writes it under
//! `msgctxt "type-forms"`, the type's English name the message:
//! `masculine; nominative: produkt, produkty; genitive: produktu, produktów`. The gender
//! first, then each case with its singular and plural. What a type people made keeps on its
//! settings page, for the types plugins declare.
const std = @import("std");
const content_type = @import("content_type.zig");

const NounForms = content_type.NounForms;
const NounForm = content_type.NounForm;

pub const context = "type-forms";
const cases_max: u32 = 16;

/// The forms `text` writes, null when it writes none (an untranslated message is its English
/// name).
pub fn parse(arena: std.mem.Allocator, locale: []const u8, text: []const u8) !?NounForms {
    std.debug.assert(locale.len > 0);
    std.debug.assert(text.len <= 1 << 12);

    var parts = std.mem.splitSequence(u8, text, ";");
    const gender = std.mem.trim(u8, parts.first(), " ");

    if (!gender_word(gender)) {
        return null;
    }

    var forms: std.ArrayList(NounForm) = .empty;

    while (parts.next()) |part| {
        if (forms.items.len == cases_max) {
            break;
        }

        const colon = std.mem.indexOfScalar(u8, part, ':') orelse continue;
        const case = std.mem.trim(u8, part[0..colon], " ");
        var numbers = std.mem.splitScalar(u8, part[colon + 1 ..], ',');
        const singular = std.mem.trim(u8, numbers.first(), " ");
        const plural = std.mem.trim(u8, numbers.next() orelse "", " ");

        if (case.len > 0) {
            try forms.append(arena, .{
                .case = case,
                .singular = singular,
                .plural = plural,
            });
        }
    }

    return .{
        .locale = locale,
        .gender = gender,
        .forms = forms.items,
    };
}

/// A grammar's gender key: `masculine`, `masculine_personal`.
fn gender_word(text: []const u8) bool {
    std.debug.assert(text.len <= 1 << 12);

    if (text.len == 0) {
        return false;
    }

    for (text) |char| {
        if (!std.ascii.isLower(char) and char != '_') {
            return false;
        }
    }

    return true;
}

test "a gender, then each case's singular and plural" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "neuter; nominative: zamówienie, zamówienia; genitive: zamówienia, zamówień";
    const forms = (try parse(arena, "pl", text)).?;

    try std.testing.expectEqualStrings("neuter", forms.gender);
    try std.testing.expectEqual(@as(usize, 2), forms.forms.len);
    try std.testing.expectEqualStrings("zamówień", forms.forms[1].plural);
    try std.testing.expect(try parse(arena, "pl", "Order") == null);
    try std.testing.expect(try parse(arena, "pl", "Tax class") == null);
    try std.testing.expect(try parse(arena, "pl", "") == null);
}
