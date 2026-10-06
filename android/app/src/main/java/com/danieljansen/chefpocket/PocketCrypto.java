package com.danieljansen.chefpocket;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Base64;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

final class PocketCrypto {
    private PocketCrypto() {}
    static byte[] sha256(String value) throws Exception { return MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)); }
    static String hex(byte[] input) { StringBuilder b = new StringBuilder(input.length * 2); for (byte value : input) b.append(String.format(java.util.Locale.ROOT, "%02x", value & 255)); return b.toString(); }
    static String channel(String token) throws Exception { return hex(sha256(token)); }
    static String authorization(String token) throws Exception { return hex(sha256("chef-auth-v1:" + token)); }
    static String seal(String token, String envelope) throws Exception {
        byte[] iv = new byte[12]; new java.security.SecureRandom().nextBytes(iv);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(sha256("chef-pocket-v1:" + token), "AES"), new GCMParameterSpec(128, iv));
        byte[] encrypted = cipher.doFinal(envelope.getBytes(StandardCharsets.UTF_8));
        byte[] packed = Arrays.copyOf(iv, iv.length + encrypted.length); System.arraycopy(encrypted, 0, packed, iv.length, encrypted.length);
        return Base64.getEncoder().encodeToString(packed);
    }
    static String open(String token, String payload) throws Exception {
        byte[] packed = Base64.getDecoder().decode(payload);
        if (packed.length < 29 || packed.length > 12_000) throw new IllegalArgumentException("Invalid sync payload");
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(sha256("chef-pocket-v1:" + token), "AES"), new GCMParameterSpec(128, packed, 0, 12));
        return new String(cipher.doFinal(packed, 12, packed.length - 12), StandardCharsets.UTF_8);
    }
    static boolean validToken(String token) { return token != null && token.matches("[a-f0-9]{64}"); }
}
