package app.sayitapp.inventar_plus

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

/**
 * Formatul fișierului de backup Inventar+ (.invbackup) — logică pură, fără
 * Android, testabilă pe JVM.
 *
 * Datele aplicației stau în SharedPreferences (nu în SQLite ca la Fidelio),
 * deci backup-ul e un export JSON al cheilor, cu tipul fiecărei valori
 * păstrat (plugin-ul Dart scrie int-urile ca Long, listele ca String etc.):
 *
 *   {
 *     "app": "inventarplus",
 *     "formatVersion": 1,
 *     "createdAt": <epoch ms>,
 *     "checksum": sha256(data),
 *     "data": "<JSON ca text: {prefs: {...}, identity: {...}}>"
 *   }
 *
 * "data" e păstrat ca text, nu ca obiect, ca checksum-ul să fie calculat pe
 * exact aceiași octeți la scriere și la citire (org.json nu garantează
 * ordinea cheilor la re-serializare).
 */
object BackupFormat {

    const val APP_ID = "inventarplus"
    const val FORMAT_VERSION = 1
    const val EXTENSION = ".invbackup"
    const val AUTO_PREFIX = "inventarplus_auto_"
    const val MANUAL_PREFIX = "inventarplus_"

    private const val FLUTTER_PREFIX = "flutter."

    // Chei care nu fac parte din datele utilizatorului — nu se salvează și nu
    // se suprascriu la restore.
    private val EXCLUDED_KEYS = setOf(
        "flutter.license_expiry_warned_on",
    )

    // Partenerul de sincronizare. La restore pe telefonul partener, cel din
    // backup ar fi propriul număr — implicit se păstrează cel actual.
    fun isSyncPartnerKey(key: String): Boolean =
        key.startsWith("flutter.sync_partner_phone")

    fun isBackedUpKey(key: String): Boolean =
        key.startsWith(FLUTTER_PREFIX) && key !in EXCLUDED_KEYS

    /** Identitatea de licență inclusă în backup (codul de instalare + licența). */
    data class Identity(val businessId: String?, val licenseJson: String?)

    data class Backup(
        val createdAt: Long,
        val prefs: Map<String, Any?>,
        val identity: Identity,
    )

    class InvalidBackupException(message: String) : Exception(message)

    fun encode(prefs: Map<String, *>, identity: Identity, createdAt: Long): String {
        val prefsJson = JSONObject()
        for ((key, value) in prefs.toSortedMap()) {
            if (!isBackedUpKey(key)) continue
            encodeValue(value)?.let { prefsJson.put(key, it) }
        }
        val identityJson = JSONObject()
        identity.businessId?.let { identityJson.put("businessId", it) }
        identity.licenseJson?.let { identityJson.put("license", it) }

        val data = JSONObject()
            .put("prefs", prefsJson)
            .put("identity", identityJson)
            .toString()

        return JSONObject()
            .put("app", APP_ID)
            .put("formatVersion", FORMAT_VERSION)
            .put("createdAt", createdAt)
            .put("checksum", sha256(data))
            .put("data", data)
            .toString()
    }

    fun decode(content: String): Backup {
        val root = try {
            JSONObject(content)
        } catch (_: Exception) {
            throw InvalidBackupException("Fișierul nu este un backup Inventar+.")
        }
        if (root.optString("app") != APP_ID) {
            throw InvalidBackupException("Fișierul nu este un backup Inventar+.")
        }
        val version = root.optInt("formatVersion", -1)
        if (version < 1 || version > FORMAT_VERSION) {
            throw InvalidBackupException(
                "Backup creat de o versiune mai nouă a aplicației. Actualizează aplicația."
            )
        }
        val data = root.optString("data")
        if (data.isEmpty() || sha256(data) != root.optString("checksum")) {
            throw InvalidBackupException("Backup-ul este corupt (checksum invalid).")
        }

        val dataJson = JSONObject(data)
        val prefsJson = dataJson.getJSONObject("prefs")
        val prefs = LinkedHashMap<String, Any?>()
        for (key in prefsJson.keys()) {
            if (!isBackedUpKey(key)) continue
            prefs[key] = decodeValue(prefsJson.getJSONObject(key))
        }
        val identityJson = dataJson.optJSONObject("identity") ?: JSONObject()
        return Backup(
            createdAt = root.optLong("createdAt", 0L),
            prefs = prefs,
            identity = Identity(
                businessId = identityJson.optString("businessId").takeIf { it.isNotEmpty() },
                licenseJson = identityJson.optString("license").takeIf { it.isNotEmpty() },
            ),
        )
    }

    /**
     * Cheile de scris la restore: cele din backup, cu excepția partenerilor de
     * sincronizare când [keepSyncPartners] — atunci rămân cei actuali.
     * Cheile actuale care nu sunt în backup se șterg (restore = stare identică
     * cu cea din backup).
     */
    fun mergeForRestore(
        current: Map<String, *>,
        backup: Map<String, Any?>,
        keepSyncPartners: Boolean,
    ): Map<String, Any?> {
        val result = LinkedHashMap<String, Any?>()
        for ((key, value) in backup) {
            if (keepSyncPartners && isSyncPartnerKey(key)) continue
            result[key] = value
        }
        for ((key, value) in current) {
            if (!key.startsWith(FLUTTER_PREFIX)) continue
            if (key in EXCLUDED_KEYS || (keepSyncPartners && isSyncPartnerKey(key))) {
                result[key] = value
            }
        }
        // Trial-ul nu se prelungește prin restore — rămâne cel mai vechi start.
        earlierTrialStart(current[TRIAL_KEY] as? String, backup[TRIAL_KEY] as? String)
            ?.let { result[TRIAL_KEY] = it }
        return result
    }

    private const val TRIAL_KEY = "flutter.trial_start_date"

    /**
     * Codul de instalare din backup se restaurează (licența merge apoi mai
     * departe), cu o excepție: nu pierdem o licență activă pe acest telefon
     * în schimbul unei identități fără licență validă.
     */
    fun shouldRestoreIdentity(currentLicenseActive: Boolean, backupLicenseActive: Boolean): Boolean =
        backupLicenseActive || !currentLicenseActive

    /** Data de start a trial-ului: cea mai veche dintre cele două (ISO-8601). */
    fun earlierTrialStart(current: String?, backup: String?): String? {
        if (current == null) return backup
        if (backup == null) return current
        return if (backup < current) backup else current
    }

    /** Backup-urile automate de șters, păstrând cele mai noi [keep]. */
    fun autoBackupsToDelete(names: List<String>, keep: Int): List<String> =
        names.filter { it.startsWith(AUTO_PREFIX) && it.endsWith(EXTENSION) }
            .sortedDescending() // numele conțin yyyyMMdd_HHmmss
            .drop(keep)

    private fun encodeValue(value: Any?): JSONObject? = when (value) {
        is String -> JSONObject().put("t", "s").put("v", value)
        is Long -> JSONObject().put("t", "l").put("v", value.toString())
        is Int -> JSONObject().put("t", "i").put("v", value.toString())
        is Boolean -> JSONObject().put("t", "b").put("v", value.toString())
        is Float -> JSONObject().put("t", "f").put("v", value.toString())
        is Set<*> -> JSONObject().put("t", "set")
            .put("v", JSONArray(value.filterIsInstance<String>().sorted()))
        else -> null
    }

    private fun decodeValue(json: JSONObject): Any? {
        val v = json.opt("v")
        return when (json.optString("t")) {
            "s" -> v as? String
            "l" -> (v as? String)?.toLongOrNull()
            "i" -> (v as? String)?.toIntOrNull()
            "b" -> (v as? String)?.toBooleanStrictOrNull()
            "f" -> (v as? String)?.toFloatOrNull()
            "set" -> (v as? JSONArray)?.let { arr ->
                (0 until arr.length()).map { arr.getString(it) }.toSet()
            }
            else -> null
        }
    }

    fun sha256(text: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(text.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
}
