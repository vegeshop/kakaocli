# kakaocli (vegeshop fork)

macOS 카카오톡의 로컬 DB를 **읽기 전용**으로 읽어 채팅·메시지를 터미널이나 AI 에이전트에서 조회하는 CLI입니다.
메시지 전송은 공식 카카오톡 앱 UI를 자동화하며, 비공식 LOCO 프로토콜은 쓰지 않습니다.

*A fork of [silver-flight-group/kakaocli](https://github.com/silver-flight-group/kakaocli) that fixes the ~11s startup / user ID detection failure ([#4](https://github.com/silver-flight-group/kakaocli/issues/4)).*

## 왜 포크했나

원본은 최신 카카오톡에서 읽기 명령(`chats`, `messages`, `search`…)이 실행할 때마다 **~11초** 걸리고, 사용자 ID가 조금만 커도 **아예 실패**합니다. 매 실행마다 SHA-512 해시에서 사용자 ID를 단일 코어·10초 제한으로 brute force 하기 때문입니다.

- 이슈 [silver-flight-group/kakaocli#4](https://github.com/silver-flight-group/kakaocli/issues/4)는 2026-04 등록 후 아직 열려 있고, 이를 고치는 PR(#6, #10, #15, #20, #26)도 모두 머지되지 않았습니다. 원본 저장소는 2026-03 이후 업데이트가 없습니다.
- 이 포크는 사용자 ID를 키체인에 캐시하고 전 코어로 병렬 탐색해 **11초 → 0.3초**(M4 Pro)로 줄였습니다. 상세: [vegeshop/kakaocli#1](https://github.com/vegeshop/kakaocli/pull/1)

## 설치

필요: macOS 14+, Xcode 또는 Command Line Tools(Swift 6), Homebrew

```bash
brew install sqlcipher
git clone https://github.com/vegeshop/kakaocli.git ~/dev/kakaocli
cd ~/dev/kakaocli && swift build -c release
mkdir -p ~/bin && cp .build/release/kakaocli ~/bin/
grep -q 'HOME/bin' ~/.zshrc || echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc && kakaocli --version
```

- Homebrew로 원본을 설치했었다면 먼저 `brew uninstall kakaocli`
- **시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한**에 사용하는 터미널 앱을 추가하세요. 전송(`send`)은 **손쉬운 사용** 권한도 필요합니다.

## 업데이트

```bash
cd ~/dev/kakaocli && git pull && swift build -c release && cp .build/release/kakaocli ~/bin/
```

## 사용

```bash
kakaocli chats --limit 10                   # 최근 채팅
kakaocli messages --chat "이름" --since 7d   # 특정 채팅의 메시지
kakaocli search "키워드"                     # 전체 메시지 검색
kakaocli query "SELECT count(*) FROM NTChatRoom"   # SQL 직접 실행 (읽기 전용)
kakaocli send --me _ "테스트"                # 나와의 채팅으로 전송
```

- 첫 실행만 1~2초 동안 사용자 ID를 찾아 키체인에 저장하고, 이후엔 바로 실행됩니다.
- 카카오톡 계정을 바꿨다면 `kakaocli cache clear`. 자동 탐색이 실패하면 `export KAKAOCLI_USER_ID=<내 ID>`.
- 전체 옵션은 `kakaocli --help`, AI 에이전트 연동은 [AGENTS.md](AGENTS.md).

## 주의

- 카카오와 무관한 비공식 도구입니다. 읽기는 로컬 파일만 보지만, 자동 전송은 카카오 이용약관상 제재 대상이 될 수 있으니 본인 대화방에서 소량으로만 쓰세요.
- 로컬 DB에는 이 Mac에서 열어본 채팅의 메시지만 있습니다.
- 키체인에는 사용자 ID만 저장하며, DB 키는 저장하거나 출력하지 않습니다.

## 크레딧 · 라이선스

- 원작: [Brian ByungHyun Shin](https://github.com/brianshin22) / [Silver Flight Group](https://github.com/silver-flight-group) — [silver-flight-group/kakaocli](https://github.com/silver-flight-group/kakaocli)
- DB 복호화 방식: [blluv](https://gist.github.com/blluv/8418e3ef4f4aa86004657ea524f2de14) · 영감: [wacli](https://github.com/steipete/wacli)
- MIT License, Copyright (c) 2026 Silver Flight Group, LLC — [LICENSE](LICENSE) · [CHANGELOG](CHANGELOG.md)
