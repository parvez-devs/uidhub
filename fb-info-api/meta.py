"""Meta Graph API adapter. Returns only records explicitly available to the token."""
import asyncio
import logging
import os
import time
from datetime import datetime, timezone

import httpx
from fastapi import HTTPException

logger = logging.getLogger("xeroxhub.meta")
GRAPH_VERSION = os.getenv("GRAPH_API_VERSION", "v26.0")
GRAPH_TOKEN = os.getenv("FACEBOOK_ACCESS_TOKEN", "")
UPSTREAM_RPM = max(1, int(os.getenv("UPSTREAM_RPM", "240")))
PACE_SECONDS = 60.0 / UPSTREAM_RPM
_slots_lock = asyncio.Lock()
_next_slot = 0.0
_semaphore = asyncio.Semaphore(8)

async def pace():
    global _next_slot
    async with _slots_lock:
        now = time.monotonic()
        wait_s = max(0.0, _next_slot - now)
        _next_slot = max(now, _next_slot) + PACE_SECONDS
    if wait_s:
        await asyncio.sleep(wait_s)

def error_from_meta(error):
    code = error.get("code")
    if code in (4, 17, 32, 613):
        return HTTPException(429, "meta_rate_limited", headers={"Retry-After": "60"})
    if code == 190:
        return HTTPException(503, "meta_token_invalid_or_expired")
    if code in (10, 200):
        return HTTPException(403, "meta_permission_denied")
    if code in (100, 803) or error.get("error_subcode") == 33:
        return HTTPException(404, "profile_not_accessible_or_not_found")
    return HTTPException(502, "meta_upstream_error")

async def graph_request(identifier, fields):
    if not GRAPH_TOKEN:
        raise HTTPException(503, "facebook_access_token_not_configured")
    async with _semaphore:
        await pace()
        try:
            async with httpx.AsyncClient(timeout=10.0, follow_redirects=False) as client:
                response = await client.get(
                    f"https://graph.facebook.com/{GRAPH_VERSION}/{identifier}",
                    params={"fields": fields},
                    headers={"Authorization": f"Bearer {GRAPH_TOKEN}", "Accept": "application/json"},
                )
        except (httpx.TimeoutException, httpx.ConnectError) as exc:
            logger.warning("Meta request failed: %s", type(exc).__name__)
            raise HTTPException(502, "meta_unreachable") from exc
    try:
        data = response.json()
    except ValueError as exc:
        raise HTTPException(502, "invalid_meta_response") from exc
    if not isinstance(data, dict):
        raise HTTPException(502, "invalid_meta_response")
    if "error" in data:
        raise error_from_meta(data["error"])
    if response.status_code == 429:
        raise HTTPException(429, "meta_rate_limited",
                            headers={"Retry-After": response.headers.get("Retry-After", "60")})
    if response.is_error:
        raise HTTPException(502, "meta_upstream_error")
    return data

async def get_authorized_profile(identifier, kind):
    base_fields = "id,name,picture.type(large){url,is_silhouette}"
    if kind in ("auto", "page"):
        try:
            data = await graph_request(identifier, base_fields + ",username")
        except HTTPException as exc:
            if exc.status_code != 404:
                raise
            data = await graph_request(identifier, base_fields)
    else:
        data = await graph_request(identifier, base_fields)
    if not data.get("id") or not data.get("name"):
        raise HTTPException(404, "profile_not_accessible_or_not_found")
    picture = data.get("picture") or {}
    image_data = picture.get("data") if isinstance(picture, dict) else None
    image_url = None
    if isinstance(image_data, dict) and not image_data.get("is_silhouette", False):
        image_url = image_data.get("url")
    return {
        "requested": identifier,
        "uid": str(data["id"]),
        "name": data["name"],
        "username": data.get("username"),
        "profile_pic": image_url,
        "source": "meta_graph_api",
        "cached": False,
        "checked_at": datetime.now(timezone.utc).isoformat(),
    }
