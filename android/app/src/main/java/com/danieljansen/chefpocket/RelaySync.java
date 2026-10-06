package com.danieljansen.chefpocket;

import android.content.Context;
import android.content.Intent;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

final class RelaySync {
    static final String ACTION_STATUS="com.danieljansen.chefpocket.SYNC_STATUS";
    static final String EXTRA_STATUS="status";
    static final String ORIGIN="https://chef-pocket-daniel.sy-alejandri-0136.chatgpt.site";
    private static final ExecutorService EXECUTOR=Executors.newSingleThreadExecutor();
    private static volatile boolean running;
    private static boolean rerun;
    private RelaySync() {}
    static void request(Context context) {
        Context app=context.getApplicationContext();
        synchronized(RelaySync.class){if(running){rerun=true;return;}running=true;}
        EXECUTOR.execute(()->{String message;try{message=sync(app);}catch(Exception e){message=e.getMessage()==null?"Sync unavailable. Your captures stay saved on this phone.":e.getMessage();}broadcast(app,message);boolean again;synchronized(RelaySync.class){running=false;again=rerun;rerun=false;}if(again)request(app);});
    }
    private static String sync(Context context)throws Exception {
        String token=PocketStore.readToken(context);if(token==null)throw new IllegalStateException("Pair with your Mac to sync.");
        String channel=PocketCrypto.channel(token),auth=PocketCrypto.authorization(token),path="/api/channels/"+channel+"/events";
        PocketStore store=new PocketStore(context);
        try {
        for(PocketStore.Pending event:store.pending()){
            JSONObject body=new JSONObject();body.put("id",event.id);body.put("payload",event.payload);
            JSONObject accepted=request("POST",path,auth,body.toString());
            if(!accepted.optBoolean("ok"))throw new IllegalStateException("Sync paused. Your captures stay queued.");
            store.removePending(event.id);
        }
        int after=store.cursor();JSONObject response;
        try{response=request("GET",path+"?after="+after,auth,null);}catch(IllegalStateException e){if("Not paired".equals(e.getMessage())&&store.pendingCount()==0&&store.items(null).isEmpty())return "Paired · add your first capture to start syncing";throw e;}
        JSONArray events=response.optJSONArray("events");int responseCursor=response.optInt("cursor",-1);
        if(events==null||events.length()>200)throw new IllegalStateException("Invalid sync response; local captures are safe.");
        List<PocketStore.Item> incoming=new ArrayList<>();int cursor=after;
        for(int i=0;i<events.length();i++){
            JSONObject event=events.getJSONObject(i);int seq=event.optInt("seq",-1);
            if(seq<=cursor||seq>responseCursor)throw new IllegalStateException("Invalid sync cursor; local captures are safe.");
            String clear=PocketCrypto.open(token,event.getString("payload"));JSONObject envelope=new JSONObject(clear);
            if(envelope.optInt("v")!=1||!"upsert".equals(envelope.optString("op")))throw new IllegalStateException("Invalid sync item; local captures are safe.");
            incoming.add(PocketStore.Item.from(envelope.getJSONObject("item")));cursor=seq;
        }
        if(responseCursor!=cursor)throw new IllegalStateException("Invalid sync cursor; local captures are safe.");
        store.commitRemote(incoming,cursor);int pending=store.pendingCount();return pending==0?"Synced · Chef updates when it is running":pending+" captures remain queued · sync will retry";
        } finally {store.close();}
    }
    private static JSONObject request(String method,String path,String auth,String body)throws Exception {
        HttpURLConnection c=(HttpURLConnection)new URL(ORIGIN+path).openConnection();c.setInstanceFollowRedirects(false);c.setRequestMethod(method);c.setConnectTimeout(8_000);c.setReadTimeout(12_000);c.setRequestProperty("Authorization","Bearer "+auth);c.setRequestProperty("Accept","application/json");c.setRequestProperty("Cache-Control","no-store");
        if(body!=null){byte[] bytes=body.getBytes(java.nio.charset.StandardCharsets.UTF_8);if(bytes.length>18_000)throw new IllegalArgumentException("Capture is too large.");c.setDoOutput(true);c.setRequestProperty("Content-Type","application/json");c.setFixedLengthStreamingMode(bytes.length);try(java.io.OutputStream out=c.getOutputStream()){out.write(bytes);}}
        int status=c.getResponseCode();InputStream stream=status>=400?c.getErrorStream():c.getInputStream();byte[] bytes=readBounded(stream,1_000_000);c.disconnect();
        if(status<200||status>=300){String message="Sync unavailable. Your captures stay saved on this phone.";try{JSONObject error=new JSONObject(new String(bytes,java.nio.charset.StandardCharsets.UTF_8));if(error.has("error"))message=error.getString("error");}catch(Exception ignored){}throw new IllegalStateException(message);}
        return new JSONObject(new String(bytes,java.nio.charset.StandardCharsets.UTF_8));
    }
    private static byte[] readBounded(InputStream in,int limit)throws Exception {if(in==null)return new byte[0];try(InputStream input=in;ByteArrayOutputStream out=new ByteArrayOutputStream()){byte[] chunk=new byte[8192];int n;while((n=input.read(chunk))!=-1){if(out.size()+n>limit)throw new IllegalStateException("Sync response is too large.");out.write(chunk,0,n);}return out.toByteArray();}}
    static void broadcast(Context c,String status){Intent i=new Intent(ACTION_STATUS);i.setPackage(c.getPackageName());i.putExtra(EXTRA_STATUS,status);c.sendBroadcast(i);}
}
