const publr = @import("publr");
const std = @import("std");

/// Place
///
/// A named point on a map.
pub const Place = struct {
    /// Name
    name: []const u8,
    /// Latitude
    lat: f64,
    /// Longitude
    lng: f64,
};

/// A latitude is between -90 and 90, a longitude between -180 and 180.
fn validate(place: Place, problems: *publr.Problems(Place)) void {
    std.debug.assert(place.name.len <= 1 << 16);

    if (place.lat < -90 or place.lat > 90) {
        problems.add(.lat, "Between -90 and 90.");
    }

    if (place.lng < -180 or place.lng > 180) {
        problems.add(.lng, "Between -180 and 180.");
    }
}

/// How a place reads in lists, search and on the site: Warsaw (52.23, 21.01).
fn text(ctx: *publr.Ctx, place: Place) publr.Error![]const u8 {
    std.debug.assert(place.name.len <= 1 << 16);

    return ctx.print("{s} ({d:.2}, {d:.2})", .{ place.name, place.lat, place.lng });
}

pub const kind = publr.field.kind(Place, .{
    .name = "place",
    .icon = "pin",
    .validate = validate,
    .text = text,
    .editor = publr.views.all.SamplerPlaceEditor,
});
