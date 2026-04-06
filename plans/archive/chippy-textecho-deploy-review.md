# Chippy Review: TextEcho Deployment Skills

## Context

TextEcho now has a signed release pipeline via GitHub Actions (tag-triggered). This is fundamentally different from BTW's Cloud Run deployments. Chippy's existing deployment skills (`/chippy-deploy`, `/chippy-wrap-session`) are designed for GCP Cloud Run — they won't work for TextEcho's DMG-based distribution.

## Questions to Answer

1. **Does TextEcho need a dedicated deploy skill?**
   - Current workflow: push a `v*` tag → GitHub Actions builds signed DMG → creates GitHub Release
   - A skill like `/chippy-deploy-textecho` could: bump version in Info.plist, create tag, push tag, monitor the workflow, post to Slack
   - Is this worth automating, or is manual tagging sufficient?

2. **Do existing skills need updates?**
   - `/chippy-deploy` — currently GCP Cloud Run only. Should it detect project type and route appropriately?
   - `/chippy-wrap-session` — does it need awareness of the TextEcho release process?
   - `/chippy-update-docs` — already generic, should work for TextEcho

3. **Version management**
   - TextEcho's version is currently hardcoded in `build_native_app.sh` (CFBundleVersion: 2.0)
   - Should versions be derived from git tags? e.g. `v2.1.0` tag → Info.plist gets `2.1.0`
   - This would be a prerequisite for any deploy skill

## Recommended Actions

1. **Research** existing Chippy skills to understand the deployment abstraction layer
2. **Assess** whether a generic "tag-based release" skill pattern would benefit other projects too
3. **Decide** build vs skip based on frequency of TextEcho releases
4. **If building:** Create `/chippy-deploy-textecho` skill that handles version bump + tag + push + monitor
5. **Update** `/chippy-deploy` to detect and route by project type (Cloud Run vs GitHub Release)

## Files to Review

- `infra/chippy/.claude/skills/chippy-deploy.md`
- `infra/chippy/.claude/skills/chippy-wrap-session.md`
- `bb/dictation-mac/.github/workflows/release.yml`
- `bb/dictation-mac/build_native_app.sh` (version management)
