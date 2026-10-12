
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Limba aplicației: română sau engleză ─────────────────────────────────────
// Până alege utilizatorul una din aplicație, se folosește limba telefonului:
// română pe un telefon setat în română, engleză pe oricare altul. Alegerea se
// salvează în SharedPreferences și e citită și de partea nativă (AppLang.kt),
// cu aceeași regulă, pentru mesajele generate acolo.
class AppLang {
  static const prefsKey = 'app_language';

  static final ValueNotifier<String> code = ValueNotifier<String>('ro');

  // Testele rulează cu limba „en_US” a mașinii — permite fixarea limbii
  // telefonului simulat.
  @visibleForTesting
  static String? debugDeviceLanguage;

  static bool get isEn => code.value == 'en';

  static String get deviceLanguage {
    final lang = debugDeviceLanguage ??
        PlatformDispatcher.instance.locale.languageCode;
    return lang == 'ro' ? 'ro' : 'en';
  }

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(prefsKey);
    code.value = (saved == 'ro' || saved == 'en') ? saved! : deviceLanguage;
  }

  static Future<void> set(String lang) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, lang == 'en' ? 'en' : 'ro');
    code.value = lang == 'en' ? 'en' : 'ro';
  }
}

// Textul în limba aplicației. Ambele variante stau una lângă alta în cod.
String tr(String ro, String en) => AppLang.isEn ? en : ro;
