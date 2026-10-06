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
        final String id, kind, text, createdAt, updatedAt; final boolean done; final JSONObject calendarRequest;
        Item(String id, String kind, String text, boolean done, String createdAt, String updatedAt) {
            this(id,kind,text,done,createdAt,updatedAt,null);
        }
        Item(String id,String kind,String text,boolean done,String createdAt,String updatedAt,JSONObject request) {this.id=id;this.kind=kind;this.text=text;this.done=done;this.createdAt=createdAt;this.updatedAt=updatedAt;this.calendarRequest=request;}
        JSONObject json() throws Exception { JSONObject o=new JSONObject();o.put("id",id);o.put("kind",kind);o.put("text",text);o.put("done",done);o.put("createdAt",createdAt);o.put("updatedAt",updatedAt);if(calendarRequest!=null)o.put("calendarRequest",calendarRequest);return o; }
        static Item from(JSONObject o) throws Exception {
            String id=o.getString("id"),kind=o.getString("kind"),text=o.getString("text"),created=o.getString("createdAt"),updated=o.getString("updatedAt");
            Object done=o.opt("done");JSONObject request=o.optJSONObject("calendarRequest");
            if (!id.matches("(?i)[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}") || (!kind.equals("todo")&&!kind.equals("thought")&&!kind.equals("calendar")) || text.trim().isEmpty() || text.codePointCount(0,text.length())>500 || !(done instanceof Boolean) || !validDate(created) || !validDate(updated)) throw new IllegalArgumentException("Invalid capture");
            if(kind.equals("calendar")){if(request==null||request.length()!=4||!validDate(request.optString("startAt"))||!validDate(request.optString("endAt"))||!(request.opt("allDay") instanceof Boolean)||request.optString("timeZone").isEmpty())throw new IllegalArgumentException("Invalid calendar request");java.time.ZoneId zone=java.time.ZoneId.of(request.getString("timeZone"));java.time.Instant start=toInstant(request.getString("startAt")),end=toInstant(request.getString("endAt"));java.time.Duration duration=java.time.Duration.between(start,end);if(!end.isAfter(start)||duration.compareTo(java.time.Duration.ofDays(366))>0)throw new IllegalArgumentException("Invalid calendar interval");if(request.getBoolean("allDay")){java.time.ZonedDateTime localStart=start.atZone(zone),localEnd=end.atZone(zone);if(!localStart.toLocalTime().equals(java.time.LocalTime.MIDNIGHT)||!localEnd.toLocalTime().equals(java.time.LocalTime.MIDNIGHT)||!localEnd.toLocalDate().isAfter(localStart.toLocalDate()))throw new IllegalArgumentException("Invalid all-day calendar request");}}
            else if(o.has("calendarRequest"))throw new IllegalArgumentException("Unexpected calendar metadata");
            return new Item(id,kind,text,(Boolean)done,created,updated,request);
        }
        static boolean validDate(String s) { try { toInstant(s); return true; } catch(Exception e) { return false; } }
        static java.time.Instant toInstant(String value){try{return java.time.Instant.parse(value);}catch(Exception e){return java.time.OffsetDateTime.parse(value).toInstant();}}
    }
    static final class Pending { final String id,payload; Pending(String id,String payload){this.id=id;this.payload=payload;} }

    PocketStore(Context c) { super(c,"chef-pocket.db",null,2); setWriteAheadLoggingEnabled(true); }
    @Override public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE items (id TEXT PRIMARY KEY, json TEXT NOT NULL, updated TEXT NOT NULL)");
        db.execSQL("CREATE TABLE pending (id TEXT PRIMARY KEY, payload TEXT NOT NULL, created INTEGER NOT NULL)");
        db.execSQL("CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
        db.execSQL("CREATE TABLE calendar_status (item_id TEXT PRIMARY KEY, provider_id INTEGER NOT NULL, calendar_id INTEGER NOT NULL)");
        db.execSQL("INSERT INTO state(key,value) VALUES('cursor','0')");
    }
    @Override public void onUpgrade(SQLiteDatabase db,int oldVersion,int newVersion) {if(oldVersion<2)db.execSQL("CREATE TABLE IF NOT EXISTS calendar_status (item_id TEXT PRIMARY KEY, provider_id INTEGER NOT NULL, calendar_id INTEGER NOT NULL)");}
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
    synchronized void saveRemote(Item item) throws Exception {
        SQLiteDatabase db=getWritableDatabase(); String old=null;
        try(Cursor c=db.rawQuery("SELECT json FROM items WHERE id=?",new String[]{item.id})){if(c.moveToFirst())old=c.getString(0);}
        if(old!=null && InstantOrder.compare(new JSONObject(old).getString("updatedAt"),item.updatedAt)>=0)return;
        ContentValues row=new ContentValues();row.put("id",item.id);row.put("json",item.json().toString());row.put("updated",item.updatedAt);db.insertWithOnConflict("items",null,row,SQLiteDatabase.CONFLICT_REPLACE);
    }
    synchronized void enqueueAll(String token)throws Exception {
        SQLiteDatabase db=getWritableDatabase();db.beginTransaction();try(Cursor c=db.rawQuery("SELECT json FROM items ORDER BY updated",null)){while(c.moveToNext())enqueueWithin(db,Item.from(new JSONObject(c.getString(0))),token);db.setTransactionSuccessful();}finally{db.endTransaction();}
    }
    synchronized void rememberCalendarEvent(String itemId,long providerId,long calendarId){SQLiteDatabase db=getWritableDatabase();ContentValues v=new ContentValues();v.put("item_id",itemId);v.put("provider_id",providerId);v.put("calendar_id",calendarId);db.insertWithOnConflict("calendar_status",null,v,SQLiteDatabase.CONFLICT_REPLACE);}
    synchronized Long calendarEventId(String itemId){try(Cursor c=getReadableDatabase().rawQuery("SELECT provider_id FROM calendar_status WHERE item_id=?",new String[]{itemId})){return c.moveToFirst()?c.getLong(0):null;}}
    synchronized void clearLocalForNewChannel(){SQLiteDatabase db=getWritableDatabase();db.beginTransaction();try{db.delete("items",null,null);db.delete("pending",null,null);db.delete("calendar_status",null,null);ContentValues v=new ContentValues();v.put("key","cursor");v.put("value","0");db.insertWithOnConflict("state",null,v,SQLiteDatabase.CONFLICT_REPLACE);db.setTransactionSuccessful();}finally{db.endTransaction();}}
    private void enqueueWithin(SQLiteDatabase db,Item item,String token)throws Exception {
        JSONObject env=new JSONObject();env.put("v",1);env.put("op","upsert");env.put("item",item.json());
        String payload=PocketCrypto.seal(token,env.toString());
        ContentValues event=new ContentValues();event.put("id",java.util.UUID.randomUUID().toString());event.put("payload",payload);event.put("created",System.currentTimeMillis());db.insert("pending",null,event);
    }
    synchronized List<Item> items(String kind)throws Exception {
        List<Item> result=new ArrayList<>();String sql="SELECT json FROM items"+(kind==null?"":" WHERE json LIKE ?")+" ORDER BY updated DESC";
        try(Cursor c=getReadableDatabase().rawQuery(sql,kind==null?null:new String[]{"%\"kind\":\""+kind+"\"%"})){while(c.moveToNext())result.add(Item.from(new JSONObject(c.getString(0))));} return result;
    }
    synchronized List<Pending> pending() { List<Pending> result=new ArrayList<>();try(Cursor c=getReadableDatabase().rawQuery("SELECT id,payload FROM pending ORDER BY created LIMIT 200",null)){while(c.moveToNext())result.add(new Pending(c.getString(0),c.getString(1)));}return result; }
    synchronized void removePending(String id){getWritableDatabase().delete("pending","id=?",new String[]{id});}
    synchronized int pendingCount(){try(Cursor c=getReadableDatabase().rawQuery("SELECT COUNT(*) FROM pending",null)){return c.moveToFirst()?c.getInt(0):0;}}
    synchronized int cursor(){try(Cursor c=getReadableDatabase().rawQuery("SELECT value FROM state WHERE key='cursor'",null)){return c.moveToFirst()?Integer.parseInt(c.getString(0)):0;}}
    synchronized void commitRemote(List<Item> items,int cursor)throws Exception {
        SQLiteDatabase db=getWritableDatabase();db.beginTransaction();try{for(Item item:items){String old=null;try(Cursor c=db.rawQuery("SELECT json FROM items WHERE id=?",new String[]{item.id})){if(c.moveToFirst())old=c.getString(0);}if(old==null||InstantOrder.compare(new JSONObject(old).getString("updatedAt"),item.updatedAt)<0){ContentValues row=new ContentValues();row.put("id",item.id);row.put("json",item.json().toString());row.put("updated",item.updatedAt);db.insertWithOnConflict("items",null,row,SQLiteDatabase.CONFLICT_REPLACE);}}ContentValues v=new ContentValues();v.put("key","cursor");v.put("value",Integer.toString(cursor));db.insertWithOnConflict("state",null,v,SQLiteDatabase.CONFLICT_REPLACE);db.setTransactionSuccessful();}finally{db.endTransaction();}
    }
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
