"use strict";
globalThis.__publr = (() => {
  const host = globalThis.__publr_host;
  const nodes = new WeakSet();
  const node = value => { nodes.add(value); return value; };
  const element = (name, attributes, children) => node({ kind: "element", name, attributes, children });
  const text = value => node({ kind: "text", value });
  const component = (index, attributes, children) => node({ kind: "component", index, attributes, children });
  const api = scope => Object.freeze({
    getEntry: (...args) => host(scope + ".getEntry", args),
    getCollection: (...args) => host(scope + ".getCollection", args),
    getReferences: (...args) => host(scope + ".getReferences", args),
    getReference: (...args) => host(scope + ".getReference", args),
    now: () => host(scope + ".now", []),
    // The language the page is in (`pl`), and the page in every language for a switch.
    locale: () => host(scope + ".locale", []),
    languages: () => host(scope + ".languages", []),
    money: (price, currency) => host(scope + ".money", [price, currency]),
    get session() { return host(scope + ".session", []); },
    header: name => host(scope + ".header", [name]),
    cookie: name => host(scope + ".cookie", [name]),
    param: name => host(scope + ".param", [name]),
    query: (text, params) => host(scope + ".query", [text, JSON.stringify(params ?? {})]),
    random: bound => host(scope + ".random", [bound]),
    userField: name => host(scope + ".userField", [name]),
    call: (name, input) => host(scope + ".call", [name, input === undefined ? "" : JSON.stringify(input)]),
    get: (type, id) => host(scope + ".get", [type, id]),
    findOne: (type, field, value) => host(scope + ".findOne", [type, field, String(value)]),
    find: (type, where, page) => host(scope + ".find", [type, JSON.stringify(where ?? {}), JSON.stringify(page ?? {})]),
    redirect: path => host(scope + ".redirect", [path]),
    // The file a media field holds: { url, alt, title, width, height, ... } or null.
    media: id => (typeof id === "string" && id !== "" ? host(scope + ".media", [id]) : null),
    // Its address, resized: mediaUrl(record.photo, { w: 800, h: 600, fit: "cover", q: 80 }).
    mediaUrl: (id, size) => {
      const file = typeof id === "string" && id !== "" ? host(scope + ".media", [id]) : null;
      if (!file) return "";
      const pairs = ["w", "h", "fit", "q"].filter(key => size && size[key] != null)
        .map(key => key + "=" + encodeURIComponent(String(size[key])));
      return pairs.length > 0 ? file.url + "?" + pairs.join("&") : file.url;
    },
  });
  return Object.freeze({ element, text, component, isNode: value => nodes.has(value),
    api: Object.freeze({ build: api("build"), request: api("request") }) });
})();
// Static computations use explicit, tracked time and randomness.
Math.random = () => { throw new Error("Use a seeded generator or Publr.request.random(n)"); };
(() => {
  const NativeDate = Date;
  const trackedTime = () => { throw new Error("Use Publr.build.now() or Publr.request.now()"); };
  globalThis.Date = new Proxy(NativeDate, {
    apply: trackedTime,
    construct(target, args, newTarget) {
      if (args.length === 0) return trackedTime();
      return Reflect.construct(target, args, newTarget);
    }
  });
  Date.now = trackedTime;
  NativeDate.prototype.constructor = Date;
})();
