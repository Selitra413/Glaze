// Desktop scroll input over the chat WebView on Windows.
//
// Flutter's win32 embedder delivers touchpad scrolling as PointerPanZoom*
// events, which flutter_inappwebview_windows never forwards to WebView2, and
// it forwards a mouse-wheel notch as a fraction of one — so without this relay
// the chat scrolls only with a wheel, and barely. These tests guard the
// Flutter capture side and the JS replay side against regressions.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/widgets/chat_webview_scroll_relay.dart';

String _bridgeAsset(String name) =>
    File('assets/chat_webview/bridge/$name').readAsStringSync();

PointerPanZoomUpdateEvent _panUpdate(Offset panDelta, {Offset? position}) {
  return PointerPanZoomUpdateEvent(
    position: position ?? Offset.zero,
    pan: panDelta,
    panDelta: panDelta,
  );
}

void main() {
  group('ScrollRelaySink', () {
    test('inverts pan into wheel sign convention', () {
      final emitted = <List<double>>[];
      final sink = ScrollRelaySink((dx, dy, position) => emitted.add([dx, dy]));

      // Fingers moving up (negative dy) must scroll the content down, which is
      // a positive wheel delta — the same sign a mouse wheel produces.
      sink.update(_panUpdate(const Offset(0, -20)));
      sink.flush();

      expect(emitted, [
        [0.0, 20.0],
      ]);
    });

    test('accumulates several pan updates into one emission', () {
      final emitted = <List<double>>[];
      final sink = ScrollRelaySink((dx, dy, position) => emitted.add([dx, dy]));

      sink.update(_panUpdate(const Offset(-3, -10)));
      sink.update(_panUpdate(const Offset(-2, -5)));
      sink.flush();

      expect(emitted, [
        [5.0, 15.0],
      ]);
    });

    test('takes a wheel notch as it is, already in wheel sign convention', () {
      final emitted = <List<double>>[];
      Offset? at;
      final sink = ScrollRelaySink((dx, dy, position) {
        emitted.add([dx, dy]);
        at = position;
      });

      sink.add(0, 100, const Offset(30, 40));
      sink.add(0, 100, const Offset(31, 41));
      sink.flush();

      expect(emitted, [
        [0.0, 200.0],
      ]);
      expect(at, const Offset(31, 41));
    });

    test('flush clears the accumulator and emits nothing when idle', () {
      final emitted = <List<double>>[];
      final sink = ScrollRelaySink((dx, dy, position) => emitted.add([dx, dy]));

      sink.update(_panUpdate(const Offset(0, -8)));
      expect(sink.hasPendingScroll, isTrue);
      sink.flush();
      expect(sink.hasPendingScroll, isFalse);

      sink.flush();
      expect(emitted, hasLength(1), reason: 'an idle flush must not emit');
    });

    test('reports the cursor position of the latest event', () {
      Offset? seen;
      final sink = ScrollRelaySink((dx, dy, position) => seen = position);

      sink.start(PointerPanZoomStartEvent(position: const Offset(10, 20)));
      sink.update(
        _panUpdate(const Offset(0, -4), position: const Offset(120, 340)),
      );
      sink.flush();

      expect(seen, const Offset(120, 340));
    });

    test('emits nothing after dispose', () {
      var calls = 0;
      final sink = ScrollRelaySink((dx, dy, position) => calls++);

      sink.update(_panUpdate(const Offset(0, -8)));
      sink.dispose();
      sink.flush();

      expect(calls, 0);
    });

    testWidgets('coalesces a burst of pan updates to one call per frame', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox());

      final emitted = <double>[];
      final sink = ScrollRelaySink((dx, dy, position) => emitted.add(dy));

      sink.update(_panUpdate(const Offset(0, -5)));
      sink.update(_panUpdate(const Offset(0, -5)));
      sink.update(_panUpdate(const Offset(0, -5)));
      expect(emitted, isEmpty, reason: 'flush is deferred to the next frame');

      await tester.pump();

      expect(emitted, [15.0]);
    });
  });

  group('cssPixelsForWheel', () {
    test('multiplies the logical delta back by the device pixel ratio', () {
      // 125% scaling, two lines per notch: the embedder reports 66.7 physical
      // px as 53.3 logical; a browser scrolls that notch by 66.7 CSS px.
      expect(
        cssPixelsForWheel(const Offset(0, 53.33), 1.25).dy,
        closeTo(66.67, 0.01),
      );
    });

    test('is the identity at 100% scaling', () {
      expect(cssPixelsForWheel(const Offset(0, 100), 1), const Offset(0, 100));
    });
  });

  group('ChatWebViewScrollRelay', () {
    // testWidgets bodies reset the override themselves: the binding asserts
    // every foundation debug variable is unset when the body returns, which
    // happens before tearDown gets a chance to run.
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('is only needed on Windows', () {
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          ChatWebViewScrollRelay.isSupported,
          platform == TargetPlatform.windows,
          reason: '$platform',
        );
      }
    });

    testWidgets(
      'wraps the child in a Listener for pans and the wheel on Windows',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        await tester.pumpWidget(
          const ProviderScope(
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: ChatWebViewScrollRelay(
                charId: 'char-1',
                child: SizedBox(width: 100, height: 100),
              ),
            ),
          ),
        );

        final listener = tester.widget<Listener>(
          find.descendant(
            of: find.byType(ChatWebViewScrollRelay),
            matching: find.byType(Listener),
          ),
        );
        expect(listener.onPointerPanZoomStart, isNotNull);
        expect(listener.onPointerPanZoomUpdate, isNotNull);
        expect(listener.onPointerPanZoomEnd, isNotNull);
        expect(listener.onPointerSignal, isNotNull);
        expect(listener.behavior, HitTestBehavior.opaque);

        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets('adds no wrapper off Windows', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(
        const ProviderScope(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: ChatWebViewScrollRelay(
              charId: 'char-1',
              child: SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byType(ChatWebViewScrollRelay),
          matching: find.byType(Listener),
        ),
        findsNothing,
      );

      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('scroll_relay.js', () {
    late String relayJs;
    late String bridgeIndexJs;
    late String bridgeControllerJs;

    setUpAll(() {
      relayJs = _bridgeAsset('scroll_relay.js');
      bridgeIndexJs = _bridgeAsset('index.js');
      bridgeControllerJs = _bridgeAsset('chat_bridge_controller.js');
    });

    test('bridge exposes the relay to Flutter', () {
      expect(bridgeControllerJs, contains('trackpadScroll(dx, dy, x, y)'));
      expect(bridgeControllerJs, contains('wheelScroll(dx, dy, x, y)'));
      expect(bridgeControllerJs, contains('relayNativeWheel(on)'));
      expect(bridgeControllerJs, contains('new ScrollRelay('));
    });

    test('undoes the page wheel scale so the pan tracks the finger 1:1', () {
      // The page's own wheel handlers scroll by `deltaY * WHEEL_PIXEL_SCALE`,
      // so a delta already expressed in CSS pixels has to be divided by the
      // same factor before it is replayed as a wheel event.
      expect(
        bridgeIndexJs,
        contains('container.scrollTop += e.deltaY * WHEEL_PIXEL_SCALE'),
      );
      expect(relayJs, contains('export const WHEEL_PIXEL_SCALE = 1;'));
      expect(relayJs, contains('deltaX: dx / WHEEL_PIXEL_SCALE'));
      expect(relayJs, contains('deltaY: dy / WHEEL_PIXEL_SCALE'));
    });

    test('replays the pan as a cancelable pixel-mode wheel at the cursor', () {
      // Reusing the page's wheel handlers keeps one scroll path instead of a
      // second, touchpad-only one that could drift out of sync.
      expect(relayJs, contains("new WheelEvent('wheel'"));
      expect(relayJs, contains('deltaMode: 0'));
      expect(relayJs, contains('cancelable: true'));
      expect(relayJs, contains('bubbles: true'));
      expect(relayJs, contains('document.elementFromPoint(x, y)'));
    });

    test('performs the default scroll itself when nothing consumes it', () {
      // Synthetic events are untrusted, so the browser runs no default action
      // for them — an unhandled wheel has to be applied by hand.
      expect(relayJs, contains('if (consumed) return;'));
      expect(relayJs, contains('_scrollNearest'));
      expect(relayJs, contains('el.scrollTop += dy'));
      expect(relayJs, contains('el.scrollLeft += dx'));
    });

    test('falls back to the chat container when no scrollable is found', () {
      expect(relayJs, contains('container.scrollTop += dy'));
    });

    test('spreads a wheel notch over the frames that follow', () {
      expect(relayJs, contains('requestAnimationFrame(this._frame)'));
      expect(relayJs, contains('Math.exp(-dt / WHEEL_SMOOTHING_MS)'));
    });

    test('drops only the trusted copy of a relayed wheel', () {
      // The plugin's own forward of the notch is the duplicate; the synthetic
      // replay has to keep flowing through the same listeners.
      expect(relayJs, contains('if (!e.isTrusted) return;'));
      expect(relayJs, contains('e.stopImmediatePropagation();'));
      expect(
        relayJs,
        contains("document.addEventListener('wheel', this._swallowNativeWheel"),
      );
    });

    test('does not save up a notch past the edge of the chat', () {
      expect(relayJs, contains('!this._canScrollAt(0, stepY)'));
      expect(relayJs, contains('this._pendingY = 0;'));
    });
  });
}
