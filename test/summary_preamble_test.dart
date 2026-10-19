import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/llm/summary_refusal.dart';
import 'package:glaze_flutter/core/services/summary_preamble.dart';
import 'package:glaze_flutter/core/state/summary_providers.dart';

/// The instruction a reader puts in front of every summary prompt for a model
/// that refuses, and how a refusal is told from a summary. See
/// `docs/INVARIANTS.md` INV-S5.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SummaryPreamble', () {
    test('is off by default, with the default text ready', () {
      const preamble = SummaryPreamble();
      expect(preamble.enabled, isFalse);
      expect(preamble.active, isFalse);
      expect(preamble.text, SummaryPreamble.defaultText);
      expect(preamble.apply('Summarize.'), 'Summarize.');
    });

    test('goes in front of the prompt when on', () {
      const preamble = SummaryPreamble(enabled: true, text: ' Retell it. ');
      expect(preamble.apply('\nSummarize.'), 'Retell it.\n\nSummarize.');
    });

    test('an emptied text puts nothing in front', () {
      const preamble = SummaryPreamble(enabled: true, text: '  ');
      expect(preamble.active, isFalse);
      expect(preamble.apply('Summarize.'), 'Summarize.');
    });

    test('survives a round trip, text and all', () {
      const preamble = SummaryPreamble(enabled: true, text: 'Retell it.');
      expect(SummaryPreamble.fromJson(preamble.toJson()), preamble);
      // A stored switch without a text falls back to the default text.
      expect(
        SummaryPreamble.fromJson(const {'enabled': true}),
        const SummaryPreamble(enabled: true),
      );
    });

    test('is stored in the prefs and read back by a new container', () async {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer();
      addTearDown(c.dispose);

      expect(
        await c.read(summaryPreambleProvider.future),
        isA<SummaryPreamble>().having((p) => p.enabled, 'enabled', isFalse),
      );
      await c
          .read(summaryPreambleProvider.notifier)
          .save(const SummaryPreamble(enabled: true, text: 'Retell it.'));

      final reopened = ProviderContainer();
      addTearDown(reopened.dispose);
      expect(
        await reopened.read(summaryPreambleProvider.future),
        const SummaryPreamble(enabled: true, text: 'Retell it.'),
      );
    });

    test('an unreadable stored value is the default, not fatal', () async {
      SharedPreferences.setMockInitialValues({
        SummaryPreambleNotifier.prefsKey: 'not json',
      });
      final c = ProviderContainer();
      addTearDown(c.dispose);

      expect(
        await c.read(summaryPreambleProvider.future),
        const SummaryPreamble(),
      );
    });
  });

  group('SummaryRefusal', () {
    test('knows an apology when it sees one', () {
      for (final refusal in const [
        "I'm sorry, but I can't help with that.",
        'I cannot summarize this content as it contains explicit material.',
        "Sorry, I can’t assist with this request.",
        'I am unable to continue with this request.',
        'As an AI language model, I must decline.',
        'Извините, но я не могу помочь с этим запросом.',
        'К сожалению, я не могу продолжить пересказ этого содержания.',
        'Я не буду пересказывать такой контент.',
      ]) {
        expect(SummaryRefusal.looksLike(refusal), isTrue, reason: refusal);
      }
    });

    test('leaves a summary alone, even one that quotes a refusal', () {
      expect(
        SummaryRefusal.looksLike(
          'Mara reached the pass after dark and found the gate barred. '
          'Tomas refused to turn back; "I can\'t leave her," he said, and '
          'they camped below the wall until dawn.',
        ),
        isFalse,
      );
      // Short and third-person: the phrase is not there.
      expect(
        SummaryRefusal.looksLike('Mara could not open the gate. They waited.'),
        isFalse,
      );
      // Long enough to be a summary whatever it opens with.
      expect(
        SummaryRefusal.looksLike(
          "I'm sorry to say the night went badly for them. "
          '${'They walked on through the snow. ' * 30}',
        ),
        isFalse,
      );
      expect(SummaryRefusal.looksLike(''), isFalse);
    });
  });
}
