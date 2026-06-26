import socket
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from typing import Optional
from main import require_auth
import samba

router = APIRouter()


class AddDNSRecord(BaseModel):
    zone: str
    name: str
    rtype: str        # A, AAAA, CNAME, MX, PTR, TXT, etc.
    data: str
    admin_pass: str


class DeleteDNSRecord(BaseModel):
    zone: str
    name: str
    rtype: str
    data: str
    admin_pass: str


@router.get("/zones")
async def list_zones(session: dict = Depends(require_auth)):
    server = socket.getfqdn()
    zones = await samba.list_dns_zones(server)
    return {"server": server, "zones": zones}


@router.get("/query")
async def query_record(zone: str, name: str, rtype: str = "A",
                        session: dict = Depends(require_auth)):
    server = socket.getfqdn()
    result = await samba.query_dns(server, zone, name, rtype)
    return {"server": server, "zone": zone, "name": name, "type": rtype, "result": result}


@router.post("/add")
async def add_record(body: AddDNSRecord, session: dict = Depends(require_auth)):
    server = socket.getfqdn()
    ok, msg = await samba.add_dns_record(server, body.zone, body.name,
                                          body.rtype, body.data, body.admin_pass)
    if not ok:
        raise HTTPException(status_code=400, detail=msg)
    return {"status": "ok", "message": msg}


@router.post("/delete")
async def delete_record(body: DeleteDNSRecord, session: dict = Depends(require_auth)):
    server = socket.getfqdn()
    ok, msg = await samba.delete_dns_record(server, body.zone, body.name,
                                             body.rtype, body.data, body.admin_pass)
    if not ok:
        raise HTTPException(status_code=400, detail=msg)
    return {"status": "ok", "message": msg}
