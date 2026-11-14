#!/bin/sh
# 一键构建「虚拟身体」ipa（macOS / GitHub Actions 通用）
#
# 用法：
#   sh scripts/build-ipa.sh                            # 未签名 ipa（AltStore / Sideloadly / ESign 重签用）
#   TEAM_ID=XXXXXXXXXX sh scripts/build-ipa.sh signed   # 用你的团队证书签好，可直接装
#
# 产物：
#   build/VirtualBody-unsigned.ipa   未签名
#   build/ipa/VirtualBody.ipa        签名（需 TEAM_ID）
set -e

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
MODE="${1:-unsigned}"
TEAM_ID="${TEAM_ID:-}"

echo "==> 0/5 同步前端（可选）"
# 前端有两种放法：仓库根 webapp/（开发中）或已提交的 Resources/WebApp/（默认）
SRC=""
if [ -d "$HERE/webapp" ]; then
  SRC="$HERE/webapp"
elif [ -d "$HERE/../astrbot_plugin_virtual_body/webapp" ]; then
  SRC="$HERE/../astrbot_plugin_virtual_body/webapp"
fi
if [ -n "$SRC" ]; then
  mkdir -p Resources/WebApp
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude 'sw.js' "$SRC/" Resources/WebApp/
  else
    rm -rf Resources/WebApp && mkdir -p Resources/WebApp && cp -R "$SRC/." Resources/WebApp/
  fi
  echo "    已同步：$SRC → Resources/WebApp"
else
  echo "    沿用已提交的 Resources/WebApp"
fi
if [ ! -f Resources/WebApp/index.html ]; then
  echo "❌ 缺少 Resources/WebApp/index.html，前端没就位" >&2
  exit 1
fi

echo "==> 1/5 准备 xcodegen"
if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then brew install xcodegen; else
    echo "请先安装 xcodegen：brew install xcodegen" >&2; exit 1
  fi
fi

echo "==> 2/5 生成 Xcode 工程"
rm -rf VirtualBody.xcodeproj
xcodegen generate

echo "==> 3/5 编译（Release / iphoneos）"
rm -rf build
if [ "$MODE" = "signed" ] && [ -n "$TEAM_ID" ]; then
  xcodebuild -project VirtualBody.xcodeproj -scheme VirtualBody -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath build/dd \
    DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates \
    build
  APP_PATH=$(find build/dd/Build/Products/Release-iphoneos -maxdepth 1 -name '*.app' | head -1)
  mkdir -p build/ipa/Payload
  cp -R "$APP_PATH" build/ipa/Payload/
  (cd build/ipa && zip -qry VirtualBody.ipa Payload)
  echo "✅ 签名 ipa：$HERE/build/ipa/VirtualBody.ipa"
else
  xcodebuild -project VirtualBody.xcodeproj -scheme VirtualBody -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath build/dd \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    build
  APP_PATH=$(find build/dd/Build/Products/Release-iphoneos -maxdepth 1 -name '*.app' | head -1)
  mkdir -p build/Payload
  cp -R "$APP_PATH" build/Payload/
  (cd build && zip -qry VirtualBody-unsigned.ipa Payload)
  echo "✅ 未签名 ipa：$HERE/build/VirtualBody-unsigned.ipa"
  echo "   用 AltStore / Sideloadly / ESign 重签后即可安装"
fi

echo "==> 5/5 完成"
ls -lh build/*.ipa 2>/dev/null || true
