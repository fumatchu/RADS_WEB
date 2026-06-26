from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from typing import Optional
from main import require_auth
import samba

router = APIRouter()


class CreateUserRequest(BaseModel):
    username: str
    password: str
    given_name: Optional[str] = ""
    surname: Optional[str] = ""
    email: Optional[str] = ""


class SetPasswordRequest(BaseModel):
    password: str


@router.get("")
async def list_users(session: dict = Depends(require_auth)):
    users = await samba.list_users()
    return {"users": users}


@router.get("/{username}")
async def get_user(username: str, session: dict = Depends(require_auth)):
    info = await samba.show_user(username)
    if "error" in info:
        raise HTTPException(status_code=404, detail=info["error"])
    return info


@router.post("")
async def create_user(body: CreateUserRequest, session: dict = Depends(require_auth)):
    ok, msg = await samba.create_user(
        body.username, body.password,
        body.given_name, body.surname, body.email
    )
    if not ok:
        raise HTTPException(status_code=400, detail=msg)
    return {"status": "ok", "message": msg}


@router.delete("/{username}")
async def delete_user(username: str, session: dict = Depends(require_auth)):
    ok, msg = await samba.delete_user(username)
    if not ok:
        raise HTTPException(status_code=400, detail=msg)
    return {"status": "ok", "message": msg}


@router.post("/{username}/password")
async def set_password(username: str, body: SetPasswordRequest, session: dict = Depends(require_auth)):
    ok, msg = await samba.set_password(username, body.password)
    if not ok:
        raise HTTPException(status_code=400, detail=msg)
    return {"status": "ok", "message": msg}


@router.post("/{username}/enable")
async def enable_user(username: str, session: dict = Depends(require_auth)):
    ok, msg = await samba.enable_user(username)
    if not ok:
        raise HTTPException(status_code=400, detail=msg)
    return {"status": "ok", "message": msg}


@router.post("/{username}/disable")
async def disable_user(username: str, session: dict = Depends(require_auth)):
    ok, msg = await samba.disable_user(username)
    if not ok:
        raise HTTPException(status_code=400, detail=msg)
    return {"status": "ok", "message": msg}
