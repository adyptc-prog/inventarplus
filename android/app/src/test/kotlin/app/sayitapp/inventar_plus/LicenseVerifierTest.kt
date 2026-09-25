package app.sayitapp.inventar_plus

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/**
 * Fixture-ul license_fixtures.json e generat cu signLicense() din
 * voltacademy_web/lib/licenseSigner.js (cu o cheie de test), deci testele
 * verifică și compatibilitatea byte-cu-byte dintre site și aplicație.
 */
class LicenseVerifierTest {

    private val fixtures = JSONObject(
        javaClass.classLoader!!.getResource("license_fixtures.json")!!.readText()
    )
    private val decoder: (String) -> ByteArray = { Base64.getMimeDecoder().decode(it) }
    private val verifier = LicenseVerifier(
        decoder(fixtures.getString("publicKeyDerB64")), decoder
    )

    private val ownId = "inventarplus-1700000000000"
    private val now = LicenseVerifier.parseIso8601Utc("2027-01-01T00:00:00Z")!!

    private fun license(name: String): String = fixtures.getJSONObject(name).toString()

    private fun tampered(name: String, field: String, value: Any): String {
        val root = fixtures.getJSONObject(name)
        val copy = JSONObject(root.toString())
        copy.getJSONObject("payload").put(field, value)
        return copy.toString()
    }

    @Test
    fun `licenta semnata de site e activa`() {
        val r = verifier.evaluate(license("timed"), ownId, now)
        assertTrue(r.message, r.isActive)
        assertEquals(ownId, r.businessId)
        assertFalse(r.isLifetime)
        assertEquals("2030-01-01T00:00:00Z", r.validUntil)
        assertEquals(1096, r.daysUntilExpiry)
    }

    @Test
    fun `licenta pe viata e activa`() {
        val r = verifier.evaluate(license("lifetime"), ownId, now)
        assertTrue(r.isActive)
        assertTrue(r.isLifetime)
        assertEquals("Lifetime license active.", r.message)
    }

    @Test
    fun `alt cod de instalare e respins`() {
        val r = verifier.evaluate(license("otherInstall"), ownId, now)
        assertEquals("invalid", r.status)
        assertEquals("License belongs to another installation.", r.message)
    }

    @Test
    fun `fara cod asteptat se accepta orice instalare (licenta de la partener)`() {
        val r = verifier.evaluate(license("otherInstall"), null, now)
        assertTrue(r.isActive)
        assertEquals("inventarplus-1800000000000", r.businessId)
    }

    @Test
    fun `licenta expirata e respinsa`() {
        val later = LicenseVerifier.parseIso8601Utc("2030-01-01T00:00:00Z")!!
        val r = verifier.evaluate(license("timed"), ownId, later)
        assertEquals("License has expired.", r.message)
    }

    @Test
    fun `ceas dat inapoi inainte de emitere e respins`() {
        val before = LicenseVerifier.parseIso8601Utc("2020-01-01T00:00:00Z")!!
        val r = verifier.evaluate(license("timed"), ownId, before)
        assertEquals("Device clock is set before the license issue date.", r.message)
    }

    @Test
    fun `data de expirare modificata invalideaza semnatura`() {
        val r = verifier.evaluate(tampered("timed", "validUntil", "2099-01-01T00:00:00Z"), ownId, now)
        assertEquals("License signature is invalid.", r.message)
    }

    @Test
    fun `codul de instalare modificat invalideaza semnatura`() {
        val r = verifier.evaluate(tampered("otherInstall", "businessId", ownId), ownId, now)
        assertEquals("License signature is invalid.", r.message)
    }

    @Test
    fun `JSON invalid nu arunca exceptie`() {
        assertEquals("invalid", verifier.evaluate("nu e json", ownId, now).status)
        assertEquals("invalid", verifier.evaluate("{}", ownId, now).status)
    }

    @Test
    fun `JSON compactat si reformatat ramane valid`() {
        val pretty = fixtures.getJSONObject("timed").toString(2)
        assertTrue(verifier.evaluate(pretty, ownId, now).isActive)
    }

    // ── Reguli de preluare de la partener ───────────────────────────────────────

    private fun check(name: String) = verifier.evaluate(license(name), null, now)
    private val invalid = LicenseCheck("invalid", "x")

    @Test
    fun `fara licenta proprie se preia licenta partenerului`() {
        assertEquals(AdoptionDecision.ADOPT,
            LicenseVerifier.decideAdoption(null, "inventarplus-999", check("timed")))
        assertEquals(AdoptionDecision.ADOPT,
            LicenseVerifier.decideAdoption(invalid, "inventarplus-999", check("timed")))
    }

    @Test
    fun `licenta primita invalida e ignorata`() {
        assertEquals(AdoptionDecision.REJECT_INVALID,
            LicenseVerifier.decideAdoption(null, ownId, invalid))
    }

    @Test
    fun `licenta activa proprie pe alt cod nu se suprascrie`() {
        assertEquals(AdoptionDecision.KEEP_OWN,
            LicenseVerifier.decideAdoption(check("timed"), ownId, check("otherInstall")))
    }

    @Test
    fun `reinnoirea pe acelasi cod inlocuieste licenta`() {
        assertEquals(AdoptionDecision.RENEW,
            LicenseVerifier.decideAdoption(check("timed"), ownId, check("timedLater")))
        assertEquals(AdoptionDecision.RENEW,
            LicenseVerifier.decideAdoption(check("timed"), ownId, check("lifetime")))
    }

    @Test
    fun `licenta mai veche sau identica nu inlocuieste`() {
        assertEquals(AdoptionDecision.ALREADY_UP_TO_DATE,
            LicenseVerifier.decideAdoption(check("timedLater"), ownId, check("timed")))
        assertEquals(AdoptionDecision.ALREADY_UP_TO_DATE,
            LicenseVerifier.decideAdoption(check("timed"), ownId, check("timed")))
        assertEquals(AdoptionDecision.ALREADY_UP_TO_DATE,
            LicenseVerifier.decideAdoption(check("lifetime"), ownId, check("timedLater")))
    }

    @Test
    fun `licenta proprie expirata pe acelasi cod se reinnoieste`() {
        assertEquals(AdoptionDecision.RENEW,
            LicenseVerifier.decideAdoption(invalid, ownId, check("timed")))
    }
}
