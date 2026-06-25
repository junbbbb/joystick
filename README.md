# Joystick 🕹️

Flutter 의 **Hot Reload / Hot Restart 를 버튼으로 누르는** macOS 미니 컨트롤 패널.
브라우저 DevTools 의 WebSocket 끊김에 지친 사람을 위한 PTY 기반 대체품.

![Joystick](docs/joystick.png)

한 줄짜리 슬림 윈도우, 항상 위에 떠 있음. 버튼은 좌→우:
📦 프로젝트 · 📱 시뮬레이터 · ▶ Run · ■ Stop · ⚡ Hot Reload · ↻ Hot Restart · ☰ 로그 · ✕ 종료

## 설치

### Claude Code 사용자 (제일 쉬움)
이 저장소 링크를 Claude 에게 주고 시키면 끝:

> "이 repo 클론해서 Joystick 설치해줘: `<repo-url>`"

루트의 [`CLAUDE.md`](./CLAUDE.md) 를 읽고 요구사항 확인 → 빌드 → 실행까지 알아서 한다.

### 직접 설치
```bash
git clone <repo-url> joystick
cd joystick
./build.sh
open Joystick.app
```

## 요구사항

- macOS 13+
- Xcode Command Line Tools — `xcode-select --install`
- Flutter — **경로는 앱이 알아서 찾는다** (로그인 셸 PATH + 흔한 경로 + fvm)

## 쓰는 법

1. 📦 프로젝트 고르기 (켜면 가장 최근 만진 프로젝트가 자동 선택돼 있음)
2. 📱 iOS 시뮬레이터 고르기 → 부팅됨
3. ▶ Run → 빌드 후 실행
4. 코드 고치고 ⚡ Hot Reload (또는 ↻ Hot Restart)

📱 를 누르면 설치된 iOS 시뮬레이터가 런타임별로 묶여 나온다 (부팅된 기기엔 ✓):

<img src="docs/joystick-devices.png" width="380" alt="시뮬레이터 선택 — iOS 런타임별 그룹">

프로젝트 루트에 `.env.local`(`KEY=VALUE`) 이 있으면 `--dart-define` 으로 자동 주입한다.

## 왜 만들었나

브라우저 기반 Flutter DevTools 는 WebSocket 이 idle/throttling 으로 자주 끊겨서,
Hot Reload 한 번 누르려고 패널을 다시 로드하는 게 번거로웠다. Joystick 은
`openpty` 로 `flutter run` 을 자식 프로세스로 직접 띄우고 stdin 에 `r`/`R`/`q` 를
보낸다 — 네트워크 계층이 없으니 끊길 일이 없다.

## 특징

- 단일 파일 (`control_panel.swift`, Cocoa/AppKit) — 외부 의존성 0
- 환경 자동 적응 — flutter 경로 · 기본 프로젝트 · 시뮬레이터 전부 런타임 탐색
- 빌드된 앱이 아니라 소스를 배포 → Gatekeeper 경고 없음

iOS 시뮬레이터 전용. macOS only.
