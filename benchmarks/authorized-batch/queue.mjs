// Authorized-source batch executor. Not a Facebook scraper.
import {performance} from "node:perf_hooks";
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
export async function runBatch(ids, fetchAuthorized, opts={}){
  const concurrency=Math.max(1,Math.min(32,Math.floor(opts.concurrency??4)));
  const ratePerSecond=Math.max(0.1,Math.min(500,Number(opts.ratePerSecond??10)));
  const maxAttempts=Math.max(1,Math.min(4,Math.floor(opts.maxAttempts??2)));
  const timeoutMs=Math.max(100,Math.min(30000,Math.floor(opts.timeoutMs??8000)));
  if(!Array.isArray(ids)||typeof fetchAuthorized!=="function")throw new TypeError("ids and fetchAuthorized required");
  const entries=new Map();
  for(let i=0;i<ids.length;i++){
    const uid=String(ids[i]??"").trim();
    if(!/^[0-9]{1,20}$/.test(uid))throw new TypeError("Invalid UID at position "+i);
    if(!entries.has(uid))entries.set(uid,[]);
    entries.get(uid).push(i);
  }
  const queue=[...entries.keys()], output=new Array(ids.length);
  const stats={total:ids.length,unique:queue.length,done:0,success:0,failed:0,attempts:0,rateLimited:0};
  const started=performance.now();
  let next=0,nextGrant=performance.now(),cooldown=0,mutex=Promise.resolve();
  async function permit(){
    let release;
    const prev=mutex;
    mutex=new Promise(resolve=>release=resolve);
    await prev;
    const at=Math.max(performance.now(),nextGrant,cooldown);
    nextGrant=at+1000/ratePerSecond;
    release();
    await sleep(Math.max(0,at-performance.now()));
  }
  async function process(uid){
    let final={uid,status:"error",reason:"not_attempted"};
    for(let n=1;n<=maxAttempts;n++){
      if(opts.signal?.aborted){final={uid,status:"cancelled",reason:"cancelled"};break;}
      await permit();stats.attempts++;
      const ac=new AbortController(),timer=setTimeout(()=>ac.abort(),timeoutMs);
      try{
        const value=await fetchAuthorized(uid,{signal:ac.signal,attempt:n});
        if(value?.status==="success"&&value?.data!=null){
          final={uid,status:"success",data:value.data};break;
        }
        const reason=value?.reason??"no_data";
        final={uid,status:"error",reason};
        if(reason==="rate_limited"){
          stats.rateLimited++;
          cooldown=Math.max(cooldown,performance.now()+Math.min(60000,Math.max(1000,Number(value.retryAfterMs)||3000)));
        }
        if(!["rate_limited","temporary_failure","timeout"].includes(reason))break;
      }catch(e){final={uid,status:"error",reason:e?.name==="AbortError"?"timeout":"temporary_failure"};}
      finally{clearTimeout(timer);}
      if(n<maxAttempts)await sleep(250*2**(n-1));
    }
    const indexes=entries.get(uid);
    for(const index of indexes)output[index]={...final};
    stats.done+=indexes.length;
    if(final.status==="success")stats.success+=indexes.length;
    else stats.failed+=indexes.length;
    opts.onProgress?.({...stats,elapsedMs:Math.round(performance.now()-started)});
  }
  await Promise.all(Array.from({length:Math.min(concurrency,queue.length)},async()=>{
    while(next<queue.length&&!opts.signal?.aborted)await process(queue[next++]);
  }));
  return {...stats,elapsedMs:Math.round(performance.now()-started),results:output};
}
