#!/bin/bash
# Reset TextEcho Accessibility permission and guide re-grant.
# Run after rebuilding to clear the stale permission tied to the old signature.

BUNDLE_ID="com.textecho.app"

echo "==> Resetting Accessibility permission for TextEcho..."
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null && echo "    Cleared." || echo "    (Nothing to clear.)"
echo ""
echo "==> Opening Privacy & Security → Accessibility..."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
echo ""
echo "    When TextEcho launches, it will prompt for Accessibility access."
echo "    Grant it in System Settings to enable hotkeys and paste."
