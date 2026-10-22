const publr = @import("publr");
const std = @import("std");

const Media = publr.operations.media;

/// Shows how many letters each file's title has, in its facts in the media library
pub fn run(_: *publr.Ctx, _: *Media.List.In, out: *const Media.List.Out) publr.Error!void {
    std.debug.assert(out.items.len <= 200);

    for (out.items) |item| {
        const letters = std.unicode.utf8CountCodepoints(item.title) catch item.title.len;

        try out.extend(item, "sampler.letters", letters);
    }
}
