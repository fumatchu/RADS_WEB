"""
RADS-WEB Samba Upgrade API
Three-stage upgrade flow:
  Stage 1 — /build     : Download SRPM + mock rebuild (background, 15-30 min)
  Stage 2 — /validate  : rpm --test + dnf --assumeno dry-run (fast, ~60s)
  Stage 3 — /apply     : One-way upgrade: stop → dnf upgrade → start → verify AD
"""

import asyncio
import glob
import os
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from main import require_auth
import samba

router = APIRouter()

# ── Constants ─────────────────────────────────────────────────────────────────
MOCK_CFG      = "rocky-10-x86_64"
MOCK_RESULT   = f"/var/lib/mock/{MOCK_CFG}/result"
SRPM_DIR      = "/root/samba-srpm-upgrade"
VERSION_FILE  = "/etc/samba-rads/installed-version"
LOCKED_FILE   = "/etc/samba-rads/locked-packages"
UPDATE_FLAG   = "/var/run/samba-update.flag"

# ── In-memory task state ──────────────────────────────────────────────────────
# stage: idle | building | built | validating | validated | applying | done | failed
_task: dict = {
    "stage":      "idle",
    "status":     "idle",   # idle | running | success | failed | success_with_warnings
    "log":        [],
    "built_rpms": [],
}


# ═════════════════════════════════════════════════════════════════════════════
# STATUS
# ═════════════════════════════════════════════════════════════════════════════

@router.get("/status")
async def upgrade_status(session: dict = Depends(require_auth)):
    installed = _read_file(VERSION_FILE, "unknown").strip()
    available = _read_file(UPDATE_FLAG, "").strip()
    return {
        "installed_version": installed,
        "available_version": available or None,
        "update_available":  bool(available),
        "task": {
            "stage":      _task["stage"],
            "status":     _task["status"],
            "log":        _task["log"],
            "rpms_ready": len(_task["built_rpms"]),
        },
    }


# ═════════════════════════════════════════════════════════════════════════════
# STAGE 1 — BUILD
# ═════════════════════════════════════════════════════════════════════════════

@router.post("/build")
async def start_build(
    background_tasks: BackgroundTasks,
    session: dict = Depends(require_auth),
):
    if _task["status"] == "running":
        raise HTTPException(status_code=409, detail="An upgrade task is already running")
    _reset("building")
    background_tasks.add_task(_run_build)
    return {"status": "started", "stage": "building",
            "message": "SRPM download and mock build started. Poll /status for progress."}


async def _run_build():
    try:
        os.makedirs(SRPM_DIR, exist_ok=True)

        # ── Download SRPM ─────────────────────────────────────────────────────
        _log("Enabling source repos...")
        await samba.run(
            ["dnf", "config-manager", "--set-enabled", "devel"],
            timeout=30,
        )

        _log("Downloading Samba SRPM from Rocky 10 repos...")
        rc, out, err = await samba.run(
            ["dnf", "download", "--source", "samba", "--destdir", SRPM_DIR],
            timeout=120,
        )
        if rc != 0:
            _fail(f"SRPM download failed (rc={rc}): {err.strip()[-500:]}")
            return

        srpms = glob.glob(f"{SRPM_DIR}/samba-*.src.rpm")
        if not srpms:
            _fail("No SRPM found in download dir after dnf download")
            return

        srpm = max(srpms, key=os.path.getmtime)   # newest if multiple
        _log(f"SRPM ready: {os.path.basename(srpm)}")

        # ── mock rebuild ──────────────────────────────────────────────────────
        _log(f"Starting mock rebuild (config: {MOCK_CFG}) — this takes 15-30 minutes...")
        rc, out, err = await samba.run(
            ["mock", "-r", MOCK_CFG, "--rebuild", srpm, "--resultdir", MOCK_RESULT],
            timeout=5400,   # 90-minute hard cap
        )
        if rc != 0:
            _fail(
                f"mock build failed (rc={rc})\n"
                + (err.strip()[-1500:] if err else "(no stderr)")
            )
            return

        rpms = [
            f for f in glob.glob(f"{MOCK_RESULT}/samba*.rpm")
            if not f.endswith(".src.rpm")
        ]
        if not rpms:
            _fail("mock exited 0 but no RPMs found in result dir")
            return

        _task["built_rpms"] = rpms
        _task["stage"]  = "built"
        _task["status"] = "success"
        _log(f"Build complete — {len(rpms)} RPMs ready for validation")

    except Exception as exc:
        _fail(f"Unhandled exception during build: {exc}")


# ═════════════════════════════════════════════════════════════════════════════
# STAGE 2 — VALIDATE (dry-run — Samba still running)
# ═════════════════════════════════════════════════════════════════════════════

@router.post("/validate")
async def validate_upgrade(session: dict = Depends(require_auth)):
    if _task["status"] == "running":
        raise HTTPException(status_code=409, detail="Task already running")
    if not _task["built_rpms"]:
        raise HTTPException(status_code=400, detail="No built RPMs — run /build first")
    if _task["stage"] not in ("built", "validated"):
        raise HTTPException(
            status_code=400,
            detail=f"Build must succeed before validation (current stage: {_task['stage']})",
        )

    _task["stage"]  = "validating"
    _task["status"] = "running"
    _task["log"].append("── Stage 2: Dry-run validation ──")

    rpms = _task["built_rpms"]

    # ── rpm --test ────────────────────────────────────────────────────────────
    _log("Running rpm --test (transaction test without writing)...")
    rc, out, err = await samba.run(
        ["rpm", "--test", "-Uvh", "--nodeps"] + rpms,
        timeout=120,
    )
    if rc != 0:
        _task["status"] = "failed"
        _log(f"rpm --test FAILED (rc={rc}):\n{err.strip()}")
        return {"status": "failed", "reason": "rpm --test", "log": _task["log"]}
    _log("rpm --test passed")

    # ── dnf upgrade --assumeno ────────────────────────────────────────────────
    _log("Running dnf upgrade --assumeno (dependency resolution dry-run)...")
    rc, out, err = await samba.run(
        ["dnf", "upgrade", "--assumeno", "--nogpgcheck", "--color=never"] + rpms,
        timeout=120,
    )
    # dnf --assumeno exits 1 when it would make changes (that's expected/OK)
    # It exits non-1 non-0 on actual errors
    if rc not in (0, 1):
        _task["status"] = "failed"
        _log(f"dnf dry-run returned unexpected rc={rc}:\n{err.strip()}")
        return {"status": "failed", "reason": "dnf --assumeno", "log": _task["log"]}

    # Check that the dry-run output doesn't show conflicts or errors
    combined = (out + err).lower()
    for problem in ("error:", "conflict", "protected", "nothing provides"):
        if problem in combined:
            _task["status"] = "failed"
            _log(f"dnf dry-run reported problems ('{problem}' found):\n{out.strip()[-800:]}")
            return {"status": "failed", "reason": f"dnf conflict: {problem}", "log": _task["log"]}

    _log("dnf dry-run passed — no dependency conflicts detected")
    _log("Upgrade is safe to apply. Snapshot your VM before proceeding to Stage 3.")

    _task["stage"]  = "validated"
    _task["status"] = "success"
    return {"status": "success", "log": _task["log"]}


# ═════════════════════════════════════════════════════════════════════════════
# STAGE 3 — APPLY  (point of no return)
# ═════════════════════════════════════════════════════════════════════════════

@router.post("/apply")
async def apply_upgrade(
    background_tasks: BackgroundTasks,
    session: dict = Depends(require_auth),
):
    if _task["status"] == "running":
        raise HTTPException(status_code=409, detail="Task already running")
    if _task["stage"] != "validated":
        raise HTTPException(
            status_code=400,
            detail="Validation must pass before applying (run /validate first)",
        )

    _task["stage"]  = "applying"
    _task["status"] = "running"
    _task["log"].append("── Stage 3: Applying upgrade (ONE-WAY) ──")
    background_tasks.add_task(_run_apply)
    return {
        "status":  "started",
        "stage":   "applying",
        "warning": "This cannot be undone. Poll /status for progress.",
    }


async def _run_apply():
    rpms = _task["built_rpms"]
    try:
        # ── Stop Samba ────────────────────────────────────────────────────────
        _log("Stopping Samba service...")
        await samba.control_service("stop")
        await asyncio.sleep(3)

        # ── dnf upgrade ───────────────────────────────────────────────────────
        _log("Applying dnf upgrade (RPM %config files preserved)...")
        rc, out, err = await samba.run(
            ["dnf", "upgrade", "-y", "--nogpgcheck", "--color=never"] + rpms,
            timeout=600,
        )
        if rc != 0:
            _log(f"dnf upgrade FAILED (rc={rc}):\n{err.strip()[-1000:]}")
            _log("CRITICAL: packages may be in inconsistent state — attempting Samba restart")
            await _try_restart_samba()
            _task["status"] = "failed"
            _task["stage"]  = "failed"
            return

        _log("Packages upgraded successfully")

        # ── Update versionlock at new version ─────────────────────────────────
        _log("Updating versionlock to new version...")
        # Remove old locks for the samba family
        for pattern in ("samba*", "libldb*", "libtalloc*", "libtevent*", "libtdb*", "libwbclient*"):
            await samba.run(
                ["dnf", "versionlock", "delete", pattern],
                timeout=30,
            )
        # Re-lock at new versions from the RPM files we just installed
        for rpm in rpms:
            pkg_name = os.path.basename(rpm).rsplit("-", 2)[0]
            await samba.run(["dnf", "versionlock", "add", pkg_name], timeout=15)

        # ── Record new version ────────────────────────────────────────────────
        rc2, ver_out, _ = await samba.run(
            ["rpm", "-q", "samba", "--qf", "%{NAME}-%{VERSION}-%{RELEASE}"],
            timeout=10,
        )
        new_nvr = ver_out.strip() if rc2 == 0 else "unknown"
        try:
            os.makedirs("/etc/samba-rads", exist_ok=True)
            with open(VERSION_FILE, "w") as f:
                f.write(new_nvr)
            _log(f"Version file updated: {new_nvr}")
        except Exception as e:
            _log(f"WARNING: could not update version file: {e}")

        # ── Start Samba ───────────────────────────────────────────────────────
        _log("Starting Samba...")
        await _try_restart_samba()
        await asyncio.sleep(6)

        # ── AD verification ───────────────────────────────────────────────────
        _log("Running AD verification tests...")
        try:
            results = await samba.run_diagnostics()
            passed  = sum(1 for r in results if r["passed"])
            total   = len(results)
            _log(f"AD verification: {passed}/{total} tests passed")
            for r in results:
                icon = "✓" if r["passed"] else "✗"
                _log(f"  [{icon}] {r['name']}")
            warnings = passed < total
        except Exception as e:
            _log(f"WARNING: diagnostics failed to run: {e}")
            warnings = True

        # ── Clear update flag ─────────────────────────────────────────────────
        try:
            os.remove(UPDATE_FLAG)
        except FileNotFoundError:
            pass

        _task["stage"]  = "done"
        _task["status"] = "success_with_warnings" if warnings else "success"
        if warnings:
            _log("Upgrade complete with warnings — check Diagnostics panel")
        else:
            _log("Upgrade complete — all AD tests passed")

    except Exception as exc:
        _log(f"Unhandled exception during apply: {exc}")
        _log("Attempting Samba restart after error...")
        await _try_restart_samba()
        _task["status"] = "failed"
        _task["stage"]  = "failed"


# ═════════════════════════════════════════════════════════════════════════════
# HELPERS
# ═════════════════════════════════════════════════════════════════════════════

def _read_file(path: str, default: str = "") -> str:
    try:
        with open(path) as f:
            return f.read()
    except Exception:
        return default


def _reset(stage: str):
    _task.update({
        "stage":      stage,
        "status":     "running",
        "log":        [f"── Stage 1: Build ──"],
        "built_rpms": [],
    })


def _log(msg: str):
    _task["log"].append(msg)


def _fail(msg: str):
    _log(f"ERROR: {msg}")
    _task["status"] = "failed"
    _task["stage"]  = "failed"


async def _try_restart_samba():
    for svc in ("samba", "smb"):
        rc, _, _ = await samba.run(["systemctl", "start", svc], timeout=15)
        if rc == 0:
            return
