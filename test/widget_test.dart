import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:inventar_plus/main.dart';

void main() {
  testWidgets('App pornește și afișează titlul', (WidgetTester tester) async {
    await tester.pumpWidget(const InventarPlusApp());
    await tester.pump();

    expect(find.text('Inventar+'), findsWidgets);
    expect(find.byIcon(Icons.add_circle_rounded), findsOneWidget);
  });
}
