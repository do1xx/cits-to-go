#!/usr/bin/env bash
# Baut ein Release-Archiv und lädt es zu TestFlight hoch.
# Vorher CURRENT_PROJECT_VERSION in project.yml erhöhen.
# Benötigt einen App-Store-Connect-API-Schlüssel mit Admin-Rechten (Cloud Signing):
#   ASC_KEY_ID, ASC_ISSUER_ID, optional ASC_KEY_PATH (Standard ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8)
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ASC_KEY_ID:?ASC_KEY_ID fehlt}" "${ASC_ISSUER_ID:?ASC_ISSUER_ID fehlt}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
test -f CitsToGo/App/BuiltInServers.swift || { echo "CitsToGo/App/BuiltInServers.swift fehlt (siehe .example)"; exit 1; }

# Homebrew-rsync bricht den IPA-Export von Xcode ab ("Copy failed").
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

mkdir -p build
cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST

/opt/homebrew/bin/xcodegen generate >/dev/null
rm -rf build/CitsToGo.xcarchive build/export
xcodebuild archive -project CitsToGo.xcodeproj -scheme CitsToGo -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/CitsToGo.xcarchive "${AUTH[@]}" -quiet
xcodebuild -exportArchive -archivePath build/CitsToGo.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist -exportPath build/export "${AUTH[@]}" 2>&1 \
  | grep -E "Progress|error|Upload|EXPORT"
