export type CalendarRequest={startAt:string;endAt:string;allDay:boolean;timeZone:string};
export type PocketItem={id:string;kind:'todo'|'thought'|'calendar';text:string;done:boolean;createdAt:string;updatedAt:string;calendarRequest?:CalendarRequest};
export type Envelope={v:1;op:'upsert';item:PocketItem};
export type Pending={id:string;payload:string};
const encoder=new TextEncoder();
export const hex=(buf:ArrayBuffer)=>Array.from(new Uint8Array(buf),v=>v.toString(16).padStart(2,'0')).join('');
export const digest=async(text:string)=>crypto.subtle.digest('SHA-256',encoder.encode(text));
export const channelFor=async(token:string)=>hex(await digest(token));
export const authorizationFor=async(token:string)=>hex(await digest('chef-auth-v1:'+token));
export function parseCapture(raw:string,kind:'todo'|'thought'):{kind:'todo'|'thought';text:string}{
 let text=raw.trim().replace(/^(?:(?:hi|hey|hello)\s+)?chef[,.!? ]+/i,'').replace(/^(?:please\s+)?(?:add|save|put)\s+/i,'');
 const match=text.match(/^(.+?)\s+(?:to|in|on)\s+(?:my\s+)?(thoughts?|to[ -]?do(?: list)?|tasks?(?: list)?)[.!?]*$/i);
 if(match){text=match[1];kind=/thought/i.test(match[2])?'thought':'todo';}
 text=text.replace(/^["“]+|["”]+$/g,'').trim();if(!text||text.length>500) throw Error('Use between 1 and 500 characters.');
 return{kind,text};
}
export function validateItem(item:any):item is PocketItem{
 if(!item||!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(item.id)||!['todo','thought','calendar'].includes(item.kind)||typeof item.done!=='boolean'||typeof item.text!=='string'||!item.text.trim()||item.text.length>500||typeof item.createdAt!=='string'||!Number.isFinite(Date.parse(item.createdAt))||typeof item.updatedAt!=='string'||!Number.isFinite(Date.parse(item.updatedAt)))return false;
 if(item.kind!=='calendar')return item.calendarRequest===undefined;
 const request=item.calendarRequest;if(!request||typeof request.startAt!=='string'||typeof request.endAt!=='string'||typeof request.allDay!=='boolean'||typeof request.timeZone!=='string')return false;
 const start=Date.parse(request.startAt),end=Date.parse(request.endAt);if(!Number.isFinite(start)||!Number.isFinite(end)||end<=start||end-start>366*86400000)return false;
 try{new Intl.DateTimeFormat('en',{timeZone:request.timeZone});}catch{return false;}return !!request.timeZone;
}
export async function seal(token:string,envelope:Envelope){
 const key=await crypto.subtle.importKey('raw',await digest('chef-pocket-v1:'+token),'AES-GCM',false,['encrypt']);
 const iv=crypto.getRandomValues(new Uint8Array(12));const body=new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv},key,encoder.encode(JSON.stringify(envelope))));
 const combined=new Uint8Array(iv.length+body.length);combined.set(iv);combined.set(body,12);return btoa(String.fromCharCode(...combined));
}
export async function open(token:string,payload:string):Promise<Envelope>{
 const bytes=Uint8Array.from(atob(payload),v=>v.charCodeAt(0));if(bytes.length<29||bytes.length>12000)throw Error('Invalid sync payload');
 const key=await crypto.subtle.importKey('raw',await digest('chef-pocket-v1:'+token),'AES-GCM',false,['decrypt']);
 const decoded=await crypto.subtle.decrypt({name:'AES-GCM',iv:bytes.slice(0,12)},key,bytes.slice(12));
 const value=JSON.parse(new TextDecoder().decode(decoded));if(value.v!==1||value.op!=='upsert'||!validateItem(value.item))throw Error('Invalid capture');return value;
}
export function merge(items:PocketItem[],item:PocketItem){const prior=items.find(v=>v.id===item.id);if(prior&&Date.parse(prior.updatedAt)>=Date.parse(item.updatedAt))return items;return [item,...items.filter(v=>v.id!==item.id)].sort((a,b)=>Date.parse(b.createdAt)-Date.parse(a.createdAt));}
let database:Promise<IDBDatabase>|null=null;
function db(){return database??=new Promise<IDBDatabase>((resolve,reject)=>{const r=indexedDB.open('chef-pocket',1);r.onupgradeneeded=()=>r.result.createObjectStore('state');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(Error('Device storage is unavailable.'));});}
export async function readLocal<T>(key:string):Promise<T|null>{const d=await db();return new Promise((resolve,reject)=>{const r=d.transaction('state').objectStore('state').get(key);r.onsuccess=()=>resolve(r.result??null);r.onerror=()=>reject(Error('Cannot read device storage.'));});}
export async function saveLocal(key:string,value:unknown){const d=await db();return new Promise<void>((resolve,reject)=>{const t=d.transaction('state','readwrite');t.objectStore('state').put(value,key);t.oncomplete=()=>resolve();t.onerror=()=>reject(Error('Cannot save on this device.'));});}
