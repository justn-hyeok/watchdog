# Watchdog 설치 가이드

이 문서는 사람과 자동화 에이전트가 함께 사용하는 설치 기준입니다.

## 배포 정보

| 항목 | 값 |
|---|---|
| 지원 OS | macOS 14 이상 |
| 현재 배포 | `v0.1.0-beta.1` |
| 공식 릴리스 | <https://github.com/justn-hyeok/watchdog/releases/tag/v0.1.0-beta.1> |
| 기본 설치 위치 | `~/Applications/Watchdog.app` 또는 `/Applications/Watchdog.app` |
| 앱 식별자 | `dev.justn.watchdog` |

공식 파일 SHA-256:

```text
Watchdog-0.1.0-macos.zip  fb1b23cb24e7c3bbe69a95ae47235d1c48d66fc175d168233ce2593b5ccf4d69
Watchdog-0.1.0-macos.dmg  7aad562f1be09229f05d132a3e4b94351ef1a69c735521c27acdb5daf58c25e4
```

## 사람용: DMG로 설치

1. [공식 릴리스](https://github.com/justn-hyeok/watchdog/releases/tag/v0.1.0-beta.1)에서 `Watchdog-0.1.0-macos.dmg`를 내려받습니다.
2. 선택적으로 무결성을 확인합니다.

   ```bash
   shasum -a 256 ~/Downloads/Watchdog-0.1.0-macos.dmg
   ```

3. DMG를 열고 Watchdog을 Applications 바로가기로 드래그합니다.
4. 현재 베타는 Apple 공증 전이므로 Finder에서 Watchdog을 우클릭하고 **열기 → 열기**를 선택합니다.
5. 우클릭으로 열리지 않으면 한 번 실행을 시도한 뒤 **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기**를 선택합니다.

전역 Gatekeeper 비활성화와 `xattr` 격리 제거는 필요하지 않습니다.

## 에이전트·터미널용: 검증형 설치

저장소를 받은 상태에서:

```bash
./scripts/install.sh
```

이 스크립트는 다음 작업만 수행합니다.

1. 공식 GitHub 릴리스의 ZIP 다운로드
2. 고정 SHA-256 검증
3. 코드 서명 구조 검증
4. 기존 Watchdog이 실행 중이면 `SIGTERM`으로 정상 종료 요청
5. `~/Applications/Watchdog.app`에 원자적으로 교체 설치
6. LaunchServices 등록 및 앱 실행

스크립트는 `sudo`, `SIGKILL`, Gatekeeper 비활성화 또는 quarantine 속성 제거를 사용하지 않습니다.

실행하지 않고 설치만 하기:

```bash
./scripts/install.sh --no-launch
```

설치 위치 변경:

```bash
./scripts/install.sh --install-dir /Applications
```

`/Applications` 쓰기 권한이 없는 환경에서는 기본 `~/Applications`를 사용합니다. 에이전트는 권한 상승을 추측하거나 자동으로 `sudo`를 사용하면 안 됩니다.

## 설치 확인

```bash
APP="$HOME/Applications/Watchdog.app"

test -d "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
defaults read "$APP/Contents/Info" CFBundleIdentifier
defaults read "$APP/Contents/Info" CFBundleShortVersionString
open "$APP"
sleep 3
pgrep -fl "$APP/Contents/MacOS/Watchdog"
```

예상 값:

```text
CFBundleIdentifier: dev.justn.watchdog
CFBundleShortVersionString: 0.1.0
```

## 소스에서 빌드

요구 사항:

- macOS 14 이상
- Xcode 16 이상
- XcodeGen

```bash
git clone https://github.com/justn-hyeok/watchdog.git
cd watchdog
xcodegen generate
xcodebuild \
  -project Watchdog.xcodeproj \
  -scheme Watchdog \
  -configuration Debug \
  -derivedDataPath DerivedData/local \
  build
open DerivedData/local/Build/Products/Debug/Watchdog.app
```

테스트와 Release 빌드:

```bash
xcodebuild \
  -project Watchdog.xcodeproj \
  -scheme Watchdog \
  -configuration Debug \
  -derivedDataPath DerivedData/test \
  test

xcodebuild \
  -project Watchdog.xcodeproj \
  -scheme Watchdog \
  -configuration Release \
  -derivedDataPath DerivedData/release \
  build
```

## 업데이트

같은 설치 명령을 다시 실행합니다.

```bash
./scripts/install.sh
```

기존 앱을 강제 종료하거나 실행 중인 번들을 덮어쓰지 않습니다. 정상 종료가 되지 않으면 설치를 중단합니다.

## 제거

앱을 종료한 뒤 설치한 번들만 삭제합니다.

```bash
rm -rf "$HOME/Applications/Watchdog.app"
```

로그인 시 자동 실행을 활성화했다면 제거 전에 Watchdog의 **감지 규칙 → 로그인 시 자동 실행**을 끕니다.

## Gatekeeper 관련 원칙

현재 베타는 Apple Development 서명이며 Developer ID 공증 전입니다. macOS의 앱별 승인 절차를 사용합니다.

허용:

- Finder 우클릭 → 열기
- 시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기

금지:

- `spctl --master-disable`
- 전역 Gatekeeper 비활성화
- 설치 스크립트에서 `xattr -d com.apple.quarantine`
- 출처와 체크섬을 확인하지 않은 미러 파일 설치

문제가 생기면 공식 릴리스에서 다시 내려받아 SHA-256을 확인합니다.
