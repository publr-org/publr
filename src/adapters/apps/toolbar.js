// The toolbar, linked from the `<head>` of every page: for someone signed in to this
// site, a small bar in the admin's rail colours with the way into the admin and to the
// editor of what the page shows ("Edit Post"). It can be dragged anywhere by the mark
// (the place is remembered) and hidden; hidden, it leaves a small triangle that shows
// when the pointer reaches the page's bottom-right corner, and brings the bar back.
//
// Everyone else pays one cookie read. The session cookie is HttpOnly, so the sign-in also
// sets `publr_signed_in=1`, which holds no secret; without it the script stops here, and
// PublrJS is never fetched. With it, `/_publr/toolbar` says what the bar offers, as the
// session sees it; a hint the server no longer backs (an expired session) is cleared.
//
// A theme that wants no toolbar (an app whose users never see the admin) says so in its
// head: <meta name="publr-toolbar" content="off">.
//
// The bar lives in a shadow root, so the page's styles never reach it and its own never
// leak out; PublrJS binds each element directly, so its directives work inside.

const hint = 'publr_signed_in';
const place_key = 'publr-toolbar-place';
const hidden_key = 'publr-toolbar-hidden';
const margin = 12;

const signed_in = () => document.cookie.split('; ').includes(hint + '=1');

const opted_out = () =>
  document.querySelector('meta[name="publr-toolbar"]')?.getAttribute('content') === 'off';

// Storage can throw (a private window, blocked site data): the bar then just forgets.
const read = (key) => {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
};

const write = (key, value) => {
  try {
    if (value == null) {
      localStorage.removeItem(key);
    } else {
      localStorage.setItem(key, value);
    }
  } catch {
    // Nothing to keep it in: it lasts as long as the page.
  }
};

// The Publr mark, as the admin's rail shows it: a ring of dots in currentColor.
const mark =
  '<svg viewBox="0 0 34 34" width="20" height="20" fill="currentColor" aria-hidden="true">' +
  [
    'M19.598 18.5a3 3 0 1 1-5.196-3 3 3 0 0 1 5.196 3Z',
    'M23.232 10.206a2 2 0 1 1-3.464-2 2 2 0 0 1 3.464 2Z',
    'M19.768 25.794a2 2 0 1 1 3.464-2 2 2 0 0 1-3.464 2Z',
    'M26 19a2 2 0 1 1 0-4 2 2 0 0 1 0 4Z',
    'M14.232 25.794a2 2 0 1 1-3.464-2 2 2 0 0 1 3.464 2Z',
    'M10.768 10.206a2 2 0 1 1 3.464-2 2 2 0 0 1-3.464 2Z',
    'M8 19a2 2 0 1 1 0-4 2 2 0 0 1 0 4Z',
    'M25.866 3.644a1 1 0 1 1-1.732-1 1 1 0 0 1 1.732 1Z',
    'M33 18a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z',
    'M31.356 9.866a1 1 0 1 1-1-1.732 1 1 0 0 1 1 1.732Z',
    'M30.356 25.866a1 1 0 1 1 1-1.732 1 1 0 0 1-1 1.732Z',
    'M16 33a1 1 0 1 1 2 0 1 1 0 0 1-2 0Z',
    'M24.134 31.357a1 1 0 1 1 1.732-1 1 1 0 0 1-1.732 1Z',
    'M9.866 31.356a1 1 0 1 1-1.732-1 1 1 0 0 1 1.732 1Z',
    'M1 18a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z',
    'M3.643 25.866a1 1 0 1 1-1-1.732 1 1 0 0 1 1 1.732Z',
    'M2.644 9.866a1 1 0 1 1 1-1.732 1 1 0 0 1-1 1.732Z',
    'M16 1a1 1 0 1 1 2 0 1 1 0 0 1-2 0Z',
    'M8.134 3.644a1 1 0 1 1 1.732-1 1 1 0 0 1-1.732 1Z',
  ]
    .map((d) => `<path d="${d}"/>`)
    .join('') +
  '</svg>';

// The corner that brings the bar back: the rail's triangle, a light edge on its long side,
// and the mark small in its corner.
const corner =
  '<svg viewBox="0 0 36 36" aria-hidden="true">' +
  '<path d="M36 0V36H0Z" fill="oklch(0.215 0.012 262)"/>' +
  '<path d="M36 0L0 36" stroke="rgb(255 255 255 / 0.7)" stroke-width="1.5"/>' +
  mark.replace('width="20" height="20"', 'x="20" y="20" width="12" height="12"')
    .replace('fill="currentColor"', 'fill="oklch(0.985 0 0)"') +
  '</svg>';

// The admin's rail tokens (ui/styles/base.css), fixed here: the page's own palette, light
// or dark, never reaches a shadow root.
const styles = `
  :host {
    all: initial;
    --rail: oklch(0.215 0.012 262);
    --rail-foreground: oklch(0.985 0 0);
    --rail-muted: oklch(0.68 0.01 260);
    --rail-accent: oklch(0.32 0.012 262);
  }
  .hidden { display: none !important; }
  .bar {
    position: fixed; z-index: 2147483647; display: flex; align-items: center; gap: 2px;
    padding: 4px; border-radius: 999px; background: var(--rail); color: var(--rail-muted);
    box-shadow: 0 8px 24px rgb(0 0 0 / 0.24), 0 0 0 1px rgb(255 255 255 / 0.1);
    font: 500 13px/1 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
    user-select: none; touch-action: none;
  }
  .bar.dragging { cursor: grabbing; box-shadow: 0 12px 32px rgb(0 0 0 / 0.32), 0 0 0 1px rgb(255 255 255 / 0.1); }
  .grip {
    display: grid; place-items: center; width: 32px; height: 32px; border-radius: 999px;
    color: var(--rail-foreground); cursor: grab;
  }
  a, button {
    display: inline-flex; align-items: center; height: 32px; padding: 0 12px; border: 0;
    border-radius: 999px; background: transparent; color: inherit; font: inherit;
    text-decoration: none; cursor: pointer; transition: background-color 120ms, color 120ms;
  }
  a:hover, button:hover { background: var(--rail-accent); color: var(--rail-foreground); }
  a:focus-visible, button:focus-visible, .corner:focus-visible {
    outline: 2px solid var(--rail-foreground); outline-offset: 1px;
  }
  .close { width: 32px; padding: 0; justify-content: center; font-size: 16px; }

  /* Hidden, the bar leaves this: a corner nobody notices until the pointer reaches it. The
     triangle is the rail's dark fill with a light edge and a light mark, so one of them
     stands out whatever the page behind it: the fill on a light page, the rest on a dark. */
  .corner {
    position: fixed; z-index: 2147483647; right: 0; bottom: 0; width: 36px; height: 36px;
    padding: 0; border: 0; border-radius: 0; background: transparent; cursor: pointer;
  }
  .corner:hover { background: transparent; }
  .corner svg {
    position: absolute; inset: 0; width: 100%; height: 100%; opacity: 0;
    transform: scale(0.4); transform-origin: 100% 100%;
    transition: opacity 120ms, transform 120ms;
    filter: drop-shadow(0 0 4px rgb(0 0 0 / 0.35));
  }
  .corner:hover svg, .corner:focus-visible svg { opacity: 1; transform: scale(1); }
`;

// Two roots, the bar and the corner, over one store: every reference names it.
const markup = `
  <div class="bar" role="toolbar" aria-label="Publr"
       data-p-show="not $publr-toolbar::hidden"
       data-p-style="left->$publr-toolbar::left; top->$publr-toolbar::top"
       data-p-class="$publr-toolbar::dragging -> dragging ~ "
       data-p-on="pointermove.window:publr-toolbar::drag; pointerup.window:publr-toolbar::drop; pointercancel.window:publr-toolbar::drop">
    <span class="grip" title="Drag to move" data-p-on="pointerdown:publr-toolbar::grab">${mark}</span>
    <a data-p-bind="href:$publr-toolbar::admin">Admin</a>
    <a class="hidden" data-p-show="$publr-toolbar::edit" data-p-bind="href:$publr-toolbar::edit"
       data-p-text="$publr-toolbar::editLabel"></a>
    <button class="close" type="button" title="Hide the toolbar" aria-label="Hide the toolbar"
            data-p-on="click:publr-toolbar::hide">&times;</button>
  </div>
  <button class="corner hidden" type="button" title="Show the Publr toolbar"
          aria-label="Show the Publr toolbar" data-p-show="$publr-toolbar::hidden"
          data-p-on="click:publr-toolbar::show">${corner}</button>
`;

// Keeps the bar whole on screen, however the window was resized since it was placed.
const clamp = (left, top, bar) => {
  const width = bar?.offsetWidth ?? 0;
  const height = bar?.offsetHeight ?? 0;

  return [
    Math.min(Math.max(margin, left), Math.max(margin, innerWidth - width - margin)),
    Math.min(Math.max(margin, top), Math.max(margin, innerHeight - height - margin)),
  ];
};

const start = async () => {
  if (!signed_in() || opted_out() || window.top !== window) {
    return;
  }

  const answer = await fetch('/_publr/toolbar?path=' + encodeURIComponent(location.pathname), {
    credentials: 'same-origin',
    headers: { accept: 'application/json' },
  })
    .then((response) => (response.ok ? response.json() : null))
    .catch(() => null);

  if (!answer) {
    return;
  }

  if (!answer.signed_in) {
    document.cookie = hint + '=; Path=/; Max-Age=0; SameSite=Lax';
    return;
  }

  const { createStore, hydrate } = await import('./publr.js');
  const host = document.createElement('publr-toolbar');
  const shadow = host.attachShadow({ mode: 'open' });
  const saved = JSON.parse(read(place_key) ?? 'null');
  let offset = [0, 0];
  let bar = null;

  createStore('publr-toolbar', ({ state }) => {
    const place = (wanted) => {
      if (!bar || state.hidden) {
        return;
      }

      const fallback = [(innerWidth - bar.offsetWidth) / 2, innerHeight - bar.offsetHeight - 24];
      const [left, top] = clamp(...(wanted ?? fallback), bar);

      state.left = left + 'px';
      state.top = top + 'px';
    };

    const keep = () => place([parseFloat(state.left), parseFloat(state.top)]);

    return {
      state: {
        admin: answer.admin,
        edit: answer.edit ?? '',
        editLabel: answer.edit_label || 'Edit',
        hidden: read(hidden_key) === '1',
        left: '0px',
        top: '0px',
        dragging: false,
      },

      init() {
        requestAnimationFrame(() => {
          bar = shadow.querySelector('.bar');
          place(saved);
        });
        addEventListener('resize', keep);

        return () => removeEventListener('resize', keep);
      },

      actions: {
        grab(_, { event }) {
          if (event.button !== 0) {
            return;
          }

          const box = bar.getBoundingClientRect();

          offset = [event.clientX - box.left, event.clientY - box.top];
          state.dragging = true;
          event.preventDefault();
        },

        drag(_, { event }) {
          if (!state.dragging) {
            return;
          }

          const [left, top] = clamp(event.clientX - offset[0], event.clientY - offset[1], bar);

          state.left = left + 'px';
          state.top = top + 'px';
        },

        drop() {
          if (!state.dragging) {
            return;
          }

          state.dragging = false;
          write(place_key, JSON.stringify([parseFloat(state.left), parseFloat(state.top)]));
        },

        hide() {
          state.hidden = true;
          write(hidden_key, '1');
        },

        show() {
          state.hidden = false;
          write(hidden_key, null);
          requestAnimationFrame(() => place(JSON.parse(read(place_key) ?? 'null')));
        },
      },
    };
  });

  shadow.innerHTML = `<style>${styles}</style>${markup}`;
  document.body.append(host);
  hydrate(shadow);
};

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', start, { once: true });
} else {
  start();
}
