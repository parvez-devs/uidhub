import test from "node:test";
import assert from "node:assert/strict";
import {runBatch} from "./queue.mjs";

test("deduplicates source calls but keeps all output rows",async()=>{
  let calls=0;
  const x=await runBatch(["4","4","42"],async uid=>{
    calls++;
    return {status:"success",data:{name:"synthetic-"+uid}};
  },{concurrency:2,ratePerSecond:400});
  assert.equal(x.total,3);
  assert.equal(x.unique,2);
  assert.equal(x.success,3);
  assert.equal(calls,2);
  assert.deepEqual(x.results.map(r=>r.uid),["4","4","42"]);
});

test("transient errors retry without false success",async()=>{
  const attempts=new Map();
  const x=await runBatch(["123","456"],async uid=>{
    const n=(attempts.get(uid)||0)+1;attempts.set(uid,n);
    if(uid==="123"&&n===1)return {status:"error",reason:"temporary_failure"};
    if(uid==="456")return {status:"error",reason:"no_data"};
    return {status:"success",data:{name:"mock"}};
  },{ratePerSecond:100,concurrency:2,maxAttempts:2});
  assert.equal(x.success,1);assert.equal(x.failed,1);
  assert.equal(attempts.get("123"),2);assert.equal(attempts.get("456"),1);
});

test("invalid UID rejected without calling adapter",async()=>{
  let calls=0;
  await assert.rejects(runBatch(["abc"],async()=>{
    calls++;return {status:"success",data:{}};
  }),/Invalid UID/);
  assert.equal(calls,0);
});

test("source rate limiting triggers delay before retry",async()=>{
  let attempts=0;
  const start=Date.now();
  const x=await runBatch(["789"],async()=>{
    if(++attempts===1)return {status:"error",reason:"rate_limited",retryAfterMs:1000};
    return {status:"success",data:{name:"mock"}};
  },{ratePerSecond:100,maxAttempts:2});
  assert.equal(x.success,1);
  assert.equal(x.rateLimited,1);
  assert.ok(Date.now()-start>=900);
});
