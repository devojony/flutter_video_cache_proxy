import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_demo/main.dart';

void main() {
  testWidgets('Verify app title', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Video Cache Demo'), findsOneWidget);
  });

  testWidgets('Verify home page content', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Video caching server is running'), findsOneWidget);
  });
}
