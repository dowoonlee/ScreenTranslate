# 릴리즈와 업데이트 운영

## 서명 키의 역할

| 구분 | 저장 위치 | 역할 |
|---|---|---|
| ScreenTranslate Local Development | 로그인 키체인 | 이 Mac의 개발 빌드에 고정 앱 신원 부여 |
| Developer ID Application | 로그인 키체인 | 정식 외부 배포·Hardened Runtime·공증 |
| Sparkle Ed25519 개인키 | 로그인 키체인의 전용 계정 | 업데이트 ZIP과 피드 서명 |
| Sparkle 공개키 | `config/sparkle-public-key.txt` | 앱에 내장하여 업데이트 검증 |

로컬 인증서는 `scripts/setup-local-signing.py`를 최초 한 번 실행해 만듭니다. 이후에는 같은 인증서를 재사용합니다. 인증서가 존재하지만 유효하지 않으면 스크립트가 중단하며 임의로 교체하지 않습니다. 로컬 개인키는 내보내기 불가능한 항목으로 가져옵니다. 이 개발용 신원은 해당 키체인이 소실되면 재생성할 수 없습니다.

현재 저장소의 업데이트 공개키는 발행자의 전용 키체인 키에 대응합니다. 기여자가 빌드할 때 이를 임의로 바꾸지 마세요. 독립적인 포크를 배포할 경우 자신의 키와 저장소·피드 URL을 사용해야 합니다.

Sparkle 키를 새로 준비하는 독립 배포자는 `swift package resolve` 후 다음을 사용할 수 있습니다. 기본 실행은 개인키를 키체인에 저장하고 **공개키만** 출력합니다.

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account dev.screentranslate.updates
```

개인키를 `-s`, 셸 인자, 환경 파일, CI 로그 또는 GitHub 저장소에 전달하지 마세요. 현재 릴리즈 스크립트는 키체인에서 직접 읽습니다. 이 저장소의 CI에는 서명 키를 등록하지 않습니다.

## 개발용 프리릴리즈

1. `config/release.json`의 `version`과 단조 증가하는 `build`를 수정합니다. 릴리즈 태그는 `vX.Y.Z-preview.N` 형식입니다.
2. `swift test`, 공개 파일 검사와 Gitleaks를 실행합니다.
3. Universal 앱을 고정 로컬 인증서로 빌드하고 패키징합니다.

```sh
./scripts/build-app.sh
python3 scripts/verify-bundle.py
./scripts/prepare-release.py --tag v0.2.0-preview.1
```

출력은 `dist/releases/<tag>/`의 ZIP, SHA256SUMS, 서명된 피드입니다. `docs/appcast-dev.xml`도 갱신됩니다. 이 파일은 서명이 있으므로 직접 편집하면 안 됩니다.

개발용 프리릴리즈는 **Apple 공증이 없는 개발 버전**이라고 명시합니다. Gatekeeper 경고를 무력화하거나 사용자의 보안 설정을 끄도록 안내하지 않습니다. 현재는 source build 또는 이를 이해하는 개발자에게 제공하는 시험 배포입니다.

## 정식 배포

Apple Developer Program과 **Developer ID Application** 인증서가 준비되어야 합니다. 앱스토어 배포용 인증서나 로컬 인증서로 대체할 수 없습니다.

1. `xcrun notarytool store-credentials`의 대화형 안내로 공증 자격 증명을 키체인 프로파일에 저장합니다. 실제 비밀번호·API 개인키를 문서나 명령 기록에 남기지 마세요.
2. 정식 버전·빌드 번호를 올립니다.
3. 다음처럼 빌드·패키징합니다. 인증서 이름과 프로파일 이름은 공개 메타데이터이며 실제 비밀값을 넣지 않습니다.

```sh
./scripts/build-app.sh --mode production --identity 'Developer ID Application: YOUR NAME (TEAMID)'
./scripts/prepare-release.py --mode production --tag v1.0.0 --notary-profile ScreenTranslateNotary
```

정식 빌드는 Developer ID 서명과 Hardened Runtime을 적용합니다. 패키징은 Apple의 `Accepted` 결과, stapling 검증, Gatekeeper 검증이 모두 통과해야 완료됩니다. `unsigned` 빌드는 릴리즈 도구가 거부합니다. **이 경로는 Developer ID가 없는 초기 프리릴리즈 환경에서는 실제 공증까지 검증하지 못했습니다.**

정식 피드는 `docs/appcast.xml`, 개발 피드는 `docs/appcast-dev.xml`입니다. 서로 자동 전환되지 않습니다. 최초 정식 배포로 이동할 때는 정식 앱을 설치하도록 별도 안내하고, 기존 개발 피드를 정식 앱으로 연결할 경우 서명·전환 절차를 따로 시험해야 합니다.

## GitHub 발행 순서

반드시 사용자에게 승인된 릴리즈만 발행합니다. 인증 토큰을 URL에 넣지 않습니다.

1. 소스 변경을 커밋·push하고 CI 성공을 확인합니다.
2. 빌드 소스를 가리키는 태그에 **draft release**를 만듭니다.
3. ZIP과 `SHA256SUMS.txt`만 명시적으로 업로드합니다. `dist/` 전체 또는 키체인·`.local/`을 업로드하지 않습니다.
4. 릴리즈 노트·파일·서명 검증을 확인한 뒤 공개합니다. 개발 버전은 prerelease로 표시합니다.
5. **다운로드 파일이 공개된 후** 생성된 `docs/appcast-dev.xml` 또는 `docs/appcast.xml`을 커밋·push합니다. 파일이 없는 업데이트를 먼저 안내하지 않도록 하기 위함입니다.
6. 실제 앱의 **업데이트 확인…**으로 피드 접근과 서명 검증을 확인합니다. 후속 릴리즈에서는 이전 버전에서 새 버전 설치·재실행까지 시험합니다.

```sh
gh auth switch --user dowoonlee
# 예시: 명확히 지정한 파일만 업로드하고 릴리즈 노트는 파일로 전달
gh release create v0.2.0-preview.1 dist/releases/v0.2.0-preview.1/ScreenTranslate-0.2.0-universal.zip dist/releases/v0.2.0-preview.1/SHA256SUMS.txt --repo dowoonlee/ScreenTranslate --draft --prerelease --title 'ScreenTranslate 0.2.0 Preview 1' --notes-file docs/releases/v0.2.0-preview.1.md
```

기존 공개 태그와 바이너리를 덮어쓰지 말고 항상 새 버전·빌드 번호를 발행합니다. SHA256 체크섬은 다운로드 무결성 확인용이며, 업데이트 인증은 앱에 내장된 공개키와 Ed25519 서명이 담당합니다.

## 권한 유지

코드 서명 요구사항은 `codesign -d -r- dist/ScreenTranslate.app`으로 확인합니다. ad-hoc의 파일 해시 대신 **앱 식별자와 고정 인증서**에 연결되어야 합니다. 빌드·배포 스크립트는 `tccutil reset`을 실행하지 않습니다. 인증서 교체, 앱 식별자 변경, macOS 정책 변화 또는 사용자의 권한 취소 시에는 다시 승인해야 할 수 있습니다.
