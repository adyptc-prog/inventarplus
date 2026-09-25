package app.sayitapp.inventar_plus

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.Calendar
import java.util.concurrent.TimeUnit

/**
 * Backup automat zilnic (în jurul miezului nopții) în folderul ales de
 * utilizator. Fără folder ales nu face nimic. Eșecul (stick scos, acces
 * pierdut la folder) nu se reîncearcă — e înregistrat și afișat în ecranul
 * Backup, ca utilizatorul să afle de el.
 */
class InventarBackupWorker(
    private val appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        if (BackupManager.folderUri(appContext) == null) return Result.success()
        try {
            BackupManager.createBackup(appContext, auto = true)
        } catch (e: Exception) {
            BackupManager.recordAutoError(appContext, e.message ?: e.toString())
        }
        return Result.success()
    }

    companion object {
        private const val WORK_NAME = "inventarplus_daily_backup"

        fun schedule(context: Context) {
            val now = Calendar.getInstance()
            val nextMidnight = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, 0)
                set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
                add(Calendar.DAY_OF_YEAR, 1)
            }
            val request = PeriodicWorkRequestBuilder<InventarBackupWorker>(1, TimeUnit.DAYS)
                .setInitialDelay(nextMidnight.timeInMillis - now.timeInMillis, TimeUnit.MILLISECONDS)
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request,
            )
        }
    }
}
