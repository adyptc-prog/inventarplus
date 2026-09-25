package app.sayitapp.inventar_plus

import android.content.Context

/**
 * Ultimul eșec la trimiterea unui SMS, păstrat până când utilizatorul îl
 * vede și îl închide în aplicație. Înainte, toate eșecurile erau silențioase.
 */
object SmsStatus {

    private const val PREFS_NAME = "SmsStatus"
    private const val KEY_FAILURE_AT = "last_failure_at"
    private const val KEY_FAILURE_PHONE = "last_failure_phone"
    private const val KEY_FAILURE_REASON = "last_failure_reason"
    private const val KEY_SUCCESS_AT = "last_success_at"
    private const val KEY_DISMISSED_AT = "dismissed_at"

    const val PERMISSION_MISSING = "Permisiunea SMS lipsește."

    // Coduri SmsManager.RESULT_ERROR_* (valori stabile din API-ul Android).
    fun describe(resultCode: Int): String = when (resultCode) {
        1 -> "Eroare generală la trimitere (verifică creditul/abonamentul și SIM-ul implicit pentru SMS)."
        2 -> "Rețeaua mobilă este oprită (mod avion?)."
        3 -> "Mesajul nu a putut fi codificat."
        4 -> "Fără semnal / serviciu mobil."
        5 -> "Limita de SMS-uri a sistemului a fost depășită."
        6 -> "Număr blocat de lista de apelare fixă (FDN)."
        7, 8 -> "Trimiterea către numere scurte nu este permisă."
        else -> "Trimiterea a eșuat (cod $resultCode)."
    }

    /** Un eșec se afișează până când e închis de utilizator. */
    fun shouldReport(failureAt: Long, dismissedAt: Long): Boolean =
        failureAt > 0 && failureAt > dismissedAt

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun recordFailure(context: Context, phone: String, reason: String) {
        prefs(context).edit()
            .putLong(KEY_FAILURE_AT, System.currentTimeMillis())
            .putString(KEY_FAILURE_PHONE, phone)
            .putString(KEY_FAILURE_REASON, reason)
            .apply()
    }

    fun recordSuccess(context: Context) {
        prefs(context).edit().putLong(KEY_SUCCESS_AT, System.currentTimeMillis()).apply()
    }

    /** Eșecul de afișat, sau null. */
    fun pendingFailure(context: Context): HashMap<String, Any?>? {
        val p = prefs(context)
        val failureAt = p.getLong(KEY_FAILURE_AT, 0L)
        if (!shouldReport(failureAt, p.getLong(KEY_DISMISSED_AT, 0L))) return null
        return hashMapOf(
            "failedAt" to failureAt,
            "phone" to p.getString(KEY_FAILURE_PHONE, ""),
            "reason" to p.getString(KEY_FAILURE_REASON, ""),
            "lastSuccessAt" to p.getLong(KEY_SUCCESS_AT, 0L).takeIf { it > 0 },
        )
    }

    fun dismiss(context: Context) {
        prefs(context).edit().putLong(KEY_DISMISSED_AT, System.currentTimeMillis()).apply()
    }
}
