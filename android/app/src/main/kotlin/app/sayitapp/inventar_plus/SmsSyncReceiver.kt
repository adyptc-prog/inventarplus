package app.sayitapp.inventar_plus

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import org.json.JSONArray

/**
 * Ascultă SMS-urile primite și stochează în coadă pe cele cu prefix INV:
 * (mesaje de sincronizare trimise de celălalt dispozitiv Inventar+).
 *
 * Flutter citește coada la pornire și la revenire în foreground via
 * MethodChannel "inventarplus/sms" → getSyncMessages / clearSyncQueue.
 */
class SmsSyncReceiver : BroadcastReceiver() {

    companion object {
        const val SYNC_PREFIX = "INV:"
        const val PREFS_NAME  = "SyncQueue"
        const val QUEUE_KEY   = "queue"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        val pdus = Telephony.Sms.Intents.getMessagesFromIntent(intent)
            ?: return

        // Grupăm PDU-urile pe expeditor și concatenăm corpul
        // (SMS multipart: toate segmentele sosesc în același broadcast)
        val bySender = mutableMapOf<String, StringBuilder>()
        for (sms in pdus) {
            val sender = sms.originatingAddress ?: continue
            val body   = sms.messageBody        ?: continue
            bySender.getOrPut(sender) { StringBuilder() }.append(body)
        }

        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        for ((_, sb) in bySender) {
            val body = sb.toString()
            if (!body.startsWith(SYNC_PREFIX)) continue
            try {
                val existing = prefs.getString(QUEUE_KEY, "[]") ?: "[]"
                val arr = JSONArray(existing)
                arr.put(body)
                prefs.edit().putString(QUEUE_KEY, arr.toString()).apply()
            } catch (_: Exception) {
                // JSON corupt — ignorat
            }
        }
    }
}
