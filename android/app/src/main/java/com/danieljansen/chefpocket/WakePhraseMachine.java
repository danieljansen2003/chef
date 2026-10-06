package com.danieljansen.chefpocket;

import java.util.Locale;
import java.util.regex.Pattern;

/** State machine fed only complete Vosk utterances; wake-only speech is never saved. */
final class WakePhraseMachine {
    private static final Pattern COMMAND=Pattern.compile("(?i)^(?:(?:please|can you|could you|make sure to)\\s+)*(?:add|save|put|schedule|remember(?:\\s+to)?|remind\\s+me\\s+to|don.t\\s+forget\\s+to|do\\s+not\\s+forget\\s+to|i\\s+need\\s+to|i\\s+have\\s+to|make\\s+a\\s+note(?:\\s+that)?)\\b.*$");
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
        String clean = utterance == null ? "" : utterance.trim().replaceAll("[.!?]+$", "").trim();
        if (mode == Mode.COMMAND && now >= deadline) { mode = Mode.WAKE; }
        String lower = clean.toLowerCase(Locale.ROOT);
        boolean heyChef=lower.startsWith("hey chef")&&(lower.length()==8||Character.isWhitespace(lower.charAt(8))||",!?".indexOf(lower.charAt(8))>=0);
        boolean heyCommaChef=lower.startsWith("hey, chef")&&(lower.length()==9||Character.isWhitespace(lower.charAt(9))||",!?".indexOf(lower.charAt(9))>=0);
        int wake = heyChef||heyCommaChef ? 0 : -1;
        if (mode == Mode.WAKE) {
            if (wake < 0) return new Result(ResultKind.IGNORE, "");
            String tail = clean.substring(wake + (heyCommaChef ? 9 : 8)).replaceFirst("^[,!?\\s]+", "").trim();
            if (tail.isEmpty()) { mode = Mode.COMMAND; deadline = now + COMMAND_WINDOW_MS; return new Result(ResultKind.LISTENING, ""); }
            return COMMAND.matcher(tail).matches()?new Result(ResultKind.CAPTURE,tail):new Result(ResultKind.IGNORE,"");
        }
        if (lower.equals("cancel") || lower.equals("never mind") || lower.equals("nevermind")) {
            mode = Mode.WAKE; return new Result(ResultKind.TIMEOUT, "");
        }
        if (!clean.isEmpty() && COMMAND.matcher(clean).matches()) { mode = Mode.WAKE;return new Result(ResultKind.CAPTURE, clean); }
        return new Result(ResultKind.IGNORE, "");
    }
    Result expire(long now) {
        if (mode == Mode.COMMAND && now >= deadline) { mode = Mode.WAKE; return new Result(ResultKind.TIMEOUT, ""); }
        return new Result(ResultKind.IGNORE, "");
    }
    void reset() { mode = Mode.WAKE; deadline = 0; }
    Mode mode() { return mode; }
    long deadline() { return deadline; }
}
