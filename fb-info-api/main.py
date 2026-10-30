"""XEROXHUB FB Info API: authorized Facebook profile/Page lookup."""
import asyncio
import os
import re
import secrets
from typing import Literal

from fastapi import Depends, FastAPI, Header, HTTPException, Query
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from meta import GRAPH_TOKEN, UPSTREAM_RPM, get_authorized_profile
from ratecontrol import TTLCache, RateLimiter

app = FastAPI(title="XEROXHUB FB Info API", version="1.0.0")
API_KEYS = tuple(x.strip() for x in os.getenv("API_KEYS", "").split(",") if x.strip())
IDENTIFIER = re.compile(r"^[A-Za-z0-9._]{1,100}$")
MAX_BATCH = min(100, max(1, int(os.getenv("MAX_BATCH", "50"))))
cache = TTLCache()
limiter = RateLimiter()

class Profile(BaseModel):
    requested: str
    uid: str | None = None
    name: str | None = None
    username: str | None = None
    profile_pic: str | None = None
    source: str = "meta_graph_api"
    cached: bool = False
    checked_at: str

class BatchRequest(BaseModel):
    identifiers: list[str] = Field(min_length=1, max_length=100)
    kind: Literal["auto", "page", "user"] = "auto"

class BatchItem(BaseModel):
    requested: str
    status: int
    profile: Profile | None = None
    error: str | None = None

def validate(identifier: str) -> str:
    value = identifier.strip()
    if not IDENTIFIER.fullmatch(value) or value in (".", ".."):
        raise HTTPException(422, "invalid_identifier")
    return value

async def authenticate(x_api_key: str | None = Header(default=None, alias="X-API-Key")):
    if not API_KEYS:
        raise HTTPException(503, "api_keys_not_configured")
    if not x_api_key or not any(secrets.compare_digest(x_api_key, k) for k in API_KEYS):
        raise HTTPException(401, "invalid_api_key")
    await limiter.check(x_api_key)
    return x_api_key

async def resolve(identifier: str, kind: str = "auto") -> Profile:
    value = validate(identifier)
    cache_key = f"{kind}:{value.lower()}"
    existing = await cache.get(cache_key)
    if existing:
        return Profile(**existing)
    result = await get_authorized_profile(value, kind)
    await cache.put(cache_key, result)
    return Profile(**result)

@app.get("/health")
async def health():
    return {"status": "ok", "meta_configured": bool(GRAPH_TOKEN),
            "api_keys_configured": bool(API_KEYS), "upstream_rpm_configured": UPSTREAM_RPM}

@app.get("/uid", response_model=Profile)
async def uid(
    uid: str | None = Query(default=None),
    username: str | None = Query(default=None),
    id: str | None = Query(default=None),
    kind: Literal["auto", "page", "user"] = "auto",
    _: str = Depends(authenticate),
):
    values = [x for x in (uid, username, id) if x is not None]
    if len(values) != 1:
        raise HTTPException(422, "supply_exactly_one_of_uid_username_id")
    return await resolve(values[0], kind)

@app.post("/batch", response_model=list[BatchItem])
async def batch(req: BatchRequest, _: str = Depends(authenticate)):
    if len(req.identifiers) > MAX_BATCH:
        raise HTTPException(422, f"max_batch_size_{MAX_BATCH}")
    pool = asyncio.Semaphore(10)
    async def one(identifier):
        async with pool:
            try:
                return BatchItem(requested=identifier, status=200,
                                 profile=await resolve(identifier, req.kind))
            except HTTPException as exc:
                return BatchItem(requested=identifier, status=exc.status_code, error=str(exc.detail))
    return await asyncio.gather(*(one(x) for x in req.identifiers))

@app.exception_handler(HTTPException)
async def api_error(_, exc: HTTPException):
    return JSONResponse(status_code=exc.status_code,
                        content={"success": False, "error": exc.detail},
                        headers=exc.headers)
