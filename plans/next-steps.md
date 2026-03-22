# TextEcho — Next Steps (updated 2026-03-22)

## Completed (2026-03-22)

- **Steps 1-5 DONE:** Security fixes tested, theme branch created, themes tested on Mac, Dependabot #4/#5 merged, GitHub security features enabled
- **Theme wiring bug FIXED:** Overlay wasn't reading colors from config — patched and tested
- **PR #7 merged:** Theme customization (5 built-in presets, custom colors, save/delete user themes) + Swift CI workflow
- **CI workflow added:** `.github/workflows/swift-ci.yml` — runs `swift test` + `swift build -c release` on PRs to main

## Next

- [ ] **Security fixes** — Branch `fix/pr2-security` for 2 HIGH + 5 MEDIUM issues from PR #2 review. Now covered by CI on PR open.
- [ ] **App Store prep** — Code signing, sandbox entitlements, App Store Connect setup
- [ ] **README update** — Reflect themes, CI, contributor info (Lochie/MachinationsContinued)
