#!/bin/zsh
# Builds Host.app/Contents/Library/LoginItems/Gateway.app/Contents/XPCServices/Worker.xpc with ad-hoc signing.
set -euo pipefail
cd "${0:A:h}"
OUT=${1:-build}; rm -rf $OUT
HOST=$OUT/Host.app
GW=$HOST/Contents/Library/LoginItems/Gateway.app
WK=$GW/Contents/XPCServices/Worker.xpc
mkdir -p $HOST/Contents/MacOS $GW/Contents/MacOS $WK/Contents/MacOS
swiftc -O Gateway/main.swift -o $GW/Contents/MacOS/Gateway
swiftc -O Worker/main.swift  -o $WK/Contents/MacOS/Worker
plist() { # path id exe type
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $2" -c "Add :CFBundleExecutable string $3" \
    -c "Add :CFBundleName string $3" -c "Add :CFBundlePackageType string $4" -c "Add :CFBundleVersion string 1" \
    -c "Add :CFBundleShortVersionString string 1.0" "$1" >/dev/null; }
plist $GW/Contents/Info.plist com.example.localllmchat.gateway Gateway APPL
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" $GW/Contents/Info.plist
plist $WK/Contents/Info.plist com.example.localllmchat.worker Worker XPC!
/usr/libexec/PlistBuddy -c "Add :XPCService dict" -c "Add :XPCService:ServiceType string Application" $WK/Contents/Info.plist
swiftc -O Host/main.swift -o $HOST/Contents/MacOS/Host
plist $HOST/Contents/Info.plist com.example.localllmchat.spike Host APPL
mkdir -p $HOST/Contents/Library/LaunchAgents
cat > $HOST/Contents/Library/LaunchAgents/com.example.localllmchat.spike.gateway.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.example.localllmchat.spike.gateway</string>
<key>BundleProgram</key><string>Contents/Library/LoginItems/Gateway.app/Contents/MacOS/Gateway</string>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>/tmp/spike-gateway.log</string>
<key>StandardErrorPath</key><string>/tmp/spike-gateway.log</string>
</dict></plist>
PL
# Sign inside-out.
codesign -f -s - $WK
codesign -f -s - $GW
codesign -f -s - $HOST
echo built $GW
