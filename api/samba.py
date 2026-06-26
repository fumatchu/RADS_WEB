"""
samba-tool command wrappers for RADS-WEB
All samba-tool calls run as root (the service user).
"""
import asyncio
import re
import subprocess
from typing import Optional


async def run(cmd: list[str], input_text: Optional[str] = None, timeout: int = 30) -> tuple[int, str, str]:
    """Run a command asynchronously, return (returncode, stdout, stderr)."""
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        stdin=asyncio.subprocess.PIPE if input_text else None,
    )
    try:
        stdin_data = input_text.encode() if input_text else None
        stdout, stderr = await asyncio.wait_for(proc.communicate(input=stdin_data), timeout=timeout)
        return proc.returncode, stdout.decode(errors="replace"), stderr.decode(errors="replace")
    except asyncio.TimeoutError:
        proc.kill()
        await proc.communicate()
        return -1, "", f"Command timed out after {timeout}s"


# ── Domain info ───────────────────────────────────────────────────────────────

async def get_domain_info() -> dict:
    rc, out, err = await run(["samba-tool", "domain", "level", "show"])
    info: dict = {"raw": out.strip()}
    for line in out.splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            info[k.strip().lower().replace(" ", "_")] = v.strip()
    return info


async def get_realm() -> str:
    rc, out, _ = await run(["samba-tool", "testparm", "--suppress-prompt", "--parameter-name=realm"])
    return out.strip() or "UNKNOWN"


# ── Users ─────────────────────────────────────────────────────────────────────

async def list_users() -> list[str]:
    rc, out, _ = await run(["samba-tool", "user", "list"])
    if rc != 0:
        return []
    return sorted([u.strip() for u in out.splitlines() if u.strip()])


async def show_user(username: str) -> dict:
    rc, out, err = await run(["samba-tool", "user", "show", username])
    if rc != 0:
        return {"error": err.strip() or f"User '{username}' not found"}
    info: dict = {}
    for line in out.splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            info[k.strip()] = v.strip()
    return info


async def create_user(username: str, password: str, given_name: str = "",
                       surname: str = "", email: str = "") -> tuple[bool, str]:
    cmd = ["samba-tool", "user", "create", username, password]
    if given_name:
        cmd += ["--given-name", given_name]
    if surname:
        cmd += ["--surname", surname]
    if email:
        cmd += ["--mail-address", email]
    rc, out, err = await run(cmd)
    if rc == 0:
        return True, out.strip() or f"User '{username}' created"
    return False, err.strip() or out.strip()


async def delete_user(username: str) -> tuple[bool, str]:
    rc, out, err = await run(["samba-tool", "user", "delete", username])
    return rc == 0, (out.strip() or err.strip())


async def set_password(username: str, password: str) -> tuple[bool, str]:
    rc, out, err = await run(["samba-tool", "user", "setpassword", username,
                               f"--newpassword={password}"])
    return rc == 0, (out.strip() or err.strip())


async def enable_user(username: str) -> tuple[bool, str]:
    rc, out, err = await run(["samba-tool", "user", "enable", username])
    return rc == 0, (out.strip() or err.strip())


async def disable_user(username: str) -> tuple[bool, str]:
    rc, out, err = await run(["samba-tool", "user", "disable", username])
    return rc == 0, (out.strip() or err.strip())


# ── Groups ────────────────────────────────────────────────────────────────────

async def list_groups() -> list[str]:
    rc, out, _ = await run(["samba-tool", "group", "list"])
    if rc != 0:
        return []
    return sorted([g.strip() for g in out.splitlines() if g.strip()])


async def show_group(groupname: str) -> dict:
    rc, out, err = await run(["samba-tool", "group", "show", groupname])
    if rc != 0:
        return {"error": err.strip()}
    info: dict = {}
    for line in out.splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            info[k.strip()] = v.strip()
    return info


async def create_group(groupname: str, description: str = "") -> tuple[bool, str]:
    cmd = ["samba-tool", "group", "add", groupname]
    if description:
        cmd += ["--description", description]
    rc, out, err = await run(cmd)
    return rc == 0, (out.strip() or err.strip())


async def delete_group(groupname: str) -> tuple[bool, str]:
    rc, out, err = await run(["samba-tool", "group", "delete", groupname])
    return rc == 0, (out.strip() or err.strip())


async def list_group_members(groupname: str) -> list[str]:
    rc, out, _ = await run(["samba-tool", "group", "listmembers", groupname])
    if rc != 0:
        return []
    return sorted([m.strip() for m in out.splitlines() if m.strip()])


async def add_group_member(groupname: str, member: str) -> tuple[bool, str]:
    rc, out, err = await run(["samba-tool", "group", "addmembers", groupname, member])
    return rc == 0, (out.strip() or err.strip())


async def remove_group_member(groupname: str, member: str) -> tuple[bool, str]:
    rc, out, err = await run(["samba-tool", "group", "removemembers", groupname, member])
    return rc == 0, (out.strip() or err.strip())


# ── DNS ───────────────────────────────────────────────────────────────────────

async def _get_server_and_admin() -> tuple[str, str]:
    """Get the local DC FQDN for samba-tool dns calls."""
    import socket
    fqdn = socket.getfqdn()
    return fqdn, "localhost"


async def list_dns_zones(server: str) -> list[str]:
    rc, out, err = await run(["samba-tool", "dns", "zonelist", server, "-U", "Administrator%placeholder"])
    # parse zone names
    zones = re.findall(r"pszZoneName\s*:\s*(.+)", out)
    return zones


async def query_dns(server: str, zone: str, name: str, rtype: str) -> str:
    rc, out, err = await run(["samba-tool", "dns", "query", server, zone, name, rtype,
                               "-U", "Administrator%placeholder"])
    return out.strip() if rc == 0 else err.strip()


async def add_dns_record(server: str, zone: str, name: str, rtype: str, data: str,
                          admin_pass: str) -> tuple[bool, str]:
    rc, out, err = await run(["samba-tool", "dns", "add", server, zone, name, rtype, data,
                               f"-U", f"Administrator%{admin_pass}"])
    return rc == 0, (out.strip() or err.strip())


async def delete_dns_record(server: str, zone: str, name: str, rtype: str, data: str,
                             admin_pass: str) -> tuple[bool, str]:
    rc, out, err = await run(["samba-tool", "dns", "delete", server, zone, name, rtype, data,
                               f"-U", f"Administrator%{admin_pass}"])
    return rc == 0, (out.strip() or err.strip())


# ── Service ───────────────────────────────────────────────────────────────────

async def _get_samba_service() -> str:
    """Return the active samba service name."""
    for name in ("samba", "smb"):
        rc, out, _ = await run(["systemctl", "is-active", name])
        if rc == 0:
            return name
        rc2, _, _ = await run(["systemctl", "is-enabled", name])
        if rc2 == 0:
            return name
    return "samba"


async def get_service_status() -> dict:
    svc = await _get_samba_service()
    rc, out, _ = await run(["systemctl", "status", svc, "--no-pager", "-l"])
    active_rc, active_out, _ = await run(["systemctl", "is-active", svc])
    enabled_rc, enabled_out, _ = await run(["systemctl", "is-enabled", svc])
    return {
        "service": svc,
        "active": active_out.strip(),
        "enabled": enabled_out.strip(),
        "output": out.strip(),
    }


async def control_service(action: str) -> tuple[bool, str]:
    if action not in ("start", "stop", "restart", "reload"):
        return False, "Invalid action"
    svc = await _get_samba_service()
    rc, out, err = await run(["systemctl", action, svc])
    return rc == 0, (out.strip() or err.strip() or f"{svc} {action} {'OK' if rc==0 else 'FAILED'}")


# ── Diagnostics ───────────────────────────────────────────────────────────────

async def run_diagnostics(admin_pass: str = "") -> list[dict]:
    import socket
    fqdn = socket.getfqdn()
    realm = await get_realm()
    results = []

    async def test(name: str, cmd: list[str], success_hint: str = "") -> dict:
        rc, out, err = await run(cmd, timeout=15)
        return {
            "name": name,
            "passed": rc == 0,
            "output": (out.strip() or err.strip())[:500],
            "hint": success_hint if rc != 0 else "",
        }

    results.append(await test(
        "Kerberos SRV Record",
        ["host", "-t", "SRV", f"_kerberos._udp.{realm}"],
        f"Check DNS is running and {realm} zone exists"
    ))
    results.append(await test(
        "LDAP SRV Record",
        ["host", "-t", "SRV", f"_ldap._tcp.{realm}"],
        f"Check DNS is running and {realm} zone exists"
    ))
    results.append(await test(
        "Anonymous LDAP",
        ["ldapsearch", "-H", f"ldap://{fqdn}", "-x", "-b", "", "-s", "base"],
        "Samba may not be running or LDAP port blocked"
    ))
    results.append(await test(
        "Samba User List",
        ["samba-tool", "user", "list"],
        "Samba service may not be running"
    ))
    results.append(await test(
        "Samba Group List",
        ["samba-tool", "group", "list"],
        "Samba service may not be running"
    ))
    results.append(await test(
        "NTP Sync Status",
        ["chronyc", "tracking"],
        "Check chrony service and NTP server reachability"
    ))
    results.append(await test(
        "Domain Level",
        ["samba-tool", "domain", "level", "show"],
        "Samba may not be running"
    ))
    return results
