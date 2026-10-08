(() => {
  const pending = new Map();
  let next = 1;
  const send = (message) => parent.postMessage(Object.assign({ publr: 1 }, message), "*");
  addEventListener("message", (event) => {
    const answer = event.data;
    if (event.source !== parent || !answer || answer.publr !== 1) return;
    const waiting = pending.get(answer.id);
    if (!waiting) return;
    pending.delete(answer.id);
    if (answer.ok) waiting.resolve(answer.value);
    else waiting.reject(new Error(answer.error));
  });
  window.publr = {
    call(operation, input) {
      const id = next++;
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        send({ kind: "call", id, operation: String(operation), input: input ?? {} });
      });
    },
    query(query, params) {
      const id = next++;
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        send({ kind: "query", id, query: String(query), params: params ?? {} });
      });
    },
    navigate(to) { send({ kind: "navigate", to: String(to) }); },
  };
  const height = () => send({ kind: "height", height: document.documentElement.scrollHeight });
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
})();
