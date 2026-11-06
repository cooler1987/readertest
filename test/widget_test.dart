import 'package:flutter_test/flutter_test.dart';
import 'package:readertest/main.dart';

void main() {
  testWidgets('ReaderApp builds successfully', (WidgetTester tester) async {
    await tester.pumpWidget(const ReaderApp());
    expect(find.text('简阅'), findsOneWidget);
  });
}
