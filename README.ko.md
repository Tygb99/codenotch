# Codenotch — yong 포크

원 저장소 [vinzdg/codenotch](https://github.com/vinzdg/codenotch) v1.23.0을 바탕으로 한 포크입니다(브랜치 `yong`, 버전 `1.23.0-yong`). 쓰는 법과 나머지 설명은 [README.md](README.md)에 있습니다.

## 이 포크가 바꾼 것

- **클로드 사용량은 한 곳에서만 읽습니다.** 클로드 사용량은 2분에 한 번까지만 읽습니다. `claude /usage`와 사용량 API가 이 횟수를 함께 씁니다. 읽은 값은 매번 `~/.claude/statusline/usage-cache.json`에 상태줄 스크립트와 같은 모양으로 씁니다. 상태줄은 Codenotch가 돌고 있으면 이 파일을 그대로 읽습니다. 같은 API를 두 곳에서 부르지 않으니 429로 막히는 일이 줄어듭니다.
- **GPT 계정을 모두 보입니다.** opencodex(`~/.opencodex`)에 등록된 계정마다 링이 하나씩 생깁니다. 값은 opencodex가 남긴 로컬 캐시에서 읽어서 요청이 더 늘지 않습니다. 메일 주소는 앞 4자만 보입니다.
- **도리 레인을 보입니다.** `~/.dori/state/lanes`에서 닫히지 않은 레인 수를 셉니다. 링의 호는 그중 아직 작업 중인 비율입니다. `~/.omo/omomeow/reports.log`에 한 시간 안에 「사장 필요」 REPORT 줄이 있으면 빨갛게 바뀝니다. 마우스를 올리면 레인 key와 제목 목록이 나옵니다. 두 파일 모두 읽기만 합니다.
- **자동 업데이트를 껐습니다.** Sparkle을 시작하지 않으므로 원 저장소의 새 판이 이 빌드를 덮어쓰지 않습니다.

빌드와 시험은 README.md의 [Building](README.md#building) 그대로입니다.
