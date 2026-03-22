#!/bin/bash
# Reset TextEcho Accessibility permission and guide re-grant.
# Run after rebuilding to clear the stale permission tied to the old signature.

BUNDLE_ID="com.textecho.app"

echo "==> Resetting Accessibility permission for TextEcho..."
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null && echo "    Cleared." || echo "    (Nothing to clear.)"
echo ""
echo "    TextEcho will prompt for Accessibility access on next launch."
echo "    Grant it in System Settings to enable hotkeys and paste."
echo ""
echo "    To open Privacy settings manually:"
echo "      open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'"
