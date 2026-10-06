package com.danieljansen.chefpocket;

import java.time.DayOfWeek;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.time.ZoneId;
import java.time.temporal.TemporalAdjusters;
import java.time.OffsetDateTime;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

final class CalendarParser {
    static final class Result { final String title,startAt,endAt,timeZone;final boolean allDay;Result(String t,String s,String e,String z,boolean a){title=t;startAt=s;endAt=e;timeZone=z;allDay=a;} }
    private CalendarParser(){}
    static Result parse(String raw,ZoneId zone){return parse(raw,zone,false);}
    static Result parseTyped(String raw,ZoneId zone){return parse(raw,zone,true);}
    private static Result parse(String raw,ZoneId zone,boolean typedSelection){
        if(raw==null)throw new IllegalArgumentException("Type a calendar event and when it should happen.");
        String s=raw.trim().replaceFirst("(?i)^(?:(?:hi|hey|hello)\\s+)?chef[,.!? ]+", "");
        Matcher command=Pattern.compile("(?i)^(?:(?:please|can you|could you|make sure to|remember to|remind me to|don't forget to|do not forget to|i need to|i have to|make a note(?: that)?)\\s+)*(?:add|save|put|schedule)\\s+(.+)$").matcher(s);
        if(command.matches())s=command.group(1);else if(!typedSelection)throw new IllegalArgumentException("Say ‘add’ or ‘schedule’ before the calendar event.");
        s=s.replaceFirst("(?i)\\s+(?:to|on)\\s+(?:my\\s+)?calendar[.!?]*$", "").trim();
        Matcher target=Pattern.compile("(?i)^(.*?)(?:\\s+(?:to|on)\\s+(?:my\\s+)?calendar)?\\s+(today|tomorrow|(?:next\\s+)?(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|\\d{4}-\\d{2}-\\d{2})(?:\\s+at\\s+([0-9]{1,2}(?::[0-9]{2})?\\s*(?:am|pm)?))?$",Pattern.CASE_INSENSITIVE).matcher(s);
        if(!target.matches())throw new IllegalArgumentException("Add a clear date, such as ‘tomorrow’ or ‘2026-10-12’.");
        String title=target.group(1).replaceFirst("(?i)\\s+(?:to|on)\\s+(?:my\\s+)?calendar$", "").replaceFirst("(?i)\\s+(?:to|on)$", "").trim();String date=target.group(2).toLowerCase(Locale.ROOT);String time=target.group(3);
        if(title.isEmpty()||title.codePointCount(0,title.length())>500)throw new IllegalArgumentException("Use a calendar title between 1 and 500 characters.");
        LocalDate today=LocalDate.now(zone),day;
        if(date.equals("today"))day=today;else if(date.equals("tomorrow"))day=today.plusDays(1);else if(date.matches("\\d{4}-\\d{2}-\\d{2}"))day=LocalDate.parse(date);else{String name=date.replace("next ","");DayOfWeek dow=DayOfWeek.valueOf(name.toUpperCase(Locale.ROOT));day=today.with(TemporalAdjusters.next(dow));}
        boolean allDay=time==null;
        if(allDay){return new Result(title,day.atStartOfDay(zone).toInstant().toString(),day.plusDays(1).atStartOfDay(zone).toInstant().toString(),zone.getId(),true);}
        LocalTime clock=parseTime(time);LocalDateTime local=LocalDateTime.of(day,clock);java.time.ZonedDateTime start=local.atZone(zone);return new Result(title,start.toOffsetDateTime().toString(),start.plusHours(1).toOffsetDateTime().toString(),zone.getId(),false);
    }
    private static LocalTime parseTime(String value){String v=value.toLowerCase(Locale.ROOT).replaceAll("\\s+","");boolean pm=v.endsWith("pm"),am=v.endsWith("am");if(pm||am)v=v.substring(0,v.length()-2);String[] parts=v.split(":");int hour=Integer.parseInt(parts[0]),minute=parts.length>1?Integer.parseInt(parts[1]):0;if(am||pm){if(hour<1||hour>12||minute>59)throw new IllegalArgumentException("Use a valid time, such as 3 PM.");hour=hour%12+(pm?12:0);}if(hour>23||minute>59)throw new IllegalArgumentException("Use a valid time.");return LocalTime.of(hour,minute);}
}
