#!/bin/bash
# ============================================================
# download_71349.sh (v1)
# AI Hub 71349 데이터셋을 filekey BATCH 개씩 나눠 받고, batch 마다 검증한다.
# (aihub-no-pain-466 의 download_466.sh 를 71349 규모에 맞게 이식)
#
# 왜 `aihubshell -mode d -datasetkey 71349` 한 줄로 받지 않는가:
#   1) aihubshell 은 요청한 filekey 전부를 download.tar 하나로 받은 뒤 푼다.
#      전체(220GB)를 한 번에 요청하면 중간에 끊겼을 때 잃는 양이 그만큼 크다.
#   2) aihubshell 은 curl 이 중간에 끊겨도(curl: (18) transfer closed ...)
#      "Download successful." 을 출력하고 잘린 tar 를 그대로 풀어 버린다.
#      (curl 종료 코드를 echo 뒤에서 읽는 버그) → 잘린 zip 이 "정상처럼" 남는다.
#   3) 같은 디렉토리에서 두 번 실행하면 download.tar 를 서로 백업·삭제해 꼬인다.
#   → 이 스크립트는 BATCH 개씩 요청하고, 직후 받은 zip 을 `unzip -tq` 로 확인해
#     실패분은 지우고 RETRY 회까지 다시 받으며, flock 으로 동시 실행을 막는다.
#
# 라벨(TL/VL, 약 0.1GB)을 원천(TS/VS)보다 먼저 받는다.
# 이미 있는 zip 은 건너뛴다 (CHECK_EXISTING 참조). 중단돼도 다시 실행하면 이어 받는다.
#
# 환경변수:
#   AIHUB_APIKEY    (필수)
#   DATASET_KEY     기본: 71349
#   FILELIST        기본: filelist_${DATASET_KEY}.txt
#   BATCH           기본: 10 — 한 번의 aihubshell 호출에 넣을 filekey 수 (TS 10개 ≈ 6GB)
#   RETRY           기본: 2  — batch 검증 실패분 재요청 횟수
#   ONLY            기본: (없음) — filekey CSV 지정 시 그것만 받음 (예: ONLY=560316,561375)
#   CHECK_EXISTING  기본: size
#                     size : 이미 있는 zip 의 크기가 filelist 용량보다 확연히 작으면 다시 받음 (빠름)
#                     full : 이미 있는 zip 을 전부 unzip -tq 로 검사 (1,400개 기준 NFS 30~40분)
#                     none : 이미 있으면 무조건 건너뜀
#   MIN_FREE_MULT   기본: 25 — batch 시작 전 필요 여유 = batch 용량 × 2.5 (10배 스케일 정수)
#   LOCK_FILE       기본: .aihub_download.lock (repair_aihub.sh 와 공유)
#   DRY_RUN         기본: 0
#
# 사용법:
#   cd /data/aihub_71349
#   cp <repo>/verify/filelist_71349.txt .
#   DRY_RUN=1 bash <repo>/verify/download_71349.sh
#   bash <repo>/verify/download_71349.sh
# ============================================================
set -u

DATASET_KEY="${DATASET_KEY:-71349}"
APIKEY="${AIHUB_APIKEY:?환경변수 AIHUB_APIKEY를 먼저 설정하세요.}"
FILELIST="${FILELIST:-filelist_${DATASET_KEY}.txt}"
BATCH="${BATCH:-10}"
RETRY="${RETRY:-2}"
ONLY="${ONLY:-}"
CHECK_EXISTING="${CHECK_EXISTING:-size}"
MIN_FREE_MULT="${MIN_FREE_MULT:-25}"
LOCK_FILE="${LOCK_FILE:-.aihub_download.lock}"
DRY_RUN="${DRY_RUN:-0}"

for cmd in aihubshell unzip find awk grep sed tr df basename stat flock pgrep; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] missing: $cmd"; exit 1; }
done
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "[ERROR] bash 4.0+ 필요"; exit 1
fi
[ -f "$FILELIST" ] || { echo "[ERROR] filelist 없음: $FILELIST  (cp <repo>/verify/filelist_${DATASET_KEY}.txt .)"; exit 1; }
case "$CHECK_EXISTING" in size|full|none) ;; *) echo "[ERROR] CHECK_EXISTING 은 size|full|none"; exit 1 ;; esac

# === filelist 파싱 (check_aihub.sh / verify_zips.sh / repair_aihub.sh 와 동일 로직) ===
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
  local size=$(echo "$clean" | grep -oE '[0-9.]+ ?(KB|MB|GB|TB)' | head -1)
  [ -z "$name_norm" ] || [ -z "$key" ] && return 1
  echo "${name_norm}|${size:-?}|${key}"
}

# "621 MB" → 바이트. 파싱 실패 시 0.
size_to_bytes() {
  echo "$1" | awk '
    {
      n = $0; gsub(/[^0-9.]/, "", n)
      if (n == "") { print 0; exit }
      m = 1
      if ($0 ~ /KB/) m = 1024
      else if ($0 ~ /MB/) m = 1024*1024
      else if ($0 ~ /GB/) m = 1024*1024*1024
      else if ($0 ~ /TB/) m = 1024*1024*1024*1024
      # %d 는 mawk에서 32비트로 잘려 큰 값이 망가진다. %.0f 를 쓴다.
      printf "%.0f\n", n * m
    }'
}

# filelist 용량은 반올림된 값("621 MB", "1 GB")이라 정확한 비교가 불가능하다.
# "한 단위 작은 값의 99%" 를 하한으로 잡아, 이보다 작으면 확실히 잘린 파일로 본다.
# 하한이 0 이하("1 GB" 처럼 단위가 큰 경우)면 크기로는 판정하지 않는다(-1).
size_floor_bytes() {
  echo "$1" | awk '
    {
      n = $0; gsub(/[^0-9.]/, "", n)
      if (n == "") { print -1; exit }
      m = 1
      if ($0 ~ /KB/) m = 1024
      else if ($0 ~ /MB/) m = 1024*1024
      else if ($0 ~ /GB/) m = 1024*1024*1024
      else if ($0 ~ /TB/) m = 1024*1024*1024*1024
      f = (n - 1) * m * 0.99
      if (f <= 0) print -1; else printf "%.0f\n", f
    }'
}

human() {
  awk -v b="$1" 'BEGIN{
    split("B KB MB GB TB PB", u, " "); i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    printf "%.1f %s\n", b, u[i]
  }'
}

only_has() {
  [ -z "$ONLY" ] && return 0
  echo ",$ONLY," | grep -q ",$1,"
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

# 디스크의 zip 을 정규화 파일명 → 경로로 색인
declare -A disk_path=()
index_disk() {
  local path
  disk_path=()
  while IFS= read -r path; do
    disk_path["$(normalize_name "$(basename "$path")")"]="$path"
  done < <(find . -type f -name '*.zip' 2>/dev/null)
}

echo "============================================"
echo "  AI Hub 분할 다운로드 (download_71349.sh)"
echo "============================================"
echo "  DATASET_KEY    : $DATASET_KEY"
echo "  FILELIST       : $FILELIST"
echo "  대상 디렉토리  : $PWD"
echo "  BATCH / RETRY  : $BATCH / $RETRY"
echo "  CHECK_EXISTING : $CHECK_EXISTING"
echo "  DRY_RUN        : $DRY_RUN"
[ -n "$ONLY" ] && echo "  ONLY           : $ONLY"
echo

# === 동시 실행 방지 ===
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [WARN] 다른 다운로드/복구가 이 디렉토리에서 실행 중입니다 ($LOCK_FILE 잠김)."
    echo
  else
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
  echo "  [ERROR] 이 디렉토리에서 aihubshell 이 이미 실행 중입니다 (PID: $(echo $running))."
  echo "          수동으로 띄운 aihubshell 이 끝난 뒤 다시 실행하세요."
  exit 1
fi

trap 'echo; echo "  [중단됨] 다시 실행하면 받아 둔 zip 은 건너뛰고 이어서 진행합니다."; exit 130' INT

# === 파싱 (라벨 TL/VL 먼저, 그다음 원천 TS/VS) ===
names=(); keys=(); sizes=()
src_names=(); src_keys=(); src_sizes=()
declare -A key_to_name=() key_to_size=()
while IFS= read -r line || [ -n "$line" ]; do
  parsed=$(parse_filelist_line "$line") || continue
  IFS='|' read -r name size key <<< "$parsed"
  only_has "$key" || continue
  key_to_name["$key"]="$name"; key_to_size["$key"]="$size"
  case "$name" in
    TL*|VL*) names+=("$name");     keys+=("$key");     sizes+=("$size") ;;
    *)       src_names+=("$name"); src_keys+=("$key"); src_sizes+=("$size") ;;
  esac
done < "$FILELIST"
names+=(${src_names[@]+"${src_names[@]}"})
keys+=(${src_keys[@]+"${src_keys[@]}"})
sizes+=(${src_sizes[@]+"${src_sizes[@]}"})

total=${#names[@]}
if [ "$total" -eq 0 ]; then
  echo "[ERROR] filelist에서 받을 zip을 찾지 못했습니다."
  echo "        head -20 $FILELIST 로 포맷을 확인하세요."
  [ -n "$ONLY" ] && echo "        ONLY='$ONLY' 필터가 너무 좁을 수도 있습니다."
  exit 1
fi

# === 이미 받은 것 판정 ===
echo "[1/3] 기존 파일 확인 (${total}개, CHECK_EXISTING=$CHECK_EXISTING)..."
index_disk
todo_keys=()
have=0; bad_existing=0; todo_bytes=0
for i in "${!names[@]}"; do
  name="${names[$i]}"; key="${keys[$i]}"; size="${sizes[$i]}"
  path="${disk_path[$name]:-}"
  if [ -n "$path" ]; then
    good=1
    case "$CHECK_EXISTING" in
      size)
        floor=$(size_floor_bytes "$size")
        if [ "$floor" -ge 0 ]; then
          actual=$(stat -c %s "$path" 2>/dev/null || echo 0)
          [ "$actual" -lt "$floor" ] && good=0
        fi
        ;;
      full)
        printf "\r          검사: %d/%d" "$((i+1))" "$total"
        unzip -tq "$path" >/dev/null 2>&1 || good=0
        ;;
    esac
    if [ "$good" = "1" ]; then
      have=$((have+1)); continue
    fi
    bad_existing=$((bad_existing+1))
    [ "$CHECK_EXISTING" = "full" ] && echo
    echo "          ✗ 깨짐/잘림 의심: $name ($(human "$(stat -c %s "$path")") / filelist $size)"
  fi
  todo_keys+=("$key")
  todo_bytes=$((todo_bytes + $(size_to_bytes "$size")))
done
[ "$CHECK_EXISTING" = "full" ] && echo

echo
echo "  filelist 대상      : ${total}개"
echo "  이미 있음(정상)    : ${have}개"
echo "  깨짐 의심 → 재요청 : ${bad_existing}개"
echo "  받을 것            : ${#todo_keys[@]}개 (약 $(human "$todo_bytes"))"
avail_kb=$(df -Pk . | awk 'NR==2{print $4}')
echo "  디스크 여유        : $(human $((avail_kb * 1024)))"
residues=$(find . -maxdepth 1 -type f \( -name 'download.tar' -o -name 'download_*.tar' \) 2>/dev/null)
if [ -n "$running" ]; then
  echo "  [WARN] 이 디렉토리에서 aihubshell 실행 중 (PID: $(echo $running)) — download.tar 는 받는 중인 파일입니다."
  echo "         실제 실행은 그 aihubshell 이 끝난 뒤에만 가능합니다."
elif [ -n "$residues" ]; then
  echo "  download.tar 잔재  : $(echo "$residues" | wc -l)개 (실행 시 삭제)"
fi
echo

if [ "${#todo_keys[@]}" -eq 0 ]; then
  echo "  ✓ 받을 것이 없습니다."
  echo "    무결성까지 확인하려면: CHECK_EXISTING=full 로 재실행하거나 verify_zips.sh"
  exit 0
fi

n_batches=$(( (${#todo_keys[@]} + BATCH - 1) / BATCH ))
if [ "$DRY_RUN" = "1" ]; then
  echo "[DRY-RUN] ${n_batches}개 batch 로 나눠 받을 예정입니다 (batch=$BATCH):"
  for ((i=0; i<${#todo_keys[@]}; i+=BATCH)); do
    batch=("${todo_keys[@]:i:BATCH}")
    first="${key_to_name[${batch[0]}]}"; last="${key_to_name[${batch[${#batch[@]}-1]}]}"
    echo "  batch $((i/BATCH+1)) (${#batch[@]}개): $first ~ $last"
  done
  echo
  echo "[DRY-RUN] 실제 다운로드는 하지 않았습니다.  실행: bash $(basename "$0")"
  exit 0
fi

# 잠금을 쥐었고 이 디렉토리의 aihubshell 도 없으므로 남은 tar 는 지워도 안전
[ -n "$residues" ] && { echo "  이전 download.tar 잔재 삭제"; echo "$residues" | xargs -d '\n' rm -f; }

# 기존의 깨진 zip 은 지우고 시작 (aihubshell 이 덮어쓰지 않고 병합 대상이 꼬일 수 있음)
for key in "${todo_keys[@]}"; do
  name="${key_to_name[$key]}"
  path="${disk_path[$name]:-}"
  [ -n "$path" ] && rm -f "$path"
done

# batch 직후 검증: 요청한 zip 이 있고 unzip -tq 를 통과하는가
verify_batch() {
  local key name path
  index_disk
  for key in "$@"; do
    name="${key_to_name[$key]}"
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
      find . -type f -name "${name}.part*" -delete 2>/dev/null
      batch_failed+=("$key")
    fi
  done
  rm -f download.tar
}

echo "[2/3] 다운로드 (${#todo_keys[@]}개, ${n_batches} batch)"
todo=("${todo_keys[@]}")
total_ok=0
start_all=$(date +%s)
for ((round=0; round<=RETRY; round++)); do
  [ "${#todo[@]}" -eq 0 ] && break
  if [ "$round" -gt 0 ]; then
    echo
    echo "  ↻ 재시도 $round/$RETRY — 실패한 ${#todo[@]}개를 다시 요청합니다."
  fi
  failed_round=()
  nb=$(( (${#todo[@]} + BATCH - 1) / BATCH ))
  for ((i=0; i<${#todo[@]}; i+=BATCH)); do
    batch=("${todo[@]:i:BATCH}")
    csv=$(IFS=,; echo "${batch[*]}")
    batch_num=$((i/BATCH+1))

    need=0
    for key in "${batch[@]}"; do need=$((need + $(size_to_bytes "${key_to_size[$key]}"))); done
    need_peak=$(( need / 10 * MIN_FREE_MULT ))
    avail_kb=$(df -Pk . | awk 'NR==2{print $4}')
    echo "============================================"
    echo "  batch $batch_num/$nb (${#batch[@]}개, 약 $(human "$need")): ${key_to_name[${batch[0]}]} ~ ${key_to_name[${batch[${#batch[@]}-1]}]}"
    echo "  디스크 여유 $(human $((avail_kb * 1024))) / 필요 추정 $(human "$need_peak")"
    echo "============================================"
    if [ $((avail_kb * 1024)) -lt "$need_peak" ]; then
      echo "  [STOP] 여유 공간 부족. 여기서 중단합니다. 공간 확보 후 다시 실행하면 이어 받습니다."
      exit 1
    fi

    t0=$(date +%s)
    rm -f download.tar
    aihubshell -mode d -datasetkey "$DATASET_KEY" -filekey "$csv" -aihubapikey "$APIKEY"

    batch_ok=0
    batch_failed=()
    echo "     batch 검증 중..."
    verify_batch "${batch[@]}"
    total_ok=$((total_ok + batch_ok))
    echo "     → 정상 ${batch_ok}/${#batch[@]} ($(( $(date +%s) - t0 ))초)"
    failed_round+=(${batch_failed[@]+"${batch_failed[@]}"})
  done
  todo=(${failed_round[@]+"${failed_round[@]}"})
done

echo
echo "[3/3] 결과"
echo "============================================"
echo "  요청   : ${#todo_keys[@]}개"
echo "  성공   : ${total_ok}개"
echo "  실패   : ${#todo[@]}개"
echo "  소요   : $(( ($(date +%s) - start_all) / 60 ))분"
echo "============================================"

if [ "${#todo[@]}" -gt 0 ]; then
  echo "  실패한 파일:"
  for key in "${todo[@]}"; do echo "    - ${key_to_name[$key]} (filekey $key)"; done
  echo
  echo "  다시 실행하면 실패분만 이어 받습니다:"
  echo "    bash $(basename "$0")"
  exit 1
fi

echo "  ✓ 전부 받았고, 이번에 받은 zip 은 무결성 검사도 통과했습니다."
echo
echo "다음 단계:"
echo "  export ROOT=\"\$(find . -maxdepth 1 -type d -name '133.*' | head -1)\""
echo "  bash <repo>/verify/check_aihub.sh"
echo "  PARALLEL=8 bash <repo>/verify/verify_zips.sh"
