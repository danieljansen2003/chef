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
        assertEquals(WakePhraseMachine.ResultKind.LISTENING,machine.accept("hey chef",100).kind);
        assertEquals(WakePhraseMachine.ResultKind.IGNORE,machine.accept("background conversation",101).kind);
        assertEquals(WakePhraseMachine.ResultKind.TIMEOUT,machine.expire(100+WakePhraseMachine.COMMAND_WINDOW_MS).kind);
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
