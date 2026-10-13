#!/bin/zsh
# Builds build/Harness.app: the real LocalLLMGateway.app (with the embedded LocalLLMWorker.xpc)
# whose executable is replaced by this harness, ad-hoc signed.
# usage: ./build.sh [path to a built LocalLLMGateway.app]
# Default: the Debug build under DerivedData (run the LocalLLMChat scheme once first).
set -euo pipefail
cd "${0:A:h}"
ROOT=${PWD:h:h}
SRC=${1:-$(ls -dt ~/Library/Developer/Xcode/DerivedData/LocalLLMChat-*/Build/Products/Debug/LocalLLMGateway.app | head -1)}
[[ -d $SRC/Contents/XPCServices/LocalLLMWorker.xpc ]] || { echo "no LocalLLMWorker.xpc in $SRC" >&2; exit 1; }
OUT=build; rm -rf $OUT; mkdir -p $OUT
APP=$OUT/Harness.app
cp -R $SRC $APP
# Same files the Gateway target compiles for the supervisor, minus the Gateway's own main.
swiftc -O -swift-version 6 \
  main.swift \
  $ROOT/Sources/Gateway/WorkerSupervisor.swift $ROOT/Sources/Gateway/XPCWorkerConnector.swift \
  $ROOT/Sources/Gateway/GatewayModels.swift $ROOT/Sources/Shared/WorkerIPC.swift \
  -o $APP/Contents/MacOS/LocalLLMGateway
codesign -f -s - $APP/Contents/XPCServices/LocalLLMWorker.xpc
codesign -f -s - $APP
echo built $APP
echo "run: MODEL=/path/to/model $APP/Contents/MacOS/LocalLLMGateway"
