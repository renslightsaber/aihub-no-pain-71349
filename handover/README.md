# 🤝 인수인계: AI Hub 71349 다운로드 → metadata 생성

AI Hub 「감성 및 발화스타일 동시 고려 음성합성 데이터」(**datasetkey=71349**)를
**처음부터 받아서 `meta/metadata.csv`까지 만드는 명령을 순서대로** 정리한 문서입니다.
위에서부터 그대로 복사해 실행하면 됩니다.

- 각 단계의 옵션·트러블슈팅: [download_guide.md](../download_guide.md) (다운로드), [USAGE.md](../USAGE.md) (압축 해제 이후)
- 전체 소요: 다운로드 수 시간(회선 의존) + 압축 해제 1.5~2시간 + 메타 생성 약 25분 (NFS 기준)

---

## ⚠️ 시작 전 필수: AI Hub API Key

**이 절차는 AI Hub API Key 없이는 진행할 수 없습니다.**

1. [AI Hub](https://www.aihub.or.kr) 회원가입
2. 「감성 및 발화스타일 동시 고려 음성합성 데이터」(71349) **다운로드 신청 → 승인** (보통 1~3일)
3. 승인 후 **마이페이지 → API Key 발급**

| 사용처 | 방식 |
|---|---|
| `aihubshell -mode d` (다운로드) | `-aihubapikey "$AIHUB_APIKEY"` 인자로 전달 |
| `verify/repair_aihub.sh` (복구) | 환경변수 `AIHUB_APIKEY` — **없으면 즉시 종료** |

> - **ID/PW가 아닙니다.** 이 레포의 어떤 스크립트도 `AIHUB_ID`/`AIHUB_PW`를 쓰지 않습니다.
> - 승인 전이거나 Key가 만료되면 인증은 되는 듯해도 0바이트/HTML 파일이 받아집니다. 마이페이지에서 승인 상태·유효기간을 확인하세요.
> - **Key를 `.bashrc`나 git에 평문으로 남기지 마세요.** 필요할 때만 `export` 하거나, 권한 600 파일에 두고 `source` 하세요.

---

## 준비물

| 항목 | 기준 |
|---|---|
| 디스크 | **600GB 이상** (zip 220GB + 해제본 293GB 동시 보관 = 순간 최대 513GB) |
| inode | 여유 70만 이상 (파일 63만 개 생성) |
| 도구 | bash 4+, Python 3.8+, `curl` `unzip` `find` `xargs` `awk` `sed` |
| 로케일 | `locale charmap` → `UTF-8` (한글 폴더명) |

metadata 생성(`build_metadata.py`)에는 Python 패키지 **`pandas` 하나**만 필요합니다: `pip install pandas`
(`verify_extraction.py`는 표준 라이브러리 + `unzip`만 사용)

---

## 전체 명령 (순서대로)

### Step 0. 공통 변수

```bash
export REPO=~/aihub-no-pain-71349            # 이 레포를 클론할 경로
export DSET=/data/aihub_71349                # 데이터셋을 받을 경로 (600GB 여유)
export AIHUB_APIKEY='<발급받은_API_Key>'     # ← 필수
export LANG=C.UTF-8 LC_ALL=C.UTF-8           # locale -a 에 있는 이름으로
```

셸을 새로 열 때마다 다시 설정해야 합니다.

### Step 1. 레포 클론

```bash
git clone https://github.com/renslightsaber/aihub-no-pain-71349.git "$REPO"
chmod +x "$REPO"/verify/*.sh "$REPO"/preprocess/*.sh
```

### Step 2. aihubshell 설치

```bash
mkdir -p ~/bin && cd ~/bin
curl -o aihubshell https://api.aihub.or.kr/api/aihubshell.do
chmod +x aihubshell
export PATH="$HOME/bin:$PATH"
command -v aihubshell && aihubshell -help
```

sudo 없는 환경 기준입니다. `aihubshell v0.6`(25.09.19) 이상에서 검증했습니다.

### Step 3. 사전 점검

```bash
mkdir -p "$DSET" && cd "$DSET"
df -BG .          # Available 600G 이상
df -i .           # IFree 70만 이상
locale charmap    # UTF-8
python3 -c "import pandas" || pip install pandas
```

### Step 4. 다운로드

```bash
cd "$DSET"
cp "$REPO/verify/filelist_71349.txt" .       # 검증 스크립트의 기준값 (zip 1,412개 목록 + filekey)

tmux new -s aihub                            # 세션이 끊겨도 살아남게
aihubshell -mode d -datasetkey 71349 -aihubapikey "$AIHUB_APIKEY"
#   Ctrl+b d 로 분리, tmux attach -t aihub 로 복귀
```

- 완료 기준: zip **1,412개 / 약 220GB**
- 진행 확인(다른 터미널): `find "$DSET" -name "*.zip" | wc -l`
- 중간에 끊겨도 처음부터 다시 받을 필요 없습니다 → Step 6에서 복구

### Step 5. ROOT 잡기

```bash
cd "$DSET"
export ROOT="$(find . -maxdepth 1 -type d -name '133.*' | head -1)"
echo "ROOT=[$ROOT]"      # 비어 있으면 다운로드 위치 재확인
```

aihubshell 버전·로케일에 따라 폴더명이 `133.감성_및_...`(밑줄) 또는 `133.감성 및 ...`(공백)로 달라서,
검증·정리 스크립트가 읽는 `ROOT`를 실제 이름으로 맞춰 줍니다.

### Step 6. 다운로드 검증 → 복구 (정상 나올 때까지 반복)

```bash
cd "$DSET"
bash "$REPO/verify/check_aihub.sh"                 # ① 누락·잔재 진단 (수 분)
PARALLEL=8 bash "$REPO/verify/verify_zips.sh"      # ② zip CRC 무결성 (약 30분, 권장)

# 이상이 있으면:
DRY_RUN=1 bash "$REPO/verify/repair_aihub.sh"      # ③ 복구 계획 미리보기
bash "$REPO/verify/repair_aihub.sh"                # ④ 실제 복구 (AIHUB_APIKEY 필요)
bash "$REPO/verify/check_aihub.sh"                 # ⑤ 수렴 확인
```

통과 기준: `✓ 모든 zip 파일이 정상적으로 다운로드되었습니다.` / `✓ 모든 zip 무결성 통과`

> ⚠️ `repair_aihub.sh`는 깨진 zip·`.part` 잔재를 **실제로 삭제**한 뒤 재다운로드합니다. 항상 `DRY_RUN=1` 먼저.
> 일부러 일부만 받은 경우에는 `INCLUDE_NEVER_DOWNLOADED=0`을 붙이세요.

### Step 7. zip 정리 → 압축 해제

```bash
cd "$DSET"
DRY_RUN=1 bash "$REPO/preprocess/move_zips_to_zips_dir.sh"   # 미리보기
bash "$REPO/preprocess/move_zips_to_zips_dir.sh"             # 모든 zip → ./zips/ (경로 구조 보존)

PARALLEL=8 bash "$REPO/preprocess/extract_zips.sh"           # ./zips → ./data 병렬 해제
```

- `move_zips_to_zips_dir.sh` 이후 zip은 `./zips/` 아래에만 있습니다 (`ROOT`는 비면 삭제됨).
- `stripped absolute path spec` 경고가 쏟아지는 건 **정상**입니다 (zip 내부가 절대경로라 unzip이 exit 1을 내지만 스크립트가 성공으로 처리).
- 끊기면 그대로 재실행하면 이어서 진행됩니다 (`SKIP_EXISTING=1`).

### Step 8. 압축 해제 완전성 검증

```bash
python3 "$REPO/preprocess/verify_extraction.py" --zips-dir ./zips --data-dir ./data
```

통과 기준: `✅ 모든 zip이 빠짐없이 압축 해제되었습니다.` (zip 1,412 / 내부 파일 636,045 / 문제 0)

실패하면 `extract_zips.sh`를 다시 돌린 뒤 재검증합니다.

### Step 9. metadata 생성

```bash
cd "$DSET"
python3 "$REPO/preprocess/build_metadata.py" \
  --data-dir ./data \
  --base-dir "$PWD" \
  --output-dir ./meta \
  --use-index
```

| 옵션 | 의미 |
|---|---|
| `--data-dir` | 압축 해제된 폴더 |
| `--base-dir` | CSV `base_dir` 컬럼 값. `audio_path`는 이 경로 기준 상대경로라, 서버 이전 시 이 컬럼만 바꾸면 됨 |
| `--output-dir` | 산출물 폴더 |
| `--use-index` | wav 목록을 한 번에 인덱싱 (NFS에서 `stat` 비용 절감, 권장) |

**산출물 (`meta/`, 약 1.3GB)**

```
meta/
├── metadata.csv               # 전체 (623,642 row)
├── stats_overall.txt          # 전체 통계
├── stats_per_speaker.txt      # 화자별 통계
├── stats_per_gender.txt       # 성별 통계
└── metadatas_per_speaker/     # 화자별 CSV 89개
```

### Step 10. 결과 확인

콘솔 출력의 마지막 요약이 아래와 같으면 성공입니다.

```
총 row 수    : 623,642
고유 화자    : 89명
split 분포   : {'train': 560624, 'valid': 63018}
audio 누락   : 0건 (0.00%)
```

```bash
grep -A3 "split 분포" ./meta/stats_overall.txt    # train 과 valid 가 둘 다 있어야 정상
```

| 어긋날 때 | 원인 | 조치 |
|---|---|---|
| JSON 11,875개 / `valid` 없음 | 구버전(v3) 라벨 패턴으로 Validation 누락 | 최신 `build_metadata.py`로 재실행 |
| `audio 누락`이 많음 | 압축 해제 미완료 | Step 7~8 재실행 후 Step 9 |

### Step 11. (선택) zip 삭제로 220GB 회수

**Step 8 전수 검증을 통과한 경우에만** 진행하세요. 되돌릴 수 없고, 다시 받으려면 220GB를 처음부터 받아야 합니다.

```bash
cd "$DSET"
rm -rf ./zips
df -h .
```

`build_metadata.py`는 `data/`만 읽으므로 zip을 지운 뒤에도 Step 9는 언제든 다시 실행할 수 있습니다.
`filelist_71349.txt`는 이후 검증·부분 재다운로드의 기준값이라 지우지 마세요.

---

## 한눈에 보는 흐름

```
[API Key 발급] → aihubshell 다운로드 → check/verify/repair (정상까지 반복)
   → move_zips → extract_zips → verify_extraction → build_metadata → meta/metadata.csv
                                         └─(통과 시)→ rm -rf zips (선택)
```

## 다음 단계

- 청음·탐색: `notebooks/explore_dataset.ipynb` → [USAGE.md 5장](../USAGE.md#5-데이터-탐색)
- CSV 컬럼 설명: [USAGE.md 6장](../USAGE.md#6-csv-컬럼-레퍼런스)
