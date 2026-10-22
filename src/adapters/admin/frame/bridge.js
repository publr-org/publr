// The frame's side of the bridge, given who is looking and the page (`frame`): what the
// view's `ctx` reads in the browser (`Publr.ctx`, made from it), and how the frame reaches
// the admin, by `postMessage` to its parent.
((frame) => {
  const pending = new Map();
  let next = 1;
  const post = (message) => parent.postMessage(Object.assign({ publr: 1 }, message), "*");
  // The admin may start listening after this page's own scripts run: what the page sends
  // waits until the admin answers a hello, which is said again until it does.
  const waiting = [];
  let listened = false;
  let hellos = 0;
  const send = (message) => (listened ? post(message) : waiting.push(message));
  const hello = () => {
    if (listened || hellos++ >= 100) return;
    post({ kind: "hello" });
    setTimeout(hello, 100);
  };
  addEventListener("message", (event) => {
    const answer = event.data;
    if (event.source !== parent || !answer || answer.publr !== 1) return;
    if (answer.kind === "ready") {
      listened = true;
      waiting.splice(0).forEach(post);
      return;
    }
    const caller = pending.get(answer.id);
    if (!caller) return;
    pending.delete(answer.id);
    if (answer.ok) caller.resolve(answer.value);
    else caller.reject(new Error(answer.error));
  });
  hello();
  window.publr = {
    person: frame.person,
    page: frame.page,
    // One of the plugin's own operations, run by the admin as the person looking.
    send(operation, input) {
      const id = next++;
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        send({ kind: "call", id, operation: String(operation), input: input ?? {} });
      });
    },
    navigate(to) { send({ kind: "navigate", to: String(to) }); },
    // The plugin's own log lines, newest first, after the line `after` (0 for the latest).
    log(after) {
      const id = next++;
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        send({ kind: "log", id, after: Number(after) || 0 });
      });
    },
    // A walk through the admin's own pages, shown over this one: each step goes to a page or
    // follows a link, and points at what to look at. It moves and points; it never presses.
    tour(steps) { send({ kind: "tour", steps: Array.isArray(steps) ? steps.slice(0, 32) : [] }); },
  };
  // What it shows, not the frame's own size: a panel shrinks to its content as well as grows.
  const height = () => {
    const body = document.body;
    const style = getComputedStyle(body);
    const margins = parseFloat(style.marginTop) + parseFloat(style.marginBottom);
    send({ kind: "height", height: Math.ceil(body.getBoundingClientRect().height + margins) });
  };
  addEventListener("load", () => {
    height();
    new ResizeObserver(height).observe(document.body);
  });
  document.addEventListener("click", (event) => {
    const link = event.target instanceof Element ? event.target.closest("a[href]") : null;
    if (!link || event.defaultPrevented) return;
    const href = link.getAttribute("href");
    if (/^https?:\/\//i.test(href)) {
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      return;
    }
    event.preventDefault();
    send({ kind: "navigate", to: href });
  });
})
