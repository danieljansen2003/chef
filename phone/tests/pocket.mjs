import assert from 'node:assert/strict';
import {parseCapture,validateItem,seal,open,merge,channelFor,authorizationFor} from '../lib/pocket.ts';
assert.deepEqual(parseCapture('Hey Chef, add "grab groceries" to my to do list','thought'),{kind:'todo',text:'grab groceries'});
assert.deepEqual(parseCapture('add get Sy a Snorlax for Christmas to my thoughts','todo'),{kind:'thought',text:'get Sy a Snorlax for Christmas'});
assert.throws(()=>parseCapture('add '+ 'x'.repeat(501),'todo'));
const token='ab'.repeat(32);const item={id:crypto.randomUUID(),kind:'todo',text:'Test capture',done:false,createdAt:'2026-10-06T12:00:00Z',updatedAt:'2026-10-06T12:00:00Z'};
const encrypted=await seal(token,{v:1,op:'upsert',item});assert.deepEqual((await open(token,encrypted)).item,item);
await assert.rejects(open('cd'.repeat(32),encrypted));
assert.notEqual(await channelFor(token),await authorizationFor(token));assert.notEqual(await authorizationFor(token),token);
const updated={...item,done:true,updatedAt:'2026-10-06T12:00:01.123Z'};
assert.equal(merge([item],updated)[0].done,true);assert.equal(merge([updated],item)[0].done,true);
console.log('Pocket capture, encryption, wrong-key rejection, timestamp merge: passed');

const calendar={...item,kind:'calendar',calendarRequest:{startAt:'2026-10-07T00:00:00-05:00',endAt:'2026-10-08T00:00:00-05:00',allDay:true,timeZone:'America/Chicago'}};
assert.equal(validateItem(calendar),true);
assert.deepEqual((await open(token,await seal(token,{v:1,op:'upsert',item:calendar}))).item,calendar);
for(const invalid of [{...calendar,calendarRequest:undefined},{...item,calendarRequest:calendar.calendarRequest},{...calendar,calendarRequest:{...calendar.calendarRequest,endAt:calendar.calendarRequest.startAt}},{...calendar,calendarRequest:{...calendar.calendarRequest,timeZone:'invalid/zone'}}]){
 assert.equal(validateItem(invalid),false);
 await assert.rejects(open(token,await seal(token,{v:1,op:'upsert',item:invalid})));
}
assert.equal(merge([calendar],{...calendar,done:true,updatedAt:updated.updatedAt}).length,1);
console.log('Legacy and calendar sync compatibility, invalid metadata rejection: passed');

assert.deepEqual(parseCapture('can you add to my to do list to do an interview','thought'),{kind:'todo',text:'do an interview'});
assert.deepEqual(parseCapture('add to my to do this to do an interview','thought'),{kind:'todo',text:'do an interview'});
const removed={...item,deleted:true,updatedAt:'2026-10-06T13:00:00Z'};assert.equal(validateItem(removed),true);assert.equal(validateItem({...calendar,deleted:true}),false);assert.equal(merge([removed],item)[0].deleted,true);
const message={id:crypto.randomUUID(),conversationID:crypto.randomUUID(),role:'user',text:'What can you help me with?',createdAt:item.createdAt};
assert.deepEqual(await open(token,await seal(token,{v:1,op:'chat',message})),{v:1,op:'chat',message});
const voice={id:crypto.randomUUID(),messageID:message.id,index:0,count:1,data:btoa('testaudio')};
assert.deepEqual(await open(token,await seal(token,{v:1,op:'voice',voice})),{v:1,op:'voice',voice});
await assert.rejects(open(token,await seal(token,{v:1,op:'voice',voice:{...voice,count:33}})));
await assert.rejects(open(token,await seal(token,{v:1,op:'chat',message:{...message,role:'chef',text:'x'.repeat(401)}})));
console.log('Leading destination, tombstones, safe chat/voice cursor compatibility: passed');

const briefing={id:crypto.randomUUID(),conversationID:message.conversationID,requestType:'now',request:'Give me a briefing',createdAt:item.createdAt};
assert.deepEqual(await open(token,await seal(token,{v:1,op:'briefing',briefing})),{v:1,op:'briefing',briefing});
await assert.rejects(open(token,await seal(token,{v:1,op:'briefing',briefing:{...briefing,requestType:'shell'}})));
console.log('Typed read-only/scheduled briefing sync validation: passed');
