const KEY="d4t/smoke/D4T_TRANSPORT_SMOKE_RECEIPT_v1.json";
async function sha256Text(text){const d=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(text));return Array.from(new Uint8Array(d)).map(b=>b.toString(16).padStart(2,"0")).join("");}
const req=["S3_ENDPOINT","S3_BUCKET","S3_REGION","S3_ACCESS_KEY_ID","S3_SECRET_ACCESS_KEY"];
for(const k of req)if(!Bun.env[k])throw Error("MISSING_ENV_"+k);
const client=new Bun.S3Client({accessKeyId:Bun.env.S3_ACCESS_KEY_ID,secretAccessKey:Bun.env.S3_SECRET_ACCESS_KEY,bucket:Bun.env.S3_BUCKET,endpoint:Bun.env.S3_ENDPOINT,region:Bun.env.S3_REGION});
const text=await client.file(KEY).text();
const sha=await sha256Text(text);
const receipt=JSON.parse(text);
console.log("D4T_DURABLE_REREAD="+JSON.stringify({sha256:sha,status:receipt.status,study_id:receipt.study_id,probe_count_completed:receipt.probe_count_completed,smoke_contract_sha256:receipt.smoke_contract_sha256,seed_generation_authorized:receipt.seed_generation_authorized,scientific:receipt.scientific}));
Bun.serve({port:Number(Bun.env.PORT||3000),fetch(){return new Response(JSON.stringify({sha256:sha,status:receipt.status}),{headers:{"content-type":"application/json"}});}});
