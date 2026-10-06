package com.danieljansen.chefpocket;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import org.json.JSONArray;
import org.json.JSONObject;
import java.security.KeyStore;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

final class PocketStore extends SQLiteOpenHelper {
    static final String PREFS = "chef-pocket-private";
    private static final String ALIAS = "chef-pocket-pairing-v1";
    static final class Item {
        final String id, kind, text, createdAt, updatedAt; final boolean done, deleted; final JSONObject calendarRequest;
        Item(String id, String kind, String text, boolean done, String createdAt, String updatedAt) {
            this(id,kind,text,done,createdAt,updatedAt,null);
        }
        Item(String id,String kind,String text,boolean done,String createdAt,String updatedAt,JSONObject request) {this(id,kind,text,done,createdAt,updatedAt,request,false);}
        Item(String id,String kind,String text,boolean done,String createdAt,String updatedAt,JSONObject request,boolean deleted) {this.id=id;this.kind=kind;this.text=text;this.done=done;this.createdAt=createdAt;this.updatedAt=updatedAt;this.calendarRequest=request;this.deleted=deleted;}
        JSONObject json() throws Exception { JSONObject o=new JSONObject();o.put("id",id);o.put("kind",kind);o.put("text",text);o.put("done",done);if(deleted)o.put("deleted",true);o.put("createdAt",createdAt);o.put("updatedAt",updatedAt);if(calendarRequest!=null)o.put("calendarRequest",calendarRequest);return o; }
        static Item from(JSONObject o) throws Exception {
            String id=o.getString("id"),kind=o.getString("kind"),text=o.getString("text"),created=o.getString("createdAt"),updated=o.getString("updatedAt");
            Object done=o.opt("done");JSONObject request=o.optJSONObject("calendarRequest");
            if (!id.matches("(?i)[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}") || (!kind.equals("todo")&&!kind.equals("thought")&&!kind.equals("calendar")) || text.trim().isEmpty() || text.codePointCount(0,text.length())>500 || !(done instanceof Boolean) || !validDate(created) || !validDate(updated)) throw new IllegalArgumentException("Invalid capture");
            if(kind.equals("calendar")){if(request==null||request.length()!=4||!validDate(request.optString("startAt"))||!validDate(request.optString("endAt"))||!(request.opt("allDay") instanceof Boolean)||request.optString("timeZone").isEmpty())throw new IllegalArgumentException("Invalid calendar request");java.time.ZoneId zone=java.time.ZoneId.of(request.getString("timeZone"));java.time.Instant start=toInstant(request.getString("startAt")),end=toInstant(request.getString("endAt"));java.time.Duration duration=java.time.Duration.between(start,end);if(!end.isAfter(start)||duration.compareTo(java.time.Duration.ofDays(366))>0)throw new IllegalArgumentException("Invalid calendar interval");if(request.getBoolean("allDay")){java.time.ZonedDateTime localStart=start.atZone(zone),localEnd=end.atZone(zone);if(!localStart.toLocalTime().equals(java.time.LocalTime.MIDNIGHT)||!localEnd.toLocalTime().equals(java.time.LocalTime.MIDNIGHT)||!localEnd.toLocalDate().isAfter(localStart.toLocalDate()))throw new IllegalArgumentException("Invalid all-day calendar request");}}
            else if(o.has("calendarRequest"))throw new IllegalArgumentException("Unexpected calendar metadata");
            if(o.has("deleted")&&!(o.opt("deleted") instanceof Boolean))throw new IllegalArgumentException("Invalid deletion marker");boolean deleted=o.optBoolean("deleted",false);if(deleted&&!kind.equals("todo"))throw new IllegalArgumentException("Only to-dos can be removed");
            return new Item(id,kind,text,(Boolean)done,created,updated,request,deleted);
        }
        static boolean validDate(String s) { try { toInstant(s); return true; } catch(Exception e) { return false; } }
        static java.time.Instant toInstant(String value){try{return java.time.Instant.parse(value);}catch(Exception e){return java.time.OffsetDateTime.parse(value).toInstant();}}
    }
    static final class Pending { final String id,payload; Pending(String id,String payload){this.id=id;this.payload=payload;} }
    static final class ChatMessage {
        final String id,conversationID,role,text,createdAt,replyToID;
        ChatMessage(String id,String conversationID,String role,String text,String createdAt,String replyToID){this.id=id;this.conversationID=conversationID;this.role=role;this.text=text;this.createdAt=createdAt;this.replyToID=replyToID;}
        JSONObject json()throws Exception{JSONObject m=new JSONObject();m.put("id",id);m.put("conversationID",conversationID);m.put("role",role);m.put("text",text);m.put("createdAt",createdAt);if(replyToID!=null)m.put("replyToID",replyToID);return m;}
        static ChatMessage from(JSONObject m)throws Exception{
            String id=m.getString("id"),conversation=m.getString("conversationID"),role=m.getString("role"),text=m.getString("text"),created=m.getString("createdAt"),reply=m.optString("replyToID",null);
            int max=role.equals("user")?2000:role.equals("chef")?400:0;
            if(!uuid(id)||!uuid(conversation)||max==0||text.trim().isEmpty()||text.codePointCount(0,text.length())>max||!Item.validDate(created)||(reply!=null&&!reply.isEmpty()&&!uuid(reply)))throw new IllegalArgumentException("Invalid chat message");
            return new ChatMessage(id,conversation,role,text,created,reply==null||reply.isEmpty()?null:reply);
        }
    }
    static final class Briefing {
        final String id,conversationID,requestType,request,createdAt;
        Briefing(String id,String conversationID,String requestType,String request,String createdAt){this.id=id;this.conversationID=conversationID;this.requestType=requestType;this.request=request;this.createdAt=createdAt;}
        JSONObject json()throws Exception{JSONObject b=new JSONObject();b.put("id",id);b.put("conversationID",conversationID);b.put("requestType",requestType);b.put("request",request);b.put("createdAt",createdAt);return b;}
        static Briefing from(JSONObject b)throws Exception{String id=b.getString("id"),conversation=b.getString("conversationID"),type=b.getString("requestType"),request=b.getString("request"),created=b.getString("createdAt");if(!uuid(id)||!uuid(conversation)||(!type.equals("now")&&!type.equals("schedule"))||request.trim().isEmpty()||request.codePointCount(0,request.length())>1200||!Item.validDate(created))throw new IllegalArgumentException("Invalid briefing request");return new Briefing(id,conversation,type,request,created);}
        ChatMessage asChatMessage(){return new ChatMessage(id,conversationID,"user",request,createdAt,null);}
    }
    static final class VoiceChunk {
        final String id,messageID,data;final int index,count;
        VoiceChunk(String id,String messageID,int index,int count,String data){this.id=id;this.messageID=messageID;this.index=index;this.count=count;this.data=data;}
        JSONObject json()throws Exception{JSONObject m=new JSONObject();m.put("id",id);m.put("messageID",messageID);m.put("index",index);m.put("count",count);m.put("data",data);return m;}
        static VoiceChunk from(JSONObject m)throws Exception{String id=m.getString("id"),message=m.getString("messageID"),data=m.getString("data");int index=m.getInt("index"),count=m.getInt("count");if(!uuid(id)||!uuid(message)||count<1||count>32||index<0||index>=count||!validPayload(data))throw new IllegalArgumentException("Invalid voice chunk");return new VoiceChunk(id,message,index,count,data);}
        static boolean validPayload(String data){return data!=null&&!data.isEmpty()&&data.length()<=8000&&data.matches("(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?");}
    }

    PocketStore(Context c) { super(c,"chef-pocket.db",null,3); setWriteAheadLoggingEnabled(true); }
    @Override public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE items (id TEXT PRIMARY KEY, json TEXT NOT NULL, updated TEXT NOT NULL)");
        db.execSQL("CREATE TABLE pending (id TEXT PRIMARY KEY, payload TEXT NOT NULL, created INTEGER NOT NULL)");
        db.execSQL("CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
        db.execSQL("CREATE TABLE calendar_status (item_id TEXT PRIMARY KEY, provider_id INTEGER NOT NULL, calendar_id INTEGER NOT NULL)");
        db.execSQL("CREATE TABLE chat_messages (id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, created TEXT NOT NULL, json TEXT NOT NULL)");
        db.execSQL("CREATE INDEX chat_messages_order ON chat_messages(conversation_id,created)");
        db.execSQL("CREATE TABLE voice_chunks (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, chunk_index INTEGER NOT NULL, chunk_count INTEGER NOT NULL, data TEXT NOT NULL)");
        db.execSQL("CREATE UNIQUE INDEX voice_chunk_order ON voice_chunks(message_id,chunk_index)");
        db.execSQL("CREATE TABLE spoken_replies (id TEXT PRIMARY KEY)");
        db.execSQL("INSERT INTO state(key,value) VALUES('cursor','0')");
    }
    @Override public void onUpgrade(SQLiteDatabase db,int oldVersion,int newVersion) {if(oldVersion<2)db.execSQL("CREATE TABLE IF NOT EXISTS calendar_status (item_id TEXT PRIMARY KEY, provider_id INTEGER NOT NULL, calendar_id INTEGER NOT NULL)");if(oldVersion<3){db.execSQL("CREATE TABLE IF NOT EXISTS chat_messages (id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, created TEXT NOT NULL, json TEXT NOT NULL)");db.execSQL("CREATE INDEX IF NOT EXISTS chat_messages_order ON chat_messages(conversation_id,created)");db.execSQL("CREATE TABLE IF NOT EXISTS voice_chunks (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, chunk_index INTEGER NOT NULL, chunk_count INTEGER NOT NULL, data TEXT NOT NULL)");db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS voice_chunk_order ON voice_chunks(message_id,chunk_index)");db.execSQL("CREATE TABLE IF NOT EXISTS spoken_replies (id TEXT PRIMARY KEY)");}}
    synchronized void save(Item item, String token) throws Exception {
        SQLiteDatabase db=getWritableDatabase(); db.beginTransaction();
        try {
            String old = null;
            try(Cursor c=db.rawQuery("SELECT json FROM items WHERE id=?",new String[]{item.id})){if(c.moveToFirst())old=c.getString(0);}
            if(old!=null && InstantOrder.compare(new JSONObject(old).getString("updatedAt"),item.updatedAt)>=0) { db.setTransactionSuccessful(); return; }
            String json=item.json().toString(); ContentValues row=new ContentValues();row.put("id",item.id);row.put("json",json);row.put("updated",item.updatedAt);db.insertWithOnConflict("items",null,row,SQLiteDatabase.CONFLICT_REPLACE);
            if(token!=null) enqueueWithin(db,item,token);
            db.setTransactionSuccessful();
        } finally {db.endTransaction();}
    }
    synchronized void removeTodo(String id,String token)throws Exception {try(Cursor c=getReadableDatabase().rawQuery("SELECT json FROM items WHERE id=?",new String[]{id})){if(!c.moveToFirst())throw new IllegalArgumentException("That to-do is no longer saved.");Item item=Item.from(new JSONObject(c.getString(0)));if(!item.kind.equals("todo")||item.deleted)throw new IllegalArgumentException("That to-do is no longer saved.");String stamp=java.time.Instant.now().toString();if(InstantOrder.compare(stamp,item.updatedAt)<=0)stamp=Item.toInstant(item.updatedAt).plusMillis(1).toString();save(new Item(item.id,item.kind,item.text,item.done,item.createdAt,stamp,null,true),token);}}
    synchronized void saveRemote(Item item) throws Exception {
        SQLiteDatabase db=getWritableDatabase(); String old=null;
        try(Cursor c=db.rawQuery("SELECT json FROM items WHERE id=?",new String[]{item.id})){if(c.moveToFirst())old=c.getString(0);}
        if(old!=null && InstantOrder.compare(new JSONObject(old).getString("updatedAt"),item.updatedAt)>=0)return;
        ContentValues row=new ContentValues();row.put("id",item.id);row.put("json",item.json().toString());row.put("updated",item.updatedAt);db.insertWithOnConflict("items",null,row,SQLiteDatabase.CONFLICT_REPLACE);
    }
    synchronized void enqueueAll(String token)throws Exception {
        SQLiteDatabase db=getWritableDatabase();db.beginTransaction();try{try(Cursor c=db.rawQuery("SELECT json FROM items ORDER BY updated",null)){while(c.moveToNext())enqueueWithin(db,Item.from(new JSONObject(c.getString(0))),token);}try(Cursor c=db.rawQuery("SELECT json FROM chat_messages WHERE json LIKE '%\"role\":\"user\"%' ORDER BY created",null)){while(c.moveToNext()){JSONObject local=new JSONObject(c.getString(0));String requestType=local.optString("briefingRequestType","");if(requestType.equals("now")||requestType.equals("schedule")){Briefing briefing=new Briefing(local.getString("id"),local.getString("conversationID"),requestType,local.getString("text"),local.getString("createdAt"));JSONObject envelope=new JSONObject();envelope.put("v",1);envelope.put("op","briefing");envelope.put("briefing",briefing.json());enqueueWithin(db,envelope,token);}else enqueueWithin(db,wrap("chat",local),token);}}db.setTransactionSuccessful();}finally{db.endTransaction();}
    }
    synchronized void rememberCalendarEvent(String itemId,long providerId,long calendarId){SQLiteDatabase db=getWritableDatabase();ContentValues v=new ContentValues();v.put("item_id",itemId);v.put("provider_id",providerId);v.put("calendar_id",calendarId);db.insertWithOnConflict("calendar_status",null,v,SQLiteDatabase.CONFLICT_REPLACE);}
    synchronized Long calendarEventId(String itemId){try(Cursor c=getReadableDatabase().rawQuery("SELECT provider_id FROM calendar_status WHERE item_id=?",new String[]{itemId})){return c.moveToFirst()?c.getLong(0):null;}}
    synchronized void clearLocalForNewChannel(){SQLiteDatabase db=getWritableDatabase();db.beginTransaction();try{db.delete("items",null,null);db.delete("pending",null,null);db.delete("calendar_status",null,null);db.delete("chat_messages",null,null);db.delete("voice_chunks",null,null);db.delete("spoken_replies",null,null);db.delete("state","key='conversation'",null);ContentValues v=new ContentValues();v.put("key","cursor");v.put("value","0");db.insertWithOnConflict("state",null,v,SQLiteDatabase.CONFLICT_REPLACE);db.setTransactionSuccessful();}finally{db.endTransaction();}}
    synchronized String conversationID(){SQLiteDatabase db=getWritableDatabase();try(Cursor c=db.rawQuery("SELECT value FROM state WHERE key='conversation'",null)){if(c.moveToFirst())return c.getString(0);}String id=java.util.UUID.randomUUID().toString().toLowerCase(java.util.Locale.ROOT);ContentValues v=new ContentValues();v.put("key","conversation");v.put("value",id);db.insertWithOnConflict("state",null,v,SQLiteDatabase.CONFLICT_REPLACE);return id;}
    synchronized void saveChatMessage(ChatMessage message,String token)throws Exception{saveChat(message,token,true);}
    synchronized void saveRemoteChat(ChatMessage message)throws Exception{saveChat(message,null,false);}
    synchronized void saveBriefing(Briefing briefing,String token)throws Exception{SQLiteDatabase db=getWritableDatabase();db.beginTransaction();try{ChatMessage chat=briefing.asChatMessage();JSONObject local=chat.json();local.put("briefingRequestType",briefing.requestType);ContentValues row=new ContentValues();row.put("id",chat.id);row.put("conversation_id",chat.conversationID);row.put("created",chat.createdAt);row.put("json",local.toString());long inserted=db.insertWithOnConflict("chat_messages",null,row,SQLiteDatabase.CONFLICT_IGNORE);if(inserted!=-1&&token!=null){JSONObject envelope=new JSONObject();envelope.put("v",1);envelope.put("op","briefing");envelope.put("briefing",briefing.json());enqueueWithin(db,envelope,token);}pruneConversation(db,chat.conversationID);db.setTransactionSuccessful();}finally{db.endTransaction();}}
    private void saveChat(ChatMessage message,String token,boolean enqueue)throws Exception{SQLiteDatabase db=getWritableDatabase();db.beginTransaction();try{ContentValues row=new ContentValues();row.put("id",message.id);row.put("conversation_id",message.conversationID);row.put("created",message.createdAt);row.put("json",message.json().toString());long inserted=db.insertWithOnConflict("chat_messages",null,row,SQLiteDatabase.CONFLICT_IGNORE);if(inserted!=-1&&enqueue&&token!=null)enqueueWithin(db,wrap("chat",message.json()),token);pruneConversation(db,message.conversationID);db.setTransactionSuccessful();}finally{db.endTransaction();}}
    private static void pruneConversation(SQLiteDatabase db,String conversation){String old="SELECT id FROM chat_messages WHERE conversation_id=? ORDER BY created DESC,id DESC LIMIT -1 OFFSET 200";String[] arg={conversation};db.delete("voice_chunks","message_id IN ("+old+")",arg);db.delete("spoken_replies","id IN ("+old+")",arg);db.delete("chat_messages","id IN ("+old+")",arg);}
    synchronized List<ChatMessage> chatMessages(String conversation)throws Exception{List<ChatMessage> result=new ArrayList<>();try(Cursor c=getReadableDatabase().rawQuery("SELECT json FROM (SELECT json,created,id FROM chat_messages WHERE conversation_id=? ORDER BY created DESC,id DESC LIMIT 200) ORDER BY created,id",new String[]{conversation})){while(c.moveToNext())result.add(ChatMessage.from(new JSONObject(c.getString(0))));}return result;}
    synchronized boolean chatReplyWasSpoken(String id){try(Cursor c=getReadableDatabase().rawQuery("SELECT id FROM spoken_replies WHERE id=?",new String[]{id})){return c.moveToFirst();}}
    synchronized void markChatReplySpoken(String id){ContentValues row=new ContentValues();row.put("id",id);getWritableDatabase().insertWithOnConflict("spoken_replies",null,row,SQLiteDatabase.CONFLICT_IGNORE);}
    synchronized void saveRemoteVoice(VoiceChunk chunk)throws Exception{SQLiteDatabase db=getWritableDatabase();ContentValues row=new ContentValues();row.put("id",chunk.id);row.put("message_id",chunk.messageID);row.put("chunk_index",chunk.index);row.put("chunk_count",chunk.count);row.put("data",chunk.data);db.insertWithOnConflict("voice_chunks",null,row,SQLiteDatabase.CONFLICT_IGNORE);}
    synchronized List<VoiceChunk> voiceChunks(String messageID)throws Exception{List<VoiceChunk> result=new ArrayList<>();try(Cursor c=getReadableDatabase().rawQuery("SELECT id,message_id,chunk_index,chunk_count,data FROM voice_chunks WHERE message_id=? ORDER BY chunk_index",new String[]{messageID})){while(c.moveToNext())result.add(new VoiceChunk(c.getString(0),c.getString(1),c.getInt(2),c.getInt(3),c.getString(4)));}return result;}
    private void enqueueWithin(SQLiteDatabase db,Item item,String token)throws Exception {
        JSONObject env=new JSONObject();env.put("v",1);env.put("op","upsert");env.put("item",item.json());enqueueWithin(db,env,token);
    }
    private JSONObject wrap(String op,JSONObject message)throws Exception{JSONObject env=new JSONObject();env.put("v",1);env.put("op",op);env.put("message",message);return env;}
    private void enqueueWithin(SQLiteDatabase db,JSONObject env,String token)throws Exception {
        String payload=PocketCrypto.seal(token,env.toString());
        ContentValues event=new ContentValues();event.put("id",java.util.UUID.randomUUID().toString());event.put("payload",payload);event.put("created",System.currentTimeMillis());db.insert("pending",null,event);
    }
    synchronized List<Item> items(String kind)throws Exception {
        List<Item> result=new ArrayList<>();String sql="SELECT json FROM items"+(kind==null?"":" WHERE json LIKE ?")+" ORDER BY updated DESC";
        try(Cursor c=getReadableDatabase().rawQuery(sql,kind==null?null:new String[]{"%\"kind\":\""+kind+"\"%"})){while(c.moveToNext()){Item item=Item.from(new JSONObject(c.getString(0)));if(!item.deleted)result.add(item);}} return result;
    }
    synchronized List<Pending> pending() { List<Pending> result=new ArrayList<>();try(Cursor c=getReadableDatabase().rawQuery("SELECT id,payload FROM pending ORDER BY created LIMIT 200",null)){while(c.moveToNext())result.add(new Pending(c.getString(0),c.getString(1)));}return result; }
    synchronized void removePending(String id){getWritableDatabase().delete("pending","id=?",new String[]{id});}
    synchronized int pendingCount(){try(Cursor c=getReadableDatabase().rawQuery("SELECT COUNT(*) FROM pending",null)){return c.moveToFirst()?c.getInt(0):0;}}
    synchronized int cursor(){try(Cursor c=getReadableDatabase().rawQuery("SELECT value FROM state WHERE key='cursor'",null)){return c.moveToFirst()?Integer.parseInt(c.getString(0)):0;}}
    synchronized void commitRemote(List<Item> items,int cursor)throws Exception {
        commitRemote(items,Collections.emptyList(),Collections.emptyList(),cursor);
    }
    synchronized void commitRemote(List<Item> items,List<ChatMessage> chats,List<VoiceChunk> voices,int cursor)throws Exception{SQLiteDatabase db=getWritableDatabase();db.beginTransaction();try{for(Item item:items){String old=null;try(Cursor c=db.rawQuery("SELECT json FROM items WHERE id=?",new String[]{item.id})){if(c.moveToFirst())old=c.getString(0);}if(old==null||InstantOrder.compare(new JSONObject(old).getString("updatedAt"),item.updatedAt)<0){ContentValues row=new ContentValues();row.put("id",item.id);row.put("json",item.json().toString());row.put("updated",item.updatedAt);db.insertWithOnConflict("items",null,row,SQLiteDatabase.CONFLICT_REPLACE);}}for(ChatMessage chat:chats){ContentValues row=new ContentValues();row.put("id",chat.id);row.put("conversation_id",chat.conversationID);row.put("created",chat.createdAt);row.put("json",chat.json().toString());db.insertWithOnConflict("chat_messages",null,row,SQLiteDatabase.CONFLICT_IGNORE);}for(VoiceChunk chunk:voices){ContentValues row=new ContentValues();row.put("id",chunk.id);row.put("message_id",chunk.messageID);row.put("chunk_index",chunk.index);row.put("chunk_count",chunk.count);row.put("data",chunk.data);db.insertWithOnConflict("voice_chunks",null,row,SQLiteDatabase.CONFLICT_IGNORE);}for(ChatMessage chat:chats)pruneConversation(db,chat.conversationID);for(VoiceChunk chunk:voices)validateVoiceStorage(db,chunk.messageID);ContentValues v=new ContentValues();v.put("key","cursor");v.put("value",Integer.toString(cursor));db.insertWithOnConflict("state",null,v,SQLiteDatabase.CONFLICT_REPLACE);db.setTransactionSuccessful();}finally{db.endTransaction();}}
    private static void validateVoiceStorage(SQLiteDatabase db,String messageID)throws Exception{try(Cursor c=db.rawQuery("SELECT chunk_index,chunk_count,data FROM voice_chunks WHERE message_id=?",new String[]{messageID})){int expected=-1,total=0;java.util.HashSet<Integer> indexes=new java.util.HashSet<>();while(c.moveToNext()){int index=c.getInt(0),count=c.getInt(1);String data=c.getString(2);if(expected==-1)expected=count;if(expected!=count||!indexes.add(index)||data.length()>8000)throw new IllegalArgumentException("Invalid stored voice chunk");byte[] bytes=android.util.Base64.decode(data,android.util.Base64.DEFAULT);if(bytes.length>6000)throw new IllegalArgumentException("Voice chunk exceeds its size limit");total+=bytes.length;if(total>192000)throw new IllegalArgumentException("Voice message exceeds its size limit");}}}
    private static boolean uuid(String id){return id!=null&&id.matches("(?i)[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}");}
    static String readToken(Context c)throws Exception {
        String packed=c.getSharedPreferences(PREFS,0).getString("pairing",null);if(packed==null)return null;
        byte[] data=Base64.decode(packed,Base64.NO_WRAP);if(data.length<29)throw new IllegalStateException("Saved pairing data is invalid.");
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.DECRYPT_MODE,key(),new GCMParameterSpec(128,data,0,12));String token=new String(cipher.doFinal(data,12,data.length-12),java.nio.charset.StandardCharsets.UTF_8);
        if(!PocketCrypto.validToken(token))throw new IllegalStateException("Saved pairing code is invalid.");return token;
    }
    static void saveToken(Context c,String token)throws Exception {
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,key());byte[] encrypted=cipher.doFinal(token.getBytes(java.nio.charset.StandardCharsets.UTF_8));byte[] iv=cipher.getIV(),packed=new byte[iv.length+encrypted.length];System.arraycopy(iv,0,packed,0,iv.length);System.arraycopy(encrypted,0,packed,iv.length,encrypted.length);
        c.getSharedPreferences(PREFS,0).edit().putString("pairing",Base64.encodeToString(packed,Base64.NO_WRAP)).apply();
    }
    static void clearToken(Context c){c.getSharedPreferences(PREFS,0).edit().remove("pairing").apply();try{KeyStore s=KeyStore.getInstance("AndroidKeyStore");s.load(null);s.deleteEntry(ALIAS);}catch(Exception ignored){}}
    private static SecretKey key()throws Exception {
        KeyStore s=KeyStore.getInstance("AndroidKeyStore");s.load(null);if(s.containsAlias(ALIAS))return (SecretKey)s.getKey(ALIAS,null);
        KeyGenerator g=KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore");g.init(new KeyGenParameterSpec.Builder(ALIAS,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setRandomizedEncryptionRequired(true).build());return g.generateKey();
    }
    private static final class InstantOrder { static int compare(String a,String b){try{return Item.toInstant(a).compareTo(Item.toInstant(b));}catch(Exception e){return 0;}} }
}
