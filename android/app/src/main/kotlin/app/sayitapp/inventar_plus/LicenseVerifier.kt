package app.sayitapp.inventar_plus

import org.json.JSONObject
import java.security.KeyFactory
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/**
 * Rezultatul verificării unui fișier de licență (format identic cu Fidelio).
 * [businessId] e codul de instalare din licență — util la preluarea licenței
 * de la telefonul partener, unde nu îl știm dinainte.
 */
data class LicenseCheck(
    val status: String,
    val message: String,
    val businessId: String? = null,
    val licenseId: String? = null,
    val isLifetime: Boolean = false,
    val validUntil: String? = null,
    val validUntilMs: Long? = null,
    val daysUntilExpiry: Int? = null,
) {
    val isActive: Boolean get() = status == "active"

    fun toMap(path: String?): HashMap<String, Any?> {
        val data = HashMap<String, Any?>()
        data["status"] = status
        data["message"] = message
        data["path"] = path
        if (isActive) {
            data["licenseId"] = licenseId
            data["isLifetime"] = isLifetime
            data["validUntil"] = validUntil
            data["daysUntilExpiry"] = daysUntilExpiry
        }
        return data
    }
}

/** Ce face telefonul când primește o licență de la partenerul de sincronizare. */
enum class AdoptionDecision {
    /** Licența primită e invalidă sau expirată — ignorată. */
    REJECT_INVALID,
    /** Telefonul are deja o licență activă pe alt cod de instalare — nu o suprascriem. */
    KEEP_OWN,
    /** Aceeași licență sau una care nu expiră mai târziu — nimic de schimbat. */
    ALREADY_UP_TO_DATE,
    /** Preia codul de instalare și licența partenerului. */
    ADOPT,
    /** Același cod de instalare, licență reînnoită — înlocuiește licența stocată. */
    RENEW,
}

/**
 * Logică pură (fără Android) — testabilă pe JVM. Base64 e injectat pentru că
 * android.util.Base64 nu există în testele JVM, iar java.util.Base64 cere
 * API 26 (minSdk e 24).
 */
class LicenseVerifier(
    private val publicKeyDer: ByteArray,
    private val decodeBase64: (String) -> ByteArray,
) {

    /**
     * [expectedBusinessId] null = nu verifica legătura cu instalarea (folosit
     * la licența primită de la partener, al cărei cod îl preluăm).
     */
    fun evaluate(content: String, expectedBusinessId: String?, nowMs: Long): LicenseCheck {
        return try {
            val root = JSONObject(content)
            val payload = root.getJSONObject("payload")
            val signature = root.optString("signature")
            val licenseBusinessId = payload.optString("businessId")
            val isLifetime = payload.optBoolean("isLifetime", false)
            val validUntilStr = if (payload.isNull("validUntil")) null
                                else payload.optString("validUntil").takeIf { it.isNotBlank() }
            val issuedAtStr = payload.optString("issuedAt")

            if (licenseBusinessId.isBlank()) {
                return LicenseCheck("invalid", "License has no installation code.")
            }
            if (expectedBusinessId != null && licenseBusinessId != expectedBusinessId) {
                return LicenseCheck("invalid", "License belongs to another installation.")
            }

            val issuedAtMs = parseIso8601Utc(issuedAtStr)
            if (issuedAtMs != null && nowMs < issuedAtMs) {
                return LicenseCheck("invalid", "Device clock is set before the license issue date.")
            }

            var validUntilMs: Long? = null
            if (!isLifetime) {
                validUntilMs = parseIso8601Utc(validUntilStr)
                    ?: return LicenseCheck("invalid", "License has no valid expiry date.")
                if (nowMs >= validUntilMs) {
                    return LicenseCheck("invalid", "License has expired.")
                }
            }

            if (!verifySignature(payload, signature)) {
                return LicenseCheck("invalid", "License signature is invalid.")
            }

            if (isLifetime || validUntilMs == null) {
                LicenseCheck(
                    status = "active",
                    message = "Lifetime license active.",
                    businessId = licenseBusinessId,
                    licenseId = payload.optString("licenseId"),
                    isLifetime = true,
                )
            } else {
                val daysRemaining = ((validUntilMs - nowMs) / DAY_MS).toInt()
                LicenseCheck(
                    status = "active",
                    message = if (daysRemaining <= 1) "License expires tomorrow."
                              else "License active. $daysRemaining days remaining.",
                    businessId = licenseBusinessId,
                    licenseId = payload.optString("licenseId"),
                    isLifetime = false,
                    validUntil = validUntilStr,
                    validUntilMs = validUntilMs,
                    daysUntilExpiry = daysRemaining,
                )
            }
        } catch (error: Exception) {
            LicenseCheck("invalid", error.message ?: error.toString())
        }
    }

    // Trebuie să fie identic byte-cu-byte cu canonicalLicensePayload() din
    // voltacademy_web/lib/licenseSigner.js — nu schimba ordinea câmpurilor.
    fun canonicalLicensePayload(payload: JSONObject): String {
        return listOf(
            payload.optString("licenseId"),
            payload.optString("businessId"),
            payload.optString("stickId"),
            payload.optString("issuedAt"),
            payload.optBoolean("isLifetime", false).toString(),
            if (payload.isNull("validUntil")) "" else payload.optString("validUntil"),
        ).joinToString("|")
    }

    private fun verifySignature(payload: JSONObject, signatureBase64: String): Boolean {
        if (signatureBase64.isBlank()) return false
        val publicKey = KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(publicKeyDer))
        val verifier = Signature.getInstance("SHA256withRSA")
        verifier.initVerify(publicKey)
        verifier.update(canonicalLicensePayload(payload).toByteArray(Charsets.UTF_8))
        return verifier.verify(decodeBase64(signatureBase64))
    }

    companion object {
        private const val DAY_MS = 24L * 60L * 60L * 1000L

        fun parseIso8601Utc(dateStr: String?): Long? {
            if (dateStr.isNullOrBlank()) return null
            return try {
                SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
                    timeZone = TimeZone.getTimeZone("UTC")
                }.parse(dateStr)?.time
            } catch (_: Exception) {
                null
            }
        }

        /**
         * Regulile de preluare a licenței de la telefonul partener:
         * - licența primită trebuie să fie validă (semnătură + neexpirată);
         * - o licență activă proprie, pe alt cod de instalare, nu se suprascrie;
         * - pe același cod, se acceptă doar o licență care expiră mai târziu
         *   (reînnoire cumpărată pe celălalt telefon).
         */
        fun decideAdoption(
            current: LicenseCheck?,
            currentBusinessId: String,
            incoming: LicenseCheck,
        ): AdoptionDecision {
            if (!incoming.isActive) return AdoptionDecision.REJECT_INVALID
            if (current == null || !current.isActive) {
                return if (incoming.businessId == currentBusinessId) AdoptionDecision.RENEW
                       else AdoptionDecision.ADOPT
            }
            if (incoming.businessId != currentBusinessId) return AdoptionDecision.KEEP_OWN
            if (current.isLifetime) return AdoptionDecision.ALREADY_UP_TO_DATE
            if (incoming.isLifetime) return AdoptionDecision.RENEW
            val currentUntil = current.validUntilMs ?: 0L
            val incomingUntil = incoming.validUntilMs ?: 0L
            return if (incomingUntil > currentUntil) AdoptionDecision.RENEW
                   else AdoptionDecision.ALREADY_UP_TO_DATE
        }
    }
}
