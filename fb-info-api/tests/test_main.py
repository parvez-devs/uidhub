import os
os.environ.setdefault("API_KEYS", "local-test-secret")
os.environ.setdefault("FACEBOOK_ACCESS_TOKEN", "mock-token-not-real")

import main
from fastapi.testclient import TestClient

client = TestClient(main.app)
AUTH = {"X-API-Key": "local-test-secret"}

def test_health():
    assert client.get("/health").json()["status"] == "ok"

def test_authentication():
    assert client.get("/uid?uid=123").status_code == 401

def test_rejects_missing_and_multiple_identifiers():
    assert client.get("/uid", headers=AUTH).status_code == 422
    assert client.get("/uid?uid=123&username=abc", headers=AUTH).status_code == 422

def test_identifier_validation():
    assert client.get("/uid?uid=https://example.org", headers=AUTH).status_code == 422

def test_page_lookup_and_cache(monkeypatch):
    calls = []
    async def graph(identifier, kind):
        calls.append(identifier)
        return {
            "requested": identifier, "uid": "42", "name": "Mock Page",
            "username": "mockpage", "profile_pic": "https://example.org/42.jpg",
            "source": "meta_graph_api", "cached": False,
            "checked_at": "2026-10-30T00:00:00+00:00",
        }
    monkeypatch.setattr(main, "get_authorized_profile", graph)
    first = client.get("/uid?username=mockpage&kind=page", headers=AUTH)
    second = client.get("/uid?username=mockpage&kind=page", headers=AUTH)
    assert first.status_code == 200 and first.json()["name"] == "Mock Page"
    assert second.json()["cached"] is True
    assert len(calls) == 1

def test_batch(monkeypatch):
    async def graph(identifier, kind):
        return {"requested": identifier, "uid": identifier, "name": "Mock",
                "username": None, "profile_pic": None, "source": "meta_graph_api",
                "cached": False, "checked_at": "2026-10-30T00:00:00+00:00"}
    monkeypatch.setattr(main, "get_authorized_profile", graph)
    x = client.post("/batch", json={"identifiers": ["90001", "90002"], "kind": "user"}, headers=AUTH)
    assert x.status_code == 200
    assert len(x.json()) == 2 and all(i["status"] == 200 for i in x.json())

def test_permission_failure_not_faked(monkeypatch):
    async def blocked(identifier, kind):
        raise main.HTTPException(403, "meta_permission_denied")
    monkeypatch.setattr(main, "get_authorized_profile", blocked)
    x = client.get("/uid?uid=789012", headers=AUTH)
    assert x.status_code == 403
    assert x.json()["error"] == "meta_permission_denied"
