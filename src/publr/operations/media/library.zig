//! A file as the media operations answer with it.

pub const Item = struct {
    id: []const u8,
    title: []const u8,
    filename: []const u8,
    mime_type: []const u8,
    /// The media field's file family: `image`, `video`, `pdf`...
    family: []const u8,
    size: u64,
    width: ?u32 = null,
    height: ?u32 = null,
    /// The file's key, as in its address.
    key: []const u8,
    /// Where the file is served: `/media/<key>`, under the base a plugin gives through the
    /// mod `media.base` (`sdk/media_base.zig`).
    url: []const u8 = "",
    private: bool,
    created_at: i64,
    /// Taken in from the media folder; no one has looked at it yet.
    unreviewed: bool = false,
    /// Its file is gone from the media folder, or never came.
    missing: bool = false,
    /// Its bytes are on their way (`media.import`): referenced already, served once here.
    pending: bool = false,
};

pub const example_item: Item = .{
    .id = "0190a1b2c3d40001a1b2c3d4",
    .title = "Harbour at dawn",
    .filename = "harbour.jpg",
    .mime_type = "image/jpeg",
    .family = "image",
    .size = 482_113,
    .width = 2400,
    .height = 1600,
    .key = "2026/10/harbour-a1b2c3.jpg",
    .url = "/media/2026/10/harbour-a1b2c3.jpg",
    .private = false,
    .created_at = 1791244800000,
};
