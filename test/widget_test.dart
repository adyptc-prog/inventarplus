import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:inventar_plus/license_service.dart';
import 'package:inventar_plus/main.dart';

const _licenseChannel = MethodChannel('inventarplus/license');
const _smsChannel = MethodChannel('inventarplus/sms');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('App pornește și afișează titlul', (WidgetTester tester) async {
    await tester.pumpWidget(const InventarPlusApp());
    await tester.pump();

    expect(find.text('Inventar+'), findsWidgets);
    expect(find.byIcon(Icons.add_circle_rounded), findsOneWidget);
  });

  group('versiunea aplicației', () {
    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'Inventar+',
        packageName: 'app.sayitapp.inventar_plus',
        version: '1.1.0',
        buildNumber: '5',
        buildSignature: '',
      );
    });

    tearDown(() {
      debugSimulateAndroid = null;
      LicenseService.debugReset();
    });

    testWidgets('apare sub tabel', (tester) async {
      await tester.pumpWidget(const InventarPlusApp());
      await tester.pumpAndSettle();
      expect(find.text('v1.1.0'), findsOneWidget);
    });

    testWidgets('încape pe un telefon îngust (360 px), cu trial și sincronizare',
        (tester) async {
      // Rândul cel mai încărcat: număr produse + trial + „Sincronizat” + versiune.
      SharedPreferences.setMockInitialValues({'sync_partner_phone': '0722000111'});
      debugSimulateAndroid = true;
      LicenseService.debugIsAndroid = true;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_licenseChannel, (call) async {
        switch (call.method) {
          case 'checkLicense':
            return {'status': 'missing', 'message': ''};
          case 'isLicensed':
          case 'consumePartnerNotice':
            return false;
        }
        return null;
      });
      messenger.setMockMethodCallHandler(
          _smsChannel, (call) async => call.method == 'getSyncMessages' ? '[]' : null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(_licenseChannel, null);
        messenger.setMockMethodCallHandler(_smsChannel, null);
      });
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const InventarPlusApp());
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.textContaining('Trial ·'), findsOneWidget);
      expect(find.text('Sincronizat'), findsOneWidget);
      expect(find.text('v1.1.0'), findsOneWidget);
      expect(tester.takeException(), isNull); // fără RenderFlex overflow
    });
  });
}
