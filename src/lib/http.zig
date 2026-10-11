//! HTTP is `publr_http`. This is the app it generates for Publr (WebSockets, for the pages
//! that watch something live) and the handler contract every adapter is written against:
//! `fn (request, response, ctx) Error!void`.

const publr_http = @import("publr_http");

pub const websocket = publr_http.extensions.websocket;
pub const App = publr_http.Server(.{
    .websocket = websocket,
});
pub const Context = App.Context;
pub const Router = App.Router;
pub const Request = publr_http.Request;
pub const Response = publr_http.Response;
pub const Error = Response.Error;
pub const Head = publr_http.Head;
pub const Method = publr_http.Method;
pub const Status = publr_http.Status;
pub const Options = publr_http.Options;
pub const Form = publr_http.Form;
pub const parse = publr_http.parse;
pub const static = publr_http.static;
