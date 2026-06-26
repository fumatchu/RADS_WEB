import asyncio
import os
import platform
import socket
import subprocess
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from main import require_auth
import samba

router = APIRouter()


@router.get("/info")
async def system_info(session: dict = Depends(require_auth)):
    fqdn = socket.getfqdn()

    # CPU/Memory
    try:
        with open("/proc/meminfo") as f:
            mem_lines = {l.split(":")[0]: l.split(":")[1].strip() for l in f if ":" in l}
        mem_total = mem_lines.get("MemTotal", "?")
        mem_free  = mem_lines.get("MemAvailable", "?")
    except Exception:
        mem_total = mem_free = "?"

    try:
        with open("/proc/loadavg") as f:
            load = f.read().strip().split()[:3]
        load_avg = " / ".join(load)
    except Exception:
        load_avg = "?"

    try:
        with open("/proc/uptime") as f:
            uptime_secs = float(f.read().split()[0])
        days = int(uptime_secs // 86400)
        hours = int((uptime_secs % 86400) // 3600)
        mins = int((uptime_secs % 3600) // 60)
        uptime_str = f"{days}d {hours}h {mins}m"
    except Exception:
        uptime_str = "?"

    # Disk usage
    rc, disk_out, _ = await samba.run(["df", "-h", "/"])
    disk_info = disk_out.strip().splitlines()[-1] if disk_out.strip() else "?"

    # Samba version
    rc2, samba_ver, _ = await samba.run(["samba", "--version"])
    samba_version = samba_ver.strip() or "unknown"

    # OS
    try:
        with open("/etc/os-release") as f:
            os_info = {}
            for line in f:
                if "=" in line:
                    k, _, v = line.partition("=")
                    os_info[k.strip()] = v.strip().strip('"')
        os_str = os_info.get("PRETTY_NAME", platform.platform())
    except Exception:
        os_str = platform.platform()

    return {
        "hostname": fqdn,
        "os": os_str,
        "uptime": uptime_str,
        "load_average": load_avg,
        "memory_total": mem_total,
        "memory_available": mem_free,
        "disk_root": disk_info,
        "samba_version": samba_version,
        "python_version": platform.python_version(),
    }


@router.get("/logs")
async def get_logs(lines: int = 100, source: str = "samba",
                   session: dict = Depends(require_auth)):
    if lines > 500:
        lines = 500

    if source == "samba":
        # Try journalctl first, then fall back to log files
        rc, out, _ = await samba.run(
            ["journalctl", "-u", "samba", "-u", "smb", "--no-pager", "-n", str(lines), "--output=short"]
        )
        if not out.strip():
            rc, out, _ = await samba.run(["tail", "-n", str(lines), "/var/log/samba/log.samba"])
    elif source == "rads":
        rc, out, _ = await samba.run(
            ["journalctl", "-u", "rads-web", "--no-pager", "-n", str(lines), "--output=short"]
        )
    elif source == "apache":
        rc, out, _ = await samba.run(
            ["tail", "-n", str(lines), "/var/log/httpd/rads-web-error.log"]
        )
    else:
        raise HTTPException(status_code=400, detail=f"Unknown log source: {source}")

    return {"source": source, "lines": lines, "output": out.strip()}


@router.post("/reboot")
async def reboot_system(session: dict = Depends(require_auth)):
    asyncio.create_task(_delayed_reboot())
    return {"status": "ok", "message": "System rebooting in 3 seconds..."}


@router.post("/shutdown")
async def shutdown_system(session: dict = Depends(require_auth)):
    asyncio.create_task(_delayed_shutdown())
    return {"status": "ok", "message": "System shutting down in 3 seconds..."}


@router.post("/update-check")
async def check_updates(session: dict = Depends(require_auth)):
    rc, out, err = await samba.run(
        ["dnf", "check-update", "--color=never", "-q"], timeout=60
    )
    updates = [l for l in out.splitlines() if l.strip() and not l.startswith("Last")]
    return {
        "updates_available": rc == 100,  # dnf returns 100 when updates exist
        "count": len(updates),
        "packages": updates[:50],
    }


async def _delayed_reboot():
    await asyncio.sleep(3)
    os.system("reboot")


async def _delayed_shutdown():
    await asyncio.sleep(3)
    os.system("poweroff")
