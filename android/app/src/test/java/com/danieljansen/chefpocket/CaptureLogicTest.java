package com.danieljansen.chefpocket;

import static org.junit.Assert.*;
import org.junit.Test;
import java.time.ZoneId;
import java.util.Arrays;
import java.util.Collections;

public class CaptureLogicTest {
    @Test public void parsesDestinationAndBoundsText(){
        CaptureParser.Capture todo=CaptureParser.parse("Hey Chef, please add pick up groceries to my to-do list", "thought");
        assertEquals("todo",todo.kind);assertEquals("pick up groceries",todo.text);
        CaptureParser.Capture thought=CaptureParser.parse("save remember the garden lights to my thoughts", "todo");
        assertEquals("thought",thought.kind);assertEquals("remember the garden lights",thought.text);
        try{CaptureParser.parse(" ","todo");fail("empty captures must fail");}catch(IllegalArgumentException expected){}
    }
    @Test public void parsesLeadingTodoDestinationWithoutSavingDestinationWords(){
        CaptureParser.Capture todo=CaptureParser.parse("can you add to my to do list to do an interview","thought");
        assertEquals("todo",todo.kind);assertEquals("do an interview",todo.text);
        CaptureParser.Capture asr=CaptureParser.parse("to my to do this to do an interview","thought");
        assertEquals("todo",asr.kind);assertEquals("do an interview",asr.text);
        CaptureParser.Capture trailing=CaptureParser.parse("add to my to-do list pick up groceries","thought");
        assertEquals("todo",trailing.kind);assertEquals("pick up groceries",trailing.text);
        try{CaptureParser.parse("add to my to do list","thought");fail("empty leading-destination task must fail");}catch(IllegalArgumentException expected){}
    }
    @Test public void removalMatchesOnlyOneConservativeTodoCandidate(){
        TodoIntentMatcher.Item interview=new TodoIntentMatcher.Item("1","do an interview");
        TodoIntentMatcher.Result equivalent=TodoIntentMatcher.matchRemoval(
                "please remove doing my interview from my to do list",Collections.singletonList(interview));
        assertEquals(TodoIntentMatcher.Status.MATCH,equivalent.status);assertEquals("1",equivalent.match.id);

        TodoIntentMatcher.Result exactWinsOverOtherSemanticCandidate=TodoIntentMatcher.matchRemoval(
                "please remove interview from my to-do list",Arrays.asList(
                        new TodoIntentMatcher.Item("2","interview"),interview));
        assertEquals(TodoIntentMatcher.Status.MATCH,exactWinsOverOtherSemanticCandidate.status);
        assertEquals("2",exactWinsOverOtherSemanticCandidate.match.id);

        TodoIntentMatcher.Result ambiguous=TodoIntentMatcher.matchRemoval(
                "please remove doing my interview from my to-do list",Arrays.asList(
                        interview,new TodoIntentMatcher.Item("3","interview")));
        assertEquals(TodoIntentMatcher.Status.AMBIGUOUS,ambiguous.status);assertNull(ambiguous.match);
        assertEquals(2,ambiguous.candidates.size());

        TodoIntentMatcher.Result noFuzzy=TodoIntentMatcher.matchRemoval(
                "remove interview from my to-do list",Collections.singletonList(
                        new TodoIntentMatcher.Item("4","job interview")));
        assertEquals(TodoIntentMatcher.Status.NOT_FOUND,noFuzzy.status);
        assertEquals(TodoIntentMatcher.Status.NOT_REMOVAL,TodoIntentMatcher.matchRemoval(
                "please remove interview",Collections.singletonList(interview)).status);
    }
    @Test public void wakePhraseIgnoresOtherSpeechAndAcceptsImmediateCommand(){
        WakePhraseMachine machine=new WakePhraseMachine();
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("turn on the radio",1).kind);
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("I said hey chef yesterday",2).kind);
        WakePhraseMachine.Result immediate=machine.accept("hey chef, add milk to my to-do list",3);
        assertEquals(WakePhraseMachine.ResultKind.CAPTURE,immediate.kind);
        assertEquals("add milk to my to-do list",immediate.text);
        assertEquals(WakePhraseMachine.Mode.COMMAND,machine.mode());
    }
    @Test public void wakeOnlyOpensBoundedCommandWindow(){
        WakePhraseMachine machine=new WakePhraseMachine();
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("add milk to my to-do list",99).kind);
        assertEquals(WakePhraseMachine.ResultKind.LISTENING,machine.accept("hey chef",100).kind);
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("background conversation",101).kind);
        assertEquals(WakePhraseMachine.ResultKind.TIMEOUT,machine.expire(100+WakePhraseMachine.COMMAND_WINDOW_MS).kind);
        assertEquals(0,machine.deadline());
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("add milk to my to-do list",100+WakePhraseMachine.COMMAND_WINDOW_MS+1).kind);
        machine.reset();
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("hey chefboyardee",102).kind);
        assertEquals(WakePhraseMachine.ResultKind.LISTENING,machine.accept("hey chef",102).kind);
        assertEquals(WakePhraseMachine.ResultKind.CAPTURE,machine.accept("make sure to add milk to my list",103).kind);
        machine.reset();
        assertEquals(WakePhraseMachine.ResultKind.CAPTURE,machine.accept("hey chef make sure to add dentist tomorrow to my calendar",104).kind);
        machine.reset();
        assertEquals(WakePhraseMachine.ResultKind.CHAT,machine.accept("hey chef what is on my calendar tomorrow",105).kind);
        machine.reset();
        assertEquals(WakePhraseMachine.ResultKind.LISTENING,machine.accept("hey chef",110).kind);
        assertEquals(WakePhraseMachine.ResultKind.TIMEOUT,machine.accept("cancel",111).kind);
        assertEquals(WakePhraseMachine.Mode.WAKE,machine.mode());
    }
    @Test public void onlyAcceptsCommandWithoutWakeInsideActiveWindow(){
        WakePhraseMachine machine=new WakePhraseMachine();
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("save this thought",1).kind);
        assertEquals(WakePhraseMachine.ResultKind.LISTENING,machine.accept("hey chef",10).kind);
        assertEquals(WakePhraseMachine.ResultKind.CAPTURE,machine.accept("save this thought",11).kind);
        assertEquals(WakePhraseMachine.Mode.COMMAND,machine.mode());
        machine.accept("hey chef",20);
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("save this thought",20+WakePhraseMachine.COMMAND_WINDOW_MS).kind);
        assertEquals(0,machine.deadline());
    }
    @Test public void constrainedWakeGrammarRequiresExactPhraseAndUnknownRejects(){
        assertTrue(WakePhraseMachine.isWakeGrammarText("hey chef"));
        assertTrue(WakePhraseMachine.isWakeGrammarText("Hey Chef."));
        assertTrue(WakePhraseMachine.isWakeGrammarText("hey chef [unk]"));
        assertTrue(WakePhraseMachine.isWakeGrammarText("hey chef [unk] [unk]"));
        assertFalse(WakePhraseMachine.isWakeGrammarText("hey jeff"));
        assertFalse(WakePhraseMachine.isWakeGrammarText("a shaft"));
        assertFalse(WakePhraseMachine.isWakeGrammarText("[unk] hey chef"));
        assertFalse(WakePhraseMachine.isWakeGrammarText("[unk]"));
        assertFalse(WakePhraseMachine.isWakeGrammarText("hey chef groceries"));
        assertFalse(WakePhraseMachine.isWakeGrammarText("hey chefboyardee"));
    }
    @Test public void wakeRecognitionRequiresValidatedWindowAndExplicitActionBoundary(){
        WakePhraseMachine machine=new WakePhraseMachine();
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("a shaft add milk to my to-do list",200).kind);
        machine.observeValidatedWake(200);
        WakePhraseMachine.Result command=machine.accept("a shaft add milk to my to-do list",201);
        assertEquals(WakePhraseMachine.ResultKind.CAPTURE,command.kind);assertEquals("add milk to my to-do list",command.text);
        machine.observeValidatedWake(202);
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("don't add milk to my to-do list",203).kind);
        machine.reset();machine.observeValidatedWake(204);
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("the cat a shaft add milk",205).kind);
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("a shaft random conversation",206).kind);
    }
    @Test public void partialWakeFollowedByFinalFullCommandCapturesAndWakeOnlyStaysListening(){
        WakePhraseMachine machine=new WakePhraseMachine();
        machine.observeValidatedWake(100);
        WakePhraseMachine.Result command=machine.accept("a shaft add groceries to my to-do list",101);
        assertEquals(WakePhraseMachine.ResultKind.CAPTURE,command.kind);
        assertEquals("add groceries to my to-do list",command.text);
        machine.observeValidatedWake(200);
        assertEquals(WakePhraseMachine.ResultKind.CHAT,machine.accept("a shaft maybe add groceries",201).kind);
        machine.reset();
        assertTrue(machine.observePartialWake("hey chef",202));
        WakePhraseMachine.Result wakeOnly=machine.accept("hey chef",203);
        assertEquals(WakePhraseMachine.ResultKind.LISTENING,wakeOnly.kind);assertEquals(WakePhraseMachine.Mode.COMMAND,machine.mode());
    }
    @Test public void followupConversationAcceptsChatRefreshesTimeoutAndEndsExplicitly(){
        WakePhraseMachine machine=new WakePhraseMachine();
        assertEquals(WakePhraseMachine.ResultKind.CAPTURE,machine.accept("hey chef add milk to my to-do list",100).kind);
        assertEquals(WakePhraseMachine.ResultKind.CHAT,machine.accept("what should I cook with it?",101).kind);
        assertEquals(101+WakePhraseMachine.FOLLOWUP_WINDOW_MS,machine.deadline());
        assertEquals(WakePhraseMachine.ResultKind.END,machine.accept("goodbye chef",102).kind);
        assertEquals(WakePhraseMachine.Mode.WAKE,machine.mode());
        assertEquals(WakePhraseMachine.ResultKind.LISTENING,machine.accept("hey chef",200).kind);
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("background conversation",201).kind);
    }
    @Test public void onlyDirectPositiveBriefingPhrasesUseTypedBriefingPath(){
        BriefingParser.Result now=BriefingParser.parse("hey chef give me a briefing");assertNotNull(now);assertEquals("now",now.requestType);
        BriefingParser.Result schedule=BriefingParser.parse("please schedule a briefing every weekday at 8");assertNotNull(schedule);assertEquals("schedule",schedule.requestType);
        assertNull(BriefingParser.parse("what is a briefing?"));assertNull(BriefingParser.parse("don't give me a briefing"));
        assertNull(BriefingParser.parse("what is the weather?"));
        WakePhraseMachine machine=new WakePhraseMachine();assertEquals(WakePhraseMachine.ResultKind.CHAT,machine.accept("hey chef schedule a briefing every weekday at 8",1).kind);
    }
    @Test public void voiceChunkBase64MustBeNonemptyCanonicalAndBounded(){
        assertTrue(PocketStore.VoiceChunk.validPayload("AA=="));assertTrue(PocketStore.VoiceChunk.validPayload("AQID"));
        assertFalse(PocketStore.VoiceChunk.validPayload(""));assertFalse(PocketStore.VoiceChunk.validPayload("A"));
        assertFalse(PocketStore.VoiceChunk.validPayload("AQID\n"));assertFalse(PocketStore.VoiceChunk.validPayload("A".repeat(8004)));
    }
    @Test public void calendarDateBecomesLocalAllDayInterval(){
        CalendarParser.Result result=CalendarParser.parse("hey chef make sure to add dentist tomorrow to my calendar",ZoneId.of("America/Chicago"));
        assertEquals("dentist",result.title);assertTrue(result.allDay);assertEquals("America/Chicago",result.timeZone);
        java.time.ZoneId zone=ZoneId.of(result.timeZone);java.time.LocalDate start=java.time.Instant.parse(result.startAt).atZone(zone).toLocalDate();java.time.LocalDate end=java.time.Instant.parse(result.endAt).atZone(zone).toLocalDate();
        assertEquals(java.time.LocalDate.now(zone).plusDays(1),start);assertEquals(start.plusDays(1),end);
    }
    @Test public void calendarRequestWithoutResolvableDateIsRejected(){
        try{CalendarParser.parse("add dentist to my calendar",ZoneId.of("UTC"));fail("an unresolved date must not become an event");}catch(IllegalArgumentException expected){}
        try{CalendarParser.parse("what is on my calendar tomorrow",ZoneId.of("UTC"));fail("calendar question must not create an event");}catch(IllegalArgumentException expected){}
    }
    @Test public void pocketCipherRoundTripsAndUsesExpectedDomains(){
        String token="ab".repeat(32);String clear="{\"v\":1,\"op\":\"upsert\",\"item\":{}}";
        try{String payload=PocketCrypto.seal(token,clear);assertEquals(clear,PocketCrypto.open(token,payload));assertNotEquals(PocketCrypto.channel(token),PocketCrypto.authorization(token));assertNotEquals(token,PocketCrypto.authorization(token));
            try{PocketCrypto.open("cd".repeat(32),payload);fail("wrong pairing key must fail");}catch(Exception expected){}
        }catch(Exception e){throw new AssertionError(e);}
    }
}
