package app.sayitapp.inventar_plus

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SmsSyncReceiverTest {

    @Test
    fun `partenerul e recunoscut indiferent de formatul numarului`() {
        assertTrue(SmsSyncReceiver.isFromPartner("+40722000111", "0722000111"))
        assertTrue(SmsSyncReceiver.isFromPartner("0722000111", "+40 722 000 111"))
        assertTrue(SmsSyncReceiver.isFromPartner("+40722000111", "+40722000111"))
    }

    @Test
    fun `alt numar e respins`() {
        assertFalse(SmsSyncReceiver.isFromPartner("+40722000999", "0722000111"))
    }

    @Test
    fun `fara partener configurat nu se accepta nimic`() {
        // Altfel oricine ne știe numărul ar putea modifica produsele sau
        // trimite o licență.
        assertFalse(SmsSyncReceiver.isFromPartner("+40722000111", null))
        assertFalse(SmsSyncReceiver.isFromPartner("+40722000111", ""))
    }

    @Test
    fun `numerele prea scurte nu se potrivesc dupa sufix`() {
        assertFalse(SmsSyncReceiver.isFromPartner("111", "0722000111"))
        assertFalse(SmsSyncReceiver.isFromPartner("INFO", "0722000111"))
    }
}
