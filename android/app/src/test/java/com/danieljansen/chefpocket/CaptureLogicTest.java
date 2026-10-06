package com.danieljansen.chefpocket;

import static org.junit.Assert.*;
import org.junit.Test;
import java.time.ZoneId;

public class CaptureLogicTest {
    @Test public void parsesDestinationAndBoundsText(){
        CaptureParser.Capture todo=CaptureParser.parse("Hey Chef, please add pick up groceries to my to-do list", "thought");
        assertEquals("todo",todo.kind);assertEquals("pick up groceries",todo.text);
        CaptureParser.Capture thought=CaptureParser.parse("save remember the garden lights to my thoughts", "todo");
        assertEquals("thought",thought.kind);assertEquals("remember the garden lights",thought.text);
        try{CaptureParser.parse(" ","todo");fail("empty captures must fail");}catch(IllegalArgumentException expected){}
    }
    @Test public void wakePhraseIgnoresOtherSpeechAndAcceptsImmediateCommand(){
        WakePhraseMachine machine=new WakePhraseMachine();
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("turn on the radio",1).kind);
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("I said hey chef yesterday",2).kind);
        WakePhraseMachine.Result immediate=machine.accept("hey chef, add milk to my to-do list",3);
        assertEquals(WakePhraseMachine.ResultKind.CAPTURE,immediate.kind);
        assertEquals("add milk to my to-do list",immediate.text);
        assertEquals(WakePhraseMachine.Mode.WAKE,machine.mode());
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
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("hey chef what is on my calendar tomorrow",105).kind);
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
        assertEquals(WakePhraseMachine.Mode.WAKE,machine.mode());
        machine.accept("hey chef",20);
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("save this thought",20+WakePhraseMachine.COMMAND_WINDOW_MS).kind);
        assertEquals(0,machine.deadline());
    }
    @Test public void wakeRecognitionHandlesSmallTranscriptionVariantsOnlyAtPhraseBoundary(){
        WakePhraseMachine machine=new WakePhraseMachine();
        assertTrue(machine.observePartialWake("hey, Jeff",200));
        long deadline=machine.deadline();assertTrue(machine.observePartialWake("hey chef add",201));assertEquals(deadline,machine.deadline());
        assertEquals(WakePhraseMachine.ResultKind.LISTENING,machine.accept("hey Jeff",201).kind);
        assertEquals(WakePhraseMachine.ResultKind.CAPTURE,machine.accept("hey check, add milk to my to-do list",202).kind);
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("hey chefboyardee",203).kind);
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("a chef walked into the room",204).kind);
    }
    @Test public void partialWakeFollowedByFinalFullCommandCapturesAndWakeOnlyStaysListening(){
        WakePhraseMachine machine=new WakePhraseMachine();
        assertTrue(machine.observePartialWake("hey chef add",100));
        WakePhraseMachine.Result command=machine.accept("hey chef add groceries to my to-do list",101);
        assertEquals(WakePhraseMachine.ResultKind.CAPTURE,command.kind);
        assertEquals("add groceries to my to-do list",command.text);
        assertTrue(machine.observePartialWake("hey jeff",200));
        WakePhraseMachine.Result wakeOnly=machine.accept("hey Jeff",201);
        assertEquals(WakePhraseMachine.ResultKind.LISTENING,wakeOnly.kind);
        assertEquals(WakePhraseMachine.Mode.COMMAND,machine.mode());
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
