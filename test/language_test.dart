import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:inventar_plus/l10n.dart';
import 'package:inventar_plus/license_service.dart';
import 'package:inventar_plus/main.dart';

const _smsChannel = MethodChannel('inventarplus/sms');
const _licenseChannel = MethodChannel('inventarplus/license');

Product _product({int stock = 1}) => Product(
      syncId: 'abc',
      number: 1,
      denumire: 'Ulei',
      descriere: '',
      codBare: '',
      stocActual: stock,
      stocMinim: 5,
      pragAlerta: 10,
      createdAt: DateTime(2026, 1, 1),
      phoneNumber: '0700000000',
    );

void main() {
  late List<String> sent;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    sent = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_smsChannel, (call) async {
      if (call.method == 'sendSms') {
        sent.add((call.arguments as Map)['message'] as String);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_smsChannel, null);
    debugSimulateAndroid = null;
    AppLang.debugDeviceLanguage = 'ro';
    AppLang.code.value = 'ro';
  });

  group('limba inițială', () {
    test('telefon în română → română', () async {
      AppLang.debugDeviceLanguage = 'ro';
      await AppLang.load();
      expect(AppLang.code.value, 'ro');
      expect(tr('Salvează', 'Save'), 'Salvează');
    });

    test('telefon în altă limbă → engleză', () async {
      for (final lang in ['en', 'de', 'hu']) {
        AppLang.debugDeviceLanguage = lang;
        await AppLang.load();
        expect(AppLang.code.value, 'en', reason: lang);
      }
      expect(tr('Salvează', 'Save'), 'Save');
    });

    test('alegerea din aplicație are prioritate față de limba telefonului',
        () async {
      SharedPreferences.setMockInitialValues({'app_language': 'ro'});
      AppLang.debugDeviceLanguage = 'en';
      await AppLang.load();
      expect(AppLang.code.value, 'ro');

      await AppLang.set('en');
      AppLang.debugDeviceLanguage = 'ro';
      await AppLang.load();
      expect(AppLang.code.value, 'en');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_language'), 'en');
    });
  });

  group('interfața', () {
    testWidgets('în engleză, ecranul principal e tradus', (tester) async {
      await AppLang.set('en');
      await tester.pumpWidget(const InventarPlusApp());
      await tester.pumpAndSettle();

      expect(find.text('Inventar+'), findsWidgets);
      expect(find.text('Report'), findsOneWidget);
      expect(find.text('SMS message'), findsOneWidget);
      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Current stock'), findsOneWidget);
      expect(find.text('Raport'), findsNothing);
      expect(find.text('Denumire'), findsNothing);
      expect(find.byTooltip('App language'), findsOneWidget);
    });

    testWidgets('schimbarea limbii din aplicație se aplică imediat și se salvează',
        (tester) async {
      await tester.pumpWidget(const InventarPlusApp());
      await tester.pumpAndSettle();
      expect(find.text('Raport'), findsOneWidget);

      await tester.tap(find.byTooltip('Limba aplicației'));
      await tester.pumpAndSettle();
      expect(find.text('Română'), findsOneWidget);
      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();

      expect(find.text('Report'), findsOneWidget);
      expect(find.text('Raport'), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_language'), 'en');

      await tester.tap(find.byTooltip('App language'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Română'));
      await tester.pumpAndSettle();
      expect(find.text('Raport'), findsOneWidget);
      expect(prefs.getString('app_language'), 'ro');
    });
    testWidgets('în engleză încape pe un telefon îngust (360 px), cu trial și sincronizare',
        (tester) async {
      SharedPreferences.setMockInitialValues(
          {'sync_partner_phone': '0722000111', 'app_language': 'en'});
      await AppLang.load();
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
      messenger.setMockMethodCallHandler(_smsChannel,
          (call) async => call.method == 'getSyncMessages' ? '[]' : null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(_licenseChannel, null);
        LicenseService.debugReset();
      });
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const InventarPlusApp());
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.textContaining('Trial ·'), findsOneWidget);
      expect(find.text('Synced'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('mesajul SMS de alertă', () {
    Future<String> templateShown(WidgetTester tester, String button) async {
      await tester.pumpWidget(const InventarPlusApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      return tester.widget<TextField>(find.byType(TextField).last).controller!.text;
    }

    testWidgets('mesajul implicit urmează limba aplicației', (tester) async {
      expect(await templateShown(tester, 'Mesaj SMS'),
          'Alertă stoc: [DENUMIRE]. Stoc actual: [STOC] (minim: [STOC_MINIM]).');
    });

    testWidgets('mesajul implicit salvat în română devine cel englezesc',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'app_language': 'en',
        'sms_template':
            'Alertă stoc: [DENUMIRE]. Stoc actual: [STOC] (minim: [STOC_MINIM]).',
      });
      await AppLang.load();
      expect(await templateShown(tester, 'SMS message'),
          'Stock alert: [NAME]. Current stock: [STOCK] (minimum: [MIN_STOCK]).');
    });

    testWidgets('un mesaj editat de utilizator rămâne neatins la schimbarea limbii',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'app_language': 'en',
        'sms_template': 'Comandă [DENUMIRE], au rămas [STOC] buc.',
      });
      await AppLang.load();
      expect(await templateShown(tester, 'SMS message'),
          'Comandă [DENUMIRE], au rămas [STOC] buc.');
    });

    test('SMS-ul pleacă în limba aplicației', () async {
      debugSimulateAndroid = true;
      await AlertService.notify(_product(), 2,
          'Alertă stoc: [DENUMIRE]. Stoc actual: [STOC] (minim: [STOC_MINIM]).');
      expect(sent.single,
          'STOC EPUIZAT: Alertă stoc: Ulei. Stoc actual: 1 (minim: 5).');

      sent.clear();
      await AppLang.set('en');
      await AlertService.notify(_product(stock: 8), 1,
          'Stock alert: [NAME]. Current stock: [STOCK] (minimum: [MIN_STOCK]).');
      expect(sent.single,
          'STOCK ALERT: Stock alert: Ulei. Current stock: 8 (minimum: 5).');
    });

    test('variabilele din ambele limbi funcționează indiferent de limbă',
        () async {
      debugSimulateAndroid = true;
      await AppLang.set('en');
      await AlertService.notify(_product(), 2,
          '[DENUMIRE]/[NAME] [STOC]/[STOCK] [STOC_MINIM]/[MIN_STOCK] [PRAG_ALERTA]/[THRESHOLD]');
      expect(sent.single, 'CRITICAL STOCK: Ulei/Ulei 1/1 5/5 10/10');
    });
  });
}
