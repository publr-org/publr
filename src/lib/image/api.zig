pub const api = @cImport({
    @cInclude("stb_image.h");
    @cInclude("stb_image_resize2.h");
    @cInclude("stb_image_write.h");
    @cInclude("src/webp/encode.h");
});
