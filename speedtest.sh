#!/usr/bin/env bash
#
# speedtest.sh - Bash port of speedtest.py (speedtest-cli)
#
# Original Python version: Copyright 2012 Matt Martz, Apache License 2.0
#   https://github.com/sivel/speedtest-cli
# Modified 2026 by Jan Willem Wijnands (live meter, fixes), ported to Bash.
#
# Needs only: bash 3.2+ (the stock macOS bash is fine), curl, awk, sed, grep.
#
# Run without downloading:
#   curl -fsSL https://raw.githubusercontent.com/JDOUBLE-U/speedtest/refs/heads/main/speedtest.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/JDOUBLE-U/speedtest/refs/heads/main/speedtest.sh | bash -s -- --simple
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

VERSION="2.1.4b1-sh"
CONFIG_URL="${SPEEDTEST_CONFIG_URL:-http://www.speedtest.net/speedtest-config.php}"
SERVERS_URL="${SPEEDTEST_SERVERS_URL:-https://www.speedtest.net/api/embed/vz0azjarf5enop8a/config}"

# Remember whether the terminal speaks UTF-8 before forcing the C locale
# (needed so awk/printf always use '.' as decimal separator).
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) UTF8=1 ;;
    *) UTF8=0 ;;
esac
export LC_ALL=C

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
usage: speedtest.sh [options]

Command line interface for testing internet bandwidth using speedtest.net.

  --no-download        Do not perform download test
  --no-upload          Do not perform upload test
  --single             Only use a single connection (simulates a file transfer)
  --bytes              Display values in bytes instead of bits
  --simple             Only show basic information
  --plain              Disable the live progress meter
  --csv                Output in CSV format (speeds in bit/s)
  --csv-delimiter C    Single character CSV delimiter (default ",")
  --csv-header         Print CSV headers and exit
  --json               Output in JSON format (speeds in bit/s)
  --list               List speedtest.net servers and exit
  --server ID          Test against this server ID (repeatable)
  --exclude ID         Exclude this server ID (repeatable)
  --timeout SECONDS    HTTP timeout (default 10)
  --version            Show the version and exit
  -h, --help           Show this help
EOF
}

# ---------------------------------------------------------------- arguments
DO_DOWNLOAD=1; DO_UPLOAD=1; SINGLE=0; UNIT=bit; UNIT_DIV=1
SIMPLE=0; PLAIN=0; CSV=0; JSON=0; CSV_DELIM=,; CSV_HEADER=0; LIST=0
TIMEOUT=10; SERVER_IDS=""; EXCLUDE_IDS=""

need_int() { case "$1" in ''|*[!0-9]*) die "$1 is an invalid server type, must be an int" ;; esac; }

while [ $# -gt 0 ]; do
    case "$1" in
        --no-download) DO_DOWNLOAD=0 ;;
        --no-upload) DO_UPLOAD=0 ;;
        --single) SINGLE=1 ;;
        --bytes) UNIT=byte; UNIT_DIV=8 ;;
        --simple) SIMPLE=1 ;;
        --plain) PLAIN=1 ;;
        --csv) CSV=1 ;;
        --csv-delimiter) shift; CSV_DELIM="${1-}" ;;
        --csv-delimiter=*) CSV_DELIM="${1#*=}" ;;
        --csv-header) CSV_HEADER=1 ;;
        --json) JSON=1 ;;
        --list) LIST=1 ;;
        --server) shift; need_int "${1-}"; SERVER_IDS="$SERVER_IDS $1" ;;
        --server=*) need_int "${1#*=}"; SERVER_IDS="$SERVER_IDS ${1#*=}" ;;
        --exclude) shift; need_int "${1-}"; EXCLUDE_IDS="$EXCLUDE_IDS $1" ;;
        --exclude=*) need_int "${1#*=}"; EXCLUDE_IDS="$EXCLUDE_IDS ${1#*=}" ;;
        --timeout) shift; TIMEOUT="${1-10}" ;;
        --timeout=*) TIMEOUT="${1#*=}" ;;
        --version)
            echo "speedtest-cli $VERSION"
            echo "bash $BASH_VERSION, $(curl --version 2>/dev/null | head -n 1)"
            exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unrecognized argument: $1" ;;
    esac
    shift
done

[ "$DO_DOWNLOAD" = 0 ] && [ "$DO_UPLOAD" = 0 ] && die "Cannot supply both --no-download and --no-upload"
[ "${#CSV_DELIM}" -eq 1 ] || die "--csv-delimiter must be a single character"

csv_field() {
    local s="$1"
    case "$s" in
        *"$CSV_DELIM"*|*\"*) s=${s//\"/\"\"}; printf '"%s"' "$s" ;;
        *) printf '%s' "$s" ;;
    esac
}
csv_row() {
    local out="" first=1 f
    for f in "$@"; do
        [ $first = 1 ] || out="$out$CSV_DELIM"
        out="$out$(csv_field "$f")"; first=0
    done
    printf '%s\n' "$out"
}

if [ "$CSV_HEADER" = 1 ]; then
    csv_row 'Server ID' Sponsor 'Server Name' Timestamp Distance Ping Download Upload Share 'IP Address'
    exit 0
fi

command -v curl >/dev/null 2>&1 || die "curl is required but was not found"

QUIET=0; { [ "$SIMPLE" = 1 ] || [ "$CSV" = 1 ] || [ "$JSON" = 1 ]; } && QUIET=1
FANCY=0; [ "$QUIET" = 0 ] && [ "$PLAIN" = 0 ] && [ -t 1 ] && FANCY=1
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

# ---------------------------------------------------------------- helpers
# Wall clock with sub-second precision: bash 5, GNU date, perl, or seconds.
now() {
    if [ -n "${EPOCHREALTIME:-}" ]; then printf '%s\n' "${EPOCHREALTIME/,/.}"; return; fi
    local t; t=$(date +%s.%N 2>/dev/null)
    case "$t" in *N*|'') ;; *) printf '%s\n' "$t"; return ;; esac
    if command -v perl >/dev/null 2>&1; then
        perl -MTime::HiRes=time -e 'printf "%.6f\n", time'; return
    fi
    date +%s
}
ms() { awk -v t="$(now)" 'BEGIN { printf "%.0f", t * 1000 }'; }
mbit() { awk -v b="$1" -v d="$UNIT_DIV" 'BEGIN { printf "%.2f", b / 1e6 / d }'; }
rep() { local s="" i; for ((i = 0; i < $2; i++)); do s="$s$1"; done; printf '%s' "$s"; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
jstr() { local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }

UA="Mozilla/5.0 ($(uname -s); U; $(uname -m); en-us) Bash/${BASH_VERSION%%(*} (KHTML, like Gecko) speedtest-cli/$VERSION"
CURL=(curl -s -A "$UA" -H 'Cache-Control: no-cache')

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t speedtest) || die "Cannot create temp directory"
PIDS=()
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
on_cancel() {
    trap - INT TERM
    : > "$TMP/stop"
    local p
    for p in "${PIDS[@]}"; do
        pkill -TERM -P "$p" 2>/dev/null
        kill -TERM "$p" 2>/dev/null
    done
    printf '\nCancelling...\n' >&2
    cleanup
    exit 130
}
trap cleanup EXIT
trap on_cancel INT TERM

# Colours and glyphs
if [ -t 1 ] && [ -z "${NO_COLOR+x}" ]; then
    ESC=$'\033'; RST="$ESC[0m"; BOLD="$ESC[1m"; DIM="$ESC[2m"; GREEN="$ESC[32m"
    CYAN="$ESC[36m"; MAGENTA="$ESC[35m"
else
    RST=""; BOLD=""; DIM=""; GREEN=""; CYAN=""; MAGENTA=""
fi
if [ "$UTF8" = 1 ]; then
    SPARKS=("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█"); BARCH="━"; HEAD="╸"; DONE="✔"
    DL_ICON="↓"; UL_ICON="↑"
else
    SPARKS=(" " "." ":" "-" "=" "+" "*" "#"); BARCH="="; HEAD=">"; DONE="OK"
    DL_ICON="D"; UL_ICON="U"
fi
BAR_W=30

# ---------------------------------------------------------------- config
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)

say "Retrieving speedtest.net configuration..."
CONFIG_XML=$("${CURL[@]}" -f --compressed --max-time "$TIMEOUT" "$CONFIG_URL?x=$(ms).0" | tr '\n\r' '  ')
[ -n "$CONFIG_XML" ] || die "Cannot retrieve speedtest configuration"

xml_attr() {  # tag attribute
    printf '%s' "$CONFIG_XML" | grep -o "<$1 [^>]*>" | head -n 1 |
        sed -n "s/.* $2=\"\([^\"]*\)\".*/\1/p"
}

C_IP=$(xml_attr client ip);       C_ISP=$(xml_attr client isp)
C_LAT=$(xml_attr client lat);     C_LON=$(xml_attr client lon)
C_COUNTRY=$(xml_attr client country)
IGNORE_IDS=$(xml_attr server-config ignoreids | tr ',' ' ')
THREADCOUNT=$(xml_attr server-config threadcount)
DL_LEN=$(xml_attr download testlength);  DL_PER_URL=$(xml_attr download threadsperurl)
UP_LEN=$(xml_attr upload testlength);    UP_RATIO=$(xml_attr upload ratio)
UP_MAXCHUNK=$(xml_attr upload maxchunkcount); UP_THREADS=$(xml_attr upload threads)

[ -n "$C_LAT" ] && [ -n "$C_LON" ] || die "Malformed speedtest.net configuration"
: "${THREADCOUNT:=4}" "${DL_LEN:=10}" "${DL_PER_URL:=4}" "${UP_LEN:=10}"
: "${UP_RATIO:=5}" "${UP_MAXCHUNK:=50}" "${UP_THREADS:=2}"

DL_THREADS=$((THREADCOUNT * 2))
UP_SIZES_ALL=(32768 65536 131072 262144 524288 1048576 7340032)
UP_SIZE_COUNT=$((7 - UP_RATIO + 1))
UP_COUNT=$(( (UP_MAXCHUNK + UP_SIZE_COUNT - 1) / UP_SIZE_COUNT ))   # ceil

# ---------------------------------------------------------------- servers
S_ID=(); S_HOST=(); S_SPONSOR=(); S_NAME=(); S_COUNTRY=()

get_servers() {
    local raw id host sponsor name country
    raw=$("${CURL[@]}" -f --compressed --max-time "$TIMEOUT" "$SERVERS_URL?x=$(ms).0") ||
        die "Cannot retrieve speedtest server list"
    [ -n "$raw" ] || die "Empty server list received"
    while IFS=$'\037' read -r id host sponsor name country; do
        case "$id" in ''|*[!0-9]*) continue ;; esac
        [ -n "$SERVER_IDS" ] && ! in_list "$id" "$SERVER_IDS" && continue
        in_list "$id" "$IGNORE_IDS $EXCLUDE_IDS" && continue
        S_ID+=("$id"); S_HOST+=("$host"); S_SPONSOR+=("$sponsor")
        S_NAME+=("$name"); S_COUNTRY+=("$country")
    done < <(printf '%s\n' "$raw" | awk '
        function trim(s) { gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", s); return s }
        { buf = buf $0 "\n" }
        END {
            while ((s = index(buf, "{")) > 0) {
                rest = substr(buf, s + 1); e = index(rest, "}")
                if (!e) break
                block = substr(rest, 1, e - 1); buf = substr(rest, e + 1)
                split("", kv); n = split(block, lines, "\n")
                for (i = 1; i <= n; i++) {
                    p = index(lines[i], "=")
                    if (!p) continue
                    k = trim(substr(lines[i], 1, p - 1))
                    v = trim(substr(lines[i], p + 1)); gsub(/^"+|"+$/, "", v)
                    if (k == "serverid") k = "id"
                    kv[k] = v
                }
                if ("host" in kv)
                    printf "%s\037%s\037%s\037%s\037%s\n", kv["id"], kv["host"], kv["sponsor"], kv["name"], kv["country"]
            }
        }')
    if [ ${#S_ID[@]} -eq 0 ]; then
        [ -n "$SERVER_IDS$EXCLUDE_IDS" ] && die "No matched servers:$SERVER_IDS"
        die "No servers found in speedtest.net server list"
    fi
}

ping_server() {  # base-url -> average latency in ms (3 samples, 3600 s per failure)
    local stamp i out codetime body times=""
    stamp=$(ms)
    for i in 0 1 2; do
        out=$("${CURL[@]}" --max-time "$TIMEOUT" -w '\n%{http_code} %{time_total}' "$1/latency.txt?x=$stamp.$i")
        codetime=${out##*$'\n'}; body=${out%$'\n'*}
        if [ "${codetime%% *}" = 200 ] && [ "${body:0:9}" = "test=test" ]; then
            times="$times ${codetime#* }"
        else
            times="$times 3600"
        fi
    done
    awk -v l="$times" 'BEGIN { n = split(l, a, " "); for (i = 1; i <= n; i++) s += a[i]; printf "%.3f", s / n * 1000 }'
}

# ---------------------------------------------------------------- workers
elapsed_left() {  # duration -> seconds left (0 when time is up)
    awk -v s="$START" -v n="$(now)" -v l="$1" 'BEGIN { r = l - (n - s); if (r <= 0) print 0; else printf "%.3f", r }'
}

dl_worker() {  # index url...
    local idx=$1 total=0 n=0 url rem got
    shift
    echo 0 > "$TMP/dl.$idx.done"
    for url in "$@"; do
        [ -e "$TMP/stop" ] && break
        rem=$(elapsed_left "$DL_LEN"); [ "$rem" = 0 ] && break
        n=$((n + 1))
        got=$("${CURL[@]}" -o "$TMP/dl.$idx.part" -w '%{size_download}' --max-time "$rem" "$url?x=$(ms).$idx$n")
        rm -f "$TMP/dl.$idx.part"
        got=${got%%.*}; total=$((total + ${got:-0}))
        echo "$total" > "$TMP/dl.$idx.done"
    done
}

ul_worker() {  # index size...
    local idx=$1 total=0 n=0 size rem got
    shift
    echo 0 > "$TMP/ul.$idx.done"
    for size in "$@"; do
        [ -e "$TMP/stop" ] && break
        rem=$(elapsed_left "$UP_LEN"); [ "$rem" = 0 ] && break
        n=$((n + 1))
        got=$("${CURL[@]}" -o /dev/null -w '%{size_upload}' --max-time "$rem" \
              -H 'Expect:' -H 'Content-Type: application/x-www-form-urlencoded' \
              --data-binary "@$TMP/payload.$size" "$BEST_URL?x=$(ms).$idx$n")
        got=${got%%.*}; total=$((total + ${got:-0}))
        echo "$total" > "$TMP/ul.$idx.done"
    done
}

make_payload() {  # size: "content1=" + 0-9A-Z repeated, exactly size bytes
    [ -e "$TMP/payload.$1" ] && return
    { printf 'content1='
      yes 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ | tr -d '\n' | head -c $(($1 - 9))
    } > "$TMP/payload.$1"
}

bytes_so_far() {  # prefix: finished transfers + partial downloads in flight
    { ls -ln "$TMP" 2>/dev/null; cat "$TMP"/"$1".*.done 2>/dev/null; } |
        awk -v p="$1" 'NF >= 8 && index($NF, p ".") == 1 && $NF ~ /\.part$/ { s += $5; next }
                       NF == 1 { s += $1 } END { printf "%.0f", s }'
}

any_alive() { local p; for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null && return 0; done; return 1; }

# ---------------------------------------------------------------- live meter
meter_start() { M_T=("$START"); M_B=(0); RATES=(); PEAK=0; M_LAST=$START; }

meter_sample() {  # prefix duration
    local t b
    t=$(now); b=$(bytes_so_far "$1")
    M_T+=("$t"); M_B+=("$b")
    if [ ${#M_T[@]} -gt 4 ]; then M_T=("${M_T[@]:1}"); M_B=("${M_B[@]:1}"); fi
    IFS='|' read -r CUR ELAPSED FILLED SPEED <<EOF
$(awk -v t0="${M_T[0]}" -v b0="${M_B[0]}" -v t="$t" -v b="$b" -v s="$START" \
      -v d="$2" -v w="$BAR_W" -v div="$UNIT_DIV" 'BEGIN {
    c = (t > t0) ? (b - b0) * 8 / (t - t0) : 0; if (c < 0) c = 0
    e = t - s; f = int(e / d * w); if (f > w) f = w
    printf "%.0f|%.1f|%d|%8.2f\n", c, e, f, c / 1e6 / div }')
EOF
    RATES+=("$CUR"); [ ${#RATES[@]} -gt 16 ] && RATES=("${RATES[@]:1}")
    [ "$CUR" -gt "$PEAK" ] && PEAK=$CUR
}

sparkline() {
    local top=0 r out=""
    for r in "${RATES[@]}"; do [ "$r" -gt "$top" ] && top=$r; done
    [ "$top" -eq 0 ] && top=1
    for r in "${RATES[@]}"; do out="$out${SPARKS[$(( (r * 14 + top) / (2 * top) ))]}"; done
    SPARK="$out$(rep ' ' $((16 - ${#RATES[@]})))"
}

meter_render() {  # label icon colour
    local bar
    if [ "$FILLED" -ge "$BAR_W" ]; then
        bar="$3$(rep "$BARCH" "$BAR_W")$RST"
    else
        bar="$3$(rep "$BARCH" "$FILLED")$HEAD$RST$DIM$(rep "$BARCH" $((BAR_W - FILLED - 1)))$RST"
    fi
    sparkline
    printf '\r  %s %-8s %s %5ss  %s %s\033[K' "$3$2$RST" "$1" "$bar" "$ELAPSED" \
        "$3$SPARK$RST" "$BOLD$SPEED M$UNIT/s$RST"
}

meter_stop() {  # label final-bps colour
    local final peak
    [ "$2" -gt "$PEAK" ] && PEAK=$2
    sparkline
    final=$(awk -v b="$2" -v d="$UNIT_DIV" 'BEGIN { printf "%8.2f", b / 1e6 / d }')
    peak=$(mbit "$PEAK")
    printf '\r  %s %-8s %s   %s   %s\033[K\n' "$GREEN$DONE$RST" "$1" "$BOLD$final M$UNIT/s$RST" \
        "${DIM}peak $peak M$UNIT/s$RST" "$3$SPARK$RST"
}

wait_phase() {  # prefix duration label icon colour
    if [ "$FANCY" = 1 ]; then
        meter_start
        while any_alive; do sleep 0.25; meter_sample "$1" "$2"; meter_render "$3" "$4" "$5"; done
    elif [ "$QUIET" = 0 ]; then
        while any_alive; do sleep 0.5; printf '.'; done; printf '\n'
    fi
    wait
}

throughput() {  # bytes start stop -> bit/s
    awk -v b="$1" -v s="$2" -v e="$3" 'BEGIN { d = e - s; if (d <= 0) d = 1e-9; printf "%.3f", b * 8 / d }'
}

run_download() {
    local base="${BEST_URL%/*}" urls=() mine size i j w
    for size in 350 500 750 1000 1500 2000 2500 3000 3500 4000; do
        for ((j = 0; j < DL_PER_URL; j++)); do urls+=("$base/random${size}x${size}.jpg"); done
    done
    w=$DL_THREADS; [ "$SINGLE" = 1 ] && w=1; [ "$w" -gt ${#urls[@]} ] && w=${#urls[@]}
    [ "$FANCY" = 0 ] && [ "$QUIET" = 0 ] && printf 'Testing download speed' 
    PIDS=(); START=$(now)
    for ((i = 0; i < w; i++)); do
        mine=(); for ((j = i; j < ${#urls[@]}; j += w)); do mine+=("${urls[$j]}"); done
        dl_worker "$i" "${mine[@]}" &
        PIDS+=($!)
    done
    wait_phase dl "$DL_LEN" Download "$DL_ICON" "$CYAN"
    STOP=$(now); PIDS=()
    BYTES_RECEIVED=$(bytes_so_far dl)
    DOWNLOAD=$(throughput "$BYTES_RECEIVED" "$START" "$STOP")
    if [ "$FANCY" = 1 ]; then meter_stop Download "${DOWNLOAD%.*}" "$CYAN"
    else say "Download: $(mbit "$DOWNLOAD") M$UNIT/s"; fi
    # Fast links get more upload threads, like the original
    awk -v d="$DOWNLOAD" 'BEGIN { exit !(d > 100000) }' && UP_THREADS=8
}

run_upload() {
    local sizes=() mine i j w
    for ((i = UP_RATIO - 1; i < 7; i++)); do
        make_payload "${UP_SIZES_ALL[$i]}"
        for ((j = 0; j < UP_COUNT; j++)); do sizes+=("${UP_SIZES_ALL[$i]}"); done
    done
    w=$UP_THREADS; [ "$SINGLE" = 1 ] && w=1; [ "$w" -gt ${#sizes[@]} ] && w=${#sizes[@]}
    [ "$FANCY" = 0 ] && [ "$QUIET" = 0 ] && printf 'Testing upload speed' 
    PIDS=(); START=$(now)
    for ((i = 0; i < w; i++)); do
        mine=(); for ((j = i; j < ${#sizes[@]}; j += w)); do mine+=("${sizes[$j]}"); done
        ul_worker "$i" "${mine[@]}" &
        PIDS+=($!)
    done
    wait_phase ul "$UP_LEN" Upload "$UL_ICON" "$MAGENTA"
    STOP=$(now); PIDS=()
    BYTES_SENT=$(bytes_so_far ul)
    UPLOAD=$(throughput "$BYTES_SENT" "$START" "$STOP")
    if [ "$FANCY" = 1 ]; then meter_stop Upload "${UPLOAD%.*}" "$MAGENTA"
    else say "Upload: $(mbit "$UPLOAD") M$UNIT/s"; fi
}

# ---------------------------------------------------------------- main
if [ "$LIST" = 1 ]; then
    get_servers
    for ((i = 0; i < ${#S_ID[@]}; i++)); do
        printf '%5s) %s (%s, %s)\n' "${S_ID[$i]}" "${S_SPONSOR[$i]:-?}" "${S_NAME[$i]:-?}" "${S_COUNTRY[$i]:-?}"
    done
    exit 0
fi

say "Testing from ${C_ISP} (${C_IP})..."
say "Retrieving speedtest.net server list..."
get_servers

if [ -n "$SERVER_IDS" ] && [ ${#S_ID[@]} -eq 1 ]; then
    say "Retrieving information for the selected server..."
else
    say "Selecting best server based on ping..."
fi

BEST=-1; PING=""
for ((i = 0; i < ${#S_ID[@]} && i < 5; i++)); do
    lat=$(ping_server "http://${S_HOST[$i]}/speedtest")
    if [ "$BEST" -lt 0 ] || awk -v a="$lat" -v b="$PING" 'BEGIN { exit !(a < b) }'; then
        BEST=$i; PING=$lat
    fi
done
awk -v p="$PING" 'BEGIN { exit !(p >= 3600000) }' && die "Unable to connect to servers to test latency."

BEST_URL="http://${S_HOST[$BEST]}/speedtest/upload.php"
say "Hosted by ${S_SPONSOR[$BEST]} (${S_NAME[$BEST]}): $PING ms"
[ "$FANCY" = 1 ] && echo

DOWNLOAD=0; UPLOAD=0; BYTES_RECEIVED=0; BYTES_SENT=0
if [ "$DO_DOWNLOAD" = 1 ]; then run_download; else say "Skipping download test"; fi
if [ "$DO_UPLOAD" = 1 ]; then run_upload; else say "Skipping upload test"; fi

if [ "$SIMPLE" = 1 ]; then
    printf 'Ping: %s ms\nDownload: %s M%s/s\nUpload: %s M%s/s\n' \
        "$PING" "$(mbit "$DOWNLOAD")" "$UNIT" "$(mbit "$UPLOAD")" "$UNIT"
elif [ "$CSV" = 1 ]; then
    csv_row "${S_ID[$BEST]}" "${S_SPONSOR[$BEST]}" "${S_NAME[$BEST]}" "$TIMESTAMP" "" \
        "$PING" "$DOWNLOAD" "$UPLOAD" "" "$C_IP"
elif [ "$JSON" = 1 ]; then
    printf '{"download": %s, "upload": %s, "ping": %s, "server": {"id": %s, "host": %s, "sponsor": %s, "name": %s, "country": %s, "url": %s, "latency": %s}, "timestamp": %s, "bytes_sent": %s, "bytes_received": %s, "share": null, "client": {"ip": %s, "isp": %s, "lat": %s, "lon": %s, "country": %s}}\n' \
        "$DOWNLOAD" "$UPLOAD" "$PING" \
        "$(jstr "${S_ID[$BEST]}")" "$(jstr "${S_HOST[$BEST]}")" "$(jstr "${S_SPONSOR[$BEST]}")" \
        "$(jstr "${S_NAME[$BEST]}")" "$(jstr "${S_COUNTRY[$BEST]}")" "$(jstr "$BEST_URL")" "$PING" \
        "$(jstr "$TIMESTAMP")" "$BYTES_SENT" "$BYTES_RECEIVED" \
        "$(jstr "$C_IP")" "$(jstr "$C_ISP")" "$(jstr "$C_LAT")" "$(jstr "$C_LON")" "$(jstr "$C_COUNTRY")"
fi
