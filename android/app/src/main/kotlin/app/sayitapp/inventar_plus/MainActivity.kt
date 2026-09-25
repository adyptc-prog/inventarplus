package app.sayitapp.inventar_plus

import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.DocumentsContract
import android.util.Base64
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
        const val BACKUP_CHANNEL  = "inventarplus/backup"
        private const val PICK_LICENSE_REQUEST_CODE = 8021
        private const val PICK_BACKUP_FOLDER_REQUEST_CODE = 8022
        private const val PICK_RESTORE_BACKUP_REQUEST_CODE = 8023

    }

    // Token .invtoken primit prin intent, așteptând ca Flutter să fie gata
    private var pendingLicenseToken: String? = null

    // Fluxul nou de licențiere (businessId + expirare, format identic cu Fidelio)
    private var pendingLicensePickResult: MethodChannel.Result? = null

    // Backup: selectoarele de folder / fișier așteaptă rezultatul activității
    private var pendingBackupFolderResult: MethodChannel.Result? = null
    private var pendingBackupDestination: String = "phone"
    private var pendingRestoreResult: MethodChannel.Result? = null
    private var pendingRestoreKeepPartners: Boolean = true

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
        when (requestCode) {
            PICK_BACKUP_FOLDER_REQUEST_CODE -> { handleBackupFolderResult(resultCode, data); return }
            PICK_RESTORE_BACKUP_REQUEST_CODE -> { handleRestoreResult(resultCode, data); return }
        }
        if (requestCode != PICK_LICENSE_REQUEST_CODE) return

        val result = pendingLicensePickResult ?: return
        pendingLicensePickResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.error("LICENSE_PICK_CANCELLED", "No license file was selected.", null)
            return
        }

        try {
            val content = contentResolver.openInputStream(uri)?.use {
                it.reader(Charsets.UTF_8).readText()
            } ?: throw IllegalStateException("Could not read license file.")
            result.success(LicenseStore.importLicense(this, content).toMap(uri.toString()))
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
        InventarBackupWorker.schedule(applicationContext)

        // ── Canal Backup ──────────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BACKUP_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getStatus" -> runInBackground(result, "BACKUP_STATUS_FAILED") {
                        BackupManager.status(this)
                    }
                    "pickFolder" -> pickBackupFolder(call.argument<String>("destination") ?: "phone", result)
                    "createBackup" -> runInBackground(result, "BACKUP_CREATE_FAILED") {
                        BackupManager.createBackup(this, auto = false)
                    }
                    "listBackups" -> runInBackground(result, "BACKUP_LIST_FAILED") {
                        BackupManager.listBackups(this)
                    }
                    "restoreBackup" -> {
                        val id = call.argument<String>("id")
                            ?: run { result.error("ARG", "missing id", null); return@setMethodCallHandler }
                        val keep = call.argument<Boolean>("keepSyncPartners") ?: true
                        runInBackground(result, "BACKUP_RESTORE_FAILED") {
                            BackupManager.restoreFromDocumentId(this, id, keep); null
                        }
                    }
                    "pickAndRestoreBackup" -> pickAndRestoreBackup(
                        call.argument<Boolean>("keepSyncPartners") ?: true, result
                    )
                    else -> result.notImplemented()
                }
            }


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

                    "getSmsFailure" -> result.success(SmsStatus.pendingFailure(this))

                    "dismissSmsFailure" -> {
                        SmsStatus.dismiss(this)
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
                    "getBusinessId" -> result.success(LicenseStore.getOrCreateBusinessId(this))
                    "checkLicense" -> result.success(LicenseStore.check(this).toMap(null))
                    "pickLicenseFile" -> pickLicenseFile(result)
                    "getShareableLicense" -> result.success(LicenseStore.shareableLicense(this))
                    "consumePartnerNotice" -> result.success(LicenseStore.consumePartnerNotice(this))

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
            val keyBytes  = Base64.decode(LicenseStore.PUBLIC_KEY_B64, Base64.DEFAULT)
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
    // Verificarea și stocarea sunt în LicenseStore.
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
        }
        startActivityForResult(intent, PICK_LICENSE_REQUEST_CODE)
    }

    // ── Backup ───────────────────────────────────────────────────────────────────
    // Operațiile pe fișiere (stick USB) nu blochează interfața.
    private fun runInBackground(result: MethodChannel.Result, errorCode: String, work: () -> Any?) {
        Thread {
            try {
                val value = work()
                runOnUiThread { result.success(value) }
            } catch (e: Exception) {
                runOnUiThread { result.error(errorCode, e.message ?: e.toString(), null) }
            }
        }.start()
    }

    private fun pickBackupFolder(destination: String, result: MethodChannel.Result) {
        if (pendingBackupFolderResult != null) {
            result.error("BACKUP_PICK_BUSY", "A backup folder picker is already open.", null)
            return
        }
        pendingBackupFolderResult = result
        pendingBackupDestination = destination
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            // Memoria telefonului: pornim din Documents, unde backup-ul
            // supraviețuiește dezinstalării aplicației.
            if (destination == "phone" && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(
                    DocumentsContract.EXTRA_INITIAL_URI,
                    DocumentsContract.buildDocumentUri(
                        "com.android.externalstorage.documents", "primary:Documents"
                    )
                )
            }
        }
        startActivityForResult(intent, PICK_BACKUP_FOLDER_REQUEST_CODE)
    }

    private fun handleBackupFolderResult(resultCode: Int, data: Intent?) {
        val result = pendingBackupFolderResult ?: return
        pendingBackupFolderResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.error("BACKUP_PICK_CANCELLED", "No backup folder was selected.", null)
            return
        }
        runInBackground(result, "BACKUP_PICK_FAILED") {
            BackupManager.setFolder(this, uri, pendingBackupDestination)
            BackupManager.status(this)
        }
    }

    private fun pickAndRestoreBackup(keepSyncPartners: Boolean, result: MethodChannel.Result) {
        if (pendingRestoreResult != null) {
            result.error("RESTORE_PICK_BUSY", "A backup picker is already open.", null)
            return
        }
        pendingRestoreResult = result
        pendingRestoreKeepPartners = keepSyncPartners
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivityForResult(intent, PICK_RESTORE_BACKUP_REQUEST_CODE)
    }

    private fun handleRestoreResult(resultCode: Int, data: Intent?) {
        val result = pendingRestoreResult ?: return
        pendingRestoreResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.error("RESTORE_PICK_CANCELLED", "No backup file was selected.", null)
            return
        }
        val keep = pendingRestoreKeepPartners
        runInBackground(result, "BACKUP_RESTORE_FAILED") {
            BackupManager.restoreFromUri(this, uri, keep); null
        }
    }

    // ── SMS imediat (multipart + raport de trimitere) ────────────────────────────
    private fun sendSmsNow(phone: String, message: String) {
        SmsSender.send(this, phone, message)
    }
}
