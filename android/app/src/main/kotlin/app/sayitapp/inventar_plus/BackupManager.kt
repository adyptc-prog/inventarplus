package app.sayitapp.inventar_plus

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.provider.DocumentsContract
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Backup / restore al datelor Inventar+ (vezi BackupFormat) într-un singur
 * folder ales de utilizator prin Storage Access Framework — pe stick-ul USB
 * sau în memoria telefonului. Același folder e folosit și de backup-ul
 * automat zilnic (InventarBackupWorker).
 */
object BackupManager {

    private const val PREFS_NAME = "BackupPrefs"
    private const val KEY_FOLDER_URI = "backup_folder_uri"
    private const val KEY_DESTINATION = "backup_destination" // "usb" | "phone"
    private const val KEY_LAST_AUTO_AT = "last_auto_backup_at"
    private const val KEY_LAST_AUTO_ERROR = "last_auto_backup_error"
    private const val KEY_LAST_MANUAL_AT = "last_manual_backup_at"
    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val SAFETY_FILE = "before_restore.invbackup"

    const val AUTO_KEEP = 14

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun flutterPrefs(context: Context): SharedPreferences =
        context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)

    // ── Folder ───────────────────────────────────────────────────────────────────
    fun folderUri(context: Context): Uri? =
        prefs(context).getString(KEY_FOLDER_URI, null)?.let(Uri::parse)

    fun setFolder(context: Context, treeUri: Uri, destination: String) {
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        // O singură destinație: eliberăm permisiunea folderului anterior.
        folderUri(context)?.takeIf { it != treeUri }?.let { old ->
            try { context.contentResolver.releasePersistableUriPermission(old, flags) } catch (_: Exception) {}
        }
        context.contentResolver.takePersistableUriPermission(treeUri, flags)
        prefs(context).edit()
            .putString(KEY_FOLDER_URI, treeUri.toString())
            .putString(KEY_DESTINATION, destination)
            .remove(KEY_LAST_AUTO_ERROR)
            .apply()
    }

    private fun folderDocumentUri(treeUri: Uri): Uri =
        DocumentsContract.buildDocumentUriUsingTree(treeUri, DocumentsContract.getTreeDocumentId(treeUri))

    private fun hasWriteAccess(context: Context, treeUri: Uri): Boolean =
        context.contentResolver.persistedUriPermissions.any {
            it.uri == treeUri && it.isWritePermission
        }

    private fun requireFolder(context: Context): Uri {
        val treeUri = folderUri(context)
            ?: throw IllegalStateException("Nu a fost ales un folder pentru backup.")
        if (!hasWriteAccess(context, treeUri)) {
            throw IllegalStateException("Aplicația nu mai are acces la folderul de backup. Alege-l din nou.")
        }
        return treeUri
    }

    private fun folderName(context: Context, treeUri: Uri): String? = try {
        context.contentResolver.query(
            folderDocumentUri(treeUri),
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null,
        )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    } catch (_: Exception) {
        null
    }

    fun status(context: Context): HashMap<String, Any?> {
        val p = prefs(context)
        val treeUri = folderUri(context)
        val accessible = treeUri != null && hasWriteAccess(context, treeUri) &&
            folderName(context, treeUri) != null
        return hashMapOf(
            "folderUri" to treeUri?.toString(),
            "folderName" to if (accessible) folderName(context, treeUri!!) else null,
            "folderAccessible" to accessible,
            "destination" to p.getString(KEY_DESTINATION, null),
            "lastAutoAt" to p.getLong(KEY_LAST_AUTO_AT, 0L).takeIf { it > 0 },
            "lastAutoError" to p.getString(KEY_LAST_AUTO_ERROR, null),
            "lastManualAt" to p.getLong(KEY_LAST_MANUAL_AT, 0L).takeIf { it > 0 },
        )
    }

    // ── Creare ───────────────────────────────────────────────────────────────────
    fun snapshot(context: Context, now: Long = System.currentTimeMillis()): String =
        BackupFormat.encode(flutterPrefs(context).all, LicenseStore.identity(context), now)

    fun createBackup(context: Context, auto: Boolean): HashMap<String, Any?> {
        val treeUri = requireFolder(context)
        val now = System.currentTimeMillis()
        val content = snapshot(context, now).toByteArray(Charsets.UTF_8)
        val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date(now))
        val prefix = if (auto) BackupFormat.AUTO_PREFIX else BackupFormat.MANUAL_PREFIX
        val name = "$prefix$stamp${BackupFormat.EXTENSION}"

        val docUri = DocumentsContract.createDocument(
            context.contentResolver, folderDocumentUri(treeUri), "application/octet-stream", name,
        ) ?: throw IllegalStateException("Nu s-a putut crea fișierul de backup.")
        try {
            context.contentResolver.openOutputStream(docUri, "w")?.use { it.write(content) }
                ?: throw IllegalStateException("Nu s-a putut scrie fișierul de backup.")
        } catch (e: Exception) {
            // Nu lăsăm în urmă un fișier gol/trunchiat care ar apărea în listă.
            try { DocumentsContract.deleteDocument(context.contentResolver, docUri) } catch (_: Exception) {}
            throw e
        }

        val p = prefs(context).edit()
        if (auto) {
            p.putLong(KEY_LAST_AUTO_AT, now).remove(KEY_LAST_AUTO_ERROR)
        } else {
            p.putLong(KEY_LAST_MANUAL_AT, now)
        }
        p.apply()
        if (auto) pruneAutoBackups(context, treeUri)

        return hashMapOf("id" to DocumentsContract.getDocumentId(docUri), "name" to name,
            "size" to content.size.toLong(), "modifiedAt" to now)
    }

    fun recordAutoError(context: Context, message: String) {
        prefs(context).edit().putString(KEY_LAST_AUTO_ERROR, message).apply()
    }

    private data class Entry(val id: String, val name: String, val modifiedAt: Long, val size: Long)

    private fun entries(context: Context, treeUri: Uri): List<Entry> {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri, DocumentsContract.getTreeDocumentId(treeUri),
        )
        return context.contentResolver.query(
            children,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                DocumentsContract.Document.COLUMN_SIZE,
            ), null, null, null,
        )?.use { c ->
            val list = mutableListOf<Entry>()
            while (c.moveToNext()) {
                val name = c.getString(1) ?: continue
                if (!name.endsWith(BackupFormat.EXTENSION)) continue
                list.add(Entry(c.getString(0), name, c.getLong(2), c.getLong(3)))
            }
            list
        } ?: emptyList()
    }

    private fun pruneAutoBackups(context: Context, treeUri: Uri) {
        val all = entries(context, treeUri)
        val toDelete = BackupFormat.autoBackupsToDelete(all.map { it.name }, AUTO_KEEP).toSet()
        for (e in all) {
            if (e.name !in toDelete) continue
            try {
                DocumentsContract.deleteDocument(
                    context.contentResolver,
                    DocumentsContract.buildDocumentUriUsingTree(treeUri, e.id),
                )
            } catch (_: Exception) {}
        }
    }

    fun listBackups(context: Context): List<HashMap<String, Any?>> {
        val treeUri = folderUri(context) ?: return emptyList()
        if (!hasWriteAccess(context, treeUri)) return emptyList()
        return entries(context, treeUri)
            .sortedByDescending { it.modifiedAt }
            .map {
                hashMapOf<String, Any?>("id" to it.id, "name" to it.name,
                    "modifiedAt" to it.modifiedAt, "size" to it.size,
                    "auto" to it.name.startsWith(BackupFormat.AUTO_PREFIX))
            }
    }

    // ── Restore ──────────────────────────────────────────────────────────────────
    private fun readText(context: Context, uri: Uri): String =
        context.contentResolver.openInputStream(uri)?.use { it.reader(Charsets.UTF_8).readText() }
            ?: throw IllegalStateException("Nu s-a putut citi fișierul de backup.")

    fun restoreFromDocumentId(context: Context, documentId: String, keepSyncPartners: Boolean) {
        val treeUri = requireFolder(context)
        val uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
        restoreContent(context, readText(context, uri), keepSyncPartners)
    }

    fun restoreFromUri(context: Context, uri: Uri, keepSyncPartners: Boolean) =
        restoreContent(context, readText(context, uri), keepSyncPartners)

    /**
     * Înlocuiește datele cu cele din backup. Ordinea contează:
     * 1. validare completă (aplicație, versiune, checksum) — înainte de orice scriere;
     * 2. copie de siguranță a stării curente (before_restore.invbackup, intern);
     * 3. înlocuirea datelor + identitatea de licență.
     *
     * Inventar+ nu are alarme native (alertele de stoc pleacă imediat, la
     * mișcarea de stoc), deci nu e nimic de anulat sau de reprogramat. Coada de
     * sincronizare SMS nu se golește — s-ar pierde mesajele de la partener.
     */
    fun restoreContent(context: Context, content: String, keepSyncPartners: Boolean) {
        val backup = BackupFormat.decode(content)

        File(context.filesDir, SAFETY_FILE).writeText(snapshot(context), Charsets.UTF_8)

        val flutter = flutterPrefs(context)
        val current = flutter.all

        val merged = BackupFormat.mergeForRestore(current, backup.prefs, keepSyncPartners)
        val editor = flutter.edit()
        for (key in current.keys) {
            if (key.startsWith("flutter.")) editor.remove(key)
        }
        for ((key, value) in merged) {
            @Suppress("UNCHECKED_CAST")
            when (value) {
                is String -> editor.putString(key, value)
                is Long -> editor.putLong(key, value)
                is Int -> editor.putInt(key, value)
                is Boolean -> editor.putBoolean(key, value)
                is Float -> editor.putFloat(key, value)
                is Set<*> -> editor.putStringSet(key, value as Set<String>)
            }
        }
        if (!editor.commit()) throw IllegalStateException("Nu s-au putut salva datele restaurate.")

        LicenseStore.restoreIdentity(context, backup.identity)
    }
}
