import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabryo/features/collaboration/domain/collaboration.dart';
import 'package:tabryo/features/collaboration/presentation/collaboration_screen.dart';
import 'package:tabryo/features/collaboration/presentation/collaboration_view_model.dart';

void main() {
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
