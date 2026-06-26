"""
RADS-WEB FastAPI Backend
Rocky Active Directory Server — Web Edition
"""
import os
import secrets
import time
import asyncio
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Request, Response, HTTPException, Depends
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware

import pam

# ── Application ───────────────────────────────────────────────────────────────
app = FastAPI(title="RADS-WEB API", version="1.0.0", docs_url=None, redoc_url=None)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Session store (in-memory) ─────────────────────────────────────────────────
SESSIONS: dict[str, dict] = {}
SESSION_TTL = 28800  # 8 hours

def create_session(username: str) -> str:
    token = secrets.token_hex(32)
    SESSIONS[token] = {"username": username, "created": time.time()}
    return token

def get_session(token: str) -> Optional[dict]:
    s = SESSIONS.get(token)
    if not s:
        return None
    if time.time() - s["created"] > SESSION_TTL:
        del SESSIONS[token]
        return None
    return s

def require_auth(request: Request) -> dict:
    token = request.cookies.get("rads_session") or request.headers.get("X-Session-Token")
    session = get_session(token or "")
    if not session:
        raise HTTPException(status_code=401, detail="Not authenticated")
    return session

# ── Auth routes ───────────────────────────────────────────────────────────────
@app.post("/api/login")
async def login(request: Request, response: Response):
    body = await request.json()
    username = body.get("username", "").strip()
    password = body.get("password", "")

    if not username or not password:
        raise HTTPException(status_code=400, detail="Username and password required")

    p = pam.pam()
    if p.authenticate(username, password):
        token = create_session(username)
        response.set_cookie("rads_session", token, httponly=True, samesite="lax", max_age=SESSION_TTL)
        return {"status": "ok", "username": username, "token": token}
    else:
        raise HTTPException(status_code=401, detail="Invalid credentials")

@app.post("/api/logout")
async def logout(request: Request, response: Response):
    token = request.cookies.get("rads_session") or request.headers.get("X-Session-Token")
    if token and token in SESSIONS:
        del SESSIONS[token]
    response.delete_cookie("rads_session")
    return {"status": "ok"}

@app.get("/api/auth/check")
async def auth_check(session: dict = Depends(require_auth)):
    return {"status": "ok", "username": session["username"]}

# ── Include routers ───────────────────────────────────────────────────────────
from routes.users         import router as users_router
from routes.groups        import router as groups_router
from routes.service       import router as service_router
from routes.diagnostics   import router as diag_router
from routes.dns           import router as dns_router
from routes.system        import router as system_router
from routes.dashboard     import router as dashboard_router
from routes.samba_upgrade import router as upgrade_router

app.include_router(users_router,     prefix="/api/users",          tags=["users"])
app.include_router(groups_router,    prefix="/api/groups",         tags=["groups"])
app.include_router(service_router,   prefix="/api/service",        tags=["service"])
app.include_router(diag_router,      prefix="/api/diagnostics",    tags=["diagnostics"])
app.include_router(dns_router,       prefix="/api/dns",            tags=["dns"])
app.include_router(system_router,    prefix="/api/system",         tags=["system"])
app.include_router(dashboard_router, prefix="/api/dashboard",      tags=["dashboard"])
app.include_router(upgrade_router,   prefix="/api/samba/upgrade",  tags=["upgrade"])
