import 'package:flutter_test/flutter_test.dart';
import 'package:tabryo/main.dart';

void main() {
  testWidgets('boot does not create a terminal session', (tester) async {
    await tester.pumpWidget(const TabryoApp());
    expect(
      find.text('No process is running. Open a shell or Codex explicitly.'),
      findsOneWidget,
    );
  });
}
