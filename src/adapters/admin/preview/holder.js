// The preview tab's own script. The editor's Preview leaves the form, as it stood, in this
// tab's session storage (a tab opened by the editor starts with a copy of the editor's); the
// form is posted into the frame, so reloading the tab draws it again without asking to send
// anything twice. Without one the frame draws what is saved. Each page in the frame says
// where it is; the tab's address follows (`?path=`), so a reload comes back to that page.
(() => {
  const frame = document.querySelector("iframe[name='publr-preview']");
  if (!frame) return;
  const page = frame.dataset.page;
  let pairs = null;
  try {
    pairs = JSON.parse(sessionStorage.getItem("publr-preview") ?? "null");
  } catch {
    pairs = null;
  }
  addEventListener("message", (event) => {
    if (event.source !== frame.contentWindow) return;
    const at = event.data && event.data.publrPreview;
    if (typeof at !== "string") return;
    const cut = at.indexOf("/site/");
    if (cut < 0) return;
    const path = at.slice(cut + "/site".length);
    history.replaceState(null, "", `${location.pathname}?path=${encodeURIComponent(path)}`);
  });
  if (!Array.isArray(pairs)) {
    frame.src = page;
    return;
  }
  const form = document.createElement("form");
  form.method = "post";
  form.action = page;
  form.target = frame.name;
  form.hidden = true;
  for (const [name, value] of pairs) {
    const input = document.createElement("input");
    input.type = "hidden";
    input.name = String(name);
    input.value = String(value);
    form.append(input);
  }
  document.body.append(form);
  form.submit();
  form.remove();
})();
