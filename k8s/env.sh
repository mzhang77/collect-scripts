#!/usr/bin/env sh

# Common environment for the k8s helper scripts.
# Override any value before running a script, for example:
#   NAMESPACE=my-namespace BEGIN_TIME="2026-09-08 06:30:00" ./pull_tidb_log.sh

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

# Namespace: explicit NAMESPACE env > kubectl current context's namespace > K8S_NAMESPACE from $COLLECT_CONF
if [ -z "${NAMESPACE:-}" ] && command -v kubectl >/dev/null 2>&1; then
    NAMESPACE="$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null)"
fi
: "${NAMESPACE:=${K8S_NAMESPACE:?set a namespace in the kubectl context, K8S_NAMESPACE in $COLLECT_CONF, or export NAMESPACE}}"
: "${CLUSTER_NAME:=${NAMESPACE}-eks}"

# Canonical input time format, in UTC:
#   YYYY-MM-DD HH:MM:SS
# 2026-11-19 13:30 -> 17:30 UTC (4h): the Titan blob write at ~14:20 UTC that pushed the
# blob compression factor to ~700 on tikv-10/13/14, and the first ~3h of the region
# split/merge thrashing it caused. ~150MB of metrics per hour -> ~600MB, one Clinic chunk.
: "${BEGIN_TIME:=2026-11-19 13:30:00}"
: "${END_TIME:=2026-11-19 17:30:00}"
: "${TIMEZONE_OFFSET:=+00:00}"

: "${INTERVAL_MINUTES:=240}"
: "${DIAG_BASE_URL:=http://localhost:4917}"
# Optional extended regex on TiKV pod names for the log pulls (pull_tikv_log.sh,
# pull_rocksdb_log.sh), e.g. TIKV_POD_FILTER='tikv-(0|10|13|14)$'. Empty = all TiKV pods.
: "${TIKV_POD_FILTER:=}"
: "${DIAG_NAMESPACE:=tidb-admin}"
: "${DIAG_SERVICE:=diag}"

_k8s_date_hyphen() {
    printf '%s\n' "$1" | tr 'T' ' ' | awk '{print $1}' | tr '/' '-'
}

_k8s_date_slash() {
    printf '%s\n' "$1" | tr 'T' ' ' | awk '{print $1}' | tr '-' '/'
}

_k8s_clock() {
    printf '%s\n' "$1" | tr 'T' ' ' | awk '{print $2}' | sed 's/\.[0-9][0-9]*$//'
}

_k8s_begin_date_hyphen="$(_k8s_date_hyphen "$BEGIN_TIME")"
_k8s_end_date_hyphen="$(_k8s_date_hyphen "$END_TIME")"
_k8s_begin_date_slash="$(_k8s_date_slash "$BEGIN_TIME")"
_k8s_end_date_slash="$(_k8s_date_slash "$END_TIME")"
_k8s_begin_clock="$(_k8s_clock "$BEGIN_TIME")"
_k8s_end_clock="$(_k8s_clock "$END_TIME")"

BEGIN_TIME_COLLECT="${_k8s_begin_date_hyphen} ${_k8s_begin_clock}"
END_TIME_COLLECT="${_k8s_end_date_hyphen} ${_k8s_end_clock}"

BEGIN_TIME_ISO="${_k8s_begin_date_hyphen}T${_k8s_begin_clock}"
END_TIME_ISO="${_k8s_end_date_hyphen}T${_k8s_end_clock}"

BEGIN_TIME_SLASH="${_k8s_begin_date_slash} ${_k8s_begin_clock}"
END_TIME_SLASH="${_k8s_end_date_slash} ${_k8s_end_clock}"

BEGIN_TIME_SLASH_TZ="${BEGIN_TIME_SLASH} ${TIMEZONE_OFFSET}"
END_TIME_SLASH_TZ="${END_TIME_SLASH} ${TIMEZONE_OFFSET}"

BEGIN_TIME_SLASH_MILLIS_TZ="${BEGIN_TIME_SLASH}.000 ${TIMEZONE_OFFSET}"
END_TIME_SLASH_MILLIS_TZ="${END_TIME_SLASH}.000 ${TIMEZONE_OFFSET}"

unset _k8s_begin_date_hyphen _k8s_end_date_hyphen
unset _k8s_begin_date_slash _k8s_end_date_slash
unset _k8s_begin_clock _k8s_end_clock
