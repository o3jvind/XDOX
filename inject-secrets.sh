#!/bin/bash
# Inject MBS secrets into SecretsBuiltin.xojo_code before a manual IDE build.
# Run this immediately before building in the XOJO IDE, then run restore-secrets.sh
# as soon as the build finishes.
#
# ⚠️  SECURITY WARNING
# This script writes real MBS credentials to SecretsBuiltin.xojo_code on disk.
# Run restore-secrets.sh immediately after the build completes.
# Do NOT commit, sync, or back up while the secrets are injected.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILTIN="$SCRIPT_DIR/SecretsBuiltin.xojo_code"

# security -w returns hex for non-ASCII values; decode with xxd if needed.
keychain_get() {
  local val
  val=$(security find-generic-password -s "MBS" -a "$1" -w 2>/dev/null || true)
  # If it looks like pure hex (all hex chars, even length, at least 8 chars, not pure digits), decode it
  if [[ "$val" =~ ^[0-9a-fA-F]+$ ]] && (( ${#val} % 2 == 0 )) && (( ${#val} >= 8 )) && ! [[ "$val" =~ ^[0-9]+$ ]]; then
    val=$(printf '%s' "$val" | xxd -r -p)
  fi
  printf '%s' "$val"
}

MBS_OWNER=$(keychain_get Owner)
MBS_PRODUCT=$(keychain_get Product)
MBS_YEAR=$(keychain_get Year)
MBS_KEY=$(keychain_get Key)

if [ -z "$MBS_KEY" ]; then
  echo "ERROR: MBS Key not found in keychain. Run setup first:"
  echo "  security add-generic-password -s MBS -a Key -w YOUR_KEY"
  exit 1
fi

escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

cat > "$BUILTIN" << EOF
#tag Module
Protected Module SecretsBuiltin
	#tag Method, Flags = &h0
		Function Get(account As String) As String
		  Select Case account
		  Case "MBS.Owner"
		    Return "$(escape "$MBS_OWNER")"
		  Case "MBS.Product"
		    Return "$(escape "$MBS_PRODUCT")"
		  Case "MBS.Year"
		    Return "$(escape "$MBS_YEAR")"
		  Case "MBS.Key"
		    Return "$(escape "$MBS_KEY")"
		  End Select
		  Return ""
		End Function
	#tag EndMethod

End Module
#tag EndModule
EOF

echo ""
echo "✓ SecretsBuiltin.xojo_code injected."
echo "  Owner:   $MBS_OWNER"
echo "  Product: $MBS_PRODUCT"
echo "  Year:    $MBS_YEAR"
echo "  Key:     ${MBS_KEY:0:8}…"
echo ""
echo "  ⚠️  IMPORTANT — if the project is already open in the XOJO IDE:"
echo "  The IDE may have the old (empty) file cached. You must reload it before building:"
echo "    • In the XOJO Navigator, right-click SecretsBuiltin → Revert to Disk"
echo "    • OR close and reopen the project in the XOJO IDE"
echo "  Then build (⌘B → Build for macOS), then run ./restore-secrets.sh immediately."
echo ""
echo "  If the project was NOT open in the XOJO IDE, just open and build normally."
