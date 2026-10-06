export const json = (data:unknown,status=200)=>Response.json(data,{status,headers:{"Cache-Control":"no-store","X-Content-Type-Options":"nosniff"}});
export const hex = (bytes:ArrayBuffer)=>Array.from(new Uint8Array(bytes),b=>b.toString(16).padStart(2,"0")).join("");
export async function sha(text:string){return hex(await crypto.subtle.digest("SHA-256",new TextEncoder().encode(text)));}
export function token(request:Request){const raw=request.headers.get("Authorization")||"";return /^Bearer [a-f0-9]{64}$/.test(raw)?raw.slice(7):null;}
export function validChannel(id:string){return /^[a-f0-9]{64}$/.test(id);}
export function validEvent(data:any){return data && /^[a-f0-9-]{36}$/i.test(data.id)&& /^[a-zA-Z0-9+/]+={0,2}$/.test(data.payload)&&data.payload.length>=40&&data.payload.length<=16384;}
