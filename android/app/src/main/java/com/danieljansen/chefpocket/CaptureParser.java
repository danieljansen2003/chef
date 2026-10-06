package com.danieljansen.chefpocket;

import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

final class CaptureParser {
    private static final Pattern LEADING_DESTINATION=Pattern.compile("(?i)^(?:to|in|on)\\s+(?:my\\s+)?(thoughts?|to[ -]?do(?:\\s+(?:list|this))?|tasks?(?:\\s+list)?)\\s*(?:[:,;]\\s*|\\s+)?(.*)$");
    private static final Pattern TRAILING_DESTINATION=Pattern.compile("(?i)^(.+?)\\s+(?:to|in|on)\\s+(?:my\\s+)?(thoughts?|to[ -]?do(?: list)?|tasks?(?: list)?|calendar)[.!?]*$");
    static final class Capture {
        final String kind;
        final String text;
        Capture(String kind, String text) { this.kind = kind; this.text = text; }
    }
    private CaptureParser() {}

    static Capture parse(String raw, String defaultKind) {
        String text = raw == null ? "" : raw.trim();
        text = text.replaceFirst("(?i)^(?:(?:hi|hey|hello)\\s+)?chef[,.!? ]+", "");
        text = text.replaceFirst("(?i)^(?:(?:please|can you|could you|make sure to|remember to|remind me to|don't forget to|do not forget to|i need to|i have to|make a note(?: that)?)\\s+)*(?:add|save|put|schedule|remember|remind me to|don't forget to|do not forget to|i need to|i have to|make a note(?: that)?)\\s+", "");
        String kind = defaultKind;
        Matcher leading=LEADING_DESTINATION.matcher(text);
        if(leading.matches()){
            text=leading.group(2).trim();String destination=leading.group(1).toLowerCase(Locale.ROOT);
            kind=destination.contains("thought")?"thought":"todo";
            text=text.replaceFirst("(?i)^(?:please|can you|could you)\\s+", "");
            text=text.replaceFirst("(?i)^(?:add|save|put|schedule)\\s+", "");
            text=text.replaceFirst("(?i)^to[ -]?do\\s+", "do ");
        }else{
            Matcher m = TRAILING_DESTINATION.matcher(text);
            if(m.matches()){
            text = m.group(1);
            String destination=m.group(2).toLowerCase(Locale.ROOT);
            kind=destination.contains("thought")?"thought":destination.equals("calendar")?"calendar":"todo";
            }
        }
        text = text.replaceAll("^[\\\"“]+|[\\\"”]+$", "").trim();
        int length = text.codePointCount(0, text.length());
        if (length < 1 || length > 500) throw new IllegalArgumentException("Use between 1 and 500 characters.");
        if (!kind.equals("todo") && !kind.equals("thought")) throw new IllegalArgumentException("Choose a to-do or thought.");
        return new Capture(kind, text);
    }
}
