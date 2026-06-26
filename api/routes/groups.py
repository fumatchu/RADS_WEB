from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from typing import Optional
from main import require_auth
import samba

router = APIRouter()


class CreateGroupRequest(BaseModel):
    groupname: str
    description: Optional[str] = ""


class MemberRequest(BaseModel):
    member: str


@router.get("")
async def list_groups(session: dict = Depends(require_auth)):
    groups = await samba.list_groups()
    return {"groups": groups}


@router.get("/{groupname}")
async def get_group(groupname: str, session: dict = Depends(require_auth)):
    info = await samba.show_group(groupname)
    if "error" in info:
        raise HTTPException(status_code=404, detail=info["error"])
    members = await samba.list_group_members(groupname)
    info["members"] = members
    return info


@router.post("")
async def create_group(body: CreateGroupRequest, session: dict = Depends(require_auth)):
    ok, msg = await samba.create_group(body.groupname, body.description)
    if not ok:
        raise HTTPException(status_code=400, detail=msg)
    return {"status": "ok", "message": msg}


@router.delete("/{groupname}")
async def delete_group(groupname: str, session: dict = Depends(require_auth)):
    ok, msg = await samba.delete_group(groupname)
    if not ok:
        raise HTTPException(status_code=400, detail=msg)
    return {"status": "ok", "message": msg}


@router.get("/{groupname}/members")
async def get_members(groupname: str, session: dict = Depends(require_auth)):
    members = await samba.list_group_members(groupname)
    return {"group": groupname, "members": members}


@router.post("/{groupname}/members")
async def add_member(groupname: str, body: MemberRequest, session: dict = Depends(require_auth)):
    ok, msg = await samba.add_group_member(groupname, body.member)
    if not ok:
        raise HTTPException(status_code=400, detail=msg)
    return {"status": "ok", "message": msg}


@router.delete("/{groupname}/members/{member}")
async def remove_member(groupname: str, member: str, session: dict = Depends(require_auth)):
    ok, msg = await samba.remove_group_member(groupname, member)
    if not ok:
        raise HTTPException(status_code=400, detail=msg)
    return {"status": "ok", "message": msg}
