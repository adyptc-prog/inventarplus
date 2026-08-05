package app.sayitapp.inventar_plus

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.telephony.SmsManager
import android.util.Base64
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyFactory
import java.security.Signature
import java.security.spec.X509EncodedKeySpec

class MainActivity : FlutterActivity() {

    companion object {
        const val SMS_CHANNEL     = "inventarplus/sms"
        const val LICENSE_CHANNEL = "inventarplus/license"
        private const val REQ_RECEIVE_SMS = 1002
        private const val KEY_LICENSE_URI = "license_uri"
        private const val PICK_LICENSE_REQUEST_CODE = 8021

        // Cheia publică RSA-2048 (DER/X.509, base64) — corespunde tools/private.pem
        private const val PUBLIC_KEY_B64 =
            "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAkkl+Dq5BabpA0LP14dx3" +
            "ocx34ZY7SHS+X6DZyuGupgoPnKUmBdG7qvmhj/vizaWcgjiQwz7hVDOFFhLiBVc6" +
            "svTpCEWPu/WuLvYiXCqclezp7NhQRALoHvS0SH1k51xx+xXmqnh1JLSI70ay43KR" +
            "FnRdOZFIaChka9r72M2UdIQ0OmhD+undCdkHek/DJJZiKwkEw55tbk2Slq5H5cpS" +
            "IUqJ6PmpLgGpsOytBmpNhoLaCxtJDKw8OxO2Oh+oShFmfPU5LPCOi/1aDQ43OYVu" +
            "n568Vbt1cSW44/IBXzHNKw5mqPlbAB6i/P1ld3aoNmTqi9ZgO9wEjtziBDGjkp+7" +
            "uwIDAQAB"
    }

    // Token .invtoken primit prin intent, așteptând ca Flutter să fie gata
    private var pendingLicenseToken: String? = null

    // Fluxul nou de licențiere (businessId + expirare, format identic cu Fidelio)
    private var pendingLicensePickResult: MethodChannel.Result? = null

    // ── Lifecycle ────────────────────────────────────────────────────────────────
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        extractTokenFromIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        extractTokenFromIntent(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_LICENSE_REQUEST_CODE) return

        val result = pendingLicensePickResult ?: return
        pendingLicensePickResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.error("LICENSE_PICK_CANCELLED", "No license file was selected.", null)
            return
        }

        try {
            val flags = data.flags and
                (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            contentResolver.takePersistableUriPermission(uri, flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
            getSharedPreferences("LicensePrefs", Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_LICENSE_URI, uri.toString())
                .apply()
            result.success(uri.toString())
        } catch (error: Exception) {
            result.error("LICENSE_PICK_FAILED", error.message ?: error.toString(), null)
        }
    }

    private fun extractTokenFromIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        val uri = intent.data ?: return
        try {
            val content = contentResolver.openInputStream(uri)?.use {
                it.readBytes().toString(Charsets.UTF_8)
            } ?: return
            // Validare rapidă: trebuie să conțină identificatorul aplicației
            if (content.contains("\"inventarplus\"")) {
                pendingLicenseToken = content
            }
        } catch (_: Exception) {}
    }

    // ── Flutter Engine ───────────────────────────────────────────────────────────
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Canal SMS (trimitere imediată + sincronizare) ─────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SMS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "sendSms" -> {
                        val phone = call.argument<String>("phone")
                            ?: run { result.error("ARG", "missing phone", null); return@setMethodCallHandler }
                        val message = call.argument<String>("message")
                            ?: run { result.error("ARG", "missing message", null); return@setMethodCallHandler }
                        sendSmsNow(phone, message)
                        result.success(null)
                    }

                    "requestReceiveSms" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            if (ContextCompat.checkSelfPermission(
                                    this, Manifest.permission.RECEIVE_SMS
                                ) != PackageManager.PERMISSION_GRANTED
                            ) {
                                ActivityCompat.requestPermissions(
                                    this,
                                    arrayOf(Manifest.permission.RECEIVE_SMS),
                                    REQ_RECEIVE_SMS
                                )
                            }
                        }
                        result.success(null)
                    }

                    "getSyncMessages" -> {
                        val prefs = getSharedPreferences(
                            SmsSyncReceiver.PREFS_NAME, Context.MODE_PRIVATE
                        )
                        result.success(
                            prefs.getString(SmsSyncReceiver.QUEUE_KEY, "[]") ?: "[]"
                        )
                    }

                    "clearSyncQueue" -> {
                        getSharedPreferences(SmsSyncReceiver.PREFS_NAME, Context.MODE_PRIVATE)
                            .edit()
                            .putString(SmsSyncReceiver.QUEUE_KEY, "[]")
                            .apply()
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }

        // ── Canal Licență ─────────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LICENSE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "isLicensed" -> {
                        val prefs = getSharedPreferences("LicensePrefs", Context.MODE_PRIVATE)
                        result.success(prefs.getBoolean("licensed", false))
                    }

                    "getPendingToken" -> {
                        result.success(pendingLicenseToken)
                        pendingLicenseToken = null
                    }

                    "getLicenseBackup" -> {
                        val prefs = getSharedPreferences("LicensePrefs", Context.MODE_PRIVATE)
                        result.success(prefs.getString("token_backup", null))
                    }

                    "verifyAndActivate" -> {
                        val token = call.argument<String>("token")
                            ?: run { result.error("ARG", "missing token", null); return@setMethodCallHandler }
                        val res = verifyAndActivate(token)
                        result.success(mapOf("success" to res.first, "msg" to res.second))
                    }

                    // ── Flux nou: licență cu businessId + expirare, cumpărată de pe site ──
                    "getBusinessId" -> result.success(getOrCreateBusinessId())
                    "checkLicense" -> checkLicense(result)
                    "pickLicenseFile" -> pickLicenseFile(result)

                    else -> result.notImplemented()
                }
            }
    }

    // ── Verificare și activare licență ───────────────────────────────────────────
    private fun verifyAndActivate(tokenJson: String): Pair<Boolean, String> {
        return try {
            val prefs      = getSharedPreferences("LicensePrefs", Context.MODE_PRIVATE)
            val usedIdsJson = prefs.getString("used_ids", "[]") ?: "[]"
            val usedArr    = JSONArray(usedIdsJson)
            val usedSet    = (0 until usedArr.length()).map { usedArr.getString(it) }.toSet()

            // Acceptăm și un singur obiect JSON (nu doar array)
            val tokens = if (tokenJson.trim().startsWith("[")) {
                JSONArray(tokenJson)
            } else {
                JSONArray().apply { put(JSONObject(tokenJson)) }
            }

            // Încarcă cheia publică (SPKI/X.509 DER, base64 concatenat)
            val keyBytes  = Base64.decode(PUBLIC_KEY_B64.replace("\\s".toRegex(), ""), Base64.DEFAULT)
            val publicKey = KeyFactory.getInstance("RSA")
                .generatePublic(X509EncodedKeySpec(keyBytes))

            for (i in 0 until tokens.length()) {
                val t      = tokens.getJSONObject(i)
                val id     = t.optString("id", "")
                val app    = t.optString("app", "")
                val issued = t.optString("issued", "")
                val sigB64 = t.optString("sig", "")

                if (id.isEmpty() || sigB64.isEmpty()) continue
                if (app != "inventarplus") continue
                if (id in usedSet) continue          // deja folosit pe acest dispozitiv

                val data = "inventarplus:${id}:${issued}".toByteArray(Charsets.UTF_8)
                val sig  = Base64.decode(sigB64, Base64.DEFAULT)

                val verifier = Signature.getInstance("SHA256withRSA")
                verifier.initVerify(publicKey)
                verifier.update(data)

                if (verifier.verify(sig)) {
                    // Valid — stocăm activarea + o copie brută a fișierului
                    // primit, ca utilizatorul să o poată retrimite oricând
                    // dacă schimbă telefonul sau șterge datele aplicației
                    // (fără copie, tokenul original e singura dovadă de
                    // licență și nu mai poate fi recreat).
                    usedArr.put(id)
                    prefs.edit()
                        .putBoolean("licensed", true)
                        .putString("used_ids", usedArr.toString())
                        .putString("token_backup", tokenJson)
                        .apply()
                    return Pair(true, "Licență activată cu succes!")
                }
            }

            Pair(false, "Token invalid sau deja utilizat pe acest dispozitiv.")
        } catch (e: Exception) {
            Pair(false, "Eroare la verificare: ${e.message}")
        }
    }

    // ── Flux nou de licențiere (identic ca format cu Fidelio) ────────────────────
    private fun getOrCreateBusinessId(): String {
        val prefs = getSharedPreferences("LicensePrefs", Context.MODE_PRIVATE)
        val existing = prefs.getString("business_id", null)
        if (existing != null) return existing
        val fresh = "inventarplus-${System.currentTimeMillis()}"
        prefs.edit().putString("business_id", fresh).apply()
        return fresh
    }

    private data class LicenseSource(val content: String, val path: String)

    private fun readSelectedLicense(): LicenseSource? {
        val uriText = getSharedPreferences("LicensePrefs", Context.MODE_PRIVATE)
            .getString(KEY_LICENSE_URI, null) ?: return null
        return try {
            val uri = Uri.parse(uriText)
            val content = contentResolver.openInputStream(uri)?.use { input ->
                input.reader(Charsets.UTF_8).readText()
            } ?: return null
            LicenseSource(content = content, path = uriText)
        } catch (_: Exception) {
            null
        }
    }

    private fun pickLicenseFile(result: MethodChannel.Result) {
        if (pendingLicensePickResult != null) {
            result.error("LICENSE_PICK_BUSY", "A license picker is already open.", null)
            return
        }

        pendingLicensePickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "text/*", "application/octet-stream"))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, PICK_LICENSE_REQUEST_CODE)
    }

    // Anti-clock-manipulation: monotonically non-decreasing "effective now",
    // identical logic to Fidelio's getEffectiveNow().
    private fun getEffectiveNow(): Long {
        val prefs = getSharedPreferences("LicensePrefs", Context.MODE_PRIVATE)
        val lastMs = prefs.getLong("last_license_check", 0L)
        val deviceNow = System.currentTimeMillis()
        val effectiveNow = if (deviceNow < lastMs - 60_000L) lastMs else maxOf(deviceNow, lastMs)
        prefs.edit().putLong("last_license_check", effectiveNow).apply()
        return effectiveNow
    }

    private fun parseIso8601Utc(dateStr: String?): Long? {
        if (dateStr.isNullOrBlank()) return null
        return try {
            java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", java.util.Locale.US).apply {
                timeZone = java.util.TimeZone.getTimeZone("UTC")
            }.parse(dateStr)?.time
        } catch (_: Exception) {
            null
        }
    }

    private fun licenseResult(status: String, message: String, path: String?): HashMap<String, Any?> {
        val data = HashMap<String, Any?>()
        data["status"] = status
        data["message"] = message
        data["path"] = path
        return data
    }

    // Trebuie să fie identic byte-cu-byte cu canonicalLicensePayload() din
    // voltacademy_web/lib/licenseSigner.js — nu schimba ordinea câmpurilor.
    private fun canonicalLicensePayload(payload: JSONObject): String {
        return listOf(
            payload.optString("licenseId"),
            payload.optString("businessId"),
            payload.optString("stickId"),
            payload.optString("issuedAt"),
            payload.optBoolean("isLifetime", false).toString(),
            if (payload.isNull("validUntil")) "" else payload.optString("validUntil"),
        ).joinToString("|")
    }

    private fun verifyLicenseSignature(payload: JSONObject, signatureBase64: String): Boolean {
        if (signatureBase64.isBlank()) {
            return false
        }
        val canonical = canonicalLicensePayload(payload)
        val signatureBytes = Base64.decode(signatureBase64, Base64.DEFAULT)
        val keyBytes = Base64.decode(PUBLIC_KEY_B64.replace("\\s".toRegex(), ""), Base64.DEFAULT)
        val publicKey = KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(keyBytes))
        val verifier = Signature.getInstance("SHA256withRSA")
        verifier.initVerify(publicKey)
        verifier.update(canonical.toByteArray(Charsets.UTF_8))
        return verifier.verify(signatureBytes)
    }

    private fun checkLicense(result: MethodChannel.Result) {
        val businessId = getOrCreateBusinessId()
        val licenseSource = readSelectedLicense()
        if (licenseSource == null) {
            result.success(licenseResult("missing", "No license file selected.", null))
            return
        }

        try {
            val root = JSONObject(licenseSource.content)
            val payload = root.getJSONObject("payload")
            val signature = root.optString("signature")
            val licenseBusinessId = payload.optString("businessId")
            val isLifetime = payload.optBoolean("isLifetime", false)
            val validUntilStr = if (payload.isNull("validUntil")) null
                                else payload.optString("validUntil").takeIf { it.isNotBlank() }
            val issuedAtStr = payload.optString("issuedAt")

            if (licenseBusinessId != businessId) {
                result.success(licenseResult("invalid", "License belongs to another installation.", licenseSource.path))
                return
            }

            val effectiveNow = getEffectiveNow()

            val issuedAtMs = parseIso8601Utc(issuedAtStr)
            if (issuedAtMs != null && effectiveNow < issuedAtMs) {
                result.success(licenseResult("invalid", "Device clock is set before the license issue date.", licenseSource.path))
                return
            }

            if (!isLifetime) {
                val validUntilMs = parseIso8601Utc(validUntilStr)
                if (validUntilMs == null) {
                    result.success(licenseResult("invalid", "License has no valid expiry date.", licenseSource.path))
                    return
                }
                if (effectiveNow >= validUntilMs) {
                    result.success(licenseResult("invalid", "License has expired.", licenseSource.path))
                    return
                }
            }

            if (!verifyLicenseSignature(payload, signature)) {
                result.success(licenseResult("invalid", "License signature is invalid.", licenseSource.path))
                return
            }

            val data = HashMap<String, Any?>()
            data["status"] = "active"
            data["path"] = licenseSource.path
            data["licenseId"] = payload.optString("licenseId")
            data["isLifetime"] = isLifetime

            if (!isLifetime && validUntilStr != null) {
                val validUntilMs = parseIso8601Utc(validUntilStr)!!
                val daysRemaining = ((validUntilMs - effectiveNow) / (24L * 60L * 60L * 1000L)).toInt()
                data["validUntil"] = validUntilStr
                data["daysUntilExpiry"] = daysRemaining
                data["message"] = if (daysRemaining <= 1) "License expires tomorrow."
                                   else "License active. $daysRemaining days remaining."
            } else {
                data["message"] = "Lifetime license active."
            }

            result.success(data)
        } catch (error: Exception) {
            result.success(licenseResult("invalid", error.message ?: error.toString(), licenseSource.path))
        }
    }

    // ── SMS imediat (multipart dacă depășește 160 caractere) ─────────────────────
    private fun sendSmsNow(phone: String, message: String) {
        try {
            val smsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                getSystemService(SmsManager::class.java)
            } else {
                @Suppress("DEPRECATION")
                SmsManager.getDefault()
            }
            val parts = smsManager?.divideMessage(message)
            if (parts != null && parts.size > 1) {
                smsManager.sendMultipartTextMessage(phone, null, parts, null, null)
            } else {
                smsManager?.sendTextMessage(phone, null, message, null, null)
            }
        } catch (_: Exception) {}
    }
}
