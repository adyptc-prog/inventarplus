package app.sayitapp.inventar_plus

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppLangTest {

    @After
    fun reset() = AppLang.setForTest(false)

    @Test
    fun `limba aleasa in aplicatie are prioritate fata de cea a telefonului`() {
        assertTrue(AppLang.resolveIsEn("en", "ro"))
        assertFalse(AppLang.resolveIsEn("ro", "en"))
    }

    @Test
    fun `fara alegere se foloseste limba telefonului - romana doar pe telefon in romana`() {
        assertFalse(AppLang.resolveIsEn(null, "ro"))
        assertTrue(AppLang.resolveIsEn(null, "en"))
        assertTrue(AppLang.resolveIsEn(null, "de"))
        assertTrue(AppLang.resolveIsEn("altceva", "fr"))
    }

    @Test
    fun `mesajele native urmeaza limba aplicatiei`() {
        assertEquals("Fără semnal / serviciu mobil.", SmsStatus.describe(4))
        assertEquals("Trimiterea a eșuat (cod 99).", SmsStatus.describe(99))
        assertEquals("Permisiunea SMS lipsește.", SmsStatus.PERMISSION_MISSING)

        AppLang.setForTest(true)
        assertEquals("No signal / mobile service.", SmsStatus.describe(4))
        assertEquals("Sending failed (code 99).", SmsStatus.describe(99))
        assertEquals("The SMS permission is missing.", SmsStatus.PERMISSION_MISSING)
    }

    @Test
    fun `limba aplicatiei nu se salveaza in backup si nu e suprascrisa la restaurare`() {
        assertFalse(BackupFormat.isBackedUpKey("flutter.app_language"))
        assertTrue(BackupFormat.isBackedUpKey("flutter.inventar_products"))
    }
}
