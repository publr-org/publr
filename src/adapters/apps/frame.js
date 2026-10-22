// The guard, first in the `<head>` of a page served to a signed-in administrator, who sees
// it in the shell's sandboxed frame (`shell.zig`): an opaque origin, where the session
// cookie never goes. What the sandbox keeps out cannot work there, and is not dressed up
// to look as if it does:
//
// - A frame of another site (a video, a map, a payment form) inherits the sandbox and
//   breaks. It keeps its box, with a notice in it instead: "Hidden while you're signed in".
// - Cookies and storage throw. A read is let fail as it would; the script that tried is
//   noted.
//
// Everything noted goes to the shell, whose toolbar lists it and says how to see the page
// as a visitor does. A click on a notice opens that list. Visitors never load this file.
(() => {
  // An opaque origin's `location.origin` is still its address's: the shell's.
  const own = location.origin;
  const self_src = (document.currentScript?.src ?? '').split('?')[0];
  const items_max = 50;
  const items = [];
  const noted = new Set();
  const frames = new Map();
  let next = 1;
  let queued = false;

  const tell = (message) => {
    if (parent === window) {
      return;
    }

    try {
      parent.postMessage(message, own);
    } catch {
      // A parent of another origin: nobody to tell.
    }
  };

  const send = () => {
    queued = false;
    tell({ publr: 'blocked', items });
  };

  const add = (item) => {
    if (items.length >= items_max) {
      return null;
    }

    const entry = { id: String(next++), ...item };

    items.push(entry);

    if (!queued) {
      queued = true;
      queueMicrotask(send);
    }

    return entry;
  };

  // A source as a person knows it: this site's own script by its path, another site's by
  // its name.
  const named = (url) => (url.origin === own ? url.pathname : url.host);

  // The script that called: the first address in the stack that is not this file.
  const caller = () => {
    const stack = String(new Error().stack ?? '');

    for (const match of stack.matchAll(/(https?:\/\/[^\s()]+):\d+:\d+/g)) {
      const address = match[1].split('?')[0];

      if (address !== self_src) {
        try {
          return named(new URL(address));
        } catch {
          // Not an address after all.
        }
      }
    }

    return '';
  };

  const note = (what) => {
    const source = caller();
    const key = what + ' ' + source;

    if (noted.has(key)) {
      return;
    }

    noted.add(key);
    add({ kind: 'storage', what, source });
  };

  // Wraps an accessor so a throw is noted, then thrown on unchanged.
  const watch = (target, name, what) => {
    let owner = target;
    let descriptor = null;

    while (owner && !descriptor) {
      descriptor = Object.getOwnPropertyDescriptor(owner, name) ?? null;
      owner = descriptor ? owner : Object.getPrototypeOf(owner);
    }

    if (!descriptor?.get || !descriptor.configurable) {
      return;
    }

    const { get, set } = descriptor;

    Object.defineProperty(owner, name, {
      configurable: true,
      enumerable: descriptor.enumerable,
      get() {
        try {
          return get.call(this);
        } catch (error) {
          note(what);
          throw error;
        }
      },
      set: set && function (value) {
        try {
          set.call(this, value);
        } catch (error) {
          note(what);
          throw error;
        }
      },
    });
  };

  // The frame's own visitor, which a page with cookies would send without asking: on the
  // site's island and `_actions` calls, so a cart added to is the cart shown.
  const visitor_id = document.currentScript?.dataset.publrVisitor ?? '';
  const send_plain = window.fetch;
  const carries_visitor = /\/_(api|islands)\//;

  window.fetch = function (input, init) {
    let url;

    try {
      url = new URL(input instanceof Request ? input.url : String(input), document.baseURI);
    } catch {
      return send_plain.call(this, input, init);
    }

    if (!visitor_id || url.origin !== own || !carries_visitor.test(url.pathname)) {
      return send_plain.call(this, input, init);
    }

    const request = new Request(input, init);
    const headers = new Headers(request.headers);

    headers.set('publr-visitor', visitor_id);

    return send_plain.call(this, new Request(request, { headers }));
  };

  // Where the page goes next is the shell's to start. A navigation the frame starts itself
  // carries no cookie at all, so the server could not tell the frame from a stranger: the
  // next page would come back without this guard, as a new visitor with an empty cart. One
  // the shell starts is the administrator's frame again, served as the frame's visitor.
  const framed = parent !== window;
  const ours = (url) => url.origin === own;

  const go = (url, method, form, submitter) => {
    const message = { publr: 'go', url: url.href, method };

    if (method === 'post') {
      message.enctype = submitter?.getAttribute('formenctype') || form.enctype;
      message.entries = [...new FormData(form, submitter ?? undefined)];
    }

    tell(message);
  };

  // A link to another page of this site, opened in this frame.
  addEventListener('click', (event) => {
    if (!framed || event.defaultPrevented || event.button !== 0 || event.metaKey ||
        event.ctrlKey || event.shiftKey || event.altKey) {
      return;
    }

    const link = event.target instanceof Element ? event.target.closest('a[href]') : null;

    if (!link || link.hasAttribute('download') || (link.target && link.target !== '_self')) {
      return;
    }

    const url = new URL(link.href, document.baseURI);
    const same_document = url.pathname === location.pathname &&
      url.search === location.search && url.hash !== '';

    if (!ours(url) || same_document) {
      return;
    }

    event.preventDefault();
    go(url, 'get');
  });

  const sent = (form, submitter) => {
    const method = (submitter?.getAttribute('formmethod') || form.method || 'get').toLowerCase();
    const action = new URL(submitter?.getAttribute('formaction') || form.action, document.baseURI);
    const target = submitter?.getAttribute('formtarget') || form.target;

    if (!framed || !ours(action) || (target && target !== '_self') || method === 'dialog') {
      return false;
    }

    if (method === 'post') {
      go(action, 'post', form, submitter);
      return true;
    }

    const fields = [...new FormData(form, submitter ?? undefined)]
      .filter(([, value]) => typeof value === 'string');

    action.search = new URLSearchParams(fields).toString();
    go(action, 'get');
    return true;
  };

  addEventListener('submit', (event) => {
    if (!event.defaultPrevented && sent(event.target, event.submitter)) {
      event.preventDefault();
    }
  });

  // `form.submit()` fires no `submit` event.
  const submit_plain = HTMLFormElement.prototype.submit;

  HTMLFormElement.prototype.submit = function () {
    if (!sent(this, null)) {
      submit_plain.call(this);
    }
  };

  // A script's own navigation (`location.href = ...`), where the browser lets it be caught.
  // One the shell started is not cancelable here, so this never loops.
  globalThis.navigation?.addEventListener('navigate', (event) => {
    const kinds = ['push', 'replace'];

    if (!framed || !event.cancelable || event.hashChange || event.destination.sameDocument ||
        event.downloadRequest !== null || event.formData || !kinds.includes(event.navigationType)) {
      return;
    }

    const url = new URL(event.destination.url);

    if (ours(url)) {
      event.preventDefault();
      go(url, 'get');
    }
  });

  // What the shell checks: a page without this guard got here unseen, and it loads it again.
  Object.defineProperty(window, 'publr_guarded', { value: true });

  watch(Document.prototype, 'cookie', 'Cookies');
  watch(window, 'localStorage', 'Local storage');
  watch(window, 'sessionStorage', 'Session storage');

  const open = globalThis.IDBFactory?.prototype.open;

  if (open) {
    IDBFactory.prototype.open = function (...args) {
      try {
        return open.apply(this, args);
      } catch (error) {
        note('IndexedDB');
        throw error;
      }
    };
  }

  const escape = (text) =>
    text.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

  // The notice, in the frame's own box: whatever size the page gave it, it fills it. A
  // click tells this page, which tells the shell.
  const notice = (source) => `<!doctype html><html><head><meta charset="utf-8"><style>
    html, body { margin: 0; height: 100%; }
    body {
      display: grid; place-items: center; box-sizing: border-box; padding: 12px;
      overflow: hidden; cursor: pointer; text-align: center;
      background: repeating-linear-gradient(135deg, #ececec 0 10px, #e4e4e4 10px 20px);
      color: #4a4a4a; font: 500 13px/1.45 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
    }
    div { display: grid; justify-items: center; gap: 4px; max-width: 32em; }
    svg { width: 22px; height: 22px; color: #c62828; }
    strong { color: #1f1f1f; font-weight: 600; }
    span { color: #6b6b6b; font-size: 12px; }
    body:hover strong { text-decoration: underline; }
  </style></head><body><div>
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
         stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z"/>
      <path d="M12 9v4M12 17h.01"/>
    </svg>
    <strong>Hidden while you're signed in</strong>
    <span>${escape(source)} &middot; click for details</span>
  </div><script>
    addEventListener('click', () => parent.postMessage({ publr: 'blocked-open' }, '*'));
  </script></body></html>`;

  // A frame of another site gets the notice instead. Its `src` stays as the page set it,
  // for the page's own code; `srcdoc` wins over it.
  const guard = (frame) => {
    if (frames.has(frame)) {
      return;
    }

    const src = frame.getAttribute('src');

    if (!src) {
      return;
    }

    let url;

    try {
      url = new URL(src, document.baseURI);
    } catch {
      return;
    }

    if ((url.protocol !== 'http:' && url.protocol !== 'https:') || url.origin === own) {
      return;
    }

    const entry = add({ kind: 'frame', what: 'Embedded content', source: named(url) });

    if (!entry) {
      return;
    }

    frames.set(frame, entry.id);
    frame.dataset.publrBlocked = entry.id;
    frame.srcdoc = notice(entry.source);
  };

  const scan = (node) => {
    if (node.nodeType !== 1) {
      return;
    }

    if (node.localName === 'iframe') {
      guard(node);
    } else if (node.firstElementChild) {
      node.querySelectorAll('iframe').forEach(guard);
    }
  };

  new MutationObserver((records) => {
    for (const record of records) {
      if (record.type === 'attributes') {
        scan(record.target);
      } else {
        record.addedNodes.forEach(scan);
      }
    }
  }).observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['src'],
  });

  document.querySelectorAll('iframe').forEach(guard);

  const reveal = (id) => {
    for (const [frame, held] of frames) {
      if (held !== id || !frame.isConnected) {
        continue;
      }

      frame.scrollIntoView({ block: 'center', behavior: 'smooth' });
      frame.style.setProperty('outline', '3px solid #c62828');
      frame.style.setProperty('outline-offset', '2px');
      setTimeout(() => {
        frame.style.removeProperty('outline');
        frame.style.removeProperty('outline-offset');
      }, 1600);
      return;
    }
  };

  addEventListener('message', (event) => {
    const kind = event.data?.publr;

    // From a notice: which one is the frame it came from.
    if (kind === 'blocked-open') {
      for (const [frame, id] of frames) {
        if (frame.contentWindow === event.source) {
          tell({ publr: 'blocked-open', id });
          return;
        }
      }

      return;
    }

    if (event.source !== parent) {
      return;
    }

    if (kind === 'blocked-ask') {
      send();
    } else if (kind === 'blocked-show') {
      reveal(String(event.data.id ?? ''));
    }
  });

  // A fresh page starts the shell's list over, empty or not.
  send();
})();
