import { env } from "cloudflare:workers";
import { json, sha, token, validChannel, validEvent } from "../../../../../lib/relay";
function database(){if(!env.DB)throw Error('Sync database unavailable');return env.DB;}
async function authorize(request:Request,channel:string){
 if(!validChannel(channel)) return null;
 const bearer=token(request); if(!bearer) return null;
 const authHash=await sha(bearer);
 const row=await database().prepare("SELECT auth_hash FROM channels WHERE id = ?").bind(channel).first<{auth_hash:string}>();
 return row?.auth_hash===authHash?authHash:null;
}
export async function GET(request:Request,{params}:{params:Promise<{channel:string}>}){
 const {channel}=await params;
 try {
 if(!await authorize(request,channel)) return json({error:"Not paired"},401);
 const after=Number(new URL(request.url).searchParams.get("after")||0);if(!Number.isSafeInteger(after)||after<0) return json({error:"Invalid cursor"},400);
 const result=await database().prepare("SELECT seq, id, payload FROM events WHERE channel = ? AND seq > ? ORDER BY seq LIMIT 200").bind(channel,after).all();
 const rows=result.results as {seq:number,id:string,payload:string}[];
 return json({events:rows,cursor:rows.at(-1)?.seq??after});
 }catch{return json({error:"Sync is unavailable. Your capture is kept on this device."},503);}
}
export async function POST(request:Request,{params}:{params:Promise<{channel:string}>}){
 const {channel}=await params;
 const origin=request.headers.get("origin");if(origin&&origin!==new URL(request.url).origin) return json({error:"Origin rejected"},403);
 const bearer=token(request);if(!validChannel(channel)||!bearer) return json({error:"Not paired"},401);
 if(Number(request.headers.get("content-length")||0)>18000) return json({error:"Capture too large"},413);
 try{
 const raw=await request.text();if(raw.length>18000) return json({error:"Capture too large"},413);
 let data;try{data=JSON.parse(raw)}catch{return json({error:"Invalid capture"},400)}
 if(!validEvent(data)) return json({error:"Invalid encrypted capture"},400);
 const authHash=await sha(bearer);
 await database().prepare("INSERT INTO channels(id, auth_hash, created_at) VALUES(?, ?, ?) ON CONFLICT(id) DO NOTHING").bind(channel,authHash,Date.now()).run();
 if(!await authorize(request,channel)) return json({error:"Not paired"},401);
 const prior=await database().prepare("SELECT seq, payload FROM events WHERE channel = ? AND id = ?").bind(channel,data.id).first<{seq:number,payload:string}>();
 if(prior) return prior.payload===data.payload?json({ok:true,seq:prior.seq}):json({error:"Conflicting capture ID"},409);
 const count=await database().prepare("SELECT COUNT(*) AS n FROM events WHERE channel = ?").bind(channel).first<{n:number}>();
 if((count?.n??0)>=10000) return json({error:"Sync history is full; reconnect with a new pairing after saving a backup."},409);
 await database().prepare("INSERT INTO events(channel, id, payload, created_at) VALUES(?, ?, ?, ?) ON CONFLICT(channel,id) DO NOTHING").bind(channel,data.id,data.payload,Date.now()).run();
 const saved=await database().prepare("SELECT seq, payload FROM events WHERE channel = ? AND id = ?").bind(channel,data.id).first<{seq:number,payload:string}>();
 return saved && saved.payload===data.payload?json({ok:true,seq:saved.seq},201):json({error:"Conflicting capture ID"},409);
 }catch{return json({error:"Sync is unavailable. Your capture is kept on this device."},503);}
}
