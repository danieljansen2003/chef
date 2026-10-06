package com.danieljansen.chefpocket;

import java.util.Locale;
import java.util.regex.Pattern;

/** State machine fed only complete Vosk utterances; wake-only speech is never saved. */
final class WakePhraseMachine {
    private static final Pattern COMMAND=Pattern.compile("(?i)^(?:(?:please|can you|could you|make sure to)\\s+)*(?:add|save|put|schedule|remember(?:\\s+to)?|remind\\s+me\\s+to|don.t\\s+forget\\s+to|do\\s+not\\s+forget\\s+to|i\\s+need\\s+to|i\\s+have\\s+to|make\\s+a\\s+note(?:\\s+that)?)\\b.*$");
    private static final Pattern WAKE_PREFIX=Pattern.compile("(?i)^(?:hey|hay)[,\\s]+(?:chef|jeff|chief|check)(?=$|[\\s,!?])(.*)$");
    enum Mode { WAKE, COMMAND }
    enum ResultKind { IGNORE, LISTENING, CAPTURE, TIMEOUT }
    static final class Result {
        final ResultKind kind; final String text;
        Result(ResultKind kind, String text) { this.kind = kind; this.text = text; }
    }
    private Mode mode = Mode.WAKE;
    private long deadline;
    static final long COMMAND_WINDOW_MS = 15_000;

    Result accept(String utterance, long now) {
        String clean = normalizeWake(utterance == null ? "" : utterance.trim().replaceAll("[.!?]+$", "").trim());
        if (mode == Mode.COMMAND && now >= deadline) { mode = Mode.WAKE; deadline=0; }
        String lower = clean.toLowerCase(Locale.ROOT);
        boolean wake=lower.startsWith("hey chef")&&(lower.length()==8||Character.isWhitespace(lower.charAt(8))||",!?".indexOf(lower.charAt(8))>=0);
        if (wake) {
            String tail = clean.substring(8).replaceFirst("^[,!?\\s]+", "").trim();
            if (tail.isEmpty()) { mode = Mode.COMMAND; deadline = now + COMMAND_WINDOW_MS; return new Result(ResultKind.LISTENING, ""); }
            if(COMMAND.matcher(tail).matches()){mode=Mode.WAKE;deadline=0;return new Result(ResultKind.CAPTURE,tail);}
            return new Result(ResultKind.IGNORE,"");
        }
        if (mode==Mode.COMMAND&&(lower.equals("cancel") || lower.equals("never mind") || lower.equals("nevermind"))) {
            mode = Mode.WAKE; deadline=0;return new Result(ResultKind.TIMEOUT, "");
        }
        if (mode==Mode.COMMAND&&!clean.isEmpty() && COMMAND.matcher(clean).matches()) { mode = Mode.WAKE;deadline=0;return new Result(ResultKind.CAPTURE, clean); }
        return new Result(ResultKind.IGNORE, "");
    }
    /** Partial recognition may arm the command window, but is never captured. */
    boolean observePartialWake(String partial, long now) {
        String normalized=normalizeWake(partial==null?"":partial.trim());
        if(!normalized.matches("(?i)^hey chef(?:$|[\\s,!?]).*"))return false;
        if(mode!=Mode.COMMAND||now>=deadline){mode=Mode.COMMAND;deadline=now+COMMAND_WINDOW_MS;}return true;
    }
    private static String normalizeWake(String text){
        java.util.regex.Matcher m=WAKE_PREFIX.matcher(text);
        return m.matches()?"hey chef"+m.group(1):text;
    }
    Result expire(long now) {
        if (mode == Mode.COMMAND && now >= deadline) { mode = Mode.WAKE;deadline=0;return new Result(ResultKind.TIMEOUT, ""); }
        return new Result(ResultKind.IGNORE, "");
    }
    void reset() { mode = Mode.WAKE; deadline = 0; }
    Mode mode() { return mode; }
    long deadline() { return deadline; }
}
