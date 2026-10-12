import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Configuration is separate from the roleplay model. No translated content
/// is written to chat messages, chat history, or SharedPreferences.
class TranslatorConfig {
  static const endpointKey = 'visualTranslatorEndpoint';
  static const apiKeyKey = 'visualTranslatorApiKey';
  static const modelKey = 'visualTranslatorModel';

  final String endpoint;
  final String apiKey;
  final String model;

  const TranslatorConfig({
    required this.endpoint,
    required this.apiKey,
    required this.model,
  });

  bool get isConfigured => endpoint.trim().isNotEmpty && model.trim().isNotEmpty;

  static Future<TranslatorConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return TranslatorConfig(
      endpoint: prefs.getString(endpointKey) ?? '',
      apiKey: prefs.getString(apiKeyKey) ?? '',
      model: prefs.getString(modelKey) ?? '',
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(endpointKey, endpoint.trim());
    await prefs.setString(apiKeyKey, apiKey.trim());
    await prefs.setString(modelKey, model.trim());
  }
}

/// OpenAI-compatible Chat Completions streaming translator.
/// Emits the accumulated translated text; never mutates the original message.
class TranslationService {
  static const systemPrompt = '''You are a professional literary translator. Translate the user's entire English roleplay passage into natural, expressive Russian. Preserve meaning, all narrative facts, character voices, subtext, humor, dialogue, internal monologues, proper names, headings, timestamps, paragraph breaks, and Markdown formatting. Translate idioms by meaning rather than literally. Never sanitize characters, summarize, invent events, or explain the translation. Respond with the Russian translation only.''';

  static Uri completionUri(String endpoint) {
    var root = endpoint.trim().replaceAll(RegExp(r'/+$'), '');
    if (root.isEmpty) throw const FormatException('Введите адрес API переводчика.');
    final uri = Uri.tryParse(root);
    if (uri == null || !uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      throw const FormatException('Введите полный адрес http(s) API.');
    }
    if (!root.endsWith('/chat/completions')) root += '/chat/completions';
    return Uri.parse(root);
  }

  static Stream<String> translate({
    required TranslatorConfig config,
    required String source,
    CancelToken? cancelToken,
  }) async* {
    if (!config.isConfigured) {
      throw StateError('Укажите адрес API и название модели в настройках переводчика.');
    }
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(minutes: 3),
      responseType: ResponseType.stream,
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
        if (config.apiKey.isNotEmpty) 'Authorization': 'Bearer ${config.apiKey}',
      },
    ));
    try {
      final response = await dio.postUri<ResponseBody>(
        completionUri(config.endpoint),
        cancelToken: cancelToken,
        data: {
          'model': config.model,
          'stream': true,
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': source},
          ],
        },
        options: Options(responseType: ResponseType.stream),
      );
      final responseBody = response.data;
      if (responseBody == null) throw StateError('Сервер вернул пустой ответ.');
      final buffer = StringBuffer();
      var completed = false;
      final contentType = response.headers.value('content-type') ?? '';
      // Some OpenAI-compatible providers ignore `stream: true` and send JSON.
      if (!contentType.contains('text/event-stream')) {
        final full = await utf8.decoder.bind(responseBody.stream).join();
        final parsed = jsonDecode(full) as Map<String, dynamic>;
        final choices = parsed['choices'] as List?;
        final content = (choices?.firstOrNull as Map?)?['message']?['content'];
        if (content is String && content.isNotEmpty) {
          yield content;
          return;
        }
        throw StateError('Сервер не вернул текст перевода.');
      }
      final lines = utf8.decoder.bind(responseBody.stream).transform(const LineSplitter());
      await for (final line in lines) {
        if (cancelToken?.isCancelled ?? false) return;
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload == '[DONE]') {
          completed = true;
          break;
        }
        if (payload.isEmpty) continue;
        final Object? decoded;
        try {
          decoded = jsonDecode(payload);
        } on FormatException {
          continue;
        }
        if (decoded is! Map) continue;
        if (decoded['error'] != null) throw StateError('${decoded['error']}');
        final choices = decoded['choices'];
        if (choices is! List || choices.isEmpty || choices.first is! Map) continue;
        final delta = (choices.first as Map)['delta'];
        if (delta is! Map) continue;
        final part = delta['content'];
        if (part is String && part.isNotEmpty) {
          buffer.write(part);
          yield buffer.toString();
        }
      }
      if (buffer.isEmpty && !completed) {
        throw StateError('Ответ переводчика оборвался без текста.');
      }
      if (buffer.isEmpty) throw StateError('Переводчик вернул пустой текст.');
    } finally {
      dio.close(force: true);
    }
  }
}
