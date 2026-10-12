import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/translation/translation_service.dart';

void main() {
  test('adds Chat Completions path to base endpoint', () {
    expect(
      TranslationService.completionUri('https://api.deepseek.com/v1/').toString(),
      'https://api.deepseek.com/v1/chat/completions',
    );
  });

  test('accepts a full Chat Completions URL without duplicating it', () {
    expect(
      TranslationService.completionUri('http://localhost:1234/v1/chat/completions').toString(),
      'http://localhost:1234/v1/chat/completions',
    );
  });

  test('rejects incomplete endpoints', () {
    expect(() => TranslationService.completionUri('localhost:1234'), throwsFormatException);
    expect(() => TranslationService.completionUri(''), throwsFormatException);
  });
}
