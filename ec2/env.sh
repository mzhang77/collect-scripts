#!/usr/bin/env sh

# Common environment for the ec2 helper scripts.
# Override any value before running a script, for example:
#   CLUSTER_NAME=my-cluster-prod BEGIN_TIME="2026-09-03 17:50:00" ./pull_cdc_log.sh

# Machine-specific settings (hostnames, cert paths, default cluster, Clinic token) live in a
# private file outside this repo, never in the scripts. Override its path with COLLECT_CONF.
: "${COLLECT_CONF:=$HOME/.config/pingcap/collect-scripts}"
if [ -r "$COLLECT_CONF" ]; then
    _conf_perm="$(stat -c '%a' "$COLLECT_CONF" 2>/dev/null || stat -f '%Lp' "$COLLECT_CONF" 2>/dev/null)"
    case "$_conf_perm" in
        ""|*00) ;;
        *) echo "[WARN] $COLLECT_CONF has permissions $_conf_perm; run: chmod 600 $COLLECT_CONF" >&2 ;;
    esac
    unset _conf_perm
    . "$COLLECT_CONF"
fi

: "${CLUSTER_NAME:=${EC2_CLUSTER:?set EC2_CLUSTER in $COLLECT_CONF, or export CLUSTER_NAME}}"
# Previous window (NAID-12273): 2026-10-08 17:00:00 -> 2026-10-09 14:15:00
# Previous window (ticdc-lag full CDC logs): 2026-11-12 20:00:00 -> 2026-11-13 18:00:00
# ticdc changefeed stall (sync point barrier vs. memory quota): Clinic metrics from just before
# the downstream errors (20:42) through the 17:25/17:27 pause/resume. All times here are UTC.
: "${BEGIN_TIME:=2026-11-12 20:00:00}"
: "${END_TIME:=2026-11-13 18:00:00}"
: "${LOG_DIR:=/var/log/tidb}"
: "${DEBUG:=1}"
: "${INTERVAL_MINUTES:=120}"
# Optional awk regular expression matched against the TiKV instance name
# (infra-tidb-tikv-<cluster>-<id>). Only matching instances are collected by
# pull_tikv_log.sh and pull_rocksdb_log.sh. Empty = collect all TiKV instances.
: "${TIKV_INSTANCE_FILTER=0a012c78|0a012646}"
# Optional awk regular expression. Matching CDC log lines are excluded from output.
#: "${CDC_LOG_FILTER_PATTERN:=scan window local advance due to pending barrier}"
#: "${CDC_LOG_FILTER_PATTERN:=scan window local advance due to pending barrier event|multiStmtExecute failed, fallback to sequence way|execute DMLs with error, retry later}"
: "${CDC_LOG_FILTER_PATTERN:=}"
# Lines longer than this are shortened field by field: each long field keeps
# its first and last CDC_LOG_MAX_LINE_LEN/8 bytes, the middle is replaced by
# " ...<cut N bytes>... ". Some TiCDC logs (e.g. "execute DMLs with error,
# retry later") dump whole SQL batches with arguments, up to tens of MB per
# line; the error cause sits at the end of the [error="..."] field.
# 0 = keep full lines.
: "${CDC_LOG_MAX_LINE_LEN:=4096}"

_ec2_date_slash() {
    printf '%s\n' "$1" | tr 'T' ' ' | awk '{print $1}' | tr '-' '/'
}

_ec2_date_hyphen() {
    printf '%s\n' "$1" | tr 'T' ' ' | awk '{print $1}' | tr '/' '-'
}

_ec2_clock() {
    printf '%s\n' "$1" | tr 'T' ' ' | awk '{print $2}' | sed 's/Z$//' | sed 's/+00:00$//' | sed 's/\.[0-9][0-9]*$//'
}

_ec2_begin_date="$(_ec2_date_slash "$BEGIN_TIME")"
_ec2_end_date="$(_ec2_date_slash "$END_TIME")"
_ec2_begin_date_hyphen="$(_ec2_date_hyphen "$BEGIN_TIME")"
_ec2_end_date_hyphen="$(_ec2_date_hyphen "$END_TIME")"
_ec2_begin_clock="$(_ec2_clock "$BEGIN_TIME")"
_ec2_end_clock="$(_ec2_clock "$END_TIME")"

: "${BEGIN_TIME_SLASH:=${_ec2_begin_date} ${_ec2_begin_clock}}"
: "${END_TIME_SLASH:=${_ec2_end_date} ${_ec2_end_clock}}"
: "${BEGIN_TIME_ISO:=${_ec2_begin_date_hyphen}T${_ec2_begin_clock}Z}"
: "${END_TIME_ISO:=${_ec2_end_date_hyphen}T${_ec2_end_clock}Z}"

unset _ec2_begin_date _ec2_end_date
unset _ec2_begin_date_hyphen _ec2_end_date_hyphen
unset _ec2_begin_clock _ec2_end_clock

: "${TIUP_METRICS_SCRIPT:=${SCRIPT_DIR}/tiup_metrics.sh}"
