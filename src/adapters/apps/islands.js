// The island loader, linked from the `<head>` of every page that has
// placeholders. It is the same bytes on every page of every site and changes
// rarely, so it is one cached file rather than a copy in every document; the
// page preloads its static fragments alongside it, so waiting for this script
// costs no round trip in the chain.
// A polyfill for the shape of the WICG "declarative partial updates"
// proposal, on today's platform:
//
//   <publr-island src="<mount>/_islands/<key>" [credentials] [prerendered] [defer]>children…</publr-island>
//
// fetches its `src` — a fragment of the form
//
//   <template patchfor="<key>">…</template>
//
// parses it with createContextualFragment (scripts inert, nothing loads until
// adopted) and *replaces the placeholder* with the fragment's nodes. Whatever
// the placeholder held — a fallback, or a prerender — goes; an island has no
// children. No wrapper survives: the island's root element stands where
// <publr-island> stood, carrying `data-island="<key>"`, `data-island-src` and
// `data-island-kind="static|dynamic"` as its identity (what a later patch
// would target).
//
// `credentials` is written for dynamic islands (rendered per request, they may
// read the session), which are fetched with `include`. A static island is
// fetched `same-origin`: moved to a cookieless host it sends no cookies, which
// is what lets it be shared and `Access-Control-Allow-Origin: *`, and served
// from this origin it sends them and the server ignores them.
//
// Not `omit`, though that is what it means here — because a page preloads its
// islands, and a preload can only declare `anonymous` (credentials mode
// `same-origin`) or `use-credentials` (`include`). There is no way to spell
// `omit` on a <link>, so a fetch that omits can never match a preload: the
// browser downloads the fragment twice and says so in the console.
//
// WHEN a placeholder is resolved is the page's business, not the loader's:
//
//   prerendered   the placeholder is already the real thing, built with what
//                 the build knew — so the fetch that personalises it waits
//                 for `load` and then for an idle moment.
//   defer         resolved once the page has loaded and the reader is within
//                 300px of it, and not at all for one who never scrolls that
//                 far.
//   neither       resolved now: the placeholder is a fallback, and the page
//                 is wrong until it is replaced.
//
// A tier that resolves several placeholders at once puts the *dynamic* ones
// in a single request. They are `no-store`, per visitor and shared with
// nobody, so N of them is N round trips bought for nothing. Static islands
// stay one request each on purpose: each is cacheable, CORS-open and shared
// between pages, and the page preloaded it from its `<head>` — batching would
// trade all of that for one saved connection.
(() => {
  // A hard refresh bypasses the HTTP cache only for requests made while the
  // reload is in flight. A nested island is fetched later — after its parent's
  // fragment arrives — so its cached copy would survive one. The loader detects
  // the hard reload on the document itself: a reload always revalidates the
  // page, and only a hard one gets the full body back instead of a 304. On that
  // view every island fetch revalidates too — with ETags, an unchanged fragment
  // is still a cheap 304.
  const nav = performance.getEntriesByType('navigation')[0];
  const reloaded = nav?.type === 'reload' && nav.responseStatus !== 304;
  const cache = reloaded ? 'no-cache' : 'default';

  const src_of = (element) => element.getAttribute('src');
  const key_of = (element) => {
    const src = src_of(element);
    return src.slice(src.lastIndexOf('/') + 1);
  };

  // Whatever the placeholder held — a fallback, or a prerender — is replaced
  // wholesale: an island has no children, only a placeholder.
  //
  // A fragment's own <script> runs on the way in: the nodes are cloned out of
  // a <template>, where the parser never prepared them, so inserting them into
  // the document is what starts them. That is how an interactive component
  // brings its client half with it instead of every page linking it.
  //
  // Nothing is announced. A client runtime observes the document for markup
  // that arrives — PublrJS wires an inserted subtree the same way it tears one
  // down when it is removed — so the loader inserts nodes and stops there,
  // which is all a polyfill for a platform feature should do.
  const patch = (element, content) => {
    if (!element.isConnected) return;
    const roots = Array.from(content.children);
    if (roots.length === 1) {
      roots[0].dataset.island = key_of(element);
      roots[0].dataset.islandSrc = src_of(element);
      roots[0].dataset.islandKind = element.hasAttribute('credentials') ? 'dynamic' : 'static';
    }
    element.replaceWith(content);
  };

  // One request, then every placeholder it answers. A response carries one
  // `<template patchfor>` per island, so a batch and a single fetch are read
  // the same way; two call sites that share a fragment are answered by the
  // same template, each with its own copy of the nodes.
  const load = async (url, credentials, elements) => {
    let response;
    try {
      response = await fetch(url, { credentials, cache });
    } catch {
      return;
    }
    if (!response.ok) return;

    const fragment = document.createRange().createContextualFragment(await response.text());
    const patches = new Map();
    for (const template of fragment.querySelectorAll('template[patchfor]')) {
      patches.set(template.getAttribute('patchfor'), template.content);
    }

    for (const element of elements) {
      const content = patches.get(key_of(element)) ?? (patches.size ? null : fragment);
      if (content) patch(element, content.cloneNode(true));
    }
  };

  // `dynamic-if` placeholders wait until every script on the page has run (the page names
  // its conditions with `Publr.islands.condition`), then are fetched only where their
  // condition holds. A condition that is not there, or throws, fetches the island anyway:
  // a mistake costs a request, never the wrong content.
  const decided = new WeakSet();
  const holds = (name) => {
    const test = window.Publr?.islands?.conditions?.[name];
    if (typeof test !== 'function') {
      console.warn(`publr: no island condition "${name}"; the island is fetched`);
      return true;
    }
    try {
      return Boolean(test());
    } catch (error) {
      console.warn(`publr: island condition "${name}" failed; the island is fetched`, error);
      return true;
    }
  };
  const when_ready = (run) => {
    const islands = window.Publr?.islands;
    if (islands?.whenReady) islands.whenReady(run);
    else run();
  };

  // A set of placeholders wanted at the same moment.
  const resolve = (wanted) => {
    let elements = [...wanted];
    const conditional = elements.filter((element) =>
      element.hasAttribute('if') && !decided.has(element));
    if (conditional.length) {
      elements = elements.filter((element) => !conditional.includes(element));
      when_ready(() => {
        for (const element of conditional) decided.add(element);
        const passing = conditional.filter((element) => holds(element.getAttribute('if')));
        if (passing.length) resolve(passing);
      });
    }
    const dynamic = [];
    for (const element of elements) {
      if (element.hasAttribute('credentials')) dynamic.push(element);
      else load(src_of(element), 'same-origin', [element]);
    }
    if (dynamic.length === 1) {
      load(src_of(dynamic[0]), 'include', dynamic);
    } else if (dynamic.length > 1) {
      // Sorted so the URL is the one the build could have predicted.
      // Every island on a page is its app's: the batch is asked of the same app.
      const keys = [...new Set(dynamic.map(key_of))].sort();
      const base = src_of(dynamic[0]).slice(0, src_of(dynamic[0]).indexOf('/_islands/'));
      load(base + '/_islands/?keys=' + keys.join(','), 'include', dynamic);
    }
  };

  // ---- the viewport tier: `defer` placeholders ------------------------------

  // How far past the fold an island is fetched. Absolute, not a fraction of
  // the viewport: a fraction scales with the window, so on a tall screen a
  // short page's whole footer sits inside it and every `defer` island loads
  // at once — which is the opposite of what the attribute asks for.
  //
  // 300px is about a second of lead at a reading scroll, which covers the
  // round trip on a slow connection. Tighter and the reader watches the
  // fallback sit there and then swap; much looser and `defer` stops meaning
  // anything.
  const margin = '300px 0px';

  const observer = new IntersectionObserver((entries) => {
    const near = [];
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      observer.unobserve(entry.target);
      near.push(entry.target);
    }
    if (near.length) resolve(near);
  }, { rootMargin: margin });

  // ---- the idle tier: after `load`, at the next quiet moment ----------------

  // What both deferred tiers wait for. An IntersectionObserver reports its
  // targets as soon as it has them — during the first layout, inside the
  // window that decides LCP — so a `defer` island that happens to sit near
  // the fold would compete with the page's own paint however tight the margin
  // is. Observing only once the page has loaded is what actually keeps the
  // tier off the critical path; the margin then only decides how far ahead of
  // the reader to fetch.
  const idle = window.requestIdleCallback ?? ((run) => setTimeout(run, 1));
  const waiting = [];
  const watching = [];
  let loaded = document.readyState === 'complete';
  let pending = false;

  // Whether this script arrived *after* the page finished loading — which is
  // how a page with nothing waiting on the loader fetches it. The load phase
  // it was keeping clear is already over, so there is nothing left to defer
  // to: flush on a microtask instead of waiting for an idle period that the
  // browser is under no obligation to grant soon. The microtask still runs
  // after every element `customElements.define` upgrades, so a tier is
  // batched into one request exactly as it would have been.
  const late = loaded;

  const flush = () => {
    pending = false;
    for (const element of watching.splice(0)) observer.observe(element);
    if (waiting.length) resolve(waiting.splice(0));
  };
  const schedule = () => {
    if (pending) return;
    pending = true;
    if (late) queueMicrotask(flush);
    else idle(flush);
  };
  // Nothing is queued yet, so there is nothing to schedule here: the first
  // placeholder to be upgraded does it. Scheduling now would burn the one
  // flush the `pending` guard allows on an empty queue.
  if (!loaded) addEventListener('load', () => { loaded = true; schedule(); }, { once: true });

  const when_idle = (queue, element) => {
    queue.push(element);
    // Before `load` the whole page is still arriving: hold everything and
    // let one idle callback take the lot. After it — a nested island, say —
    // schedule for whatever has arrived since.
    if (loaded) schedule();
  };

  customElements.define('publr-island', class extends HTMLElement {
    connectedCallback() {
      if (!src_of(this) || !this.isConnected) return;
      if (this.hasAttribute('defer')) when_idle(watching, this);
      else if (this.hasAttribute('prerendered')) when_idle(waiting, this);
      else resolve([this]);
    }
  });
})();
