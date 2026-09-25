import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:inventar_plus/backup_screen.dart';
import 'package:inventar_plus/backup_service.dart';

const _channel = MethodChannel('inventarplus/backup');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, Object?> status;
  late List<Map<String, Object?>> backups;
  late List<MethodCall> calls;
  PlatformException? failWith;
  late List<String> events;

  final noFolder = <String, Object?>{'folderUri': null};
  final usbFolder = <String, Object?>{
    'folderUri': 'content://usb/tree/1',
    'folderName': 'Backup Inventar+',
    'folderAccessible': true,
    'destination': 'usb',
    'lastAutoAt': DateTime(2026, 9, 24, 0, 1).millisecondsSinceEpoch,
    'lastAutoError': null,
    'lastManualAt': null,
  };

  setUp(() {
    BackupService.debugIsAndroid = true;
    status = noFolder;
    backups = [];
    calls = [];
    failWith = null;
    events = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      if (failWith != null && call.method != 'getStatus') throw failWith!;
      switch (call.method) {
        case 'getStatus':
          return status;
        case 'pickFolder':
          status = {...usbFolder, 'destination': call.arguments['destination']};
          return status;
        case 'createBackup':
          return {
            'id': 'doc1',
            'name': 'inventarplus_20260924_101500.invbackup',
            'size': 2048,
            'modifiedAt': 0,
          };
        case 'listBackups':
          return backups;
        case 'restoreBackup':
        case 'pickAndRestoreBackup':
          events.add('restore(${call.arguments['keepSyncPartners']})');
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    BackupService.debugIsAndroid = null;
  });

  // FilledButton.icon / OutlinedButton.icon sunt subclase private — căutăm
  // orice buton Material care conține textul.
  bool buttonEnabled(WidgetTester tester, String label) => tester
      .widget<ButtonStyleButton>(find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)))
      .enabled;

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: BackupScreen(
        onBeforeRestore: () async => events.add('before'),
        onRestored: (ok) async => events.add('after($ok)'),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('fără folder: cere alegerea destinației, backup dezactivat',
      (tester) async {
    await pumpScreen(tester);
    expect(find.text('Niciun folder ales'), findsOneWidget);
    expect(buttonEnabled(tester, 'Creează backup acum'), isFalse);
  });

  testWidgets('alegerea stick-ului USB trimite destinația', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Stick USB'));
    await tester.pumpAndSettle();
    final pick = calls.firstWhere((c) => c.method == 'pickFolder');
    expect(pick.arguments['destination'], 'usb');
    expect(find.text('Backup Inventar+'), findsOneWidget);
    expect(find.text('Folderul de backup a fost setat.'), findsOneWidget);
  });

  testWidgets('memoria telefonului trimite destinația phone', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Memoria telefonului'));
    await tester.pumpAndSettle();
    expect(calls.firstWhere((c) => c.method == 'pickFolder').arguments['destination'],
        'phone');
  });

  testWidgets('afișează ultimul backup automat și crearea manuală', (tester) async {
    status = usbFolder;
    await pumpScreen(tester);
    expect(find.text('Ultimul backup automat: 24.09.2026 00:01'), findsOneWidget);
    await tester.tap(find.text('Creează backup acum'));
    await tester.pumpAndSettle();
    expect(find.text('Backup creat: inventarplus_20260924_101500.invbackup'),
        findsOneWidget);
  });

  testWidgets('eroarea backup-ului automat e vizibilă', (tester) async {
    status = {...usbFolder, 'lastAutoError': 'Nu s-a putut crea fișierul de backup.'};
    await pumpScreen(tester);
    expect(find.textContaining('Ultima încercare a eșuat'), findsOneWidget);
  });

  testWidgets('folder inaccesibil (stick scos): butoanele sunt dezactivate',
      (tester) async {
    status = {...usbFolder, 'folderAccessible': false, 'folderName': null};
    await pumpScreen(tester);
    expect(find.text('Folderul nu este accesibil'), findsOneWidget);
    expect(buttonEnabled(tester, 'Creează backup acum'), isFalse);
    expect(buttonEnabled(tester, 'Restaurează din folderul de backup'), isFalse);
    // Restaurarea dintr-un fișier ales manual rămâne disponibilă.
    expect(buttonEnabled(tester, 'Restaurează din alt fișier'), isTrue);
  });

  testWidgets('eroarea nativă la creare e afișată', (tester) async {
    status = usbFolder;
    await pumpScreen(tester);
    failWith = PlatformException(
        code: 'BACKUP_CREATE_FAILED',
        message: 'Aplicația nu mai are acces la folderul de backup. Alege-l din nou.');
    await tester.tap(find.text('Creează backup acum'));
    await tester.pumpAndSettle();
    expect(find.text('Aplicația nu mai are acces la folderul de backup. Alege-l din nou.'),
        findsOneWidget);
  });

  testWidgets('restaurare din folder: confirmare, parteneri păstrați implicit',
      (tester) async {
    status = usbFolder;
    backups = [
      {
        'id': 'doc9',
        'name': 'inventarplus_auto_20260924_000100.invbackup',
        'modifiedAt': DateTime(2026, 9, 24, 0, 1).millisecondsSinceEpoch,
        'size': 4096,
        'auto': true,
      },
    ];
    await pumpScreen(tester);
    await tester.tap(find.text('Restaurează din folderul de backup'));
    await tester.pumpAndSettle();
    expect(find.text('Automat · 4.0 KB'), findsOneWidget);
    await tester.tap(find.text('24.09.2026 00:01'));
    await tester.pumpAndSettle();

    expect(find.text('Restaurezi backup-ul?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Restaurează'));
    await tester.pumpAndSettle();

    expect(events, ['before', 'restore(true)', 'after(true)']);
    expect(calls.firstWhere((c) => c.method == 'restoreBackup').arguments['id'],
        'doc9');
    expect(find.text('Backup restaurat. Datele au fost reîncărcate.'),
        findsOneWidget);
  });

  testWidgets('restaurare din fișier cu partenerul din backup', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Restaurează din alt fișier'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Păstrează partenerul de sincronizare actual'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Restaurează'));
    await tester.pumpAndSettle();
    expect(events, ['before', 'restore(false)', 'after(true)']);
  });

  testWidgets('restaurare anulată la confirmare nu atinge datele', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Restaurează din alt fișier'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anulează'));
    await tester.pumpAndSettle();
    expect(events, isEmpty);
    expect(calls.where((c) => c.method == 'pickAndRestoreBackup'), isEmpty);
  });

  testWidgets('backup respins: mesaj de eroare, datele se reîncarcă oricum',
      (tester) async {
    await pumpScreen(tester);
    failWith = PlatformException(
        code: 'BACKUP_RESTORE_FAILED',
        message: 'Backup-ul este corupt (checksum invalid).');
    await tester.tap(find.text('Restaurează din alt fișier'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Restaurează'));
    await tester.pumpAndSettle();
    expect(events, ['before', 'after(false)']);
    expect(find.text('Backup-ul este corupt (checksum invalid).'), findsOneWidget);
  });

  testWidgets('selector de fișier închis fără alegere: fără eroare', (tester) async {
    await pumpScreen(tester);
    failWith = PlatformException(code: 'RESTORE_PICK_CANCELLED');
    await tester.tap(find.text('Restaurează din alt fișier'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Restaurează'));
    await tester.pumpAndSettle();
    expect(find.textContaining('RESTORE_PICK'), findsNothing);
    expect(find.textContaining('restaurat'), findsNothing);
  });

  testWidgets('folder fără backup-uri', (tester) async {
    status = usbFolder;
    await pumpScreen(tester);
    await tester.tap(find.text('Restaurează din folderul de backup'));
    await tester.pumpAndSettle();
    expect(find.text('Nu există backup-uri în folderul ales.'), findsOneWidget);
  });
}
