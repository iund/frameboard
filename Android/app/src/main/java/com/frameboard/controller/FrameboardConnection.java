package com.frameboard.controller;

import android.graphics.*;
import android.os.*;
import android.util.Base64;
import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;

/** One cancellable connection attempt; callbacks are delivered on the main thread. */
final class FrameboardConnection {
    interface Listener {
        void state(String title,String detail,boolean connected);
        void connectionFailed(String detail);
        void preview(Bitmap image);
        void layout(float x,float y,float w,float h);
    }
    private final Listener listener;
    private final Handler main=new Handler(Looper.getMainLooper());
    private final ExecutorService reader=Executors.newSingleThreadExecutor();
    private final ThreadPoolExecutor sender=new ThreadPoolExecutor(1,1,0,TimeUnit.SECONDS,new ArrayBlockingQueue<>(128));
    private volatile int generation;
    private volatile Socket socket;
    private volatile BufferedWriter writer;
    private volatile SecureChannel secureChannel;
    private boolean closed;

    FrameboardConnection(Listener listener) {
        this.listener=listener;
    }
    private void post(int id,Runnable action) { main.post(()->{ if(id==generation && !closed)action.run(); }); }
    private void state(int id,String title,String detail,boolean connected) { post(id,()->listener.state(title,detail,connected)); }
    private void fail(int id,String detail) { post(id,()->{
        stop();
        listener.state("Not connected",detail,false);
        listener.connectionFailed(detail);
    }); }
    void stop() {
        generation++;writer=null;secureChannel=null;sender.getQueue().clear();
        Socket old=socket;socket=null;if(old!=null)try { old.close(); }catch(IOException ignored){}
    }
    void close() { stop();closed=true;main.removeCallbacksAndMessages(null);reader.shutdownNow();sender.shutdownNow(); }
    void manual(String host,int port,String pairToken) {
        stop();int id=generation;
        state(id,"Connecting…",host+":"+port,false);open(id,host,port,pairToken);
    }
    private void open(int id,String host,int port,String pairToken) {
        reader.execute(()->{
            try(Socket current=new Socket()) {
                if(id!=generation)return;
                socket=current;
                if(id!=generation) { current.close();return; }
                current.connect(new InetSocketAddress(host,port),5000);current.setSoTimeout(10000);
                BufferedReader in=new BufferedReader(new InputStreamReader(current.getInputStream(),StandardCharsets.UTF_8));
                BufferedWriter out=new BufferedWriter(new OutputStreamWriter(current.getOutputStream(),StandardCharsets.UTF_8));
                JSONObject challenge=new JSONObject(readLine(in));
                byte[] serverNonce=decodeNonce(challenge,"serverNonce");
                if(!"challenge".equals(challenge.optString("type")) || challenge.optInt("version")!=2)throw new IOException("Unsupported Mac handshake");
                byte[] clientNonce=SecureChannel.randomNonce();
                byte[] clientProof=SecureChannel.clientProof(pairToken,serverNonce,clientNonce);
                JSONObject authentication=new JSONObject().put("type","authenticate").put("version",2)
                    .put("clientNonce",java.util.Base64.getEncoder().encodeToString(clientNonce))
                    .put("proof",java.util.Base64.getEncoder().encodeToString(clientProof));
                out.write(authentication.toString());out.newLine();out.flush();
                JSONObject authenticated=new JSONObject(readLine(in));
                byte[] serverProof=decodeBase64(authenticated.optString("proof",""));
                if(!"authenticated".equals(authenticated.optString("type")) || authenticated.optInt("version")!=2 ||
                    !SecureChannel.equal(SecureChannel.serverProof(pairToken,serverNonce,clientNonce),serverProof))
                    throw new IOException("The Mac did not prove its pairing secret");
                SecureChannel channel=SecureChannel.client(pairToken,serverNonce,clientNonce);
                JSONObject hello=channel.open(new JSONObject(readLine(in)));
                if(!"status".equals(hello.optString("type")) || !"connected".equals(hello.optString("state")))throw new IOException("Secure session was not accepted");
                if(id!=generation)return;
                post(id,()->{ secureChannel=channel;writer=out; });current.setSoTimeout(0);
                state(id,"Connected securely",host+" · Encrypted camera and blackboard control",true);
                String line;
                while(id==generation && (line=readLine(in))!=null) {
                    JSONObject message=channel.open(new JSONObject(line));
                    if("layout".equals(message.optString("type"))) {
                        float x=(float)message.getDouble("x"),y=(float)message.getDouble("y"),w=(float)message.getDouble("w"),h=(float)message.getDouble("h");
                        post(id,()->listener.layout(x,y,w,h));
                    } else if("preview".equals(message.optString("type"))) {
                        byte[] jpeg=Base64.decode(message.getString("jpeg"),Base64.DEFAULT);
                        BitmapFactory.Options bounds=new BitmapFactory.Options();bounds.inJustDecodeBounds=true;
                        BitmapFactory.decodeByteArray(jpeg,0,jpeg.length,bounds);
                        if(bounds.outWidth!=1280 || bounds.outHeight!=720)throw new IOException("Unexpected preview size");
                        Bitmap image=BitmapFactory.decodeByteArray(jpeg,0,jpeg.length);
                        if(image!=null)post(id,()->listener.preview(image));
                    }
                }
                if(id==generation)fail(id,"The Mac disconnected. Tap Connect to reconnect.");
            }catch(Exception e) { if(id==generation)fail(id,"Connection failed. Check the Mac address, port and token, then retry."); }
        });
    }
    private static byte[] decodeNonce(JSONObject object,String name) throws IOException {
        byte[] value=decodeBase64(object.optString(name,""));
        if(value.length!=SecureChannel.NONCE_BYTES)throw new IOException("Invalid handshake nonce");return value;
    }
    private static byte[] decodeBase64(String value) throws IOException {
        try { return java.util.Base64.getDecoder().decode(value); }
        catch(IllegalArgumentException e) { throw new IOException("Invalid handshake data",e); }
    }
    static String readLine(Reader in) throws IOException {
        StringBuilder line=new StringBuilder();int value;
        while((value=in.read())!=-1) {
            if(value=='\n')return line.toString();
            if(line.length()>=2*1024*1024)throw new IOException("Message too large");
            line.append((char)value);
        }
        if(line.length()!=0)throw new IOException("Incomplete message");return null;
    }
    void send(JSONObject message) {
        BufferedWriter target=writer;SecureChannel channel=secureChannel;int id=generation;
        if(target==null || channel==null)return;
        try { sender.execute(()->{
            if(id!=generation || target!=writer || channel!=secureChannel)return;
            try { target.write(channel.seal(message).toString());target.newLine();target.flush(); }
            catch(IOException e) { fail(id,"Sending stopped. Tap Connect to reconnect."); }
            catch(Exception e) { fail(id,"The encrypted session failed. Tap Connect to reconnect."); }
        }); }catch(RejectedExecutionException e) { fail(id,"The connection is too slow. Tap Connect to retry."); }
    }
}
