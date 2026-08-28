#!/bin/bash
# 打「NewTerm Beat」并存测试版：独立 bundle id / 独立包名 / 独立图标，
# 与用户现装的正式版 NewTerm 共存，互不覆盖、互不共享配置。
# 编译后重命名法：二进制模块名仍是 NewTerm（scene delegate 类名不变），
# 只改 Info.plist 的 bundle id + 显示名 + 换 app 目录名 + 重签。
set -euo pipefail
cd "$(dirname "$0")/.."

PREFIX="/var/jb"          # roothide/rootless
# 二进制是 arm64（libiosexec.xcframework 无 arm64e slice），但 arm64 app 在 arm64e 设备上正常运行。
# control 标 arm64e 是为了让设备上 dpkg（--print-architecture=iphoneos-arm64e）接受，正式版也这么做。
DEB_ARCH="iphoneos-arm64e"
APP_NAME="NewTermBeat"
BUNDLE_ID="ws.hbang.Terminal.beat"
DISPLAY_NAME="NewTerm Beat"
PKG="ws.hbang.newterm3.beat"

echo "==> xcodebuild (Release, arm64e, beat)"
xcodebuild -project NewTerm.xcodeproj -scheme "NewTerm (iOS)" -configuration Release \
	-destination "generic/platform=iOS" -derivedDataPath build/DerivedData \
	CODE_SIGNING_ALLOWED=NO INSTALL_PREFIX="$PREFIX" build -quiet

SRC="build/DerivedData/Build/Products/Release-iphoneos/NewTerm.app"
STAGE="build/stage-beat"
DEST="$STAGE$PREFIX/Applications"

echo "==> stage as $APP_NAME.app"
rm -rf "$STAGE"
mkdir -p "$DEST" "$STAGE/DEBIAN"
cp -a "$SRC" "$DEST/$APP_NAME.app"
APP="$DEST/$APP_NAME.app"

echo "==> rebrand Info.plist"
plutil -replace CFBundleIdentifier  -string "$BUNDLE_ID"    "$APP/Info.plist"
plutil -replace CFBundleName        -string "$DISPLAY_NAME" "$APP/Info.plist"
plutil -insert  CFBundleDisplayName -string "$DISPLAY_NAME" "$APP/Info.plist" 2>/dev/null \
	|| plutil -replace CFBundleDisplayName -string "$DISPLAY_NAME" "$APP/Info.plist"

echo "==> sign (ldid)"
ldid -SApp/entitlements.plist "$APP/NewTerm"
ldid -SApp/entitlements.plist "$APP/NewTermLoginHelper"
find "$APP/Frameworks" -name "*.dylib" -exec ldid -S {} \;

echo "==> control + postinst"
VERSION="3.0~beta1+beat.$(git rev-list --count HEAD).$(git rev-parse --short HEAD)"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Name: $DISPLAY_NAME
Version: $VERSION
Architecture: $DEB_ARCH
Description: NewTerm Beat — 并存测试版，独立于正式版
Maintainer: yang
Author: HASHBANG Productions
Section: Terminal Support
Depends: firmware (>= 14.0)
EOF
cat > "$STAGE/DEBIAN/postinst" <<EOF
#!/bin/sh
uicache -p "$PREFIX/Applications/$APP_NAME.app" 2>/dev/null || uicache -a 2>/dev/null || true
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/postinst"

echo "==> dpkg-deb"
mkdir -p build/out
DEB="build/out/${PKG}_${VERSION}_${DEB_ARCH}.deb"
dpkg-deb -Zgzip --root-owner-group -b "$STAGE" "$DEB" >/dev/null
echo "OK: $DEB"
