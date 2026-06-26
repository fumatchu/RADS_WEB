from fastapi import APIRouter, Depends
from main import require_auth
import samba

router = APIRouter()


@router.get("")
async def run_diagnostics(session: dict = Depends(require_auth)):
    results = await samba.run_diagnostics()
    passed = sum(1 for r in results if r["passed"])
    return {
        "total": len(results),
        "passed": passed,
        "failed": len(results) - passed,
        "results": results,
    }
