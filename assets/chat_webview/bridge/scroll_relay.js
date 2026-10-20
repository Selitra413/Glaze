/* Desktop scroll input relayed into the chat WebView by Flutter.
 *
 * On Windows the page gets neither input the way a browser would:
 *
 * - A precision touchpad produces no `wheel` event at all. Flutter's win32
 *   embedder reports its scrolling as pan/zoom pointer events
 *   (PointerPanZoomStart/Update/End), and flutter_inappwebview_windows forwards
 *   only PointerScrollEvent to WebView2 (flutter_inappwebview #2503 / #2511,
 *   both closed as not planned).
 * - A mouse wheel does arrive, but shrunk. The plugin hands WebView2 Flutter's
 *   scroll delta — logical pixels, already divided by the device pixel ratio —
 *   as if it were wheel units (120 per notch), so one notch lands as a fraction
 *   of one: 0.83 at 100% scaling and three lines per notch, 0.43 at 125% and
 *   two. The page then moved by that fraction, in a single jump.
 *
 * ChatWebViewScrollRelay on the Flutter side captures both and hands them to
 * the Bridge, which lands them here: scrollBy() for a pan, wheel() for a notch
 * already converted back to the CSS pixels a browser would scroll. Both are
 * replayed as a synthetic `wheel` event at the cursor so every existing wheel
 * handler (the #chat-container handler in ./index.js, the edit textarea
 * handler in ./edit_controller.js) reacts exactly as it does to a real wheel —
 * one scroll path, not three. A pan is applied as it comes, so the content
 * tracks the finger; a notch is spread over the frames that follow, the way a
 * browser animates a wheel.
 *
 * While the wheel is relayed, the trusted `wheel` the plugin still forwards for
 * the same notch is swallowed at the document — see relayNativeWheel() — or
 * every notch would scroll twice.
 */

/* Pixel-mode wheel scale used by the page's own wheel handlers: they scroll by
 * `deltaY * WHEEL_PIXEL_SCALE`. Deltas arrive here already in CSS pixels, so
 * they are divided by the same factor to survive the round trip and track the
 * finger 1:1. Shared with the container handler in ./index.js and
 * EditController._scaledWheelDelta in ./edit_controller.js so all three stay
 * in step. `1` is the browser's native pixel-mode rate — one CSS pixel of
 * scroll per wheel delta unit — instead of the older, slower 0.3. */
export const WHEEL_PIXEL_SCALE = 1;

/* How a wheel notch closes in on its target: each frame scrolls
 * 1 − e^(−dt/τ) of what is left, with τ = this many milliseconds. 70 puts a
 * notch 95% of the way in about 200 ms, close to Chromium's own wheel
 * animation. Notches that arrive while one is still moving add to what is
 * left rather than queue behind it, so a fast spin stays fast. */
export const WHEEL_SMOOTHING_MS = 70;

const SCROLLABLE_OVERFLOW = /^(auto|scroll|overlay)$/;

function prefersReducedMotion() {
  return typeof window.matchMedia === 'function' &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

export class ScrollRelay {
  /** @param containerFn returns the chat scroll container (may be null early). */
  constructor(containerFn) {
    this._containerFn = containerFn;
    // What the wheel still has to scroll, in CSS pixels, and where the cursor
    // was when the last notch came in.
    this._pendingX = 0;
    this._pendingY = 0;
    this._cursorX = NaN;
    this._cursorY = NaN;
    this._frameId = 0;
    this._frameAt = 0;
    this._nativeWheelRelayed = false;
    this._frame = this._frame.bind(this);
    this._swallowNativeWheel = (e) => {
      if (!e.isTrusted) return;
      e.preventDefault();
      e.stopImmediatePropagation();
    };
  }

  /* Flutter relays the mouse wheel through wheel() from now on: drop the
   * trusted copy of every notch the plugin still forwards. Off until told,
   * so a page without the relay — every other platform — keeps its native
   * wheel. Synthetic events are untouched; they are the relay. */
  relayNativeWheel(on) {
    on = !!on;
    if (on === this._nativeWheelRelayed) return;
    this._nativeWheelRelayed = on;
    if (on) {
      document.addEventListener('wheel', this._swallowNativeWheel, {
        capture: true,
        passive: false,
      });
    } else {
      document.removeEventListener('wheel', this._swallowNativeWheel, {
        capture: true,
      });
    }
  }

  get nativeWheelRelayed() {
    return this._nativeWheelRelayed;
  }

  /* Scroll by (dx, dy) CSS pixels at once, wheel sign convention: positive dy
   * moves the content up (scrollTop grows), like a wheel scrolled towards the
   * user. (x, y) are client coordinates of the cursor. */
  scrollBy(dx, dy, x, y) {
    dx = Number(dx) || 0;
    dy = Number(dy) || 0;
    if (dx === 0 && dy === 0) return;

    const container = this._containerFn ? this._containerFn() : null;
    const hasPoint = Number.isFinite(x) && Number.isFinite(y);
    const target = (hasPoint ? document.elementFromPoint(x, y) : null) || container;
    if (!target) return;

    // dispatchEvent returns false when a listener called preventDefault(),
    // which is how both page handlers signal "I scrolled this myself".
    const consumed = !target.dispatchEvent(new WheelEvent('wheel', {
      deltaX: dx / WHEEL_PIXEL_SCALE,
      deltaY: dy / WHEEL_PIXEL_SCALE,
      deltaMode: 0,
      clientX: hasPoint ? x : 0,
      clientY: hasPoint ? y : 0,
      bubbles: true,
      cancelable: true,
      composed: true,
    }));
    if (consumed) return;

    // Synthetic events are untrusted, so the browser performs no default
    // scrolling for them. Nothing claimed the event — do the default action
    // ourselves on the nearest scrollable ancestor.
    this._scrollNearest(target, dx, dy, container);
  }

  /* A mouse wheel notch of (dx, dy) CSS pixels, wheel sign convention, spread
   * over the frames that follow. (x, y) are client coordinates of the cursor. */
  wheel(dx, dy, x, y) {
    dx = Number(dx) || 0;
    dy = Number(dy) || 0;
    if (dx === 0 && dy === 0) return;
    if (Number.isFinite(x) && Number.isFinite(y)) {
      this._cursorX = x;
      this._cursorY = y;
    }
    if (prefersReducedMotion()) {
      this.scrollBy(dx, dy, this._cursorX, this._cursorY);
      return;
    }
    // A notch the other way starts over: what the last one had left would
    // only pull against it.
    if (dx * this._pendingX < 0) this._pendingX = 0;
    if (dy * this._pendingY < 0) this._pendingY = 0;
    this._pendingX += dx;
    this._pendingY += dy;
    if (!this._frameId) {
      this._frameAt = 0;
      this._frameId = requestAnimationFrame(this._frame);
    }
  }

  /* What the wheel still owes, for tests. */
  get pendingWheel() {
    return { dx: this._pendingX, dy: this._pendingY };
  }

  _frame(now) {
    this._frameId = 0;
    // A frame that comes late (a hidden tab) counts as a long one, not as the
    // whole wait, or the chat would leap when it is shown again.
    const dt = this._frameAt ? Math.min(now - this._frameAt, 100) : 16;
    this._frameAt = now;
    const share = 1 - Math.exp(-dt / WHEEL_SMOOTHING_MS);
    const grain = 1 / (window.devicePixelRatio || 1);
    let stepX = this._stepOf(this._pendingX, share, grain);
    let stepY = this._stepOf(this._pendingY, share, grain);
    // At an edge, what cannot scroll is dropped rather than saved up: a notch
    // past the end of the chat must not come back as movement the moment the
    // wheel turns the other way.
    if (stepX !== 0 && !this._canScrollAt(stepX, 0)) {
      this._pendingX = 0;
      stepX = 0;
    }
    if (stepY !== 0 && !this._canScrollAt(0, stepY)) {
      this._pendingY = 0;
      stepY = 0;
    }
    this._pendingX -= stepX;
    this._pendingY -= stepY;
    if (stepX !== 0 || stepY !== 0) {
      this.scrollBy(stepX, stepY, this._cursorX, this._cursorY);
    }
    if (this._pendingX !== 0 || this._pendingY !== 0) {
      this._frameId = requestAnimationFrame(this._frame);
    }
  }

  /* This frame's share of what is left, on the grid of whole device pixels
   * the browser keeps scroll offsets on: a fraction of one is rounded away by
   * the scroller, and twenty frames of rounding left a notch a few pixels
   * short. The tail goes a device pixel a frame, and the last one in a piece. */
  _stepOf(pending, share, grain) {
    if (Math.abs(pending) <= grain) return pending;
    const step = Math.round((pending * share) / grain) * grain;
    return step !== 0 ? step : Math.sign(pending) * grain;
  }

  /* Whether anything under the cursor — or, failing that, the chat container —
   * can still scroll in the direction of (dx, dy). */
  _canScrollAt(dx, dy) {
    const container = this._containerFn ? this._containerFn() : null;
    const hasPoint = Number.isFinite(this._cursorX) && Number.isFinite(this._cursorY);
    let el = hasPoint ? document.elementFromPoint(this._cursorX, this._cursorY) : null;
    while (el && el !== document.body && el !== document.documentElement) {
      if (this._canScroll(el, dx, dy)) return true;
      el = el.parentElement;
    }
    return !!container && this._canScroll(container, dx, dy);
  }

  _scrollNearest(target, dx, dy, container) {
    let el = target;
    while (el && el !== document.body && el !== document.documentElement) {
      if (this._canScroll(el, dx, dy)) {
        el.scrollLeft += dx;
        el.scrollTop += dy;
        return;
      }
      el = el.parentElement;
    }
    if (container) {
      container.scrollLeft += dx;
      container.scrollTop += dy;
    }
  }

  _canScroll(el, dx, dy) {
    const style = window.getComputedStyle(el);
    if (dy !== 0 && SCROLLABLE_OVERFLOW.test(style.overflowY)) {
      const max = el.scrollHeight - el.clientHeight;
      if (max > 1 && ((dy < 0 && el.scrollTop > 0) ||
                      (dy > 0 && el.scrollTop < max - 1))) {
        return true;
      }
    }
    if (dx !== 0 && SCROLLABLE_OVERFLOW.test(style.overflowX)) {
      const max = el.scrollWidth - el.clientWidth;
      if (max > 1 && ((dx < 0 && el.scrollLeft > 0) ||
                      (dx > 0 && el.scrollLeft < max - 1))) {
        return true;
      }
    }
    return false;
  }
}
