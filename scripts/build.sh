#!/usr/bin/env bash
# 构建 SGLiveIsland.dylib + SGLiveIslandWidget.appex
# 需要一个带 iPhoneOS SDK 的 Xcode（macOS）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"
SWIFTC="$(xcrun --sdk iphoneos --find swiftc)"

rm -rf "$OUT"
mkdir -p "$OUT/SGLiveIslandWidget.appex" "$OUT/.obj"

echo "==> SDK: $SDK"

echo "==> 1/3 ObjC 构造器"
for f in Bootstrap Settings Artwork Diag; do
  "$CLANG" -c "$ROOT/Source/$f.m" -o "$OUT/.obj/$f.o" \
    -target arm64-apple-ios16.2 -isysroot "$SDK" -fobjc-arc -O2 -Wall -I "$ROOT/Source"
done

echo "==> 2/3 SGLiveIsland.dylib"
"$SWIFTC" -O -wmo -emit-library \
  -target arm64-apple-ios16.2 -sdk "$SDK" \
  -module-name SGLiveIsland \
  -swift-version 5 \
  -import-objc-header "$ROOT/Source/Bridge.h" \
  -framework Foundation -framework UIKit -framework ActivityKit \
  -framework CoreGraphics -framework QuartzCore \
  -Xlinker -install_name -Xlinker @rpath/SGLiveIsland.dylib \
  -o "$OUT/SGLiveIsland.dylib" \
  "$ROOT/Shared/SGLyricsAttributes.swift" \
  "$ROOT/Source/SGLLiveIsland.swift" \
  "$OUT/.obj/Bootstrap.o" "$OUT/.obj/Settings.o" "$OUT/.obj/Artwork.o" "$OUT/.obj/Diag.o"

echo "==> 3/3 SGLiveIslandWidget.appex"
"$SWIFTC" -O -wmo -parse-as-library \
  -target arm64-apple-ios17.0 -sdk "$SDK" \
  -module-name SGLiveIsland \
  -swift-version 5 \
  -import-objc-header "$ROOT/Source/Diag.h" \
  -framework SwiftUI -framework WidgetKit -framework ActivityKit \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$OUT/SGLiveIslandWidget.appex/SGLiveIslandWidget" \
  "$ROOT/Shared/SGLyricsAttributes.swift" \
  "$ROOT/Widget/ClockDriver.swift" \
  "$ROOT/Widget/SGLiveIslandWidget.swift" \
  "$OUT/.obj/Diag.o"

cp "$ROOT/Widget/Info.plist" "$OUT/SGLiveIslandWidget.appex/Info.plist"
plutil -convert binary1 "$OUT/SGLiveIslandWidget.appex/Info.plist"
codesign -f -s - "$OUT/SGLiveIslandWidget.appex" >/dev/null 2>&1 || true

rm -rf "$OUT/.obj"
echo "==> 产物"
ls -l "$OUT" "$OUT/SGLiveIslandWidget.appex"
shasum -a 256 "$OUT/SGLiveIsland.dylib" "$OUT/SGLiveIslandWidget.appex/SGLiveIslandWidget" || true
