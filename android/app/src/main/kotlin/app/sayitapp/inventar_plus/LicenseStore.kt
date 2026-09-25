package app.sayitapp.inventar_plus

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.util.Base64
import org.json.JSONObject

/**
 * Starea licenței (flux nou, format identic cu Fidelio), păstrată în
 * "LicensePrefs":
 *  - business_id   — codul de instalare pe care e emisă licența;
 *  - license_json  — conținutul semnat al licenței, copiat intern la import,
 *                    ca licența să nu depindă de fișierul original (poate fi
 *                    șters, sau URI-ul poate deveni inaccesibil) și să poată
 *                    fi inclusă în backup / trimisă telefonului partener;
 *  - license_uri   — fluxul inițial, păstrat doar pentru migrare.
 */
object LicenseStore {

    const val PREFS_NAME = "LicensePrefs"
    const val KEY_BUSINESS_ID = "business_id"
    const val KEY_LICENSE_JSON = "license_json"
    const val KEY_LICENSE_URI = "license_uri"
    private const val KEY_LAST_CHECK = "last_license_check"
    // Setat când licența a fost preluată/reînnoită de la telefonul partener,
    // ca Flutter să poată anunța utilizatorul la următoarea verificare.
    private const val KEY_PARTNER_NOTICE = "license_partner_notice"

    // Cheia publică RSA-2048 (DER/X.509, base64) — corespunde
    // volt-academy-license-tools/inventarplus/private.pem, cu care semnează
    // și site-ul (LICENSE_PRIVATE_KEY_PEM_INVENTARPLUS).
    const val PUBLIC_KEY_B64 =
        "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAkkl+Dq5BabpA0LP14dx3" +
        "ocx34ZY7SHS+X6DZyuGupgoPnKUmBdG7qvmhj/vizaWcgjiQwz7hVDOFFhLiBVc6" +
        "svTpCEWPu/WuLvYiXCqclezp7NhQRALoHvS0SH1k51xx+xXmqnh1JLSI70ay43KR" +
        "FnRdOZFIaChka9r72M2UdIQ0OmhD+undCdkHek/DJJZiKwkEw55tbk2Slq5H5cpS" +
        "IUqJ6PmpLgGpsOytBmpNhoLaCxtJDKw8OxO2Oh+oShFmfPU5LPCOi/1aDQ43OYVu" +
        "n568Vbt1cSW44/IBXzHNKw5mqPlbAB6i/P1ld3aoNmTqi9ZgO9wEjtziBDGjkp+7" +
        "uwIDAQAB"

    private val verifier by lazy {
        LicenseVerifier(Base64.decode(PUBLIC_KEY_B64, Base64.DEFAULT)) {
            Base64.decode(it, Base64.DEFAULT)
        }
    }

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun getOrCreateBusinessId(context: Context): String {
        val prefs = prefs(context)
        val existing = prefs.getString(KEY_BUSINESS_ID, null)
        if (existing != null) return existing
        val fresh = "inventarplus-${System.currentTimeMillis()}"
        prefs.edit().putString(KEY_BUSINESS_ID, fresh).apply()
        return fresh
    }

    // Anti-clock-manipulation: monotonically non-decreasing "effective now",
    // identical logic to Fidelio's getEffectiveNow().
    private fun effectiveNow(context: Context): Long {
        val prefs = prefs(context)
        val lastMs = prefs.getLong(KEY_LAST_CHECK, 0L)
        val deviceNow = System.currentTimeMillis()
        val effectiveNow = if (deviceNow < lastMs - 60_000L) lastMs else maxOf(deviceNow, lastMs)
        prefs.edit().putLong(KEY_LAST_CHECK, effectiveNow).apply()
        return effectiveNow
    }

    /** Licența stocată intern; migrează o singură dată din vechiul license_uri. */
    fun storedLicense(context: Context): String? {
        val prefs = prefs(context)
        prefs.getString(KEY_LICENSE_JSON, null)?.let { return it }
        val uriText = prefs.getString(KEY_LICENSE_URI, null) ?: return null
        val content = try {
            context.contentResolver.openInputStream(Uri.parse(uriText))?.use {
                it.reader(Charsets.UTF_8).readText()
            }
        } catch (_: Exception) {
            null
        } ?: return null
        prefs.edit().putString(KEY_LICENSE_JSON, content).apply()
        return content
    }

    fun check(context: Context): LicenseCheck {
        val content = storedLicense(context)
            ?: return LicenseCheck("missing", "No license file selected.")
        return verifier.evaluate(content, getOrCreateBusinessId(context), effectiveNow(context))
    }

    /**
     * Import din fișierul ales de utilizator. O licență invalidă NU înlocuiește
     * licența stocată — altfel alegerea greșită a unui fișier ar dezactiva o
     * licență bună.
     */
    fun importLicense(context: Context, content: String): LicenseCheck {
        val result = verifier.evaluate(content, getOrCreateBusinessId(context), effectiveNow(context))
        if (result.isActive) {
            prefs(context).edit().putString(KEY_LICENSE_JSON, content).apply()
        }
        return result
    }

    /**
     * Licența de trimis telefonului partener — doar dacă e activă. Compactată
     * (fără spații/linii noi) ca SMS-ul să aibă cât mai puține segmente;
     * semnătura acoperă câmpurile canonice, nu textul JSON, deci rămâne validă.
     */
    fun shareableLicense(context: Context): String? {
        if (!check(context).isActive) return null
        val content = storedLicense(context) ?: return null
        return try { JSONObject(content).toString() } catch (_: Exception) { null }
    }

    /** Licență primită prin SMS de la partenerul de sincronizare. */
    fun adoptFromPartner(context: Context, content: String): AdoptionDecision {
        val now = effectiveNow(context)
        val incoming = verifier.evaluate(content, null, now)
        val currentBusinessId = getOrCreateBusinessId(context)
        val current = storedLicense(context)?.let { verifier.evaluate(it, currentBusinessId, now) }
        val decision = LicenseVerifier.decideAdoption(current, currentBusinessId, incoming)
        if (decision == AdoptionDecision.ADOPT || decision == AdoptionDecision.RENEW) {
            prefs(context).edit()
                .putString(KEY_BUSINESS_ID, incoming.businessId)
                .putString(KEY_LICENSE_JSON, content)
                .putBoolean(KEY_PARTNER_NOTICE, true)
                .commit()
        }
        return decision
    }

    // ── Backup / restore ─────────────────────────────────────────────────────────
    fun identity(context: Context): BackupFormat.Identity =
        BackupFormat.Identity(getOrCreateBusinessId(context), storedLicense(context))

    /** True dacă [licenseJson] e o licență activă emisă pe [businessId]. */
    fun isActiveFor(context: Context, licenseJson: String?, businessId: String?): Boolean {
        if (licenseJson == null || businessId == null) return false
        return verifier.evaluate(licenseJson, businessId, effectiveNow(context)).isActive
    }

    /**
     * Restaurează codul de instalare (și licența) din backup — licența
     * cumpărată continuă să funcționeze după reinstalare sau pe telefon nou.
     * Nu înlocuiește o licență activă cu o identitate fără licență validă.
     * Întoarce true dacă identitatea a fost schimbată.
     */
    fun restoreIdentity(context: Context, identity: BackupFormat.Identity): Boolean {
        val businessId = identity.businessId ?: return false
        val restore = BackupFormat.shouldRestoreIdentity(
            currentLicenseActive = check(context).isActive,
            backupLicenseActive = isActiveFor(context, identity.licenseJson, businessId),
        )
        if (!restore) return false
        val editor = prefs(context).edit().putString(KEY_BUSINESS_ID, businessId)
        if (identity.licenseJson != null) {
            editor.putString(KEY_LICENSE_JSON, identity.licenseJson)
        } else {
            editor.remove(KEY_LICENSE_JSON)
        }
        // URI-ul vechi ar reintroduce, prin migrare, licența altei identități.
        editor.remove(KEY_LICENSE_URI).commit()
        return true
    }

    /** Întoarce true (o singură dată) dacă licența a venit de la partener. */
    fun consumePartnerNotice(context: Context): Boolean {
        val prefs = prefs(context)
        if (!prefs.getBoolean(KEY_PARTNER_NOTICE, false)) return false
        prefs.edit().putBoolean(KEY_PARTNER_NOTICE, false).apply()
        return true
    }
}
