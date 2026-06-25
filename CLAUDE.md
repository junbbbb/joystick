# Joystick — Flutter Hot Reload 컨트롤 패널

macOS 데스크톱에 뜨는 미니 윈도우. 아무 Flutter 프로젝트나 골라 iOS 시뮬레이터에서
실행하고, Hot Reload / Hot Restart 를 버튼 하나로 제어한다. 브라우저 DevTools 가
ws 끊김으로 답답한 사람을 위한 PTY 기반 대체 컨트롤러.

**이 파일은 설치를 돕는 에이전트(Claude Code)용 지침이다. 아래 순서를 그대로 따르면 된다.**

## 설치

이 저장소를 클론한 위치에서:

1. **요구사항 확인**
   - macOS 13 이상.
   - Xcode Command Line Tools: `xcode-select -p` 로 확인. 없으면 사용자에게
     `xcode-select --install` 실행을 안내(설치 GUI 가 떠서 사람이 눌러야 함).
   - Flutter: `command -v flutter` 로 확인. 없으면 설치를 안내. (있으면 앱이
     알아서 경로를 찾으니 추가 설정 불필요.)

2. **빌드**
   ```bash
   ./build.sh
   ```
   `swiftc` 로 컴파일하고 `Joystick.app` 을 만든다. 로컬 빌드라 Gatekeeper
   "미확인 개발자" 경고가 뜨지 않는다.

3. **실행**
   ```bash
   open Joystick.app
   ```

설치 끝. 코드를 수정할 필요는 없다 — 환경 의존값(flutter 경로, 기본 프로젝트,
시뮬레이터)은 모두 런타임에 자동 탐색된다.

## 사용법 (사용자에게 안내)

한 줄짜리 슬림 윈도우. 버튼 좌→우:
📦 프로젝트 선택 · 📱 시뮬레이터 · ▶ Run · ■ Stop · ⚡ Hot Reload ·
↻ Hot Restart · ☰ 로그 토글 · ✕ 종료.

- 켜면 **가장 최근 작업한 Flutter 프로젝트**가 자동 선택된다. 바꾸려면 📦.
- 📱 로 iOS 시뮬레이터를 고르면 부팅된다.
- ▶ 누르면 그 프로젝트를 그 시뮬에서 실행. 이후 ⚡/↻ 로 Hot Reload/Restart.
- 프로젝트 루트에 `.env.local`(KEY=VALUE) 이 있으면 `--dart-define` 으로 자동 주입.

## flutter 경로 자동 탐색

코드를 고칠 필요 없다. 앱이 실행될 때:
1. **로그인 셸 PATH** 에서 탐색 (`$SHELL -lc 'command -v flutter'`). GUI 앱은 PATH
   가 짧아 단순 which 로는 못 찾으므로, 사용자의 `.zshrc`/fvm 설정을 로드한 뒤의
   PATH 에서 찾는다. fvm 사용자도 이 단계에서 잡힌다.
2. 안 잡히면 **흔한 설치 경로** 직접 확인: `~/Developer/flutter`, `~/flutter`,
   `~/development/flutter`, `~/fvm/default`, `/opt/homebrew`, `/usr/local`, `/opt`.
3. 다 실패하면 윈도우 상태바에 "flutter 못 찾음" 표시.

## 트러블슈팅

- **"flutter 못 찾음"** → 터미널에서 `command -v flutter` 가 경로를 내는지 확인.
  경로가 나오는데도 앱이 못 찾으면, 그 경로가 위 흔한 목록에 없는 특이 위치일 수
  있다. `control_panel.swift` 의 `resolveFlutterBin()` candidates 에 추가.
- **시뮬레이터가 안 보임** → Xcode 와 iOS 시뮬레이터 런타임 필요.
  `xcrun simctl list devices available` 로 iPhone 이 나오는지 확인.
- **빌드 실패 (swiftc: command not found)** → `xcode-select --install`.
- **이미 다른 `flutter run` 이 시뮬을 점유** → `pkill -f "flutter_tools.*run"` 후 재시도.

## 동작 방식 (참고)

PTY(`Darwin.openpty`)로 `flutter run` 을 자식 프로세스로 띄우고, 버튼 클릭 시
stdin 에 `r`(reload) / `R`(restart) / `q`(quit) 를 직접 보낸다. 네트워크 계층이
없어 DevTools 처럼 끊기지 않는다. 전체가 단일 파일 `control_panel.swift`
(Cocoa/AppKit, 외부 의존성 0). iOS 시뮬레이터 전용.
