#!/bin/bash
# 手工打 NewTerm deb（Theos 未安装环境用）。
# 用法: scripts/build-deb.sh [rootless|rootful]   默认 rootless
set -euo pipefail
cd "$(dirname "$0")/.."

LAYOUT="${1:-rootless}"
if [[ "$LAYOUT" == "rootless" ]]; then
	PREFIX="/var/jb"
	ARCH="iphoneos-arm64"
else
	PREFIX=""
	ARCH="iphoneos-arm"
fi

echo "==> xcodebuild (Release, $LAYOUT)"
xcodebuild -project NewTerm.xcodeproj -scheme "NewTerm (iOS)" -configuration Release \
	-destination "generic/platform=iOS" -derivedDataPath build/DerivedData \
	CODE_SIGNING_ALLOWED=NO INSTALL_PREFIX="$PREFIX" build -quiet

APP="build/DerivedData/Build/Products/Release-iphoneos/NewTerm.app"
STAGE="build/stage"
DEST="$STAGE$PREFIX/Applications"

echo "==> stage"
rm -rf "$STAGE"
mkdir -p "$DEST" "$STAGE/DEBIAN"
cp -a "$APP" "$DEST/"

echo "==> sign (ldid)"
# 主二进制带 entitlements；helper 同样（对齐 Makefile after-stage）；Swift dylib 无 entitlements 签名即可
ldid -SApp/entitlements.plist "$DEST/NewTerm.app/NewTerm"
ldid -SApp/entitlements.plist "$DEST/NewTerm.app/NewTermLoginHelper"
find "$DEST/NewTerm.app/Frameworks" -name "*.dylib" -exec ldid -S {} \;

echo "==> control"
VERSION="3.0~beta1+beat.$(git rev-list --count HEAD).$(git rev-parse --short HEAD)"
sed -e "s/^Architecture:.*/Architecture: $ARCH/" \
		-e "s/^Version:.*/Version: $VERSION/" control > "$STAGE/DEBIAN/control"

echo "==> dpkg-deb"
mkdir -p build/out
DEB="build/out/ws.hbang.newterm3_${VERSION}_${ARCH}.deb"
dpkg-deb -Zgzip --root-owner-group -b "$STAGE" "$DEB" >/dev/null
echo "OK: $DEB"
