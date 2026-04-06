# TextEcho — Lessons Learned

## 2026-04-06: PRD vs Issues

**What happened:** Started writing a PRD for a macOS version bump when the real problem was specific build failures from dependency updates.

**Root cause:** Assumed CI warnings were caused by the deployment target being old. Didn't check the actual build logs first.

**Rule:** Always check CI logs before proposing a solution. Use **issues** for specific bugs/tasks. Use **PRDs** only for strategic decisions or new features that need alignment before work starts.

## 2026-04-06: Check current state before filing issues

**What happened:** Created 3 GitHub issues based on build failures from an older CI run, without verifying whether those failures still existed on main. They were already fixed in later commits on the same branch before it merged.

**Root cause:** Looked at failed CI runs but didn't check whether the successful runs that followed had resolved the issues. Filed issues from stale data.

**Rule:** Before filing issues from CI failures, always check: (1) Is the failure on the current main branch? (2) Did later runs on the same branch succeed? (3) `gh run list --branch main` to verify current CI status. Don't create issues from mid-development failures on feature branches.
