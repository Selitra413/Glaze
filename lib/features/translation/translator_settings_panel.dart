import 'package:flutter/material.dart';

import 'translation_service.dart';

/// Dedicated, independent OpenAI-compatible translation connection.
class TranslatorSettingsPanel extends StatefulWidget {
  final ScrollController controller;
  const TranslatorSettingsPanel({super.key, required this.controller});

  @override
  State<TranslatorSettingsPanel> createState() => _TranslatorSettingsPanelState();
}

class _TranslatorSettingsPanelState extends State<TranslatorSettingsPanel> {
  final endpoint = TextEditingController();
  final apiKey = TextEditingController();
  final model = TextEditingController();
  bool showKey = false;
  bool loading = true;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await TranslatorConfig.load();
    if (!mounted) return;
    endpoint.text = config.endpoint;
    apiKey.text = config.apiKey;
    model.text = config.model;
    setState(() => loading = false);
  }

  Future<void> _save() async {
    setState(() => saving = true);
    try {
      final config = TranslatorConfig(
        endpoint: endpoint.text,
        apiKey: apiKey.text,
        model: model.text,
      );
      TranslationService.completionUri(config.endpoint);
      if (config.model.trim().isEmpty) {
        throw const FormatException('Укажите идентификатор модели.');
      }
      await config.save();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Настройки переводчика сохранены')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось сохранить: $e')),
      );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  void dispose() {
    endpoint.dispose();
    apiKey.dispose();
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
      children: [
        const Text('Литературный перевод', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        const Text('Отдельный OpenAI-совместимый сервер. Перевод виден только на экране: история ролевой и исходные сообщения не изменяются.'),
        const SizedBox(height: 24),
        TextField(
          controller: endpoint,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Адрес API',
            hintText: 'https://api.deepseek.com/v1',
            helperText: 'Базовый URL или полный адрес /chat/completions',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 18),
        TextField(
          controller: apiKey,
          obscureText: !showKey,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'API-ключ (если требуется)',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(showKey ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => showKey = !showKey),
            ),
          ),
        ),
        const SizedBox(height: 18),
        TextField(
          controller: model,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Модель',
            hintText: 'deepseek-chat',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: saving ? null : _save,
          icon: const Icon(Icons.save_outlined),
          label: Text(saving ? 'Сохранение…' : 'Сохранить подключение'),
        ),
        const SizedBox(height: 16),
        const Text('Ключ сохраняется локально в настройках приложения. Переводы хранятся только в оперативной памяти и пропадают после закрытия приложения. При нажатии «Перевести» исходный текст отправляется выбранному провайдеру.'),
      ],
    );
  }
}
