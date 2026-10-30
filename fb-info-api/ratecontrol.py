"""Bounded in-memory cache and per-key rate control for one API worker."""
import asyncio
import os
import time
from collections import OrderedDict, deque

from fastapi import HTTPException

class TTLCache:
    def __init__(self):
        self.ttl = max(0, int(os.getenv("CACHE_SECONDS", "900")))
        self.max_items = max(50, int(os.getenv("MAX_CACHE_ITEMS", "20000")))
        self.items = OrderedDict()
        self.lock = asyncio.Lock()

    async def get(self, key):
        async with self.lock:
            entry = self.items.get(key)
            if entry is None:
                return None
            expiry, value = entry
            if expiry <= time.monotonic():
                self.items.pop(key, None)
                return None
            self.items.move_to_end(key)
            return dict(value, cached=True)

    async def put(self, key, value):
        if not self.ttl:
            return
        async with self.lock:
            self.items[key] = (time.monotonic() + self.ttl, dict(value))
            self.items.move_to_end(key)
            while len(self.items) > self.max_items:
                self.items.popitem(last=False)

class RateLimiter:
    def __init__(self):
        self.limit = max(1, int(os.getenv("CLIENT_RPM", "400")))
        self.calls = {}
        self.lock = asyncio.Lock()

    async def check(self, key):
        async with self.lock:
            now = time.monotonic()
            if len(self.calls) > 5000:
                self.calls = {k: v for k, v in self.calls.items() if v and v[-1] > now - 60}
            events = self.calls.setdefault(key, deque())
            while events and events[0] <= now - 60:
                events.popleft()
            if len(events) >= self.limit:
                retry_after = max(1, int(60 - (now - events[0])) + 1)
                raise HTTPException(429, "client_rate_limited", headers={"Retry-After": str(retry_after)})
            events.append(now)
