#!/bin/bash
# Resets the app's Accessibility grant. Useful during development: rebuilding from Xcode
# with a churning ad-hoc signature can silently invalidate a previously-granted
# Accessibility permission, requiring a clean re-grant.
set -euo pipefail
BUNDLE_ID="${1:-com.omar.whisperkeyboard}"
tccutil reset Accessibility "$BUNDLE_ID"
echo "Reset Accessibility permission for $BUNDLE_ID — re-grant it in System Settings on next launch."
