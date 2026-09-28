package com.frameboard.controller;

import org.json.JSONObject;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.util.Arrays;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/** Frameboard protocol v2 authentication and ordered AES-GCM record protection. */
final class SecureChannel {
    static final int NONCE_BYTES=32;
    private static final byte[] CLIENT_LABEL="frameboard-client-v2".getBytes(StandardCharsets.UTF_8);
    private static final byte[] SERVER_LABEL="frameboard-server-v2".getBytes(StandardCharsets.UTF_8);
    private static final byte[] SESSION_INFO="frameboard-session-v2".getBytes(StandardCharsets.UTF_8);
    private static final byte[] C2S_LABEL="frameboard-c2s-v2".getBytes(StandardCharsets.UTF_8);
    private static final byte[] S2C_LABEL="frameboard-s2c-v2".getBytes(StandardCharsets.UTF_8);
    private final SecretKeySpec sendKey,receiveKey;
    private long sendSequence,receiveSequence;

    private SecureChannel(byte[] sendKey,byte[] receiveKey) {
        this.sendKey=new SecretKeySpec(sendKey,"AES");this.receiveKey=new SecretKeySpec(receiveKey,"AES");
    }
    static byte[] randomNonce() {
        byte[] value=new byte[NONCE_BYTES];new SecureRandom().nextBytes(value);return value;
    }
    static byte[] clientProof(String secret,byte[] serverNonce,byte[] clientNonce) throws GeneralSecurityException {
        return hmac(secretKey(secret),join(CLIENT_LABEL,serverNonce,clientNonce));
    }
    static byte[] serverProof(String secret,byte[] serverNonce,byte[] clientNonce) throws GeneralSecurityException {
        return hmac(secretKey(secret),join(SERVER_LABEL,serverNonce,clientNonce));
    }
    static SecureChannel client(String secret,byte[] serverNonce,byte[] clientNonce) throws GeneralSecurityException {
        byte[] material=hkdf(secretKey(secret),join(serverNonce,clientNonce),SESSION_INFO,64);
        return new SecureChannel(Arrays.copyOfRange(material,32,64),Arrays.copyOfRange(material,0,32));
    }
    JSONObject seal(JSONObject message) throws GeneralSecurityException,org.json.JSONException {
        long sequence=sendSequence++;
        byte[] counter=counter(sequence),aad=join(C2S_LABEL,counter);
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE,sendKey,new GCMParameterSpec(128,nonce(sequence)));
        cipher.updateAAD(aad);
        byte[] sealed=cipher.doFinal(message.toString().getBytes(StandardCharsets.UTF_8));
        return new JSONObject().put("sequence",sequence).put("ciphertext",java.util.Base64.getEncoder().encodeToString(sealed));
    }
    JSONObject open(JSONObject envelope) throws IOException,GeneralSecurityException,org.json.JSONException {
        long sequence=envelope.optLong("sequence",-1);
        if(sequence!=receiveSequence)throw new IOException("Unexpected encrypted record sequence");
        String encoded=envelope.optString("ciphertext","");
        if(encoded.length()>3_000_000)throw new IOException("Encrypted record is too large");
        byte[] sealed;
        try { sealed=java.util.Base64.getDecoder().decode(encoded); }
        catch(IllegalArgumentException e) { throw new IOException("Invalid encrypted record",e); }
        byte[] counter=counter(sequence),aad=join(S2C_LABEL,counter);
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE,receiveKey,new GCMParameterSpec(128,nonce(sequence)));
        cipher.updateAAD(aad);
        byte[] clear=cipher.doFinal(sealed);receiveSequence++;
        return new JSONObject(new String(clear,StandardCharsets.UTF_8));
    }
    static boolean equal(byte[] expected,byte[] actual) { return MessageDigest.isEqual(expected,actual); }
    private static byte[] secretKey(String secret) throws GeneralSecurityException {
        MessageDigest digest=MessageDigest.getInstance("SHA-256");
        digest.update("frameboard-pairing-v2\0".getBytes(StandardCharsets.UTF_8));
        return digest.digest(secret.getBytes(StandardCharsets.UTF_8));
    }
    private static byte[] hmac(byte[] key,byte[] data) throws GeneralSecurityException {
        Mac mac=Mac.getInstance("HmacSHA256");mac.init(new SecretKeySpec(key,"HmacSHA256"));return mac.doFinal(data);
    }
    private static byte[] hkdf(byte[] input,byte[] salt,byte[] info,int length) throws GeneralSecurityException {
        byte[] prk=hmac(salt,input),output=new byte[length],previous=new byte[0];int offset=0,counter=1;
        while(offset<length) {
            previous=hmac(prk,join(previous,info,new byte[]{(byte)counter++}));
            int count=Math.min(previous.length,length-offset);System.arraycopy(previous,0,output,offset,count);offset+=count;
        }
        return output;
    }
    private static byte[] counter(long value) { return ByteBuffer.allocate(8).putLong(value).array(); }
    private static byte[] nonce(long sequence) { return join(new byte[]{'F','B','V','2'},counter(sequence)); }
    private static byte[] join(byte[]... values) {
        int size=0;for(byte[] value:values)size+=value.length;
        byte[] joined=new byte[size];int offset=0;
        for(byte[] value:values) { System.arraycopy(value,0,joined,offset,value.length);offset+=value.length; }
        return joined;
    }
}
