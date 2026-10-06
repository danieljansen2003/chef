export type CalendarRequest={startAt:string;endAt:string;allDay:boolean;timeZone:string};
export type PocketItem={id:string;kind:'todo'|'thought'|'calendar';text:string;done:boolean;createdAt:string;updatedAt:string;calendarRequest?:CalendarRequest;deleted?:boolean};
export type Envelope={v:1;op:'upsert';item:PocketItem}|{v:1;op:'chat';message:{id:string;conversationID:string;role:'user'|'chef';text:string;createdAt:string;replyToID?:string}}|{v:1;op:'voice';voice:{id:string;messageID:string;index:number;count:number;data:string}}|{v:1;op:'briefing';briefing:{id:string;conversationID:string;requestType:'now'|'schedule';request:string;createdAt:string}};
export type Pending={id:string;payload:string};
const encoder=new TextEncoder();
export const hex=(buf:ArrayBuffer)=>Array.from(new Uint8Array(buf),v=>v.toString(16).padStart(2,'0')).join('');
export const digest=async(text:string)=>crypto.subtle.digest('SHA-256',encoder.encode(text));
export const channelFor=async(token:string)=>hex(await digest(token));
export const authorizationFor=async(token:string)=>hex(await digest('chef-auth-v1:'+token));
export function parseCapture(raw:string,kind:'todo'|'thought'):{kind:'todo'|'thought';text:string}{
 let text=raw.trim().replace(/^(?:(?:hi|hey|hello)\s+)?chef[,.!? ]+/i,'').replace(/^(?:(?:please|can you|could you)\s+)*(?:add|save|put)\s+/i,'');
 const leading=text.match(/^(?:to|in|on)\s+(?:my\s+)?(thoughts?|to[ -]?do(?:\s+(?:list|this))?|tasks?(?:\s+list)?)\s+(.+)$/i);
 if(leading){kind=/thought/i.test(leading[1])?'thought':'todo';text=leading[2].replace(/^to[ -]?do\s+/i,'do ');}
 const match=text.match(/^(.+?)\s+(?:to|in|on)\s+(?:my\s+)?(thoughts?|to[ -]?do(?: list)?|tasks?(?: list)?)[.!?]*$/i);
 if(match){text=match[1];kind=/thought/i.test(match[2])?'thought':'todo';}
 text=text.replace(/^["“]+|["”]+$/g,'').trim();if(!text||text.length>500) throw Error('Use between 1 and 500 characters.');
 return{kind,text};
}
export function validateItem(item:any):item is PocketItem{
 if(!item||!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(item.id)||!['todo','thought','calendar'].includes(item.kind)||typeof item.done!=='boolean'||typeof item.text!=='string'||!item.text.trim()||item.text.length>500||typeof item.createdAt!=='string'||!Number.isFinite(Date.parse(item.createdAt))||typeof item.updatedAt!=='string'||!Number.isFinite(Date.parse(item.updatedAt)))return false;
 if(item.deleted!==undefined&&typeof item.deleted!=='boolean'||item.deleted===true&&item.kind!=='todo')return false;
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
 const value=JSON.parse(new TextDecoder().decode(decoded));if(!validateEnvelope(value))throw Error('Invalid capture');return value;
}
export function validateEnvelope(value:any):value is Envelope{
 const uuid=(id:unknown)=>typeof id==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(id);
 if(value?.v!==1)return false;
 if(value.op==='upsert')return validateItem(value.item);
 if(value.op==='chat'){const m=value.message;return !!m&&uuid(m.id)&&uuid(m.conversationID)&&['user','chef'].includes(m.role)&&typeof m.text==='string'&&!!m.text.trim()&&m.text.length<=(m.role==='chef'?400:2000)&&typeof m.createdAt==='string'&&Number.isFinite(Date.parse(m.createdAt))&&(m.replyToID===undefined||uuid(m.replyToID));}
 if(value.op==='briefing'){const b=value.briefing;return !!b&&uuid(b.id)&&uuid(b.conversationID)&&['now','schedule'].includes(b.requestType)&&typeof b.request==='string'&&!!b.request.trim()&&b.request.length<=1200&&typeof b.createdAt==='string'&&Number.isFinite(Date.parse(b.createdAt));}
 if(value.op==='voice'){const v=value.voice;return !!v&&uuid(v.id)&&uuid(v.messageID)&&Number.isInteger(v.count)&&v.count>=1&&v.count<=32&&Number.isInteger(v.index)&&v.index>=0&&v.index<v.count&&typeof v.data==='string'&&v.data.length>0&&v.data.length<=8000&&/^[A-Za-z0-9+/]+={0,2}$/.test(v.data)&&v.data.length%4===0;}
 return false;
}
export function merge(items:PocketItem[],item:PocketItem){const prior=items.find(v=>v.id===item.id);if(prior&&Date.parse(prior.updatedAt)>=Date.parse(item.updatedAt))return items;return [item,...items.filter(v=>v.id!==item.id)].sort((a,b)=>Date.parse(b.createdAt)-Date.parse(a.createdAt));}
let database:Promise<IDBDatabase>|null=null;
function db(){return database??=new Promise<IDBDatabase>((resolve,reject)=>{const r=indexedDB.open('chef-pocket',1);r.onupgradeneeded=()=>r.result.createObjectStore('state');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(Error('Device storage is unavailable.'));});}
export async function readLocal<T>(key:string):Promise<T|null>{const d=await db();return new Promise((resolve,reject)=>{const r=d.transaction('state').objectStore('state').get(key);r.onsuccess=()=>resolve(r.result??null);r.onerror=()=>reject(Error('Cannot read device storage.'));});}
export async function saveLocal(key:string,value:unknown){const d=await db();return new Promise<void>((resolve,reject)=>{const t=d.transaction('state','readwrite');t.objectStore('state').put(value,key);t.oncomplete=()=>resolve();t.onerror=()=>reject(Error('Cannot save on this device.'));});}
