// Basic widget test for Smart Attendance app.

import 'package:flutter_test/flutter_test.dart';

import 'package:attendance/main.dart';

void main() {
  testWidgets('App builds successfully', (WidgetTester tester) async {
    await tester.pumpWidget(const SmartAttendanceApp());

    // Verify splash screen renders
    expect(find.text('Smart Attendance'), findsOneWidget);
  });
}
