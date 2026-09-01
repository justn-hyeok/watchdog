# Watchdog

Watchdog는 폭주하거나 고아가 된 프로세스를 터미널 명령 없이 찾아 정리할 수 있는 네이티브 macOS 메뉴바 유틸리티입니다.

## 설치

요구 사항: macOS 14 이상. 사람·에이전트 공통 상세 절차는 **[INSTALL.md](INSTALL.md)**가 기준입니다.

### 사람이 설치

1. [GitHub Releases](https://github.com/justn-hyeok/watchdog/releases)에서 최신 DMG를 내려받습니다.
2. DMG를 열고 Watchdog을 Applications 폴더로 드래그합니다.
3. 현재 공개 배포본은 Apple 공증 전 빌드이므로 최초 실행 시 Finder에서 Watchdog을 우클릭하고 **열기 → 열기**를 선택합니다.

우클릭으로 열리지 않으면 한 번 실행을 시도한 뒤 **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기**를 선택합니다. 이는 Apple이 제공하는 앱별 승인 절차입니다. 전역 Gatekeeper 비활성화나 격리 속성 제거는 필요하지 않습니다.

공식 배포 파일은 이 저장소의 Releases에서만 제공합니다. `v0.1.0` 파일 무결성:

```text
Watchdog-0.1.0-macos.zip  44b198ae0aa19137706f2e39f0cc01eb23687e59515c00b2b1e45377229256bb
Watchdog-0.1.0-macos.dmg  ab6937131d23a487418ac5e72763781ac88717a464aec6654e565b06aca2af57
```

검증 명령:

```bash
shasum -a 256 Watchdog-0.1.0-macos.dmg
```

### 에이전트·터미널에서 설치

```bash
git clone https://github.com/justn-hyeok/watchdog.git
cd watchdog
./scripts/install.sh
```

스크립트는 공식 릴리스 다운로드, SHA-256 확인, 코드 서명 구조 검증과 `~/Applications` 설치만 수행합니다. `sudo`, `SIGKILL`, Gatekeeper 비활성화 또는 quarantine 제거는 사용하지 않습니다.

## 주요 기능

- 앱 실행 직후 메뉴를 열지 않아도 2초 주기로 감시를 시작합니다.
- 프로세스 CPU 누적 시간의 구간별 차이와 실제 메모리 사용량을 확인합니다.
- macOS 시스템 CPU와 메모리 사용량·압축 메모리·스왑 사용량·VM 압력 상태를 표시합니다.
- CPU·메모리 임계값을 지속해서 넘긴 프로세스와 고아 의심 에이전트를 이유와 함께 표시합니다.
- 지원하는 코딩 에이전트의 작업 디렉터리와 프로젝트명을 비동기로 조회합니다.
- 경고를 해당 프로세스가 종료될 때까지 무시하고 즉시 되돌릴 수 있습니다.
- 현재 사용자 소유 프로세스를 일시 정지, 재개, 종료 또는 강제 종료합니다.
- 첫 실행 시 로그인 항목에 자동 등록되며, 감지 규칙에서 끌 수 있습니다.

## 안전 계약

- 시스템·다른 사용자·PID 1·Watchdog 자체와 신원을 확인할 수 없는 프로세스는 제어하지 않습니다.
- 모든 동작은 PID, 사용자 ID, 시작 시각, 최신 관측 세대를 결합한 단일 사용 권한을 거칩니다.
- 표본이 5초 이상 오래됐거나 수집에 실패하면 기존 정보는 참고용으로 남지만 모든 제어가 차단됩니다.
- 일반 종료는 `SIGTERM`만 사용하며 종료 여부를 별도로 확인합니다.
- `SIGKILL`은 별도의 강제 종료 확인을 완료한 경우에만 한 번 전송합니다. 시간 초과나 경고가 자동 강제 종료로 이어지지 않습니다.
- PID 확인과 `kill(2)` 사이의 운영체제 수준 경쟁 조건을 완전히 제거할 수는 없으므로, 전송 직전 신원을 다시 검사하고 전송 후 결과를 재확인합니다.

## 감지 설정

| 설정 | 기본값 | 지원 범위 |
|---|---:|---:|
| CPU 임계값 | 100% | 1–1000% |
| 지속 시간 | 20초 | 2–300초 |
| 프로세스 메모리 | 2 GiB | 0.1–1024 GiB |

저장된 값이 숫자가 아니거나 무한대·범위 밖 값이면 시작 시 안전한 범위로 정규화됩니다. CPU와 메모리의 지속 시간은 벽시계가 아닌 단조 시계로 계산하며, 수집 실패나 5초를 넘는 관측 공백은 누적을 초기화합니다.

## 소스에서 빌드

요구 사항: Xcode 16 이상, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone https://github.com/justn-hyeok/watchdog.git
cd watchdog
xcodegen generate
xcodebuild -project Watchdog.xcodeproj -scheme Watchdog -configuration Debug build
```

전체 검증:

```bash
xcodebuild -project Watchdog.xcodeproj -scheme Watchdog -configuration Debug test
xcodebuild -project Watchdog.xcodeproj -scheme Watchdog -configuration Release build
```

`WatchdogPreview`는 합성 프로세스 상태로 메뉴 화면과 접근성을 검증하는 개발 전용 창입니다. `WatchdogUITests`는 실제 프로세스에 시그널을 보내지 않습니다.

`project.yml`이 Xcode 프로젝트 구성의 유일한 기준입니다. 대상이나 파일 배치를 변경한 뒤에는 XcodeGen으로 프로젝트를 재생성합니다.

## 배포 정책

Watchdog는 유료 Apple Developer Program에 의존하지 않는 공개판으로 배포합니다. Developer ID 공증은 현재 릴리스 조건이 아니며, 사용자는 최초 실행 시 macOS의 앱별 승인 절차를 거쳐야 합니다. 공식 GitHub Releases, 고정 SHA-256, 코드 서명 구조 검증, 재현 가능한 소스 빌드 절차로 배포 무결성을 보완합니다.

단위·통합·UI 테스트, Debug/Release 빌드, 앱 실행 스모크와 장기 실행 리소스 검증은 공증 여부와 관계없이 릴리스 품질 게이트로 유지합니다. 향후 공증 배포를 선택할 경우에만 Developer ID 서명, 올바른 Team ID, Apple 공증 `Accepted`, stapling과 Gatekeeper 검증을 추가로 요구합니다.

## 라이선스

[MIT License](LICENSE)
