package com.danieljansen.chefpocket;

import java.text.Normalizer;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Pure intent parsing and conservative matching for explicit to-do removal requests. */
final class TodoIntentMatcher {
    private static final Pattern REMOVE_COMMAND = Pattern.compile(
            "(?iu)^(?:please\\s+)?(?:remove|delete)\\s+(.+?)\\s+from\\s+(?:my\\s+)?to[ -]?do(?:\\s+(?:list|this))?[.!?]*$");
    private static final Pattern PUNCTUATION = Pattern.compile("[^\\p{L}\\p{N}]+", Pattern.UNICODE_CHARACTER_CLASS);

    enum Status { NOT_REMOVAL, NOT_FOUND, MATCH, AMBIGUOUS }

    static final class Item {
        final String id;
        final String text;

        Item(String id, String text) {
            this.id = id;
            this.text = text;
        }
    }

    static final class Result {
        final Status status;
        final String requestedText;
        final Item match;
        final List<Item> candidates;

        private Result(Status status, String requestedText, Item match, List<Item> candidates) {
            this.status = status;
            this.requestedText = requestedText;
            this.match = match;
            this.candidates = Collections.unmodifiableList(candidates);
        }
    }

    private TodoIntentMatcher() {}

    static boolean isRemovalRequest(String raw) {
        String text = raw == null ? "" : raw.trim();
        text = text.replaceFirst("(?iu)^(?:(?:hi|hey|hello)\\s+)?chef[,.!? ]+", "");
        return text.matches("(?iu)^(?:please\\s+)?(?:remove|delete)\\b.*$");
    }

    /**
     * Recognizes only explicit remove/delete commands ending in a to-do destination.
     * It never mutates items and never chooses between semantically equivalent entries.
     */
    static Result matchRemoval(String raw, List<Item> items) {
        String text = raw == null ? "" : raw.trim();
        text = text.replaceFirst("(?iu)^(?:(?:hi|hey|hello)\\s+)?chef[,.!? ]+", "");
        Matcher command = REMOVE_COMMAND.matcher(text);
        if (!command.matches()) return result(Status.NOT_REMOVAL, "", null, Collections.emptyList());
        String requested = command.group(1).trim();
        if (requested.isEmpty()) return result(Status.NOT_FOUND, requested, null, Collections.emptyList());

        String exactKey = normalize(requested, false);
        List<Item> exact = candidates(items, exactKey, false);
        if (exact.size() == 1) return result(Status.MATCH, requested, exact.get(0), exact);
        if (exact.size() > 1) return result(Status.AMBIGUOUS, requested, null, exact);

        String intentKey = normalize(requested, true);
        if (intentKey.isEmpty()) return result(Status.NOT_FOUND, requested, null, Collections.emptyList());
        List<Item> semantic = candidates(items, intentKey, true);
        if (semantic.size() == 1) return result(Status.MATCH, requested, semantic.get(0), semantic);
        if (semantic.size() > 1) return result(Status.AMBIGUOUS, requested, null, semantic);
        return result(Status.NOT_FOUND, requested, null, Collections.emptyList());
    }

    private static Result result(Status status, String requested, Item match, List<Item> candidates) {
        return new Result(status, requested, match, new ArrayList<>(candidates));
    }

    private static List<Item> candidates(List<Item> items, String key, boolean semantic) {
        List<Item> found = new ArrayList<>();
        if (items == null) return found;
        for (Item item : items) {
            if (item == null || item.text == null) continue;
            if (normalize(item.text, semantic).equals(key)) found.add(item);
        }
        return found;
    }

    private static String normalize(String value, boolean semantic) {
        String normalized = Normalizer.normalize(value, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT);
        normalized = PUNCTUATION.matcher(normalized).replaceAll(" ").trim().replaceAll("\\s+", " ");
        if (!semantic || normalized.isEmpty()) return normalized;

        String[] words = normalized.split(" ");
        int start = 0;
        if (words.length > 0 && (words[0].equals("do") || words[0].equals("doing"))) start++;
        if (start < words.length && (words[start].equals("a") || words[start].equals("an")
                || words[start].equals("the") || words[start].equals("my"))) start++;
        StringBuilder key = new StringBuilder();
        for (int i = start; i < words.length; i++) {
            if (key.length() > 0) key.append(' ');
            key.append(words[i]);
        }
        return key.toString();
    }
}
