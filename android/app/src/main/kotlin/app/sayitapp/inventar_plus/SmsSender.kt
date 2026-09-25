package app.sayitapp.inventar_plus

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.telephony.SmsManager
import android.util.Log
import java.util.concurrent.atomic.AtomicInteger

/**
 * Trimiterea tuturor SMS-urilor aplicației (alerte de stoc, sincronizare,
 * licență).
 *
 * - Mesajul e împărțit mereu în segmente: un SMS cu diacritice (ă, ș, ț, î)
 *   încape în doar 70 de caractere, iar sendTextMessage() cu un text mai lung
 *   eșuează fără nicio eroare vizibilă.
 * - Fiecare trimitere cere raportul de trimitere de la sistem (SmsSentReceiver);
 *   eșecurile sunt înregistrate în SmsStatus și afișate în aplicație.
 */
object SmsSender {

    private val requestCodes = AtomicInteger((System.currentTimeMillis() % 1_000_000).toInt())

    fun send(context: Context, phone: String, message: String) {
        val app = context.applicationContext
        try {
            val smsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                app.getSystemService(SmsManager::class.java)
            } else {
                @Suppress("DEPRECATION")
                SmsManager.getDefault()
            } ?: throw IllegalStateException("Serviciul SMS nu este disponibil pe acest telefon.")

            val parts = smsManager.divideMessage(message)
            val sentIntents = ArrayList<PendingIntent>(parts.size)
            for (i in parts.indices) sentIntents.add(sentIntent(app, phone))

            if (parts.size > 1) {
                smsManager.sendMultipartTextMessage(phone, null, parts, sentIntents, null)
            } else {
                smsManager.sendTextMessage(phone, null, message, sentIntents.firstOrNull(), null)
            }
            Log.i("InvDiag", "SmsSender: queued to=$phone parts=${parts.size} len=${message.length}")
        } catch (e: SecurityException) {
            Log.e("InvDiag", "SmsSender: no permission to=$phone", e)
            SmsStatus.recordFailure(app, phone, SmsStatus.PERMISSION_MISSING)
        } catch (e: Exception) {
            Log.e("InvDiag", "SmsSender: FAILED to=$phone", e)
            SmsStatus.recordFailure(app, phone, e.message ?: e.toString())
        }
    }

    private fun sentIntent(context: Context, phone: String): PendingIntent {
        val intent = Intent(context, SmsSentReceiver::class.java).apply {
            putExtra(SmsSentReceiver.EXTRA_PHONE, phone)
        }
        val flags = PendingIntent.FLAG_ONE_SHOT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        // Cod unic per segment — altfel PendingIntent-urile s-ar suprapune.
        return PendingIntent.getBroadcast(context, requestCodes.incrementAndGet(), intent, flags)
    }
}

/** Primește de la sistem rezultatul fiecărui segment SMS trimis. */
class SmsSentReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val phone = intent.getStringExtra(EXTRA_PHONE).orEmpty()
        if (resultCode == Activity.RESULT_OK) {
            SmsStatus.recordSuccess(context)
        } else {
            Log.e("InvDiag", "SmsSentReceiver: FAILED to=$phone code=$resultCode")
            SmsStatus.recordFailure(context, phone, SmsStatus.describe(resultCode))
        }
    }

    companion object {
        const val EXTRA_PHONE = "phone"
    }
}
