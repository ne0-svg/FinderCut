#!/bin/zsh
# 剪切助手（FinderCut）：编译主程序 + FinderSync 扩展（Apple Silicon + Intel 双架构），
# 组装 .app 并签名
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/FinderCut.app"
APPEX="$APP/Contents/PlugIns/FinderCutExtension.appex"
ARCHS=(arm64 x86_64)

rm -rf "$BUILD"
mkdir -p "$BUILD"

# 把多个单架构产物合并成 Universal 二进制
fat() {  # fat <output> <inputs...>
  local out="$1"; shift
  lipo -create "$@" -output "$out"
  rm -f "$@"
}

echo "[1/5] 编译 Finder 扩展（${ARCHS[*]}）..."
# 说明：LC_MAIN 入口直接指向 Foundation 的 _NSExtensionMain（与 Xcode 扩展模板一致，无需 main 函数）
ext_inputs=()
for ARCH in "${ARCHS[@]}"; do
  swiftc -O -parse-as-library \
    -module-name FinderCutExtension \
    -target "${ARCH}-apple-macos13.0" \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$BUILD/FinderCutExtension-$ARCH" \
    "$ROOT/FinderCutExt/FinderSync.swift" \
    "$ROOT/Shared/MoveEngine.swift" \
    -framework FinderSync -framework Cocoa -framework UserNotifications
  ext_inputs+=("$BUILD/FinderCutExtension-$ARCH")
done
fat "$BUILD/FinderCutExtension" "${ext_inputs[@]}"

echo "[2/5] 编译主程序（${ARCHS[*]}）..."
app_inputs=()
for ARCH in "${ARCHS[@]}"; do
  swiftc -O \
    -target "${ARCH}-apple-macos13.0" \
    -o "$BUILD/FinderCut-$ARCH" \
    "$ROOT/FinderCut/main.swift" \
    "$ROOT/Shared/MoveEngine.swift" \
    -framework AppKit -framework SwiftUI -framework UserNotifications
  app_inputs+=("$BUILD/FinderCut-$ARCH")
done
fat "$BUILD/FinderCut" "${app_inputs[@]}"

echo "[3/5] 组装 .app ..."
mkdir -p "$APP/Contents/MacOS" \
         "$APP/Contents/Resources/zh-Hans.lproj" \
         "$APPEX/Contents/MacOS"
cp "$BUILD/FinderCut" "$APP/Contents/MacOS/FinderCut"
cp "$ROOT/FinderCut/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" <<'EOF'
"CFBundleDisplayName" = "剪切助手";
"CFBundleName" = "剪切助手";
EOF
cp "$BUILD/FinderCutExtension" "$APPEX/Contents/MacOS/FinderCutExtension"
cp "$ROOT/FinderCutExt/Info.plist" "$APPEX/Contents/Info.plist"

echo "[4/5] 签名（ad-hoc；扩展启用 App Sandbox）..."
codesign --force --sign - --entitlements "$ROOT/FinderCutExt/FinderCutExt.entitlements" "$APPEX"
codesign --force --sign - "$APP"

echo "[5/5] 验证..."
codesign --verify --deep --strict "$APP"
lipo -info "$APP/Contents/MacOS/FinderCut"
lipo -info "$APPEX/Contents/MacOS/FinderCutExtension"
echo "构建完成：$APP"
