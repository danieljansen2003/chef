package com.danieljansen.chefpocket;

import java.util.regex.Pattern;

/** Recognizes only explicit, positive requests for a briefing. */
final class BriefingParser {
    private static final Pattern SCHEDULE=Pattern.compile("(?iu)^(?:please\\s+)?(?:schedule|set up|create)\\s+(?:a\\s+)?briefing(?:\\s+.*)?$");
    private static final Pattern NOW=Pattern.compile("(?iu)^(?:please\\s+)?(?:give me|provide me with|prepare)\\s+(?:a\\s+)?briefing(?:\\b.*)?$|^(?:please\\s+)?brief me(?:\\b.*)?$");
    static final class Result{final String requestType,request;Result(String type,String request){this.requestType=type;this.request=request;}}
    private BriefingParser(){}
    static String requestType(String raw){String text=raw==null?"":raw.trim();text=text.replaceFirst("(?iu)^(?:(?:hi|hey|hello)\\s+)?chef[,.!? ]+","").trim();if(SCHEDULE.matcher(text).matches())return "schedule";if(NOW.matcher(text).matches())return "now";return null;}
    static Result parse(String raw){String text=raw==null?"":raw.trim();text=text.replaceFirst("(?iu)^(?:(?:hi|hey|hello)\\s+)?chef[,.!? ]+","").trim();String type=requestType(text);if(type==null)return null;if(text.codePointCount(0,text.length())>1200)throw new IllegalArgumentException("Briefing requests are limited to 1,200 characters.");return new Result(type,text);}
}
