# ScreenTranslate

macOS에서 `⌘⇧2`로 선택한 화면을 한국어로 번역하는 Swift 메뉴 막대 앱입니다. 일반 캡처는 원본과 번역을 좌우로, 가로가 세로의 2.2배 이상인 긴 캡처는 원본을 위·번역을 아래로 표시합니다.

## 현재 배포 상태

**개발용 프리릴리즈**입니다. Apple Developer ID 서명·공증은 아직 제공하지 않습니다. 다운로드한 앱은 Gatekeeper가 실행을 제한할 수 있습니다. 일반 사용자용 정식 배포는 Developer ID와 공증을 갖춘 후 제공합니다. 보안 설정을 끄는 방법은 제공하지 않습니다.

- [릴리즈](https://github.com/dowoonlee/ScreenTranslate/releases)
- macOS 13 이상, Apple Silicon / Intel Universal 앱
- API 키는 사용자가 직접 등록하며 API 사용료는 해당 계정에 청구됩니다.

## 사용

1. 앱을 실행하면 메뉴 막대의 말풍선 아이콘에서 대기합니다.
2. 메뉴의 **설정…**에서 OpenAI 또는 Claude를 선택하고 API 키를 저장합니다.
3. 워크스페이스에 연결되지 않은 Claude 키는 **워크스페이스 ID**도 입력합니다.
4. `⌘⇧2`를 누르고 화면 기록 권한을 허용한 뒤 필요하면 앱을 다시 실행합니다.
5. 영역을 드래그합니다. Esc로 취소할 수 있습니다.
6. 번역이 완료되면 이미지 비율에 맞춰 원본·한국어 이미지가 좌우 또는 위아래로 표시됩니다. 결과 창은 다른 일반 창보다 위에 유지됩니다.

설정은 메뉴에서 직접 열 때만 표시됩니다. 캡처·번역 중에는 앱 창을 숨깁니다. 진행 상태·오류 확인과 취소는 메뉴 막대에서 할 수 있습니다. 결과 이미지를 복사하거나 PNG로 저장할 수 있고, 번역 텍스트도 따로 볼 수 있습니다.

등록된 API 키는 설정 화면에 다시 채워 넣지 않습니다. 새 키 입력란을 비워 저장하면 기존 키를 유지하며, **키 삭제**로 해당 서비스의 키를 제거합니다.

## 업데이트

메뉴 막대 또는 설정의 **업데이트 확인…** 버튼으로 새 버전을 확인하고 Sparkle의 안내에 따라 설치합니다. 자동 확인·자동 설치·시스템 프로파일 전송은 기본적으로 꺼져 있습니다.

업데이트 파일과 배포 목록은 전용 Ed25519 키로 서명합니다. 앱은 서명된 목록을 확인하고, 압축을 풀기 전에 파일 서명을 검증합니다. 개발용과 정식 배포는 다른 업데이트 목록을 사용합니다. 최초 개발용 다운로드는 Apple 공증 대상이 아니므로 일반 배포와 동일한 신뢰를 제공하지 않습니다.

## 처리 과정

`영역 캡처 → 로컬 Vision OCR → 선택 이미지·OCR 텍스트를 API로 전송 → JSON 번역 검증 → 로컬 이미지 합성`

기본 모델은 OpenAI `gpt-4.1-mini`, Claude `claude-sonnet-5-5`입니다. 계정에서 이용 가능한 이미지 입력 모델 ID로 변경할 수 있습니다. 이미지 생성 모델이 아닌, 원문 위치에 흰 배경과 한국어를 그리는 방식입니다. OCR 누락, 세로쓰기, 작은 글씨, 긴 문단에는 한계가 있습니다. 복잡한 배경·원본 글꼴은 복원하지 않습니다.

## 개발

Xcode 또는 Swift 5.9 이상과 Python 3.9 이상이 필요합니다. 별도 Swift 라이브러리는 Sparkle 하나이며 버전을 고정하고 있습니다.

```sh
swift test
python3 scripts/setup-local-signing.py
./scripts/build-app.sh
open dist/ScreenTranslate.app
```

전용 로컬 서명 인증서는 로그인 키체인에 생성되고 이후 재사용됩니다. 임시 ad-hoc 서명으로 자동 전환하지 않습니다. 인증서·앱 식별자가 유지되면 업데이트 사이에도 같은 앱 신원을 유지할 수 있습니다. 이전 ad-hoc 버전에서 최초 전환할 때는 화면 기록 권한과 키체인 접근을 다시 허용해야 할 수 있습니다. 로컬 인증서는 이 Mac의 개발용이며 Apple Developer ID를 대체하지 않습니다.

CI용 서명 없는 빌드는 `./scripts/build-app.sh --mode unsigned`로 명시해야 하며 릴리즈 도구는 이 결과의 배포를 거부합니다.

## 배포와 보안

- [릴리즈·업데이트 절차](docs/RELEASING.md)
- [보안 정책과 데이터 처리](SECURITY.md)
- [초기 보안 검토](docs/SECURITY-REVIEW.md)
- [개인정보 처리](PRIVACY.md)

[OpenAI 이미지 입력](https://developers.openai.com/api/docs/guides/images-vision) · [Claude 이미지 입력](https://platform.claude.com/docs/en/build-with-claude/vision) · [Sparkle](https://sparkle-project.org/documentation/)

앱 아이콘은 `assets/AppIcon.icns`를 사용합니다. `swift scripts/generate-icon.swift`로 원본 PNG와 macOS 아이콘을 재생성할 수 있습니다.
