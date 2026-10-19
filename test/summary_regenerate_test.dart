import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/summary_service.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/summary_block.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/summary_providers.dart';
import 'package:glaze_flutter/features/chat/services/summary_generation_service.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';

/// Regenerating writes one block of the chain again, in place, the way a
/// Memory Books draft can be regenerated. See `docs/INVARIANTS.md` INV-S5.
class _RecordingAuxLlmClient extends AuxLlmClient {
  String answer = 'Fresh retelling.';
  final calls = <List<Map<String, String>>>[];

  String? get system =>
      calls.lastOrNull?.firstWhere((m) => m['role'] == 'system')['content'];
  String? get user =>
      calls.lastOrNull?.lastWhere((m) => m['role'] == 'user')['content'];

  @override
  Future<String> callOnce({
    required AuxApiConfig config,
    String prompt = '',
    List<Map<String, String>>? messages,
    required int maxTokens,
    required double temperature,
    required int timeoutMs,
    CancelToken? cancelToken,
    LlmCaptureContext? captureContext,
    AuxRawResponseSink? onRawResponse,
  }) async {
    calls.add(messages ?? const []);
    return answer;
  }
}

const _api = ApiConfig(
  id: 'chat',
  endpoint: 'https://chat.example.com/v1',
  apiKey: 'chat-key',
  model: 'chat-model',
  maxTokens: 900,
);

final _messages = [
  for (var i = 0; i < 4; i++)
    ChatMessage(
      id: 'm$i',
      role: i.isEven ? 'user' : 'assistant',
      content: 'Message $i. ${'They walked on through the snow. ' * 40}',
    ),
];

ChatSession _session([List<ChatMessage>? messages]) => ChatSession(
  id: 'session',
  characterId: 'char',
  sessionIndex: 0,
  messages: messages ?? _messages,
);

SummaryBlock _block(
  String id,
  List<String> ids, {
  int level = 1,
  String? content,
  List<String> childIds = const [],
  bool archived = false,
}) => SummaryBlock(
  id: id,
  level: level,
  content: content ?? 'Old text of $id.',
  messageIds: ids,
  sourceHash: SummaryChain.fingerprint(ids, SummaryChain.index(_messages)),
  childIds: childIds,
  archived: archived,
  tokens: 5,
  sourceTokens: 400,
  createdAt: 7,
);

typedef _Harness = ({ProviderContainer container, _RecordingAuxLlmClient llm});

Future<_Harness> _harness(List<SummaryBlock> blocks) async {
  SharedPreferences.setMockInitialValues({});
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final llm = _RecordingAuxLlmClient();
  final container = ProviderContainer(
    overrides: [
      appDbProvider.overrideWithValue(db),
      summaryServiceProvider.overrideWith(
        (ref) => SummaryService(ref.watch(summaryRepoProvider), llm: llm),
      ),
    ],
  );
  addTearDown(() async {
    container.dispose();
    await db.close();
  });
  await container.read(apiConfigRepoProvider).put(_api);
  container.invalidate(apiListProvider);
  await container.read(apiListProvider.future);
  container.read(activeApiPresetIdProvider.notifier).state = _api.id;
  await container
      .read(summaryServiceProvider)
      .saveBlocks(sessionId: 'session', blocks: blocks, messages: _messages);
  return (container: container, llm: llm);
}

Future<void> _regenerate(
  ProviderContainer container,
  String blockId, [
  List<ChatMessage>? messages,
]) => container
    .read(summaryGenerationServiceProvider)
    .regenerateBlock(
      charId: 'char',
      session: _session(messages),
      blockId: blockId,
    );

Future<List<SummaryBlock>> _blocks(ProviderContainer container) =>
    container.read(summaryServiceProvider).getBlocks('session');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a block is retold again in its own place', () async {
    final h = await _harness([
      _block('b1', ['m0', 'm1']),
      _block('b2', ['m2', 'm3']),
    ]);

    await _regenerate(h.container, 'b1');

    final blocks = await _blocks(h.container);
    final b1 = blocks.firstWhere((b) => b.id == 'b1');
    expect(b1.content, 'Fresh retelling.');
    expect(b1.level, 1);
    expect(b1.messageIds, ['m0', 'm1']);
    expect(b1.createdAt, 7);
    expect(blocks.firstWhere((b) => b.id == 'b2').content, 'Old text of b2.');
    expect(h.llm.user, contains('Message 0.'));
    expect(h.llm.user, isNot(contains('Message 2.')));
  });

  test('the blocks before it are its context, not itself', () async {
    final h = await _harness([
      _block('b1', ['m0', 'm1']),
      _block('b2', ['m2', 'm3']),
    ]);

    await _regenerate(h.container, 'b2');

    expect(h.llm.user, contains('Old text of b1.'));
    expect(h.llm.user, isNot(contains('Old text of b2.')));
  });

  test('a stale block is retold from its messages as they read now', () async {
    final h = await _harness([
      _block('b1', ['m0', 'm1']),
    ]);
    final edited = [
      _messages[0].copyWith(content: 'Edited. ${_messages[0].content}'),
      ..._messages.skip(1),
    ];
    expect(
      SummaryChain.isStale(
        (await _blocks(h.container)).single,
        SummaryChain.index(edited),
      ),
      isTrue,
    );

    await _regenerate(h.container, 'b1', edited);

    final b1 = (await _blocks(h.container)).single;
    expect(SummaryChain.isStale(b1, SummaryChain.index(edited)), isFalse);
    expect(h.llm.user, contains('Edited.'));
  });

  test('a merge is merged again from its parts', () async {
    final h = await _harness([
      _block('p1', ['m0', 'm1'], archived: true),
      _block('p2', ['m2', 'm3'], archived: true),
      _block(
        'merged',
        ['m0', 'm1', 'm2', 'm3'],
        level: 2,
        childIds: const ['p1', 'p2'],
      ),
    ]);

    await _regenerate(h.container, 'merged');

    final blocks = await _blocks(h.container);
    final merged = blocks.firstWhere((b) => b.id == 'merged');
    expect(merged.content, 'Fresh retelling.');
    expect(merged.level, 2);
    expect(merged.childIds, ['p1', 'p2']);
    expect(blocks.where((b) => b.archived).map((b) => b.id), ['p1', 'p2']);
    expect(h.llm.system, startsWith(summaryMergePrompt));
    expect(h.llm.user, contains('Old text of p1.'));
    expect(h.llm.user, contains('Old text of p2.'));
  });

  test('a merge whose messages changed is refused', () async {
    final h = await _harness([
      _block('p1', ['m0', 'm1'], archived: true),
      _block('p2', ['m2', 'm3'], archived: true),
      _block(
        'merged',
        ['m0', 'm1', 'm2', 'm3'],
        level: 2,
        childIds: const ['p1', 'p2'],
      ),
    ]);
    final edited = [
      _messages[0].copyWith(content: 'Edited.'),
      ..._messages.skip(1),
    ];

    await expectLater(
      _regenerate(h.container, 'merged', edited),
      throwsA(
        isA<SummaryChainException>().having(
          (e) => e.reason,
          'reason',
          'stale_merge',
        ),
      ),
    );
    expect(h.llm.calls, isEmpty);
  });

  test('a note is not regenerated', () async {
    final h = await _harness([
      const SummaryBlock(id: 'note', level: 0, content: 'A note.'),
    ]);

    await expectLater(
      _regenerate(h.container, 'note'),
      throwsA(isA<SummaryChainException>()),
    );
    expect(h.llm.calls, isEmpty);
  });

  test('an answer no shorter than its source leaves the block', () async {
    final h = await _harness([
      _block('b1', ['m0', 'm1']),
    ]);
    h.llm.answer = 'Far too long. ' * 2000;

    await expectLater(
      _regenerate(h.container, 'b1'),
      throwsA(
        isA<SummaryChainException>().having(
          (e) => e.reason,
          'reason',
          'not_shorter',
        ),
      ),
    );
    expect((await _blocks(h.container)).single.content, 'Old text of b1.');
  });

  group('chain', () {
    test('liveBefore keeps notes and the blocks that start earlier', () {
      final chain = [
        const SummaryBlock(id: 'note', level: 0, content: 'A note.'),
        _block('b1', ['m0', 'm1']),
        _block('b2', ['m2', 'm3']),
      ];

      expect(SummaryChain.liveBefore(chain, _messages, 'm2').map((b) => b.id), [
        'note',
        'b1',
      ]);
    });

    test('commitRegenerated replaces the active block only', () {
      final chain = [
        _block('b1', ['m0', 'm1']),
      ];
      final written = _block('b1', ['m0', 'm1'], content: 'New.');

      expect(
        SummaryChain.commitRegenerated(chain, written).single.content,
        'New.',
      );
      expect(
        () => SummaryChain.commitRegenerated(chain, _block('gone', ['m2'])),
        throwsA(isA<SummaryChainException>()),
      );
    });
  });
}
