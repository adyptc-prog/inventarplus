import 'dart:async';

import 'package:inventar_plus/l10n.dart';

// Testele existente verifică textele în română: fixează limba telefonului
// simulat (mașina de test raportează „en_US”). Testele pentru engleză o
// schimbă explicit.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  AppLang.debugDeviceLanguage = 'ro';
  AppLang.code.value = 'ro';
  await testMain();
}
