import asyncio
import socket
import platform
import subprocess
from fastapi import APIRouter, Depends, Request
from main import require_auth
import samba

router = APIRouter()


@router.get("")
async def get_dashboard(session: dict = Depends(require_auth)):
    fqdn = socket.getfqdn()
    hostname = socket.gethostname()

    users, groups, svc_status, domain_info = await asyncio.gather(
        samba.list_users(),
        samba.list_groups(),
        samba.get_service_status(),
        samba.get_domain_info(),
        return_exceptions=True,
    )

    # Uptime
    try:
        with open("/proc/uptime") as f:
            uptime_secs = float(f.read().split()[0])
        days = int(uptime_secs // 86400)
        hours = int((uptime_secs % 86400) // 3600)
        mins = int((uptime_secs % 3600) // 60)
        uptime_str = f"{days}d {hours}h {mins}m"
    except Exception:
        uptime_str = "unknown"

    # Check for pending Samba update
    import os
    update_flag = os.path.exists("/var/run/samba-update.flag")
    update_msg = ""
    if update_flag:
        try:
            with open("/var/run/samba-update.flag") as f:
                update_msg = f.read().strip()
        except Exception:
            update_msg = "Samba update available"

    return {
        "hostname": fqdn,
        "short_hostname": hostname,
        "os": platform.platform(),
        "uptime": uptime_str,
        "user_count": len(users) if isinstance(users, list) else 0,
        "group_count": len(groups) if isinstance(groups, list) else 0,
        "samba_status": svc_status if isinstance(svc_status, dict) else {"active": "unknown"},
        "domain_info": domain_info if isinstance(domain_info, dict) else {},
        "update_available": update_flag,
        "update_message": update_msg,
    }
