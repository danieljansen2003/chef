package com.danieljansen.chefpocket;

import android.Manifest;
import android.content.ContentValues;
import android.content.Context;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.provider.CalendarContract;

/** Adds explicitly requested events to the user's previously selected writable calendar. */
final class CalendarExecutor {
    private CalendarExecutor(){}
    static boolean addIfConfigured(Context context,PocketStore store,PocketStore.Item item)throws Exception{
        if(!item.kind.equals("calendar")||item.done||context.checkSelfPermission(Manifest.permission.WRITE_CALENDAR)!=PackageManager.PERMISSION_GRANTED)return false;
        long calendarId=context.getSharedPreferences("calendar-choice",0).getLong("calendar",-1);if(calendarId<0)return false;
        add(context,store,calendarId,item);PocketStore.Item added=new PocketStore.Item(item.id,item.kind,item.text,true,item.createdAt,java.time.Instant.now().toString(),item.calendarRequest);store.save(added,PocketStore.readToken(context));return true;
    }
    static synchronized void add(Context context,PocketStore store,long calendarId,PocketStore.Item item)throws Exception{
        if(context.checkSelfPermission(Manifest.permission.WRITE_CALENDAR)!=PackageManager.PERMISSION_GRANTED||context.checkSelfPermission(Manifest.permission.READ_CALENDAR)!=PackageManager.PERMISSION_GRANTED)throw new SecurityException("Calendar permission is off.");
        if(item.calendarRequest==null)throw new IllegalArgumentException("Missing calendar details.");
        Long priorId=store.calendarEventId(item.id);if(priorId!=null){store.rememberCalendarEvent(item.id,priorId,calendarId);return;}
        String marker="Chef Pocket capture "+item.id;
        Cursor prior=context.getContentResolver().query(CalendarContract.Events.CONTENT_URI,new String[]{CalendarContract.Events._ID},CalendarContract.Events.CALENDAR_ID+"=? AND "+CalendarContract.Events.DESCRIPTION+"=?",new String[]{Long.toString(calendarId),marker},null);
        if(prior!=null){if(prior.moveToFirst())store.rememberCalendarEvent(item.id,prior.getLong(0),calendarId);boolean exists=prior.getCount()>0;prior.close();if(exists)return;}
        java.time.Instant instantStart=toInstant(item.calendarRequest.getString("startAt")),instantEnd=toInstant(item.calendarRequest.getString("endAt"));boolean allDay=item.calendarRequest.getBoolean("allDay");String eventZone=item.calendarRequest.getString("timeZone");long start,end;
        if(allDay){java.time.ZoneId zone=java.time.ZoneId.of(eventZone);java.time.LocalDate startDate=instantStart.atZone(zone).toLocalDate(),endDate=instantEnd.atZone(zone).toLocalDate();start=startDate.atStartOfDay(java.time.ZoneOffset.UTC).toInstant().toEpochMilli();end=endDate.atStartOfDay(java.time.ZoneOffset.UTC).toInstant().toEpochMilli();eventZone="UTC";}else{start=instantStart.toEpochMilli();end=instantEnd.toEpochMilli();}
        ContentValues values=new ContentValues();values.put(CalendarContract.Events.CALENDAR_ID,calendarId);values.put(CalendarContract.Events.TITLE,item.text);values.put(CalendarContract.Events.DESCRIPTION,marker);values.put(CalendarContract.Events.DTSTART,start);values.put(CalendarContract.Events.DTEND,end);values.put(CalendarContract.Events.EVENT_TIMEZONE,eventZone);values.put(CalendarContract.Events.ALL_DAY,allDay?1:0);
        Uri uri=context.getContentResolver().insert(CalendarContract.Events.CONTENT_URI,values);if(uri==null)throw new IllegalStateException("Calendar provider rejected event.");long providerId=android.content.ContentUris.parseId(uri);store.rememberCalendarEvent(item.id,providerId,calendarId);
    }
    private static java.time.Instant toInstant(String value){try{return java.time.Instant.parse(value);}catch(Exception e){return java.time.OffsetDateTime.parse(value).toInstant();}}
}
