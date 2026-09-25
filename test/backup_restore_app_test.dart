import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:inventar_plus/backup_service.dart';
import 'package:inventar_plus/main.dart';

// Restaurarea scrie datele nativ (BackupManager.kt), pe lângă cache-ul Dart
// al SharedPreferences. Testul verifică pe aplicația întreagă că, după
// restaurare, tabelul afișează datele restaurate — nu cele vechi din cache.
const _backupChannel = MethodChannel('inventarplus/backup');

String _items(List<String> names) => jsonEncode([
      for (var i = 0; i < names.length; i++)
        {
          'syncId': 's$i',
          'number': i + 1,
          'denumire': names[i],
          'descriere': '',
          'codBare': '',
          'stocActual': 50,
          'stocMinim': 10,
          'pragAlerta': 20,
          'createdAt': '2026-09-01T10:00:00.000',
        }
    ]);

Map<String, Object> _state(List<String> names) => {
      'inventar_products': _items(names),
      'inventar_next_number': names.length + 1,
    };

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    try { await AlertService.init(); } catch (_) {}
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(_state(['Făină veche', 'Ulei vechi']));
    BackupService.debugIsAndroid = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_backupChannel, (call) async {
      switch (call.method) {
        case 'getStatus':
          return {'folderUri': null};
        case 'pickAndRestoreBackup':
          // „Partea nativă” înlocuiește datele direct în store, pe lângă
          // cache-ul instanței Dart — ca pe Android. (setMockInitialValues
          // ar reseta și instanța, ascunzând lipsa unui reload.)
          final store = SharedPreferencesStorePlatform.instance;
          await store.clear();
          for (final e in _state(['Zahăr restaurat', 'Orez restaurat', 'Sare restaurată']).entries) {
            await store.setValue(e.value is int ? 'Int' : 'String', 'flutter.${e.key}', e.value);
          }
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_backupChannel, null);
    BackupService.debugIsAndroid = null;
  });

  testWidgets('după restaurare tabelul afișează produsele din backup',
      (tester) async {
    await tester.pumpWidget(const InventarPlusApp());
    await tester.pumpAndSettle();
    expect(find.text('Făină veche'), findsOneWidget);
    expect(find.text('2 produse'), findsOneWidget);

    await tester.tap(find.byTooltip('Backup & restaurare'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restaurează din alt fișier'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Restaurează'));
    await tester.pumpAndSettle();
    expect(find.text('Backup restaurat. Datele au fost reîncărcate.'),
        findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('Făină veche'), findsNothing);
    expect(find.text('Zahăr restaurat'), findsOneWidget);
    expect(find.text('3 produse'), findsOneWidget);

    // Adăugarea după restaurare continuă numerotarea din backup și nu
    // readuce datele vechi din cache.
    await tester.tap(find.byIcon(Icons.add_circle_rounded));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Denumire produs *'), 'Nou');
    await tester.tap(find.text('Adaugă').last);
    await tester.pumpAndSettle();
    expect(find.text('4 produse'), findsOneWidget);
    expect(find.text('Făină veche'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('inventar_products')!;
    expect(saved, contains('Zahăr restaurat'));
    expect(saved, isNot(contains('Făină veche')));
  });
}
