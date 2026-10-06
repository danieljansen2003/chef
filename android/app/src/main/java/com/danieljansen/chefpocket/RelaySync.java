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
    static final String EXTRA_CHEF_REPLY_ID="chef_reply_id";
    static final String ORIGIN="https://chef-pocket-daniel.sy-alejandri-0136.chatgpt.site";
    private static final ExecutorService EXECUTOR=Executors.newSingleThreadExecutor();
    private static volatile boolean running;
    private static boolean rerun;
    private static final class SyncStatus{final String text,chefReplyId;SyncStatus(String text,String id){this.text=text;this.chefReplyId=id;}}
    private RelaySync() {}
    static void request(Context context) {
        Context app=context.getApplicationContext();
        synchronized(RelaySync.class){if(running){rerun=true;return;}running=true;}
        EXECUTOR.execute(()->{SyncStatus result;try{result=sync(app);}catch(Exception e){result=new SyncStatus(e.getMessage()==null?"Sync unavailable. Your captures stay saved on this phone.":e.getMessage(),null);}broadcast(app,result.text,result.chefReplyId);boolean again;synchronized(RelaySync.class){running=false;again=rerun;rerun=false;}if(again)request(app);});
    }
    private static SyncStatus sync(Context context)throws Exception {
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
        try{response=request("GET",path+"?after="+after,auth,null);}catch(IllegalStateException e){if("Not paired".equals(e.getMessage())&&store.pendingCount()==0&&store.items(null).isEmpty())return new SyncStatus("Paired · add your first capture to start syncing",null);throw e;}
        JSONArray events=response.optJSONArray("events");int responseCursor=response.optInt("cursor",-1);
        if(events==null||events.length()>200)throw new IllegalStateException("Invalid sync response; local captures are safe.");
        List<PocketStore.Item> incoming=new ArrayList<>();List<PocketStore.ChatMessage> chats=new ArrayList<>();List<PocketStore.VoiceChunk> voices=new ArrayList<>();String chefReplyId=null;int cursor=after;
        for(int i=0;i<events.length();i++){
            JSONObject event=events.getJSONObject(i);int seq=event.optInt("seq",-1);
            if(seq<=cursor||seq>responseCursor)throw new IllegalStateException("Invalid sync cursor; local captures are safe.");
            String clear=PocketCrypto.open(token,event.getString("payload"));JSONObject envelope=new JSONObject(clear);
            if(envelope.optInt("v")!=1)throw new IllegalStateException("Invalid sync item; local captures are safe.");
            String op=envelope.optString("op");
            if("upsert".equals(op))incoming.add(PocketStore.Item.from(envelope.getJSONObject("item")));
            else if("chat".equals(op)){PocketStore.ChatMessage chat=PocketStore.ChatMessage.from(envelope.getJSONObject("message"));chats.add(chat);if(chat.role.equals("chef"))chefReplyId=chat.id;}
            else if("voice".equals(op))voices.add(PocketStore.VoiceChunk.from(envelope.getJSONObject("voice")));
            else if("briefing".equals(op))chats.add(PocketStore.Briefing.from(envelope.getJSONObject("briefing")).asChatMessage());
            else throw new IllegalStateException("Invalid sync item; local captures are safe.");
            cursor=seq;
        }
        if(responseCursor!=cursor)throw new IllegalStateException("Invalid sync cursor; local captures are safe.");
        validateVoiceBatch(voices);store.commitRemote(incoming,chats,voices,cursor);int pending=store.pendingCount();return new SyncStatus(pending==0?"Synced · Chef updates when it is running":pending+" captures remain queued · sync will retry",chefReplyId);
        } finally {store.close();}
    }
    private static void validateVoiceBatch(List<PocketStore.VoiceChunk> chunks)throws Exception{
        java.util.Map<String,java.util.List<PocketStore.VoiceChunk>> groups=new java.util.HashMap<>();
        for(PocketStore.VoiceChunk chunk:chunks){java.util.List<PocketStore.VoiceChunk> group=groups.computeIfAbsent(chunk.messageID,k->new ArrayList<>());group.add(chunk);}
        for(java.util.List<PocketStore.VoiceChunk> group:groups.values()){int count=group.get(0).count,total=0;java.util.HashSet<Integer> indexes=new java.util.HashSet<>();for(PocketStore.VoiceChunk chunk:group){if(chunk.count!=count||!indexes.add(chunk.index))throw new IllegalStateException("Invalid voice message; local captures are safe.");byte[] data=android.util.Base64.decode(chunk.data,android.util.Base64.DEFAULT);if(data.length>6000)throw new IllegalStateException("Voice chunk is too large.");total+=data.length;if(total>192_000)throw new IllegalStateException("Voice message is too large.");}}
    }
    private static JSONObject request(String method,String path,String auth,String body)throws Exception {
        HttpURLConnection c=(HttpURLConnection)new URL(ORIGIN+path).openConnection();c.setInstanceFollowRedirects(false);c.setRequestMethod(method);c.setConnectTimeout(8_000);c.setReadTimeout(12_000);c.setRequestProperty("Authorization","Bearer "+auth);c.setRequestProperty("Accept","application/json");c.setRequestProperty("Cache-Control","no-store");
        if(body!=null){byte[] bytes=body.getBytes(java.nio.charset.StandardCharsets.UTF_8);if(bytes.length>18_000)throw new IllegalArgumentException("Capture is too large.");c.setDoOutput(true);c.setRequestProperty("Content-Type","application/json");c.setFixedLengthStreamingMode(bytes.length);try(java.io.OutputStream out=c.getOutputStream()){out.write(bytes);}}
        int status=c.getResponseCode();InputStream stream=status>=400?c.getErrorStream():c.getInputStream();byte[] bytes=readBounded(stream,4_000_000);c.disconnect();
        if(status<200||status>=300){String message="Sync unavailable. Your captures stay saved on this phone.";try{JSONObject error=new JSONObject(new String(bytes,java.nio.charset.StandardCharsets.UTF_8));if(error.has("error"))message=error.getString("error");}catch(Exception ignored){}throw new IllegalStateException(message);}
        return new JSONObject(new String(bytes,java.nio.charset.StandardCharsets.UTF_8));
    }
    private static byte[] readBounded(InputStream in,int limit)throws Exception {if(in==null)return new byte[0];try(InputStream input=in;ByteArrayOutputStream out=new ByteArrayOutputStream()){byte[] chunk=new byte[8192];int n;while((n=input.read(chunk))!=-1){if(out.size()+n>limit)throw new IllegalStateException("Sync response is too large.");out.write(chunk,0,n);}return out.toByteArray();}}
    static void broadcast(Context c,String status){broadcast(c,status,null);}
    static void broadcast(Context c,String status,String chefReplyId){Intent i=new Intent(ACTION_STATUS);i.setPackage(c.getPackageName());i.putExtra(EXTRA_STATUS,status);if(chefReplyId!=null)i.putExtra(EXTRA_CHEF_REPLY_ID,chefReplyId);c.sendBroadcast(i);}
}
