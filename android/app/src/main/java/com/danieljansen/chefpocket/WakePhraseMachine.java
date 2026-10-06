package com.danieljansen.chefpocket;

import java.util.Locale;
import java.util.regex.Pattern;

/** State machine fed only complete Vosk utterances; wake-only speech is never saved. */
final class WakePhraseMachine {
    private static final Pattern COMMAND=Pattern.compile("(?i)^(?:(?:please|can you|could you|make sure to)\\s+)*(?:add|remove|delete|save|put|schedule|remember(?:\\s+to)?|remind\\s+me\\s+to|don.t\\s+forget\\s+to|do\\s+not\\s+forget\\s+to|i\\s+need\\s+to|i\\s+have\\s+to|make\\s+a\\s+note(?:\\s+that)?)\\b.*$");
    private static final Pattern NEGATED_ACTION=Pattern.compile("(?i)^(?:(?:please\\s+)?(?:don.t|do\\s+not|never)\\s+)(?:add|remove|delete|save|put|schedule|remember|remind)\\b.*$");
    private static final Pattern WAKE_GARBLED_PREFIX=Pattern.compile("(?i)^(?:(?:a\\s+)?shaft|(?:a\\s+)?chef|hey\\s+jeff|hey\\s+chief|hey\\s+check)\\s+((?:(?:please|can you|could you|make sure to)\\s+)*(?:add|remove|delete|save|put|schedule|remember(?:\\s+to)?|remind\\s+me\\s+to|don.t\\s+forget\\s+to|do\\s+not\\s+forget\\s+to|i\\s+need\\s+to|i\\s+have\\s+to|make\\s+a\\s+note(?:\\s+that)?)\\b.*)$");
    enum Mode { WAKE, COMMAND }
    enum ResultKind { IGNORE, LISTENING, CAPTURE, CHAT, END, TIMEOUT }
    static final class Result {
        final ResultKind kind; final String text;
        Result(ResultKind kind, String text) { this.kind = kind; this.text = text; }
    }
    private Mode mode = Mode.WAKE;
    private long deadline;
    private boolean conversationActive;
    static final long COMMAND_WINDOW_MS = 15_000;
    static final long FOLLOWUP_WINDOW_MS = 120_000;

    Result accept(String utterance, long now) {
        String clean = utterance == null ? "" : utterance.trim().replaceAll("[.!?]+$", "").trim();
        if (mode == Mode.COMMAND && now >= deadline) { reset(); }
        String lower = clean.toLowerCase(Locale.ROOT);
        boolean wake=lower.startsWith("hey chef")&&(lower.length()==8||Character.isWhitespace(lower.charAt(8))||",!?".indexOf(lower.charAt(8))>=0);
        if (wake) {
            String tail = clean.substring(8).replaceFirst("^[,!?\\s]+", "").trim();
            if (tail.isEmpty()) { mode = Mode.COMMAND; conversationActive=false; deadline = now + COMMAND_WINDOW_MS; return new Result(ResultKind.LISTENING, ""); }
            if(BriefingParser.requestType(tail)!=null){mode=Mode.COMMAND;conversationActive=true;deadline=now+FOLLOWUP_WINDOW_MS;return new Result(ResultKind.CHAT,tail);}
            if(COMMAND.matcher(tail).matches()){mode=Mode.COMMAND;conversationActive=true;deadline=now+FOLLOWUP_WINDOW_MS;return new Result(ResultKind.CAPTURE,tail);}
            mode=Mode.COMMAND;conversationActive=true;deadline=now+FOLLOWUP_WINDOW_MS;return new Result(ResultKind.CHAT,tail);
        }
        if(mode==Mode.COMMAND&&lower.matches("(?:bye|goodbye|thanks|thank you|that.s all|go to sleep|stop listening|turn off)(?: chef)?")){reset();return new Result(ResultKind.END,"");}
        if (mode==Mode.COMMAND&&(lower.equals("cancel") || lower.equals("never mind") || lower.equals("nevermind"))) {
            reset();return new Result(ResultKind.TIMEOUT, "");
        }
        if(mode==Mode.COMMAND&&BriefingParser.requestType(clean)!=null){conversationActive=true;deadline=now+FOLLOWUP_WINDOW_MS;return new Result(ResultKind.CHAT,clean);}
        if (mode==Mode.COMMAND&&!clean.isEmpty() && COMMAND.matcher(clean).matches()) { conversationActive=true;deadline=now+FOLLOWUP_WINDOW_MS;return new Result(ResultKind.CAPTURE, clean); }
        if(mode==Mode.COMMAND){java.util.regex.Matcher garbled=WAKE_GARBLED_PREFIX.matcher(clean);if(garbled.matches()&&COMMAND.matcher(garbled.group(1)).matches()){conversationActive=true;deadline=now+FOLLOWUP_WINDOW_MS;return new Result(ResultKind.CAPTURE,garbled.group(1));}}
        if(mode==Mode.COMMAND&&NEGATED_ACTION.matcher(clean).matches())return new Result(ResultKind.IGNORE,"");
        if(mode==Mode.COMMAND&&!clean.isEmpty()&&conversationActive){deadline=now+FOLLOWUP_WINDOW_MS;return new Result(ResultKind.CHAT,clean);}
        return new Result(ResultKind.IGNORE, "");
    }
    void continueConversation(long now){mode=Mode.COMMAND;conversationActive=true;deadline=now+FOLLOWUP_WINDOW_MS;}
    /** Called only when the constrained wake recognizer confirms its exact grammar phrase. */
    void observeValidatedWake(long now){if(mode!=Mode.COMMAND||now>=deadline){mode=Mode.COMMAND;conversationActive=false;deadline=now+COMMAND_WINDOW_MS;}}
    /** Partial recognition may arm the command window, but is never captured. */
    boolean observePartialWake(String partial, long now) {
        String normalized=partial==null?"":partial.trim();
        if(!normalized.matches("(?i)^hey chef(?:$|[\\s,!?]).*"))return false;
        observeValidatedWake(now);return true;
    }
    static boolean isWakeGrammarText(String text){
        if(text==null)return false;String[] words=text.trim().toLowerCase(Locale.ROOT).split("\\s+");
        if(words.length<2||!words[0].replaceAll("^[,.!?]+|[,.!?]+$","").equals("hey")||!words[1].replaceAll("^[,.!?]+|[,.!?]+$","").equals("chef"))return false;
        for(int i=2;i<words.length;i++)if(!words[i].replaceAll("^[,.!?]+|[,.!?]+$","").equals("[unk]"))return false;
        return true;
    }
    Result expire(long now) {
        if (mode == Mode.COMMAND && now >= deadline) { reset();return new Result(ResultKind.TIMEOUT, ""); }
        return new Result(ResultKind.IGNORE, "");
    }
    void reset() { mode = Mode.WAKE; deadline = 0; conversationActive=false; }
    Mode mode() { return mode; }
    boolean conversationActive(){return conversationActive;}
    long deadline() { return deadline; }
}
