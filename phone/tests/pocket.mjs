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
