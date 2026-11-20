#!/usr/bin/env bash
# Pull TiKV RocksDB (and Titan) info logs from the TiKV pods for [BEGIN_TIME, END_TIME].
#
# TiKV writes the KV RocksDB info log as JSON lines into its data directory:
#   rocksdb.info                          active file
#   rocksdb-YYYY-MM-DDTHH-MM-SS.mmm.info  rotated files (name = rotation time, UTC)
# Titan writes into the same log. Examples:
#   TIKV_POD_FILTER='tikv-(10|13|14)$' ./pull_rocksdb_log.sh
#   ROCKSDB_LOG_PREFIX=raftdb ./pull_rocksdb_log.sh
#   ROCKSDB_LOG_FILTER_PATTERN='file deletion' ./pull_rocksdb_log.sh   # drop matching lines
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/env.sh"

NS="$NAMESPACE"
BEGIN_TIME="$BEGIN_TIME_SLASH"
END_TIME="$END_TIME_SLASH"

: "${ROCKSDB_LOG_DIR:=/var/lib/tikv}"
: "${ROCKSDB_LOG_PREFIX:=rocksdb}"
: "${ROCKSDB_LOG_FILTER_PATTERN:=}"
KUBECTL_CONTAINER="tikv"
OUT_DIR="./rocksdb_logs_$(date +%Y%m%d_%H%M%S)"

# Runs inside the pod. Args: log_dir begin end prefix filter_pattern
REMOTE_SCRIPT='log_dir="$1"; begin="$2"; end="$3"; prefix="$4"; filter_pattern="$5"
cd "$log_dir" || exit 10
begin_cmp="${begin:0:19}"; end_cmp="${end:0:19}"
shopt -s nullglob
selected=()
prev_end="0000/00/00 00:00:00"
# A rotated file covers (previous rotation time, its own rotation time]; keep files that can
# overlap the window. The awk time filter below is the source of truth.
while read -r d t f; do
  [ -z "$f" ] && continue
  file_end="$d $t"
  if [[ ! "$file_end" < "$begin_cmp" && ! "$prev_end" > "$end_cmp" ]]; then selected+=( "$f" ); fi
  prev_end="$file_end"
done < <(for f in "${prefix}"-[0-9][0-9][0-9][0-9]-*.info; do
  n="${f#${prefix}-}"
  if [[ "$n" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2})-([0-9]{2})-([0-9]{2}) ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]} $f"
  fi
done | sort)
[ -f "${prefix}.info" ] && selected+=( "${prefix}.info" )
echo "[remote] dir=$log_dir files: ${selected[*]:-<none>}" >&2
[ ${#selected[@]} -eq 0 ] && exit 0
awk -v begin="$begin_cmp" -v end="$end_cmp" -v fp="$filter_pattern" '\''
  match($0, /"time":"[0-9][0-9][0-9][0-9]\/[0-9][0-9]\/[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) {
    t = substr($0, RSTART + 8, 19)
    if (t >= begin && t <= end && (fp == "" || $0 !~ fp)) print
  }'\'' "${selected[@]}" 2>/dev/null | gzip -c'

mkdir -p "$OUT_DIR"
SUMMARY_FILE="${OUT_DIR}/collection_summary.txt"
{
    echo "namespace=${NS}"
    echo "begin_time=${BEGIN_TIME}"
    echo "end_time=${END_TIME}"
    echo "remote_log_dir=${ROCKSDB_LOG_DIR}"
    echo "log_prefix=${ROCKSDB_LOG_PREFIX}"
    echo "filter_pattern=${ROCKSDB_LOG_FILTER_PATTERN}"
    echo "pod_filter=${TIKV_POD_FILTER}"
    echo
} > "$SUMMARY_FILE"

pods=$(kubectl get pod -n "$NS" -o name | grep -E 'tikv-[0-9]+$' | sed 's#pod/##' | grep -E -- "${TIKV_POD_FILTER:-.}")
if [ -z "$pods" ]; then
    echo "No TiKV pods matched (namespace=${NS}, filter=${TIKV_POD_FILTER:-<none>})" >&2
    exit 1
fi

for pod in $pods; do
    echo "===== $pod ====="
    out="${OUT_DIR}/${pod}.${ROCKSDB_LOG_PREFIX}.info.gz"
    printf '%s\n' "$REMOTE_SCRIPT" | kubectl exec -i -n "$NS" -c "$KUBECTL_CONTAINER" "$pod" -- \
        bash -s -- "$ROCKSDB_LOG_DIR" "$BEGIN_TIME" "$END_TIME" "$ROCKSDB_LOG_PREFIX" "$ROCKSDB_LOG_FILTER_PATTERN" > "$out"
    rc=$?
    lines=$( (gzip -dc "$out" 2>/dev/null || true) | wc -l | tr -d ' ')
    if [ $rc -ne 0 ] || [ "$lines" -eq 0 ]; then
        echo "WARN: $pod rc=$rc lines=$lines (check ROCKSDB_LOG_DIR)"
        rm -f "$out"
    else
        echo "saved $out ($lines lines)"
    fi
    echo "pod=${pod} rc=${rc} lines=${lines}" >> "$SUMMARY_FILE"
done

echo "Summary written to: $SUMMARY_FILE"
