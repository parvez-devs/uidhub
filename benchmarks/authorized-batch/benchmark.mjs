import {runBatch} from "./queue.mjs";
const count=Number(process.argv[2]??5000);
const rate=Number(process.argv[3]??200);
const ids=Array.from({length:count},(_,i)=>String(100000000000000+i));
const result=await runBatch(ids,async uid=>({status:"success",data:{uid,source:"SYNTHETIC_MOCK"}}),{
  concurrency:16,ratePerSecond:rate,
  onProgress:s=>{if(s.done%1000===0||s.done===count)console.log(JSON.stringify({event:"progress",done:s.done,failed:s.failed,elapsedMs:s.elapsedMs}));}
});
const passed=result.total===5000&&result.success===5000&&result.failed===0&&result.elapsedMs<=600000;
console.log(JSON.stringify({mode:"SYNTHETIC_NOT_FACEBOOK",total:result.total,success:result.success,failed:result.failed,elapsedMs:result.elapsedMs,passed}));
if(!passed)process.exitCode=1;
