package app.sayitapp.inventar_plus

import android.content.Context
import java.util.Locale

/**
 * Limba aplicației (română sau engleză), aceeași regulă ca în lib/l10n.dart:
 * alegerea salvată din aplicație, iar până atunci limba telefonului — română
 * pe un telefon setat în română, engleză pe oricare altul.
 *
 * Fiecare punct de intrare nativ (activitate, receiver, worker) apelează
 * [sync] înainte să genereze mesaje, ca alegerea făcută între timp în
 * aplicație să fie respectată.
 */
object AppLang {
    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val KEY = "flutter.app_language"

    @Volatile
    var isEn: Boolean = false
        private set

    fun sync(context: Context) {
        val saved = context.applicationContext
            .getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
            .getString(KEY, null)
        isEn = resolveIsEn(saved, Locale.getDefault().language)
    }

    fun resolveIsEn(saved: String?, deviceLanguage: String): Boolean = when (saved) {
        "en" -> true
        "ro" -> false
        else -> deviceLanguage != "ro"
    }

    /** Doar pentru teste. */
    fun setForTest(en: Boolean) {
        isEn = en
    }
}

/** Textul în limba aplicației. Ambele variante stau una lângă alta în cod. */
fun tr(ro: String, en: String): String = if (AppLang.isEn) en else ro
