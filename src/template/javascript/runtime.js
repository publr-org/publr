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
    get session() { return host(scope + ".session", []); },
    header: name => host(scope + ".header", [name]),
    cookie: name => host(scope + ".cookie", [name]),
    random: bound => host(scope + ".random", [bound]),
    userField: name => host(scope + ".userField", [name]),
    call: name => host(scope + ".call", [name]),
    redirect: path => host(scope + ".redirect", [path]),
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
