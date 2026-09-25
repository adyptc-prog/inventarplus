import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:inventar_plus/license_service.dart';
import 'package:inventar_plus/main.dart';

const _smsChannel = MethodChannel('inventarplus/sms');
const _licenseChannel = MethodChannel('inventarplus/license');
const _permChannel = MethodChannel('flutter.baseflow.com/permissions/methods');

const _license = '{"payload":{"businessId":"inventarplus-1"},"signature":"x"}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<({String phone, String message})> sent;
  late String? shareable; // licența activă (null = fără licență)

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    debugSimulateAndroid = true;
    LicenseService.debugReset();
    LicenseService.debugIsAndroid = true;
    sent = [];
    shareable = null;
    await SyncService.clearPartner();

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_smsChannel, (call) async {
      switch (call.method) {
        case 'sendSms':
          final args = (call.arguments as Map).cast<String, Object?>();
          sent.add((
            phone: args['phone'] as String,
            message: args['message'] as String,
          ));
          return null;
        case 'getSyncMessages':
          return '[]';
      }
      return null;
    });
    messenger.setMockMethodCallHandler(_licenseChannel, (call) async {
      switch (call.method) {
        case 'getShareableLicense':
          return shareable;
        case 'checkLicense':
          return {'status': 'missing', 'message': ''};
        case 'isLicensed':
        case 'consumePartnerNotice':
          return false;
      }
      return null;
    });
    // Permisiunea SMS acordată.
    messenger.setMockMethodCallHandler(_permChannel, (call) async {
      switch (call.method) {
        case 'checkPermissionStatus':
          return 1;
        case 'requestPermissions':
          return {for (final p in (call.arguments as List).cast<int>()) p: 1};
      }
      return null;
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in [_smsChannel, _licenseChannel, _permChannel]) {
      messenger.setMockMethodCallHandler(ch, null);
    }
    debugSimulateAndroid = null;
    LicenseService.debugReset();
  });

  group('schimbul de licență la împerechere', () {
    test('telefonul cu licență o trimite partenerului', () async {
      shareable = _license;
      await SyncService.setPartner('0722000111');
      await SyncService.sendLicenseHandshake();
      expect(sent, [(phone: '0722000111', message: 'INV:L:$_license')]);
    });

    test('telefonul fără licență o cere', () async {
      await SyncService.setPartner('0722000111');
      await SyncService.sendLicenseHandshake();
      expect(sent, [(phone: '0722000111', message: 'INV:R:')]);
    });

    test('fără partener nu se trimite nimic', () async {
      shareable = _license;
      await SyncService.sendLicenseHandshake();
      expect(await SyncService.sendLicenseToPartner(), 0);
      expect(sent, isEmpty);
    });

    test('trimiterea licenței (ex. după reînnoire) ajunge la partener',
        () async {
      shareable = _license;
      await SyncService.setPartner('0722000111');
      expect(await SyncService.sendLicenseToPartner(), 1);
      expect(sent.single.message, 'INV:L:$_license');
    });

    test('fără licență activă nu se trimite nimic', () async {
      await SyncService.setPartner('0722000111');
      expect(await SyncService.sendLicenseToPartner(), 0);
      expect(sent, isEmpty);
    });
  });

  testWidgets('„Sincronizează” trimite întâi licența, apoi produsele',
      (tester) async {
    shareable = _license;
    await tester.pumpWidget(const InventarPlusApp());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.tap(find.byTooltip('Configurează sincronizare'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '0722000111');
    await tester.tap(find.text('Sincronizează'));
    // Sincronizarea inițială trimite SMS-urile la 1,5 s distanță.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(seconds: 1));
    }

    expect(sent.first.message, 'INV:L:$_license');
    expect(sent.skip(1).every((m) => m.message.startsWith('INV:I:') ||
        m.message == 'INV:Z:'), isTrue);
    expect(sent.last.message, 'INV:Z:');
  });
}
