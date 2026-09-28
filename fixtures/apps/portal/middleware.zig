const publr = @import("publr");

pub fn middleware(request: *publr.Request) !?publr.Response {
    const user = request.user();

    return request.json(.{
        .app = "portal",
        .path = request.path(),
        .signed_in = user != null,
    });
}
