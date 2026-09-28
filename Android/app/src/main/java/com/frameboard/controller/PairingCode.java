package com.frameboard.controller;

import android.net.Uri;
import java.math.BigInteger;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.interfaces.ECPublicKey;
import java.security.spec.*;
import java.util.UUID;

/** Parses and verifies a signed Frameboard QR pairing payload. */
final class PairingCode {
    final String host,secret,identity,fingerprint,payload;
    final int port;
    private PairingCode(String host,int port,String secret,String identity,String fingerprint,String payload) {
        this.host=host;this.port=port;this.secret=secret;this.identity=identity;this.fingerprint=fingerprint;this.payload=payload;
    }
    static PairingCode verify(String text) throws Exception {
        Uri uri=Uri.parse(text);
        if(!"frameboard".equals(uri.getScheme()) || !"pair".equals(uri.getHost()) || !"2".equals(uri.getQueryParameter("v")))
            throw new GeneralSecurityException("This is not a Frameboard pairing code.");
        String host=required(uri,"host"),secret=required(uri,"secret"),identity=required(uri,"identity"),signed=required(uri,"signature");
        int port=Integer.parseInt(required(uri,"port"));
        if(port<1 || port>65535)throw new GeneralSecurityException("Invalid Frameboard port.");
        InetAddress.getByName(host);UUID.fromString(secret);
        byte[] publicBytes=base64URL(identity),signature=base64URL(signed);
        PublicKey publicKey=publicKey(publicBytes);
        String canonical="frameboard-pair-v2\n"+host+"\n"+port+"\n"+secret+"\n"+identity;
        Signature verifier=Signature.getInstance("SHA256withECDSA");verifier.initVerify(publicKey);
        verifier.update(canonical.getBytes(StandardCharsets.UTF_8));
        if(!verifier.verify(signature))throw new GeneralSecurityException("The pairing-code signature is invalid.");
        byte[] digest=MessageDigest.getInstance("SHA-256").digest(publicBytes);
        StringBuilder hex=new StringBuilder();for(int i=0;i<6;i++)hex.append(String.format("%02X",digest[i]));
        String raw=hex.toString(),fingerprint=raw.substring(0,4)+"-"+raw.substring(4,8)+"-"+raw.substring(8);
        return new PairingCode(host,port,secret,identity,fingerprint,text);
    }
    private static PublicKey publicKey(byte[] encoded) throws Exception {
        if(encoded.length!=65 || encoded[0]!=4)throw new GeneralSecurityException("Invalid Mac identity key.");
        AlgorithmParameters parameters=AlgorithmParameters.getInstance("EC");parameters.init(new ECGenParameterSpec("secp256r1"));
        ECParameterSpec curve=parameters.getParameterSpec(ECParameterSpec.class);
        ECPoint point=new ECPoint(new BigInteger(1,java.util.Arrays.copyOfRange(encoded,1,33)),new BigInteger(1,java.util.Arrays.copyOfRange(encoded,33,65)));
        ECPublicKey key=(ECPublicKey)KeyFactory.getInstance("EC").generatePublic(new ECPublicKeySpec(point,curve));
        return key;
    }
    private static String required(Uri uri,String name) throws GeneralSecurityException {
        String value=uri.getQueryParameter(name);if(value==null || value.isEmpty())throw new GeneralSecurityException("Incomplete Frameboard pairing code.");return value;
    }
    private static byte[] base64URL(String value) { return java.util.Base64.getUrlDecoder().decode(value); }
}
