# TextEcho — Next Steps (updated 2026-03-22)

## Completed (2026-03-22)

- **Steps 1-5 DONE:** Security fixes tested, theme branch created, themes tested on Mac, Dependabot #4/#5 merged, GitHub security features enabled
- **Theme wiring bug FIXED:** Overlay wasn't reading colors from config — patched and tested
- **PR #7 merged:** Theme customization (5 built-in presets, custom colors, save/delete user themes) + Swift CI workflow
- **CI workflow added:** `.github/workflows/swift-ci.yml` — runs `swift test` + `swift build -c release` on PRs to main

## Completed (continued)

- **Security fixes ALL APPLIED:** All 7 items from PR #2 review (2 HIGH + 5 MEDIUM) were already fixed on main. 8 security tests in place. No `fix/pr2-security` branch needed.
- **Menu bar hover bug:** PR #8 — long transcriptions now open a submenu instead of a tooltip. Preview bumped 40→80 chars.

## Completed (continued)

- **PR #8 merged** — menu bar hover fix (120-char preview, click to copy)
- **PR #9 merged** — help window (themes + idle timeout sections), double privacy prompt fix, wizard Customize step (theme picker with color swatches, silence slider, model memory), Settings silence slider
- **README updated** — contributor credit for Lochie, setup wizard description

## Next

- [ ] **App Store prep** — Code signing, sandbox entitlements, App Store Connect setup
