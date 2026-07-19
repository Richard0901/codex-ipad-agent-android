package com.gaixianggeng.mimiremote.core.security

import android.content.Context
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class TokenStore(context: Context) {
    private val preferences = context.getSharedPreferences("mimi_remote_secure", Context.MODE_PRIVATE)
    private val keyAlias = "mimi_remote_token_key"

    fun save(profileId: String, token: String) {
        val cipher = cipher(Cipher.ENCRYPT_MODE)
        val encrypted = cipher.doFinal(token.toByteArray(Charsets.UTF_8))
        preferences.edit()
            .putString("$profileId.value", Base64.encodeToString(encrypted, Base64.NO_WRAP))
            .putString("$profileId.iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .apply()
    }

    fun read(profileId: String): String? {
        val encrypted = preferences.getString("$profileId.value", null) ?: return null
        val iv = preferences.getString("$profileId.iv", null) ?: return null
        return runCatching {
            val cipher = cipher(Cipher.DECRYPT_MODE, Base64.decode(iv, Base64.NO_WRAP))
            String(cipher.doFinal(Base64.decode(encrypted, Base64.NO_WRAP)), Charsets.UTF_8)
        }.getOrNull()
    }

    fun delete(profileId: String) {
        preferences.edit().remove("$profileId.value").remove("$profileId.iv").apply()
    }

    private fun cipher(mode: Int, iv: ByteArray? = null): Cipher {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        if (mode == Cipher.ENCRYPT_MODE) cipher.init(mode, secretKey())
        else cipher.init(mode, secretKey(), GCMParameterSpec(128, requireNotNull(iv)))
        return cipher
    }

    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!store.containsAlias(keyAlias)) {
            val generator = KeyGenerator.getInstance("AES", "AndroidKeyStore")
            generator.init(256)
            generator.generateKey()
        }
        return (store.getEntry(keyAlias, null) as KeyStore.SecretKeyEntry).secretKey
    }
}
