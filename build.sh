#!/usr/bin/env bash
#
# Joystick 빌드 — control_panel.swift 를 컴파일해 Joystick.app 을 만든다.
# 멱등(여러 번 돌려도 안전). 받는 사람은 이 스크립트만 실행하면 된다.
#
#   ./build.sh        # 빌드
#   open Joystick.app # 실행
#
set -euo pipefail
cd "$(dirname "$0")"

APP="Joystick.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
SRC="control_panel.swift"

echo "▶ Joystick 빌드"

# 1) swiftc(스위프트 컴파일러) 확인 — Xcode Command Line Tools 에 들어있다.
if ! command -v swiftc >/dev/null 2>&1; then
  echo "✗ swiftc 가 없습니다. Xcode Command Line Tools 를 먼저 설치하세요:"
  echo "    xcode-select --install"
  exit 1
fi

# 2) .app 번들 뼈대
mkdir -p "$MACOS"

# 3) Info.plist (앱 메타데이터) 생성 — .app 은 이 파일이 있어야 앱으로 인식된다.
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Joystick</string>
    <key>CFBundleIdentifier</key>
    <string>com.joystick.panel</string>
    <key>CFBundleName</key>
    <string>Joystick</string>
    <key>CFBundleDisplayName</key>
    <string>Joystick</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
PLIST

# 4) 컴파일
echo "  swiftc → $MACOS/Joystick"
swiftc "$SRC" -o "$MACOS/Joystick"

# 5) ad-hoc 코드사인 — 로컬 빌드라 개발자 인증서가 필요 없다. 직접 빌드한
#    바이너리는 quarantine 이 안 붙어 Gatekeeper 경고 없이 바로 실행된다.
echo "  codesign (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "✓ 완료. 실행:  open $APP"
