import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabryo/features/collaboration/domain/collaboration.dart';
import 'package:tabryo/features/collaboration/presentation/collaboration_screen.dart';
import 'package:tabryo/features/collaboration/presentation/collaboration_view_model.dart';

void main() {
  testWidgets('failed sessions keep their recovery guidance after reconnect', (
    tester,
  ) async {
    final client = _Client()..failed = true;
    final model = CollaborationViewModel(client)..group = 'group';
    var terminals = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CollaborationScreen(
          model: model,
          onOpenTerminal: (_) async {
            terminals++;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Last turn failed'), findsOneWidget);
    expect(find.text('Connected Codex CLI: 0.153.4'), findsOneWidget);
    expect(find.textContaining('does not retry failed work'), findsOneWidget);
    final connect = find.text('Connect / resume');
    await tester.ensureVisible(connect);
    await tester.tap(connect);
    await tester.pumpAndSettle();
    expect(find.text('Last turn failed'), findsOneWidget);
    final terminal = find.text('Open in Tabryo');
    await tester.ensureVisible(terminal);
    await tester.tap(terminal);
    await tester.pumpAndSettle();
    expect(terminals, 1);
    expect(client.operations, containsAllInOrder(['connect', 'launch']));
    expect(client.operations, isNot(contains('turn/start')));
    client.diagnostics = false;
    await model.refresh();
    await tester.pump();
    expect(find.textContaining('predates session diagnostics'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await model.disposeAsync();
  });
  testWidgets(
    'collaboration panel exposes sessions, persisted delivery and approval controls',
    (tester) async {
      final client = _Client();
      final model = CollaborationViewModel(client)..group = 'group';
      await tester.pumpWidget(
        MaterialApp(
          home: CollaborationScreen(model: model, onOpenTerminal: (_) async {}),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('API · writer'), findsOneWidget);
      expect(find.text('Open in Tabryo'), findsOneWidget);
      expect(find.text('External terminal'), findsOneWidget);
      final respond = find.text(
        'Respond · item/commandExecution/requestApproval',
      );
      await tester.ensureVisible(respond);
      await tester.tap(respond);
      await tester.pumpAndSettle();
      expect(find.textContaining('git status'), findsOneWidget);
      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();
      expect(
        client.operations,
        containsAllInOrder(['approval_detail', 'respond']),
      );
      await tester.tap(find.text('Messages'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Contract ready'), findsOneWidget);
      expect(find.textContaining('uncertain'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      expect(client.operations.contains('stop'), isFalse);
      await model.disposeAsync();
    },
  );
}

final class _Client implements CollaborationClient {
  final operations = <String>[];
  bool failed = false;
  bool diagnostics = true;
  @override
  Future<void> connect({bool start = false}) async {}
  @override
  Future<Json> call(String operation, [Json arguments = const {}]) async {
    operations.add(operation);
    if (operation == 'approval_detail') {
      return {
        'parameters': {'command': 'git status'},
        'review': 'git status',
        'review_available': true,
      };
    }
    if (operation == 'respond') return {};
    return {
      'capabilities': [if (diagnostics) 'session_diagnostics'],
      'groups': [
        {'id': 'group', 'name': 'API + Flutter'},
      ],
      'participants': [
        {
          'id': 'api',
          'name': 'API',
          'root': r'C:\api',
          'writer': 1,
          'auto_wake': 1,
          'state': 'active',
          'status': {'type': 'idle'},
          if (failed) ...{
            'last_turn_status': 'failed',
            'codex_version': '0.153.4',
            'error': 'The selected model requires a newer Codex CLI.',
          },
          'objective': 'Pagination',
          'updated': 'now',
          'approvals': [
            {'id': '1', 'method': 'item/commandExecution/requestApproval'},
          ],
        },
      ],
      'messages': [
        {
          'id': 1,
          'sender': 'api',
          'recipient': 'flutter',
          'kind': 'request',
          'summary': 'Contract ready',
          'status': 'uncertain',
        },
      ],
      'checkpoints': <Json>[],
    };
  }

  @override
  void close() {}
}
