//! The sampler's own source, as the reference cuts its code from it: every file an entry
//! of `catalog.json` names.

pub const File = struct {
    path: []const u8,
    text: []const u8,
};

pub const files = [_]File{
    .{
        .path = "events/noted.zig",
        .text = @embedFile("../events/noted.zig"),
    },
    .{
        .path = "hooks/announce.zig",
        .text = @embedFile("../hooks/announce.zig"),
    },
    .{
        .path = "hooks/double.zig",
        .text = @embedFile("../hooks/double.zig"),
    },
    .{
        .path = "hooks/log_note.zig",
        .text = @embedFile("../hooks/log_note.zig"),
    },
    .{
        .path = "hooks/note_title.zig",
        .text = @embedFile("../hooks/note_title.zig"),
    },
    .{
        .path = "hooks/shout.zig",
        .text = @embedFile("../hooks/shout.zig"),
    },
    .{
        .path = "jobs/tick.zig",
        .text = @embedFile("../jobs/tick.zig"),
    },
    .{
        .path = "jobs/write_note.zig",
        .text = @embedFile("../jobs/write_note.zig"),
    },
    .{
        .path = "main.zig",
        .text = @embedFile("../main.zig"),
    },
    .{
        .path = "native.zig",
        .text = @embedFile("../native.zig"),
    },
    .{
        .path = "operations/count.zig",
        .text = @embedFile("../operations/count.zig"),
    },
    .{
        .path = "operations/hello.zig",
        .text = @embedFile("../operations/hello.zig"),
    },
    .{
        .path = "operations/later.zig",
        .text = @embedFile("../operations/later.zig"),
    },
    .{
        .path = "operations/measure.zig",
        .text = @embedFile("../operations/measure.zig"),
    },
    .{
        .path = "operations/note.zig",
        .text = @embedFile("../operations/note.zig"),
    },
    .{
        .path = "operations/note_panel.zig",
        .text = @embedFile("../operations/note_panel.zig"),
    },
    .{
        .path = "operations/page.zig",
        .text = @embedFile("../operations/page.zig"),
    },
    .{
        .path = "operations/submit.zig",
        .text = @embedFile("../operations/submit.zig"),
    },
    .{
        .path = "operations/wave.zig",
        .text = @embedFile("../operations/wave.zig"),
    },
    .{
        .path = "records/notes.zig",
        .text = @embedFile("../records/notes.zig"),
    },
    .{
        .path = "records/profile.zig",
        .text = @embedFile("../records/profile.zig"),
    },
    .{
        .path = "records/reviews.zig",
        .text = @embedFile("../records/reviews.zig"),
    },
    .{
        .path = "records/tallies.zig",
        .text = @embedFile("../records/tallies.zig"),
    },
};

pub fn find(path: []const u8) ?[]const u8 {
    @import("std").debug.assert(path.len > 0);

    for (files) |file| {
        if (@import("std").mem.eql(u8, file.path, path)) {
            return file.text;
        }
    }

    return null;
}
