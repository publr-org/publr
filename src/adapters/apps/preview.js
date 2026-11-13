// What a page in preview does for the window around it. It tells the tab where it is, so the
// tab's address follows the frame. And for a review comparing two versions of the site, it
// sends the window at the top its content as blocks (a heading, a paragraph, an image), and
// marks itself as told: blocks added or removed, blocks changed with the words they changed.
// A review makes it read only. Nothing leaves the browser.
(() => {
  parent.postMessage({ publrPreview: location.pathname + location.search }, "*");

  const BLOCKS = "h1,h2,h3,h4,h5,h6,p,li,blockquote,figcaption,td,th,dt,dd,pre,img,button,label";
  const LOOKS = {
    added: "outline:2px solid #16a34a;outline-offset:2px;background:rgba(22,163,74,.10)",
    removed: "outline:2px solid #dc2626;outline-offset:2px;background:rgba(220,38,38,.08)",
    changed: "outline:2px solid #d97706;outline-offset:2px",
  };
  const WORDS = {
    added: "background:rgba(22,163,74,.18);color:#15803d;border-radius:2px",
    removed: "background:rgba(220,38,38,.12);color:#b91c1c;text-decoration:line-through;border-radius:2px",
  };
  let found = [];
  const kept = new Map();

  const blocks = () =>
    [...document.body.querySelectorAll(BLOCKS)].filter(
      (element) => element.tagName === "IMG" || !element.querySelector(BLOCKS),
    );

  const describe = (element) => ({
    tag: element.tagName.toLowerCase(),
    text: element.tagName === "IMG"
      ? element.getAttribute("src") || ""
      : element.textContent.replace(/\s+/g, " ").trim(),
    plain: element.children.length === 0,
  });

  const send = () => {
    found = blocks();
    top.postMessage({ publrReview: "blocks", blocks: found.map(describe) }, "*");
  };

  const clear = () => {
    for (const [element, before] of kept) {
      if (before.style === null) element.removeAttribute("style");
      else element.setAttribute("style", before.style);
      if (before.html !== null) element.innerHTML = before.html;
    }
    kept.clear();
  };

  const keep = (element, words) => {
    if (kept.has(element)) return;
    kept.set(element, { style: element.getAttribute("style"), html: words ? element.innerHTML : null });
  };

  const apply = (marks) => {
    clear();
    for (const mark of marks) {
      const element = found[mark.at];
      if (!element || !LOOKS[mark.kind]) continue;
      const words = Array.isArray(mark.words) && mark.words.length > 0;
      keep(element, words);
      element.setAttribute("style", `${element.getAttribute("style") || ""};${LOOKS[mark.kind]}`);
      if (!words) continue;
      element.textContent = "";
      for (const part of mark.words) {
        const span = document.createElement("span");
        span.textContent = part.text;
        if (WORDS[part.mark]) span.setAttribute("style", WORDS[part.mark]);
        element.append(span);
      }
    }
  };

  // Shown in a review, a page is read only: nothing in it leads anywhere or sends anything.
  let read_only = false;
  const refuse = (event) => {
    if (event.type === "submit" || event.target.closest("a,area,button,[role=link]")) {
      event.preventDefault();
      event.stopPropagation();
    }
  };
  const lock = () => {
    if (read_only) return;
    read_only = true;
    addEventListener("click", refuse, true);
    addEventListener("submit", refuse, true);
    const style = document.createElement("style");
    style.textContent = "a,area,button,[role=link]{cursor:default!important}";
    document.head.append(style);
  };

  addEventListener("message", (event) => {
    const data = event.data;
    if (!data || typeof data.publrReview !== "string") return;
    if (data.publrReview === "read-only") lock();
    if (data.publrReview === "collect") send();
    if (data.publrReview === "marks" && Array.isArray(data.marks)) apply(data.marks);
    if (data.publrReview === "clear") clear();
  });

  if (document.readyState === "loading") addEventListener("DOMContentLoaded", send);
  else send();
})();
