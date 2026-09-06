#!/bin/sh
set -u
umask 077

STEP='P5-R11E5G-INSTALL1-R1-PLATFORM-PREFLIGHT'
MODE='INTERACTIVE'

case "${1:-}" in
    '') ;;
    --auto) MODE='AUTO' ;;
    --help)
        echo 'USAGE: P5-R11E5G-INSTALL1-R1-platform-preflight.sh [--auto]'
        exit 0
        ;;
    *)
        echo 'USAGE: P5-R11E5G-INSTALL1-R1-platform-preflight.sh [--auto]'
        exit 2
        ;;
esac

WORK="/tmp/${STEP}.$$"
mkdir -m 700 "$WORK" >/dev/null 2>&1 || exit 1
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT HUP INT TERM

RESULT='FAIL'
REASON='UNKNOWN'
PLATFORM_VERDICT='NOT_SUPPORTED'
ROOT_GATE='FAIL'
TOOL_GATE='FAIL'
SPACE_GATE='FAIL'
CAPABILITY_GATE='FAIL'
DEPENDENCY_PLAN_GATE='N/A'
DOWNLOAD_STAGE_ALLOWED='NO'
PACKAGE_MANAGER='UNKNOWN'
PACKAGE_MANAGER_DIAGNOSTIC='UNKNOWN'

CAP_TOTAL=0
CAP_PASS=0
CAP_FAIL=0
MISSING_CAPABILITIES=''
MISSING_PROVIDER_PLAN=''

UPLINK_CANDIDATE_COUNT=0
UPLINK_SELECTED='NONE'
UPLINK_AUTO='NONE'
UPLINK_AUTO_REASON='NO_DEFAULT_ROUTE'
UPLINK_SELECTION_MODE='NONE'
UPLINK_SELECTION_REQUIRED='NO'
UPLINK_CANDIDATES_TRUNCATED='NO'

MIN_FREE_KB=8192
FREE_KB=0
SPACE_PATH='/'

sha()
{
    if [ -f "$1" ]; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    else
        echo N/A
    fi
}

provider_for()
{
    case "$1" in
        amneziawg_runtime) echo 'amneziawg-tools' ;;
        luci_runtime) echo 'luci-base' ;;
        luci_amneziawg_protocol) echo 'luci-proto-amneziawg' ;;
        rpcd_ucode) echo 'rpcd-mod-ucode' ;;
        rpcd_file_ops) echo 'rpcd-mod-file' ;;
        firewall4_nft) echo 'firewall4+nftables' ;;
        dnsmasq_nftset) echo 'dnsmasq-full' ;;
        netifd) echo 'netifd' ;;
        uci) echo 'uci' ;;
        ip_cli) echo 'ip-full' ;;
        jsonfilter) echo 'jsonfilter' ;;
        flock) echo 'native-provider:auto-resolve' ;;
        uclient_fetch) echo 'uclient-fetch' ;;
        dns_lookup_cli) echo 'native-provider:auto-resolve' ;;
        *) echo 'NONE' ;;
    esac
}

cap_check()
{
    C="$1"

    case "$C" in
        amneziawg_runtime)
            command -v awg >/dev/null 2>&1 &&
            [ -f /lib/netifd/proto/amneziawg.sh ]
            ;;
        luci_runtime)
            [ -f /www/luci-static/resources/luci.js ] &&
            [ -f /www/luci-static/resources/rpc.js ] &&
            [ -f /www/luci-static/resources/fs.js ]
            ;;
        luci_amneziawg_protocol)
            [ -f /www/luci-static/resources/protocol/amneziawg.js ] &&
            [ -f /usr/share/rpcd/ucode/luci.amneziawg ]
            ;;
        rpcd_ucode)
            [ -f /usr/lib/rpcd/ucode.so ] &&
            [ -d /usr/share/rpcd/ucode ]
            ;;
        rpcd_file_ops)
            [ -f /usr/lib/rpcd/file.so ]
            ;;
        firewall4_nft)
            [ -x /sbin/fw4 ] && command -v nft >/dev/null 2>&1
            ;;
        dnsmasq_nftset)
            command -v dnsmasq >/dev/null 2>&1 &&
            dnsmasq --version 2>/dev/null | grep -qi 'nftset'
            ;;
        netifd)
            [ -x /sbin/netifd ] && command -v ubus >/dev/null 2>&1
            ;;
        uci)
            command -v uci >/dev/null 2>&1
            ;;
        ip_cli)
            command -v ip >/dev/null 2>&1
            ;;
        jsonfilter)
            command -v jsonfilter >/dev/null 2>&1
            ;;
        flock)
            command -v flock >/dev/null 2>&1
            ;;
        uclient_fetch)
            command -v uclient-fetch >/dev/null 2>&1
            ;;
        dns_lookup_cli)
            command -v nslookup >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

record_cap()
{
    C="$1"
    H="$(provider_for "$C")"
    CAP_TOTAL=$((CAP_TOTAL + 1))

    if cap_check "$C"; then
        CAP_PASS=$((CAP_PASS + 1))
        printf '%s|PASS|N/A\n' "$C" >>"$WORK/capabilities"
    else
        CAP_FAIL=$((CAP_FAIL + 1))
        printf '%s|FAIL|%s\n' "$C" "$H" >>"$WORK/capabilities"
        if [ -z "$MISSING_CAPABILITIES" ]; then
            MISSING_CAPABILITIES="$C"
            MISSING_PROVIDER_PLAN="$C:$H"
        else
            MISSING_CAPABILITIES="$MISSING_CAPABILITIES,$C"
            MISSING_PROVIDER_PLAN="$MISSING_PROVIDER_PLAN,$C:$H"
        fi
    fi
}

route_metric()
{
    printf '%s\n' "$1" |
        awk '{
            m=0;
            for(i=1;i<=NF;i++) if($i=="metric" && (i+1)<=NF) m=$(i+1);
            print m+0;
            exit
        }'
}

route_dev()
{
    printf '%s\n' "$1" |
        awk '{
            for(i=1;i<=NF;i++) if($i=="dev" && (i+1)<=NF) {print $(i+1); exit}
        }'
}

route_via()
{
    printf '%s\n' "$1" |
        awk '{
            for(i=1;i<=NF;i++) if($i=="via" && (i+1)<=NF) {print $(i+1); exit}
        }'
}

choose_uplink_interactive()
{
    AUTO_DEV="$1"
    COUNT="$2"

    if [ "$COUNT" -le 1 ]; then
        UPLINK_SELECTED="$AUTO_DEV"
        UPLINK_SELECTION_MODE='AUTO_SINGLE_CANDIDATE'
        return 0
    fi

    UPLINK_SELECTION_REQUIRED='YES'

    if [ "$MODE" = AUTO ]; then
        UPLINK_SELECTED="$AUTO_DEV"
        UPLINK_SELECTION_MODE='AUTO_HEURISTIC'
        return 0
    fi

    printf '\nINSTALL-1: обнаружено несколько default-route uplink кандидатов.\n' >&2
    printf '1) [Авто / Рекомендуется] %s — %s\n' "$AUTO_DEV" "$UPLINK_AUTO_REASON" >&2

    N=1
    while IFS='|' read -r DEV METRIC VIA
    do
        [ -n "$DEV" ] || continue
        [ "$DEV" = "$AUTO_DEV" ] && continue
        N=$((N + 1))
        [ "$N" -le 5 ] || break
        printf '%s) %s (metric=%s, via=%s)\n' "$N" "$DEV" "$METRIC" "${VIA:-direct}" >&2
        printf '%s|%s\n' "$N" "$DEV" >>"$WORK/menu"
    done <"$WORK/uplink.unique"

    while :
    do
        printf 'Выбор [1-%s]: ' "$N" >&2
        if ! IFS= read -r CHOICE; then
            CHOICE=1
        fi

        case "$CHOICE" in
            1)
                UPLINK_SELECTED="$AUTO_DEV"
                UPLINK_SELECTION_MODE='INTERACTIVE_AUTO_RECOMMENDED'
                return 0
                ;;
            *)
                SEL="$(awk -F'|' -v n="$CHOICE" '$1==n {print $2; exit}' "$WORK/menu" 2>/dev/null)"
                if [ -n "$SEL" ]; then
                    UPLINK_SELECTED="$SEL"
                    UPLINK_SELECTION_MODE='INTERACTIVE_EXPLICIT'
                    return 0
                fi
                ;;
        esac
    done
}

: >"$WORK/capabilities"
: >"$WORK/menu"

if [ "$(id -u 2>/dev/null || echo X)" = 0 ]; then
    ROOT_GATE='PASS'
fi

TOOL_MISSING=''
for T in sha256sum awk sed grep sort cp chmod mkdir mv rm date wc id ls tar df
 do
    command -v "$T" >/dev/null 2>&1 || TOOL_MISSING="$TOOL_MISSING $T"
 done

if [ -z "$TOOL_MISSING" ]; then
    TOOL_GATE='PASS'
fi

if [ -d /overlay ]; then
    SPACE_PATH='/overlay'
fi

FREE_KB="$(df -Pk "$SPACE_PATH" 2>/dev/null | awk 'NR==2 {print $4+0; exit}')"
[ -n "$FREE_KB" ] || FREE_KB=0

if [ "$FREE_KB" -ge "$MIN_FREE_KB" ]; then
    SPACE_GATE='PASS'
fi

if command -v apk >/dev/null 2>&1; then
    PACKAGE_MANAGER='APK'
    PACKAGE_MANAGER_DIAGNOSTIC="$(apk --version 2>/dev/null | sed -n '1p')"
elif command -v opkg >/dev/null 2>&1; then
    PACKAGE_MANAGER='OPKG'
    PACKAGE_MANAGER_DIAGNOSTIC="$(opkg --version 2>/dev/null | sed -n '1p')"
fi
[ -n "$PACKAGE_MANAGER_DIAGNOSTIC" ] || PACKAGE_MANAGER_DIAGNOSTIC='UNKNOWN'

record_cap amneziawg_runtime
record_cap luci_runtime
record_cap luci_amneziawg_protocol
record_cap rpcd_ucode
record_cap rpcd_file_ops
record_cap firewall4_nft
record_cap dnsmasq_nftset
record_cap netifd
record_cap uci
record_cap ip_cli
record_cap jsonfilter
record_cap flock
record_cap uclient_fetch
record_cap dns_lookup_cli

if [ "$CAP_FAIL" -eq 0 ]; then
    CAPABILITY_GATE='PASS'
fi

if [ "$CAP_FAIL" -gt 0 ]; then
    if [ "$PACKAGE_MANAGER" != UNKNOWN ]; then
        DEPENDENCY_PLAN_GATE='PASS'
    else
        DEPENDENCY_PLAN_GATE='FAIL'
    fi
fi

# Read-only default-route diagnostics for future tunlink/uplink decisions.
if command -v ip >/dev/null 2>&1; then
    ip -4 route show default 2>/dev/null >"$WORK/default.routes" || true
else
    : >"$WORK/default.routes"
fi

: >"$WORK/uplink.raw"
while IFS= read -r R
 do
    [ -n "$R" ] || continue
    DEV="$(route_dev "$R")"
    [ -n "$DEV" ] || continue
    METRIC="$(route_metric "$R")"
    VIA="$(route_via "$R")"
    printf '%s|%s|%s\n' "$DEV" "$METRIC" "$VIA" >>"$WORK/uplink.raw"
 done <"$WORK/default.routes"

awk -F'|' '
    !seen[$1]++ { print $1 "|" $2 "|" $3 }
' "$WORK/uplink.raw" >"$WORK/uplink.unique"

UPLINK_CANDIDATE_COUNT="$(awk 'NF{n++} END{print n+0}' "$WORK/uplink.unique")"

if [ "$UPLINK_CANDIDATE_COUNT" -gt 0 ]; then
    UPLINK_AUTO="$(sort -t'|' -k2,2n "$WORK/uplink.unique" | awk -F'|' 'NR==1 {print $1; exit}')"
    AUTO_METRIC="$(sort -t'|' -k2,2n "$WORK/uplink.unique" | awk -F'|' 'NR==1 {print $2; exit}')"
    SAME_BEST="$(awk -F'|' -v m="$AUTO_METRIC" '$2==m {n++} END{print n+0}' "$WORK/uplink.unique")"

    if [ "$UPLINK_CANDIDATE_COUNT" -eq 1 ]; then
        UPLINK_AUTO_REASON='ONLY_DEFAULT_ROUTE_CANDIDATE'
    elif [ "$SAME_BEST" -eq 1 ]; then
        UPLINK_AUTO_REASON="LOWEST_ROUTE_METRIC_${AUTO_METRIC}"
    else
        UPLINK_AUTO_REASON="LOWEST_METRIC_TIE_${AUTO_METRIC}_FIRST_KERNEL_CANDIDATE"
    fi

    if [ "$UPLINK_CANDIDATE_COUNT" -gt 4 ]; then
        UPLINK_CANDIDATES_TRUNCATED='YES'
    fi

    choose_uplink_interactive "$UPLINK_AUTO" "$UPLINK_CANDIDATE_COUNT"
fi

# Existing Grizz diagnostics only; no ownership is claimed here.
GRIZZ_EXISTING_MARKERS=0
for P in \
    /usr/sbin/awg-split-mode \
    /usr/sbin/tunnel-profile-runtime \
    /usr/sbin/grizz-state-restore \
    /etc/config/awg_tunnel_profiles \
    /etc/config/awg_override \
    /etc/awg-split
 do
    [ -e "$P" ] && GRIZZ_EXISTING_MARKERS=$((GRIZZ_EXISTING_MARKERS + 1))
 done

case "$GRIZZ_EXISTING_MARKERS" in
    0) GRIZZ_EXISTING_STATE='NONE' ;;
    6) GRIZZ_EXISTING_STATE='PRESENT' ;;
    *) GRIZZ_EXISTING_STATE='PARTIAL' ;;
esac

HOSTNAME_NOW="$(uci -q get system.@system[0].hostname 2>/dev/null || hostname 2>/dev/null || echo UNKNOWN)"
BOARD_MODEL="$(ubus call system board 2>/dev/null | jsonfilter -e '@.model' 2>/dev/null || echo UNKNOWN)"

OPENWRT_RELEASE='UNKNOWN'
OPENWRT_TARGET='UNKNOWN'
OPENWRT_ARCH='UNKNOWN'
if [ -r /etc/openwrt_release ]; then
    . /etc/openwrt_release
    OPENWRT_RELEASE="${DISTRIB_RELEASE:-UNKNOWN}"
    OPENWRT_TARGET="${DISTRIB_TARGET:-UNKNOWN}"
    OPENWRT_ARCH="${DISTRIB_ARCH:-UNKNOWN}"
fi

if [ "$ROOT_GATE" != PASS ]; then
    PLATFORM_VERDICT='NOT_SUPPORTED'
    REASON='ROOT_REQUIRED'
elif [ "$TOOL_GATE" != PASS ]; then
    PLATFORM_VERDICT='NOT_SUPPORTED'
    REASON='INSTALLER_BASE_TOOL_MISSING'
elif [ "$SPACE_GATE" != PASS ]; then
    PLATFORM_VERDICT='NOT_SUPPORTED'
    REASON='INSUFFICIENT_WRITABLE_SPACE'
elif [ "$CAP_FAIL" -eq 0 ]; then
    PLATFORM_VERDICT='READY'
    DOWNLOAD_STAGE_ALLOWED='YES'
    RESULT='PASS'
    REASON='NONE'
elif [ "$DEPENDENCY_PLAN_GATE" = PASS ]; then
    PLATFORM_VERDICT='READY_AFTER_DEPS'
    DOWNLOAD_STAGE_ALLOWED='YES'
    RESULT='PASS'
    REASON='MISSING_CAPABILITIES_NATIVE_DEPENDENCY_PLAN_AVAILABLE'
else
    PLATFORM_VERDICT='NOT_SUPPORTED'
    REASON='MISSING_CAPABILITIES_WITHOUT_NATIVE_PACKAGE_MANAGER'
fi

cat <<EOF_SUMMARY
===== P5-R11E5G INSTALL-1 R1 BARE INFRASTRUCTURE PLATFORM PREFLIGHT =====

VERDICT=$PLATFORM_VERDICT

--- PLATFORM IDENTITY ---
HOSTNAME=$HOSTNAME_NOW
BOARD_MODEL=$BOARD_MODEL
OPENWRT_RELEASE=$OPENWRT_RELEASE
OPENWRT_TARGET=$OPENWRT_TARGET
OPENWRT_ARCH=$OPENWRT_ARCH
COMPATIBILITY_MODEL=CAPABILITY_ONLY
OPENWRT_VERSION_GATE=NO
TARGET_GATE=NO
ARCH_GATE=NO

--- CAPABILITIES ---
FORMAT=CAPABILITY|STATE|PROVIDER_PLAN
$(cat "$WORK/capabilities")

===== SUMMARY =====
RUN_MODE=$MODE
ROOT_GATE=$ROOT_GATE
TOOL_MISSING=${TOOL_MISSING:-NONE}
TOOL_GATE=$TOOL_GATE

SPACE_PATH=$SPACE_PATH
FREE_KB=$FREE_KB
MIN_FREE_KB=$MIN_FREE_KB
SPACE_GATE=$SPACE_GATE

NATIVE_PACKAGE_MANAGER=$PACKAGE_MANAGER
PACKAGE_MANAGER_DIAGNOSTIC=$PACKAGE_MANAGER_DIAGNOSTIC
CAPABILITY_TOTAL=$CAP_TOTAL
CAPABILITY_PASS=$CAP_PASS
CAPABILITY_FAIL=$CAP_FAIL
CAPABILITY_GATE=$CAPABILITY_GATE
MISSING_CAPABILITIES=${MISSING_CAPABILITIES:-NONE}
MISSING_PROVIDER_PLAN=${MISSING_PROVIDER_PLAN:-NONE}
DEPENDENCY_PLAN_GATE=$DEPENDENCY_PLAN_GATE
REPOSITORY_REACHABILITY=DEFERRED_TO_INSTALL1_STAGE2

UPLINK_CANDIDATE_COUNT=$UPLINK_CANDIDATE_COUNT
UPLINK_AUTO=$UPLINK_AUTO
UPLINK_AUTO_REASON=$UPLINK_AUTO_REASON
UPLINK_SELECTED=$UPLINK_SELECTED
UPLINK_SELECTION_MODE=$UPLINK_SELECTION_MODE
UPLINK_SELECTION_REQUIRED=$UPLINK_SELECTION_REQUIRED
UPLINK_CANDIDATES_TRUNCATED=$UPLINK_CANDIDATES_TRUNCATED
UPLINK_DECISION_PERSISTED=NO

GRIZZ_EXISTING_MARKERS=$GRIZZ_EXISTING_MARKERS
GRIZZ_EXISTING_STATE=$GRIZZ_EXISTING_STATE
GENERIC_LAN_WAN_FIREWALL_DHCP_TOUCHED=NO

PLATFORM_VERDICT=$PLATFORM_VERDICT
DOWNLOAD_STAGE_ALLOWED=$DOWNLOAD_STAGE_ALLOWED

PACKAGE_INSTALL=NO
CODE_DOWNLOAD=NO
CODE_COPY=NO
INIT_MUTATION=NO
CRON_MUTATION=NO
UCI_MUTATION=NO
NETWORK_MUTATION=NO
FIREWALL_MUTATION=NO
DHCP_MUTATION=NO
DATAPLANE_MUTATION=NO
SERVICE_RELOAD=NO
SERVICE_RESTART=NO
PERSISTENT_MUTATION=NO

INSTALL1_STAGE=R1_PREFLIGHT_ONLY
NEXT_IF_PASS=ACCEPT_R1_THEN_DESIGN_R2_DOWNLOAD_ONLY
RESULT=$RESULT
REASON=$REASON
===== END SUMMARY =====
EOF_SUMMARY

[ "$RESULT" = PASS ]
