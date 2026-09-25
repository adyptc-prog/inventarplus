package app.sayitapp.inventar_plus

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log
import org.json.JSONArray

/**
 * Ascultă SMS-urile primite și stochează în coadă pe cele cu prefix INV:
 * (mesaje de sincronizare trimise de celălalt dispozitiv Inventar+).
 * Sunt acceptate doar mesajele de la partenerul de sincronizare configurat.
 *
 * Flutter citește coada la pornire și la revenire în foreground via
 * MethodChannel "inventarplus/sms" → getSyncMessages / clearSyncQueue.
 */
class SmsSyncReceiver : BroadcastReceiver() {

    companion object {
        const val SYNC_PREFIX = "INV:"
        const val PREFS_NAME  = "SyncQueue"
        const val QUEUE_KEY   = "queue"

        // Licența se împarte între cele două telefoane sincronizate: „L” poartă
        // fișierul de licență semnat, „R” e cererea unui telefon fără licență
        // (trimisă când își configurează partenerul după ce celălalt a făcut-o
        // deja — altfel licența trimisă atunci ar fi fost ignorată).
        const val LICENSE_PREFIX         = "INV:L:"
        const val LICENSE_REQUEST_PREFIX = "INV:R:"

        // Păstrăm doar cifrele, ca să comparăm numere indiferent de format
        // (+40712345678, 0712345678, cu spații etc.)
        private fun digitsOnly(raw: String?): String = raw.orEmpty().filter { it.isDigit() }

        /**
         * True dacă [sender] e partenerul configurat. Fără partener, niciun
         * mesaj nu e acceptat — altfel oricine ne știe numărul ar putea
         * adăuga/modifica/șterge produse sau trimite o licență trimițând un
         * SMS "INV:...".
         */
        fun isFromPartner(sender: String?, partnerPhone: String?): Boolean {
            val partnerDigits = digitsOnly(partnerPhone)
            if (partnerDigits.isEmpty()) return false
            val senderDigits = digitsOnly(sender)
            val minLen = minOf(senderDigits.length, partnerDigits.length)
            if (minLen < 7) return false
            return senderDigits.takeLast(minLen) == partnerDigits.takeLast(minLen)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        val pdus = Telephony.Sms.Intents.getMessagesFromIntent(intent)
            ?: return

        val partnerPhone = context
            .getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getString("flutter.sync_partner_phone", null)

        // Grupăm PDU-urile pe expeditor și concatenăm corpul
        // (SMS multipart: toate segmentele sosesc în același broadcast)
        val bySender = mutableMapOf<String, StringBuilder>()
        for (sms in pdus) {
            val sender = sms.originatingAddress ?: continue
            val body   = sms.messageBody        ?: continue
            bySender.getOrPut(sender) { StringBuilder() }.append(body)
        }

        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        for ((sender, sb) in bySender) {
            val body = sb.toString()
            if (!body.startsWith(SYNC_PREFIX)) continue
            if (!isFromPartner(sender, partnerPhone)) continue

            if (body.startsWith(LICENSE_PREFIX)) {
                try {
                    val decision = LicenseStore.adoptFromPartner(
                        context, body.removePrefix(LICENSE_PREFIX)
                    )
                    Log.i("InvDiag", "license from partner: $decision")
                } catch (e: Exception) {
                    Log.e("InvDiag", "license from partner FAILED", e)
                }
                continue
            }
            if (body.startsWith(LICENSE_REQUEST_PREFIX)) {
                LicenseStore.shareableLicense(context)?.let {
                    SmsSender.send(context, sender, LICENSE_PREFIX + it)
                }
                continue
            }

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
