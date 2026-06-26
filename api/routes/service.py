from fastapi import APIRouter, Depends, HTTPException
from main import require_auth
import samba

router = APIRouter()


@router.get("/status")
async def service_status(session: dict = Depends(require_auth)):
    return await samba.get_service_status()


@router.post("/{action}")
async def service_action(action: str, session: dict = Depends(require_auth)):
    if action not in ("start", "stop", "restart", "reload"):
        raise HTTPException(status_code=400, detail=f"Invalid action: {action}")
    ok, msg = await samba.control_service(action)
    if not ok:
        raise HTTPException(status_code=500, detail=msg)
    return {"status": "ok", "action": action, "message": msg}
