#!/bin/bash
# ============================================================
# repair_aihub.sh (v6)
#
# v6 변경점:
#   - [버그] `.part` 잔재가 0개면 "processed_base: unbound variable" 로 1-B 통계
#     출력이 실패하던 문제 수정. `declare -A x` 만 하고 원소를 넣지 않은 배열은
#     bash 에서 "unset" 으로 취급되어 `set -u` 아래 `${#x[@]}` 가 에러가 된다.
#     → 모든 배열을 `=()` 로 초기화하고, 빈 배열 순회는 `${a[@]+"${a[@]}"}`
#       형태로 감싸 bash 4.0~4.3 에서도 안전하게 함.
#   - [버그] download.tar 잔재를 $ROOT 안에서만 찾던 문제 수정.
#     aihubshell 은 download.tar 를 "현재 디렉토리"에 만들고, 기존 파일이 있으면
#     download_YYYYMMDD_HHMMSS.tar 로 백업한다. 둘 다 현재 디렉토리에서 찾는다.
#   - [신규] batch 마다 결과 검증. aihubshell 은 curl 이 중간에 끊겨도
#     (curl: (18) transfer closed ...) "Download successful." 을 출력하고
#     잘린 tar 를 그대로 풀어 버린다(종료 코드 판정 버그). 그래서 batch 직후
#     요청한 zip 을 하나씩 `unzip -tq` 로 확인하고, 실패분은 삭제 후
#     RETRY 회까지 다시 받는다. 끝까지 실패한 것이 있으면 exit 1.
#   - [신규] 동시 실행 방지. 같은 디렉토리에서 두 번 실행하면 download.tar 를
#     서로 빼앗아(백업·삭제) 결과가 꼬인다. flock 잠금(LOCK_FILE)과
#     "같은 디렉토리에서 돌고 있는 aihubshell" 검사로 막는다.
#     (Ctrl+Z 로 멈춰 둔 이전 실행도 잠금을 쥐고 있으므로 여기서 걸린다.)
#
# v5 변경점:
#   - filelist 파싱 로직 정규화 (토큰 기반, 트리 문자 처리)
#   - 디스크 파일명 정규화 매칭 (한글 사이 공백 케이스 대응)
#   - DEBUG=1 모드 추가
#   - 깨진/누락 파일 식별 정확도 개선
#
# 환경변수:
#   AIHUB_APIKEY              (필수)
#   DATASET_KEY               기본: 71349
#   ROOT                      기본: ./133.감성_...
#   FILELIST                  기본: filelist_${DATASET_KEY}.txt
#   BATCH                     기본: 10
#   RETRY                     기본: 2   (batch 검증 실패분 재요청 횟수)
#   DRY_RUN                   기본: 0
#   INCLUDE_NEVER_DOWNLOADED  기본: 1
#   LOCK_FILE                 기본: .aihub_download.lock (download_71349.sh 와 공유)
#   DEBUG                     기본: 0
# ============================================================
set -u

DATASET_KEY="${DATASET_KEY:-71349}"
APIKEY="${AIHUB_APIKEY:?환경변수 AIHUB_APIKEY를 먼저 설정하세요.}"
FILELIST="${FILELIST:-filelist_${DATASET_KEY}.txt}"
ROOT="${ROOT:-./133.감성_및_발화_스타일_동시_고려_음성합성_데이터}"
BATCH="${BATCH:-10}"
RETRY="${RETRY:-2}"
DRY_RUN="${DRY_RUN:-0}"
INCLUDE_NEVER_DOWNLOADED="${INCLUDE_NEVER_DOWNLOADED:-1}"
LOCK_FILE="${LOCK_FILE:-.aihub_download.lock}"
DEBUG="${DEBUG:-0}"

for cmd in aihubshell unzip awk grep find sed tr flock pgrep; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] missing: $cmd"; exit 1; }
done
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "[ERROR] bash 4.0+ 필요"; exit 1
fi
[ -f "$FILELIST" ] || { echo "[ERROR] filelist 없음: $FILELIST"; exit 1; }
[ -d "$ROOT" ] || { echo "[ERROR] ROOT 없음: $ROOT"; exit 1; }

normalize_name() {
  echo "$1" | tr -d '[:space:]'
}

parse_filelist_line() {
  local line="$1"
  local clean=$(echo "$line" | sed -e 's/[─├└│|]/ /g' -e 's/\r//g')
  local zip_part=$(echo "$clean" | grep -oE '.*\.zip' | head -1)
  [ -z "$zip_part" ] && return 1
  local name_norm=$(echo "$zip_part" | sed 's/^[[:space:]]*//' | tr -d '[:space:]')
  local key=$(echo "$clean" | grep -oE '[0-9]{4,}' | tail -1)
  [ -z "$name_norm" ] || [ -z "$key" ] && return 1
  echo "${name_norm}|${key}"
}

# 현재 디렉토리에서 돌고 있는 aihubshell 의 PID 목록 (다른 디렉토리 것은 무시).
# 명령줄 문자열 검색만 하면 "aihubshell" 이라는 글자가 든 다른 셸까지 걸리므로,
# argv[0] 또는 argv[1] (bash 로 실행된 경우) 이 실제로 aihubshell 인 프로세스만 센다.
aihubshell_here() {
  local here pid a0 a1
  here=$(pwd -P)
  for pid in $(pgrep -u "$(id -u)" -f 'aihubshell' 2>/dev/null); do
    a0=""; a1=""
    { IFS= read -r -d '' a0; IFS= read -r -d '' a1; } 2>/dev/null < "/proc/$pid/cmdline" || continue
    [ "${a0##*/}" = "aihubshell" ] || [ "${a1##*/}" = "aihubshell" ] || continue
    [ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" = "$here" ] && echo "$pid"
  done
}

echo "============================================"
echo "  repair_aihub.sh v6"
echo "  DATASET_KEY              : $DATASET_KEY"
echo "  ROOT                     : $ROOT"
echo "  FILELIST                 : $FILELIST"
echo "  BATCH                    : $BATCH"
echo "  RETRY                    : $RETRY"
echo "  DRY_RUN                  : $DRY_RUN"
echo "  INCLUDE_NEVER_DOWNLOADED : $INCLUDE_NEVER_DOWNLOADED"
[ "$DEBUG" = "1" ] && echo "  DEBUG                    : ON"
echo "============================================"

# === 동시 실행 방지 ===
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  if [ "$DRY_RUN" = "1" ]; then
    echo
    echo "  [WARN] 다른 다운로드/복구가 이 디렉토리에서 실행 중입니다 ($LOCK_FILE 잠김)."
    echo "         진행 중인 파일 때문에 아래 점검 결과가 실제와 다를 수 있습니다."
  else
    echo
    echo "  [ERROR] 다른 download_71349.sh / repair_aihub.sh 가 이 디렉토리에서 실행 중입니다."
    echo "          ($LOCK_FILE 잠김)  두 개를 동시에 돌리면 download.tar 를 서로 빼앗습니다."
    echo "          - 끝날 때까지 기다리거나,"
    echo "          - Ctrl+Z 로 멈춰 둔 실행이 있다면: jobs → kill %번호"
    echo "          - 다른 창에서 돌고 있다면:  pgrep -af 'repair_aihub|download_71349|aihubshell'"
    exit 1
  fi
fi
running=$(aihubshell_here)
if [ -n "$running" ] && [ "$DRY_RUN" = "0" ]; then
  echo
  echo "  [ERROR] 이 디렉토리에서 aihubshell 이 이미 실행 중입니다 (PID: $(echo $running))."
  echo "          수동으로 띄운 aihubshell 이 끝난 뒤 다시 실행하세요."
  exit 1
fi

trap 'echo; echo "  [중단됨] 다시 실행하면 정상 zip 은 건너뛰고 이어서 진행합니다."; exit 130' INT

echo
echo "[1/3] 데이터셋 상태 점검 중..."

declare -A status_map=()      # 정규화 파일명 -> 상태
declare -A raw_name_map=()    # 정규화 파일명 -> 원본 파일명 (디스크 기준)
declare -A processed_base=()  # part 잔재를 이미 집계한 base (중복 방지)
declare -A filelist_files=()  # 정규화 파일명 -> filekey
declare -A key_to_name=()     # filekey -> 정규화 파일명 (batch 검증용)

# 1-A. 모든 zip 무결성 검증 (정규화 키로 저장)
total_zip=$(find "$ROOT" -name "*.zip" 2>/dev/null | wc -l)
echo "    (1-A) zip 무결성 검증 (${total_zip}개)..."
idx=0
while IFS= read -r zip; do
  idx=$((idx+1))
  printf "\r          진행: %d/%d" "$idx" "$total_zip"
  base_raw=$(basename "$zip")
  base_norm=$(normalize_name "$base_raw")
  raw_name_map["$base_norm"]="$base_raw"
  if unzip -tq "$zip" >/dev/null 2>&1; then
    status_map["$base_norm"]="ok"
  else
    status_map["$base_norm"]="broken"
  fi
done < <(find "$ROOT" -name "*.zip" 2>/dev/null)
[ "$total_zip" -gt 0 ] && echo

# 1-B. part 잔재 (정규화 키)
echo "    (1-B) part 잔재 식별..."
total_parts=$(find "$ROOT" -name "*.zip.part*" 2>/dev/null | wc -l)
while IFS= read -r partfile; do
  filename=$(basename "$partfile")
  base_raw=$(echo "$filename" | sed 's/\.part[0-9]*$//')
  base_norm=$(normalize_name "$base_raw")
  [ -n "${processed_base[$base_norm]:-}" ] && continue
  processed_base["$base_norm"]=1
  raw_name_map["$base_norm"]="$base_raw"

  current="${status_map[$base_norm]:-}"
  if [ -z "$current" ]; then
    status_map["$base_norm"]="missing"
  elif [ "$current" = "ok" ]; then
    status_map["$base_norm"]="residue_only"
  fi
done < <(find "$ROOT" -name "*.zip.part*" 2>/dev/null)
echo "          part 파일 총 ${total_parts}개 / 영향 base ${#processed_base[@]}개"

# 1-C. download.tar (aihubshell 은 현재 디렉토리에 만들고, 기존 것은 download_*.tar 로 백업)
tar_residues=()
while IFS= read -r t; do
  tar_residues+=("$t")
done < <( { find . -maxdepth 1 -type f \( -name 'download.tar' -o -name 'download_*.tar' \);
            find "$ROOT" -type f -name 'download*.tar'; } 2>/dev/null | sort -u)
tar_count=${#tar_residues[@]}
echo "    (1-C) download.tar 잔재 ${tar_count}개"
for t in ${tar_residues[@]+"${tar_residues[@]}"}; do
  echo "          - $t ($(du -h "$t" 2>/dev/null | cut -f1))"
done
if [ -n "$running" ] && [ "$tar_count" -gt 0 ]; then
  echo "          [WARN] aihubshell 실행 중 (PID: $(echo $running)) — 위 download.tar 는 받는 중인 파일일 수 있습니다."
fi

# 1-D. filelist 파싱
echo "    (1-D) filelist 파싱..."
total_in_filelist=0
debug_shown=0
while IFS= read -r line || [ -n "$line" ]; do
  parsed=$(parse_filelist_line "$line") || continue
  IFS='|' read -r name key <<< "$parsed"
  filelist_files["$name"]="$key"
  key_to_name["$key"]="$name"
  total_in_filelist=$((total_in_filelist+1))
  if [ "$DEBUG" = "1" ] && [ "$debug_shown" -lt 5 ]; then
    echo "          [DEBUG] name=[$name] key=[$key]"
    debug_shown=$((debug_shown+1))
  fi
done < "$FILELIST"
echo "          filelist 등록: ${total_in_filelist}개"

if [ "$total_in_filelist" -eq 0 ]; then
  echo "    [ERROR] filelist 파싱 실패. DEBUG=1 ./repair_aihub.sh 로 진단하세요."
  exit 1
fi

# 1-E. never_downloaded (정규화 키 비교)
never_downloaded=()
for name in "${!filelist_files[@]}"; do
  [ -z "${status_map[$name]:-}" ] && never_downloaded+=("$name")
done
echo "    (1-E) 다운로드 시도 안 됨: ${#never_downloaded[@]}개"

if [ "$INCLUDE_NEVER_DOWNLOADED" = "1" ]; then
  for name in ${never_downloaded[@]+"${never_downloaded[@]}"}; do
    status_map["$name"]="never_downloaded"
  done
  echo "          → 재다운로드 대상 포함"
fi

# 1-F. 통계
ok_count=0; broken_count=0; missing_count=0; residue_count=0; never_count=0
unhealthy_normalized=()
for name in "${!status_map[@]}"; do
  case "${status_map[$name]}" in
    ok)               ok_count=$((ok_count+1)) ;;
    broken)           broken_count=$((broken_count+1));   unhealthy_normalized+=("$name") ;;
    missing)          missing_count=$((missing_count+1)); unhealthy_normalized+=("$name") ;;
    residue_only)     residue_count=$((residue_count+1)) ;;
    never_downloaded) never_count=$((never_count+1));     unhealthy_normalized+=("$name") ;;
  esac
done

echo
echo "    === 점검 결과 ==="
echo "    filelist 등록 zip     : $total_in_filelist건"
echo "    --------"
echo "    정상 zip              : $ok_count건"
echo "    깨진 zip              : $broken_count건"
echo "    part만 있고 zip 없음  : $missing_count건"
echo "    zip 정상 + part 잔재  : $residue_count건"
echo "    다운로드 시도 안 됨   : $never_count건"
echo "    download.tar 잔재     : $tar_count건"
echo "    → 재다운로드 대상     : ${#unhealthy_normalized[@]}건"

if [ "$broken_count" -gt 0 ]; then
  echo "    깨진 zip 목록:"
  for name in "${!status_map[@]}"; do
    [ "${status_map[$name]}" = "broken" ] && echo "      - $name"
  done
fi

# 50%+ 경고
if [ "$total_in_filelist" -gt 0 ] && [ "${#never_downloaded[@]}" -gt 0 ]; then
  ratio=$(( never_count * 100 / total_in_filelist ))
  if [ "$ratio" -ge 50 ]; then
    echo
    echo "    [WARN] $never_count/$total_in_filelist (${ratio}%)가 다운로드 시도 안 됨."
    echo "           의도된 부분 다운로드라면 INCLUDE_NEVER_DOWNLOADED=0 으로 실행."
  fi
fi

# 1-G. 잔재 정리 (raw 파일명 사용해서 실제 디스크 파일 삭제)
if [ "$DRY_RUN" = "0" ]; then
  echo "    → 잔재 정리 중..."
  for t in ${tar_residues[@]+"${tar_residues[@]}"}; do
    rm -f "$t"
  done

  for name_norm in ${unhealthy_normalized[@]+"${unhealthy_normalized[@]}"}; do
    raw="${raw_name_map[$name_norm]:-}"
    if [ -n "$raw" ]; then
      find "$ROOT" -name "${raw}.part*" -delete 2>/dev/null
      find "$ROOT" -name "$raw" -delete 2>/dev/null
    fi
  done
  for name_norm in "${!status_map[@]}"; do
    if [ "${status_map[$name_norm]}" = "residue_only" ]; then
      raw="${raw_name_map[$name_norm]:-}"
      [ -n "$raw" ] && find "$ROOT" -name "${raw}.part*" -delete 2>/dev/null
    fi
  done
  echo "          잔재 정리 완료"
else
  echo "    → [DRY-RUN] 잔재 정리 건너뜀"
fi

if [ "${#unhealthy_normalized[@]}" -eq 0 ]; then
  echo
  echo "  ✓ 재다운로드 필요 없음. 종료."
  exit 0
fi

echo
echo "[2/3] filekey 매핑..."
filekeys=()
unmatched=()
for name in "${unhealthy_normalized[@]}"; do
  key="${filelist_files[$name]:-}"
  if [ -n "$key" ]; then
    filekeys+=("$key")
  else
    unmatched+=("$name")
  fi
done
echo "    매칭: ${#filekeys[@]}건 / 실패: ${#unmatched[@]}건"
if [ "${#unmatched[@]}" -gt 0 ]; then
  echo "    [WARN] 매칭 실패:"
  printf '      - %s\n' "${unmatched[@]}"
fi
if [ "${#filekeys[@]}" -eq 0 ]; then
  echo "  재다운로드할 filekey 없음. 종료."
  exit 1
fi

# batch 직후 검증: 요청한 filekey 의 zip 이 존재하고 unzip -tq 를 통과하는지.
# 실패한 filekey 는 batch_failed 에 쌓고, 깨진 zip·part 잔재는 지운다.
verify_batch() {
  local key name path
  declare -A disk_path=()
  while IFS= read -r path; do
    disk_path["$(normalize_name "$(basename "$path")")"]="$path"
  done < <(find "$ROOT" -type f -name '*.zip' 2>/dev/null)

  for key in "$@"; do
    name="${key_to_name[$key]:-}"
    path="${disk_path[$name]:-}"
    if [ -n "$path" ] && unzip -tq "$path" >/dev/null 2>&1; then
      batch_ok=$((batch_ok+1))
    else
      if [ -n "$path" ]; then
        echo "      ✗ 깨짐: $name → 삭제"
        rm -f "$path"
      else
        echo "      ✗ 없음: $name"
      fi
      [ -n "$name" ] && find "$ROOT" -name "${name}.part*" -delete 2>/dev/null
      batch_failed+=("$key")
    fi
  done
  # curl 이 실패하면 aihubshell 이 download.tar 를 남길 수 있다 (잠금을 쥐고 있으므로 지워도 안전).
  rm -f download.tar
}

echo
echo "[3/3] 재다운로드 batch (총 ${#filekeys[@]}개, batch=$BATCH, retry=$RETRY)"
if [ "$DRY_RUN" = "1" ]; then
  for ((i=0; i<${#filekeys[@]}; i+=BATCH)); do
    batch=("${filekeys[@]:i:BATCH}")
    csv=$(IFS=,; echo "${batch[*]}")
    echo "  [DRY-RUN] batch $((i/BATCH+1)) (${#batch[@]}개): $csv"
  done
  echo
  echo "Done."
  echo "DRY-RUN 모드였습니다. 실제 복구는 DRY_RUN 없이 재실행."
  exit 0
fi

todo=("${filekeys[@]}")
total_ok=0
for ((round=0; round<=RETRY; round++)); do
  [ "${#todo[@]}" -eq 0 ] && break
  if [ "$round" -gt 0 ]; then
    echo
    echo "  ↻ 재시도 $round/$RETRY — 실패한 ${#todo[@]}개를 다시 요청합니다."
  fi
  failed_round=()
  n_batches=$(( (${#todo[@]} + BATCH - 1) / BATCH ))
  for ((i=0; i<${#todo[@]}; i+=BATCH)); do
    batch=("${todo[@]:i:BATCH}")
    csv=$(IFS=,; echo "${batch[*]}")
    batch_num=$((i/BATCH+1))
    echo "  >> batch $batch_num/$n_batches (${#batch[@]}개): $csv"
    rm -f download.tar
    aihubshell -mode d -datasetkey "$DATASET_KEY" \
      -filekey "$csv" -aihubapikey "$APIKEY"

    batch_ok=0
    batch_failed=()
    echo "     batch 검증 중..."
    verify_batch "${batch[@]}"
    total_ok=$((total_ok + batch_ok))
    echo "     → 정상 ${batch_ok}/${#batch[@]}"
    failed_round+=(${batch_failed[@]+"${batch_failed[@]}"})
  done
  todo=(${failed_round[@]+"${failed_round[@]}"})
done

echo
echo "============================================"
echo "  결과: 요청 ${#filekeys[@]}개 중 정상 ${total_ok}개 / 실패 ${#todo[@]}개"
echo "============================================"
if [ "${#todo[@]}" -gt 0 ]; then
  echo "  실패한 파일:"
  for key in "${todo[@]}"; do
    echo "    - ${key_to_name[$key]:-?} (filekey $key)"
  done
  echo
  echo "  같은 명령으로 다시 실행하면 실패분만 다시 받습니다:"
  echo "    bash repair_aihub.sh"
  exit 1
fi
echo "  ✓ 요청한 zip 을 모두 받았고 무결성 검사도 통과했습니다."
echo "  수렴 확인: check_aihub.sh → (선택) verify_zips.sh"
