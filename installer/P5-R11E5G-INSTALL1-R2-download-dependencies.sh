#!/bin/sh
set -u
umask 077

STEP='P5-R11E5G-INSTALL1-R2-DOWNLOAD-DEPENDENCIES'
RUN_MODE='INTERACTIVE'
DECISION='AUTO'

case "${1:-}" in
    '') ;;
    --auto)
        RUN_MODE='AUTO'
        ;;
    --download-only)
        RUN_MODE='DOWNLOAD_ONLY'
        DECISION='DOWNLOAD_ONLY'
        ;;
    --help)
        echo 'USAGE: P5-R11E5G-INSTALL1-R2-download-dependencies.sh [--auto|--download-only]'
        exit 0
        ;;
    *)
        echo 'USAGE: P5-R11E5G-INSTALL1-R2-download-dependencies.sh [--auto|--download-only]'
        exit 2
        ;;
esac

R1_URL='https://raw.githubusercontent.com/GrizzlikovOleg/Grizz_tun_openwrt/main/installer/P5-R11E5G-INSTALL1-R1-platform-preflight.sh'
OVERLAY_URL='https://github.com/GrizzlikovOleg/Grizz_tun_openwrt/releases/download/grizz-overlay-v4/grizz-overlay-files-v4-20260906-231436.tar.gz'
OVERLAY_SUM_URL='https://github.com/GrizzlikovOleg/Grizz_tun_openwrt/releases/download/grizz-overlay-v4/grizz-overlay-files-v4-20260906-231436.tar.gz.sha256'

EXPECTED_R1_SHA='7403f8ffb99fda6f10d6209d684a000182ea26fcb65ccac2313b2514f8e48361'
EXPECTED_OVERLAY_SHA='7df32c3380e5d8ba4dd14a19d4fb61b46356dac5642fe6a649f6bce1d4bb9f2c'
EXPECTED_MANIFEST_SHA='77adbc125a57653fb8b22825d9de7c195d865fd1990ab3a33cc7f795a6a11be7'

CACHE_ROOT='/tmp/grizz-install1'
CACHE_DIR="$CACHE_ROOT/cache"
OVERLAY_DIR="$CACHE_ROOT/overlay-v4"
R1_CACHE="$CACHE_DIR/P5-R11E5G-INSTALL1-R1-platform-preflight.sh"
OVERLAY_CACHE="$CACHE_DIR/grizz-overlay-files-v4-20260906-231436.tar.gz"
OVERLAY_SUM_CACHE="$CACHE_DIR/grizz-overlay-files-v4-20260906-231436.tar.gz.sha256"

WORK="/tmp/${STEP}.$$"
PREIMAGE_ROOT='/root/grizz-install1-preimage'
LOCK='/tmp/grizz-install1.lock'

RESULT='FAIL'
REASON='UNKNOWN'
R2_ACCEPTANCE='NOT_ACCEPTED'

ROOT_GATE='FAIL'
TOOL_GATE='FAIL'
UCI_GATE='FAIL'
R1_DOWNLOAD_GATE='FAIL'
R1_SHA_GATE='FAIL'
R1_PRE_GATE='FAIL'
PLATFORM_PRE_VERDICT='UNKNOWN'
PACKAGE_MANAGER='UNKNOWN'
DEPENDENCY_PLAN_GATE='N/A'
DECISION_GATE='N/A'
OVERLAY_DOWNLOAD_GATE='FAIL'
OVERLAY_SUM_DOWNLOAD_GATE='FAIL'
OVERLAY_SHA_GATE='FAIL'
PUBLISHED_SHA_GATE='FAIL'
EXTRACT_GATE='FAIL'
MANIFEST_GATE='FAIL'
PAYLOAD_GATE='FAIL'
LOCK_GATE='N/A'
PREIMAGE_GATE='N/A'
REPOSITORY_GATE='N/A'
PACKAGE_AVAILABILITY_GATE='N/A'
PACKAGE_INSTALL_GATE='N/A'
R1_POST_GATE='N/A'
OVERLAY_PREFLIGHT_GATE='N/A'
NETWORK_SAFETY_GATE='N/A'
ROLLBACK='NOT_REQUIRED'
ROLLBACK_GATE='N/A'
PACKAGE_MUTATION='NO'
PACKAGE_UPDATE_EXECUTED='NO'
PACKAGE_INSTALL_EXECUTED='NO'
OVERLAY_APPLY_EXECUTED='NO'
PERSISTENT_CONFIG_MUTATION='NO'

mkdir -m 700 "$WORK" >/dev/null 2>&1 || exit 1
mkdir -p "$CACHE_DIR" >/dev/null 2>&1 || exit 1
chmod 700 "$CACHE_ROOT" "$CACHE_DIR" >/dev/null 2>&1 || exit 1

cleanup()
{
    rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

sha()
{
    if [ -f "$1" ]; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    else
        echo N/A
    fi
}

file_sha_or_absent()
{
    if [ -f "$1" ]; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    else
        echo ABSENT
    fi
}

run_limited()
{
    LIMIT="$1"
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout "$LIMIT" "$@"
        return $?
    fi

    FLAG="$WORK/timeout.flag.$$"
    rm -f "$FLAG" 2>/dev/null || true

    "$@" &
    CMD_PID=$!

    (
        sleep "$LIMIT"
        if kill -0 "$CMD_PID" 2>/dev/null; then
            : >"$FLAG"
            kill "$CMD_PID" 2>/dev/null || true
            sleep 2
            kill -9 "$CMD_PID" 2>/dev/null || true
        fi
    ) &
    WATCH_PID=$!

    wait "$CMD_PID"
    CMD_RC=$?

    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true

    if [ -f "$FLAG" ]; then
        rm -f "$FLAG" 2>/dev/null || true
        return 124
    fi

    return "$CMD_RC"
}

fetch_atomic()
{
    URL="$1"
    DEST="$2"
    EXPECTED="$3"
    NAME="$4"

    if [ -s "$DEST" ] && [ "$(sha "$DEST")" = "$EXPECTED" ]; then
        return 0
    fi

    TMP="$WORK/${NAME}.download"
    rm -f "$TMP" >/dev/null 2>&1 || true

    if ! run_limited 60 uclient-fetch -O "$TMP" "$URL" \
        >"$WORK/${NAME}.fetch.out" 2>"$WORK/${NAME}.fetch.err"; then
        rm -f "$TMP" >/dev/null 2>&1 || true
        return 1
    fi

    [ -s "$TMP" ] || { rm -f "$TMP"; return 1; }
    [ "$(sha "$TMP")" = "$EXPECTED" ] || { rm -f "$TMP"; return 1; }

    mv -f "$TMP" "$DEST" || return 1
    chmod 600 "$DEST" >/dev/null 2>&1 || return 1
    return 0
}

pkg_list()
{
    case "$PACKAGE_MANAGER" in
        APK)
            apk list -I 2>/dev/null | sort
            ;;
        OPKG)
            opkg list-installed 2>/dev/null | sort
            ;;
        *)
            return 1
            ;;
    esac
}

pkg_installed()
{
    P="$1"
    case "$PACKAGE_MANAGER" in
        APK)
            apk list -I "$P" 2>/dev/null |
                awk -v p="$P" 'index($0,p "-")==1 {f=1} END{exit(f?0:1)}'
            ;;
        OPKG)
            opkg status "$P" 2>/dev/null |
                grep -Eq '^Status: .* installed$'
            ;;
        *)
            return 1
            ;;
    esac
}

pkg_available()
{
    P="$1"
    case "$PACKAGE_MANAGER" in
        APK)
            apk list -a "$P" 2>/dev/null |
                awk -v p="$P" 'index($0,p "-")==1 {f=1} END{exit(f?0:1)}'
            ;;
        OPKG)
            opkg list "$P" 2>/dev/null |
                awk -F' - ' -v p="$P" '$1==p {f=1} END{exit(f?0:1)}'
            ;;
        *)
            return 1
            ;;
    esac
}

pkg_update()
{
    case "$PACKAGE_MANAGER" in
        APK)
            run_limited 120 apk update
            ;;
        OPKG)
            run_limited 120 opkg update
            ;;
        *)
            return 1
            ;;
    esac
}

pkg_add_file()
{
    LIST="$1"
    set --
    while IFS= read -r P
    do
        [ -n "$P" ] || continue
        set -- "$@" "$P"
    done <"$LIST"

    [ "$#" -gt 0 ] || return 0

    case "$PACKAGE_MANAGER" in
        APK)
            run_limited 180 apk add "$@"
            ;;
        OPKG)
            run_limited 180 opkg install "$@"
            ;;
        *)
            return 1
            ;;
    esac
}

pkg_remove_file()
{
    LIST="$1"
    set --
    while IFS= read -r P
    do
        [ -n "$P" ] || continue
        if pkg_installed "$P"; then
            set -- "$@" "$P"
        fi
    done <"$LIST"

    [ "$#" -gt 0 ] || return 0

    case "$PACKAGE_MANAGER" in
        APK)
            run_limited 180 apk del "$@"
            ;;
        OPKG)
            if opkg --help 2>&1 | grep -q -- '--autoremove'; then
                run_limited 180 opkg remove --autoremove "$@"
            else
                run_limited 180 opkg remove "$@"
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

network_snapshot()
{
    {
        printf 'network=%s\n' "$(file_sha_or_absent /etc/config/network)"
        printf 'firewall=%s\n' "$(file_sha_or_absent /etc/config/firewall)"
        printf 'dhcp=%s\n' "$(file_sha_or_absent /etc/config/dhcp)"
        printf 'system=%s\n' "$(file_sha_or_absent /etc/config/system)"
        printf 'wireless=%s\n' "$(file_sha_or_absent /etc/config/wireless)"
        ip -4 route show default 2>/dev/null | sort
    } | sha256sum | awk '{print $1}'
}

rollback_packages()
{
    ROLLBACK='ATTEMPTED'
    RB_OK='YES'

    if ! pkg_remove_file "$WORK/new-requested-packages" \
        >"$WORK/package.rollback.out" 2>"$WORK/package.rollback.err"; then
        RB_OK='NO'
    fi

    pkg_list >"$WORK/packages.rollback" 2>/dev/null || RB_OK='NO'

    if ! cmp -s "$WORK/packages.before" "$WORK/packages.rollback" 2>/dev/null; then
        RB_OK='NO'
    fi

    NETWORK_ROLLBACK="$(network_snapshot)"
    if [ "$NETWORK_ROLLBACK" != "$NETWORK_SNAPSHOT_BEFORE" ]; then
        RB_OK='NO'
    fi

    if [ "$RB_OK" = YES ]; then
        ROLLBACK_GATE='PASS'
    else
        ROLLBACK_GATE='FAIL'
    fi
}

# ---------- Read-only preflight ----------

if [ "$(id -u 2>/dev/null || echo X)" = 0 ]; then
    ROOT_GATE='PASS'
fi

TOOL_MISSING=''
for T in sha256sum awk sed grep sort cp chmod mkdir mv rm date wc id ls tar df cmp ip uclient-fetch flock
 do
    command -v "$T" >/dev/null 2>&1 || TOOL_MISSING="$TOOL_MISSING $T"
 done

if [ -z "$TOOL_MISSING" ]; then
    TOOL_GATE='PASS'
fi

UCI_PENDING="$(
    {
        uci -q changes network
        uci -q changes firewall
        uci -q changes dhcp
        uci -q changes system
        uci -q changes wireless
    } 2>/dev/null
)"

if [ -z "$UCI_PENDING" ]; then
    UCI_GATE='PASS'
fi

if [ "$ROOT_GATE" != PASS ] || [ "$TOOL_GATE" != PASS ] || [ "$UCI_GATE" != PASS ]; then
    if [ "$ROOT_GATE" != PASS ]; then REASON='ROOT_REQUIRED';
    elif [ "$TOOL_GATE" != PASS ]; then REASON='INSTALLER_BASE_TOOL_MISSING';
    else REASON='PENDING_GENERIC_UCI_CHANGES'; fi
else
    if fetch_atomic "$R1_URL" "$R1_CACHE" "$EXPECTED_R1_SHA" 'r1'; then
        R1_DOWNLOAD_GATE='PASS'
    else
        REASON='R1_DOWNLOAD_OR_SHA_FAILED'
    fi
fi

R1_SHA="$(sha "$R1_CACHE")"
if [ "$R1_DOWNLOAD_GATE" = PASS ] && [ "$R1_SHA" = "$EXPECTED_R1_SHA" ] && sh -n "$R1_CACHE"; then
    R1_SHA_GATE='PASS'
else
    REASON='R1_SHA_OR_SYNTAX_INVALID'
fi

if [ "$R1_SHA_GATE" = PASS ]; then
    sh "$R1_CACHE" --auto >"$WORK/r1.before.out" 2>"$WORK/r1.before.err"
    R1_PRE_RC=$?

    PLATFORM_PRE_VERDICT="$(awk -F= '$1=="PLATFORM_VERDICT"{v=$2} END{print v}' "$WORK/r1.before.out")"
    PACKAGE_MANAGER="$(awk -F= '$1=="NATIVE_PACKAGE_MANAGER"{v=$2} END{print v}' "$WORK/r1.before.out")"
    MISSING_CAPABILITIES="$(awk -F= '$1=="MISSING_CAPABILITIES"{sub(/^[^=]*=/,"");v=$0} END{print v}' "$WORK/r1.before.out")"
    MISSING_PROVIDER_PLAN="$(awk -F= '$1=="MISSING_PROVIDER_PLAN"{sub(/^[^=]*=/,"");v=$0} END{print v}' "$WORK/r1.before.out")"

    if [ "$R1_PRE_RC" -eq 0 ] &&
       grep -Fqx 'RESULT=PASS' "$WORK/r1.before.out" &&
       { [ "$PLATFORM_PRE_VERDICT" = READY ] || [ "$PLATFORM_PRE_VERDICT" = READY_AFTER_DEPS ]; }; then
        R1_PRE_GATE='PASS'
    else
        REASON='R1_PLATFORM_PREFLIGHT_FAILED'
    fi
else
    R1_PRE_RC='N/A'
    MISSING_CAPABILITIES='UNKNOWN'
    MISSING_PROVIDER_PLAN='UNKNOWN'
fi

# Build a concrete native package plan. Any unresolved provider fails closed.
: >"$WORK/requested-packages"
PLAN_UNRESOLVED=0

if [ "$R1_PRE_GATE" = PASS ] && [ "$PLATFORM_PRE_VERDICT" = READY_AFTER_DEPS ]; then
    printf '%s\n' "$MISSING_PROVIDER_PLAN" |
        awk -F',' '
        {
            for (i=1; i<=NF; i++) {
                item=$i
                p=index(item, ":")
                if (!p) { print "UNRESOLVED|" item; continue }
                cap=substr(item,1,p-1)
                provider=substr(item,p+1)
                if (provider=="" || provider=="NONE" || provider ~ /^native-provider:/) {
                    print "UNRESOLVED|" cap ":" provider
                    continue
                }
                n=split(provider,a,"+")
                for (j=1; j<=n; j++) if (a[j] != "") print "PACKAGE|" a[j]
            }
        }' >"$WORK/plan.expanded"

    PLAN_UNRESOLVED="$(awk -F'|' '$1=="UNRESOLVED"{n++} END{print n+0}' "$WORK/plan.expanded")"
    awk -F'|' '$1=="PACKAGE"{print $2}' "$WORK/plan.expanded" | sort -u >"$WORK/requested-packages"

    REQUESTED_COUNT="$(awk 'NF{n++} END{print n+0}' "$WORK/requested-packages")"

    if [ "$PLAN_UNRESOLVED" -eq 0 ] &&
       [ "$REQUESTED_COUNT" -gt 0 ] &&
       { [ "$PACKAGE_MANAGER" = APK ] || [ "$PACKAGE_MANAGER" = OPKG ]; }; then
        DEPENDENCY_PLAN_GATE='PASS'
    else
        DEPENDENCY_PLAN_GATE='FAIL'
        REASON='NATIVE_DEPENDENCY_PLAN_UNRESOLVED'
    fi
else
    REQUESTED_COUNT=0
    DEPENDENCY_PLAN_GATE='NOT_REQUIRED'
fi

# Decision source differs; stage logic does not.
if [ "$R1_PRE_GATE" = PASS ] && [ "$PLATFORM_PRE_VERDICT" = READY_AFTER_DEPS ]; then
    if [ "$RUN_MODE" = AUTO ]; then
        DECISION='INSTALL_DEPS'
        DECISION_GATE='PASS'
    elif [ "$RUN_MODE" = DOWNLOAD_ONLY ]; then
        DECISION='DOWNLOAD_ONLY'
        DECISION_GATE='PASS'
    else
        printf '\nINSTALL-1 R2: platform needs native dependencies.\n' >&2
        printf '1) [Auto / Recommended] Download verified overlay and install only missing native dependencies\n' >&2
        printf '2) Download and verify overlay only; defer dependency installation\n' >&2
        printf '3) Abort without mutation\n' >&2
        while :
        do
            printf 'Selection [1-3]: ' >&2
            if ! IFS= read -r CHOICE; then CHOICE=1; fi
            case "$CHOICE" in
                1) DECISION='INSTALL_DEPS'; DECISION_GATE='PASS'; break ;;
                2) DECISION='DOWNLOAD_ONLY'; DECISION_GATE='PASS'; break ;;
                3) DECISION='ABORT'; DECISION_GATE='PASS'; break ;;
            esac
        done
    fi
elif [ "$R1_PRE_GATE" = PASS ] && [ "$PLATFORM_PRE_VERDICT" = READY ]; then
    DECISION='NO_DEPS_REQUIRED'
    DECISION_GATE='PASS'
fi

if [ "$DECISION" = ABORT ]; then
    REASON='USER_ABORTED_BEFORE_MUTATION'
fi

# ---------- Frozen overlay download ----------

if [ "$R1_PRE_GATE" = PASS ] && [ "$DECISION" != ABORT ]; then
    if fetch_atomic "$OVERLAY_URL" "$OVERLAY_CACHE" "$EXPECTED_OVERLAY_SHA" 'overlay'; then
        OVERLAY_DOWNLOAD_GATE='PASS'
    else
        REASON='OVERLAY_DOWNLOAD_OR_SHA_FAILED'
    fi

    # Published checksum is downloaded separately and must agree with frozen value.
    TMP_SUM="$WORK/overlay.sum.download"
    rm -f "$TMP_SUM" >/dev/null 2>&1 || true
    if run_limited 60 uclient-fetch -O "$TMP_SUM" "$OVERLAY_SUM_URL" \
        >"$WORK/sum.fetch.out" 2>"$WORK/sum.fetch.err" && [ -s "$TMP_SUM" ]; then
        mv -f "$TMP_SUM" "$OVERLAY_SUM_CACHE" && chmod 600 "$OVERLAY_SUM_CACHE"
        OVERLAY_SUM_DOWNLOAD_GATE='PASS'
    else
        rm -f "$TMP_SUM" >/dev/null 2>&1 || true
        REASON='OVERLAY_SHA_FILE_DOWNLOAD_FAILED'
    fi
fi

OVERLAY_SHA="$(sha "$OVERLAY_CACHE")"
PUBLISHED_SHA="$(awk 'NF{print $1; exit}' "$OVERLAY_SUM_CACHE" 2>/dev/null)"

if [ "$OVERLAY_DOWNLOAD_GATE" = PASS ] && [ "$OVERLAY_SHA" = "$EXPECTED_OVERLAY_SHA" ]; then
    OVERLAY_SHA_GATE='PASS'
else
    REASON='OVERLAY_SHA_MISMATCH'
fi

if [ "$OVERLAY_SUM_DOWNLOAD_GATE" = PASS ] &&
   [ "$PUBLISHED_SHA" = "$EXPECTED_OVERLAY_SHA" ] &&
   [ "$PUBLISHED_SHA" = "$OVERLAY_SHA" ]; then
    PUBLISHED_SHA_GATE='PASS'
else
    REASON='PUBLISHED_SHA_MISMATCH'
fi

if [ "$OVERLAY_SHA_GATE" = PASS ] && [ "$PUBLISHED_SHA_GATE" = PASS ]; then
    rm -rf "$OVERLAY_DIR.candidate" >/dev/null 2>&1 || true
    mkdir -m 700 "$OVERLAY_DIR.candidate" || REASON='OVERLAY_EXTRACT_DIR_FAILED'

    if tar -xzf "$OVERLAY_CACHE" -C "$OVERLAY_DIR.candidate" \
        >"$WORK/overlay.extract.out" 2>"$WORK/overlay.extract.err"; then
        EXTRACT_GATE='PASS'
    else
        REASON='OVERLAY_EXTRACT_FAILED'
    fi
fi

MANIFEST_SHA="$(sha "$OVERLAY_DIR.candidate/MANIFEST")"
if [ "$EXTRACT_GATE" = PASS ] &&
   [ "$MANIFEST_SHA" = "$EXPECTED_MANIFEST_SHA" ] &&
   [ -f "$OVERLAY_DIR.candidate/RELEASE" ] &&
   grep -Fqx 'RELEASE_ID=GRIZZ_OVERLAY_V4' "$OVERLAY_DIR.candidate/RELEASE" &&
   grep -Fqx 'STATE_SCHEMA=1' "$OVERLAY_DIR.candidate/RELEASE"; then
    MANIFEST_GATE='PASS'
else
    REASON='OVERLAY_MANIFEST_INVALID'
fi

FILE_COUNT=0
BAD_COUNT=0
if [ "$MANIFEST_GATE" = PASS ]; then
    while IFS='|' read -r MODE HASH PATH_ABS
    do
        [ -n "$MODE" ] || continue
        [ -n "$HASH" ] || continue
        [ -n "$PATH_ABS" ] || continue
        FILE_COUNT=$((FILE_COUNT + 1))
        REL="${PATH_ABS#/}"
        F="$OVERLAY_DIR.candidate/rootfs/$REL"
        if [ ! -f "$F" ] || [ "$(sha "$F")" != "$HASH" ]; then
            BAD_COUNT=$((BAD_COUNT + 1))
        fi
    done <"$OVERLAY_DIR.candidate/MANIFEST"

    if [ "$FILE_COUNT" -eq 47 ] && [ "$BAD_COUNT" -eq 0 ] &&
       sh -n "$OVERLAY_DIR.candidate/preflight.sh" &&
       sh -n "$OVERLAY_DIR.candidate/apply.sh"; then
        PAYLOAD_GATE='PASS'
        rm -rf "$OVERLAY_DIR" >/dev/null 2>&1 || true
        mv "$OVERLAY_DIR.candidate" "$OVERLAY_DIR" || { PAYLOAD_GATE='FAIL'; REASON='OVERLAY_CACHE_COMMIT_FAILED'; }
    else
        REASON='OVERLAY_PAYLOAD_INVALID'
    fi
fi

# Download-only is intentionally non-mutating and does not close R2 acceptance.
if [ "$PAYLOAD_GATE" = PASS ] &&
   { [ "$DECISION" = DOWNLOAD_ONLY ] || [ "$DECISION" = NO_DEPS_REQUIRED ]; }; then

    if [ "$DECISION" = NO_DEPS_REQUIRED ]; then
        sh "$R1_CACHE" --auto >"$WORK/r1.after.out" 2>"$WORK/r1.after.err"
        R1_POST_RC=$?
        if [ "$R1_POST_RC" -eq 0 ] &&
           grep -Fqx 'PLATFORM_VERDICT=READY' "$WORK/r1.after.out" &&
           grep -Fqx 'CAPABILITY_FAIL=0' "$WORK/r1.after.out" &&
           grep -Fqx 'RESULT=PASS' "$WORK/r1.after.out"; then
            R1_POST_GATE='PASS'
            R2_ACCEPTANCE='CLOSED_PASS'
            RESULT='PASS'
            REASON='NONE'
        else
            R1_POST_GATE='FAIL'
            REASON='READY_PLATFORM_POSTCHECK_FAILED'
        fi
    else
        R2_ACCEPTANCE='PARTIAL_DOWNLOAD_ONLY'
        RESULT='PASS'
        REASON='DEPENDENCY_INSTALL_DEFERRED'
    fi
fi

# ---------- Native dependency transaction ----------

if [ "$PAYLOAD_GATE" = PASS ] &&
   [ "$DECISION" = INSTALL_DEPS ] &&
   [ "$DEPENDENCY_PLAN_GATE" = PASS ]; then

    exec 9>"$LOCK"
    if flock -n 9; then
        LOCK_GATE='PASS'
    else
        REASON='INSTALLER_MUTATION_LOCK_BUSY'
    fi

    if [ "$LOCK_GATE" = PASS ]; then
        TS="$(date +%Y%m%d-%H%M%S)"
        PREIMAGE="$PREIMAGE_ROOT/R2-$TS"
        mkdir -p "$PREIMAGE" >/dev/null 2>&1
        PRE_RC=$?
        chmod 700 "$PREIMAGE" >/dev/null 2>&1 || PRE_RC=1

        cp "$WORK/r1.before.out" "$PREIMAGE/r1.before.out" 2>/dev/null || PRE_RC=1
        cp "$WORK/requested-packages" "$PREIMAGE/requested-packages" 2>/dev/null || PRE_RC=1
        pkg_list >"$WORK/packages.before" 2>/dev/null || PRE_RC=1
        cp "$WORK/packages.before" "$PREIMAGE/packages.before" 2>/dev/null || PRE_RC=1

        NETWORK_SNAPSHOT_BEFORE="$(network_snapshot)"
        printf '%s\n' "$NETWORK_SNAPSHOT_BEFORE" >"$PREIMAGE/network-snapshot.sha256" || PRE_RC=1

        if [ "$PACKAGE_MANAGER" = APK ]; then
            mkdir -p "$PREIMAGE/apk-repositories" >/dev/null 2>&1 || PRE_RC=1
            for F in /etc/apk/repositories /etc/apk/repositories.d/*; do
                [ -f "$F" ] || continue
                cp -p "$F" "$PREIMAGE/apk-repositories/" 2>/dev/null || PRE_RC=1
            done
        elif [ "$PACKAGE_MANAGER" = OPKG ]; then
            mkdir -p "$PREIMAGE/opkg" >/dev/null 2>&1 || PRE_RC=1
            for F in /etc/opkg/*.conf; do
                [ -f "$F" ] || continue
                cp -p "$F" "$PREIMAGE/opkg/" 2>/dev/null || PRE_RC=1
            done
        fi

        : >"$WORK/new-requested-packages"
        PROVIDER_ALREADY_INSTALLED=0
        PROVIDER_MISSING=0
        while IFS= read -r P
        do
            [ -n "$P" ] || continue
            if pkg_installed "$P"; then
                PROVIDER_ALREADY_INSTALLED=$((PROVIDER_ALREADY_INSTALLED + 1))
            else
                PROVIDER_MISSING=$((PROVIDER_MISSING + 1))
                printf '%s\n' "$P" >>"$WORK/new-requested-packages"
            fi
        done <"$WORK/requested-packages"
        cp "$WORK/new-requested-packages" "$PREIMAGE/new-requested-packages" 2>/dev/null || PRE_RC=1

        if [ "$PRE_RC" -eq 0 ]; then
            PREIMAGE_GATE='PASS'
        else
            PREIMAGE_GATE='FAIL'
            REASON='PACKAGE_PREIMAGE_FAILED'
        fi
    fi

    if [ "$PREIMAGE_GATE" = PASS ]; then
        # If provider package is already installed but capability is missing,
        # do not silently repair/reinstall it in Stage 2.
        if [ "$PROVIDER_MISSING" -eq 0 ]; then
            PACKAGE_AVAILABILITY_GATE='FAIL'
            REASON='PROVIDER_INSTALLED_BUT_CAPABILITY_MISSING'
        else
            PACKAGE_MUTATION='YES'
            PACKAGE_UPDATE_EXECUTED='YES'
            if pkg_update >"$WORK/package.update.out" 2>"$WORK/package.update.err"; then
                REPOSITORY_GATE='PASS'
            else
                REPOSITORY_GATE='FAIL'
                REASON='NATIVE_REPOSITORY_UPDATE_FAILED_OR_TIMEOUT'
            fi
        fi
    fi

    if [ "$REPOSITORY_GATE" = PASS ]; then
        AVAIL_BAD=0
        while IFS= read -r P
        do
            [ -n "$P" ] || continue
            if ! pkg_available "$P"; then
                AVAIL_BAD=$((AVAIL_BAD + 1))
            fi
        done <"$WORK/new-requested-packages"

        if [ "$AVAIL_BAD" -eq 0 ]; then
            PACKAGE_AVAILABILITY_GATE='PASS'
        else
            PACKAGE_AVAILABILITY_GATE='FAIL'
            REASON='NATIVE_PROVIDER_PACKAGE_NOT_AVAILABLE'
        fi
    fi

    if [ "$PACKAGE_AVAILABILITY_GATE" = PASS ]; then
        PACKAGE_INSTALL_EXECUTED='YES'
        if pkg_add_file "$WORK/new-requested-packages" \
            >"$WORK/package.install.out" 2>"$WORK/package.install.err"; then
            PACKAGE_INSTALL_GATE='PASS'
        else
            PACKAGE_INSTALL_GATE='FAIL'
            REASON='NATIVE_PACKAGE_INSTALL_FAILED_OR_TIMEOUT'
        fi
    fi

    if [ "$PACKAGE_INSTALL_GATE" = PASS ]; then
        sh "$R1_CACHE" --auto >"$WORK/r1.after.out" 2>"$WORK/r1.after.err"
        R1_POST_RC=$?
        if [ "$R1_POST_RC" -eq 0 ] &&
           grep -Fqx 'PLATFORM_VERDICT=READY' "$WORK/r1.after.out" &&
           grep -Fqx 'CAPABILITY_TOTAL=14' "$WORK/r1.after.out" &&
           grep -Fqx 'CAPABILITY_PASS=14' "$WORK/r1.after.out" &&
           grep -Fqx 'CAPABILITY_FAIL=0' "$WORK/r1.after.out" &&
           grep -Fqx 'RESULT=PASS' "$WORK/r1.after.out"; then
            R1_POST_GATE='PASS'
        else
            R1_POST_GATE='FAIL'
            REASON='DEPENDENCY_CAPABILITY_POSTCHECK_FAILED'
        fi
    fi

    if [ "$R1_POST_GATE" = PASS ]; then
        "$OVERLAY_DIR/preflight.sh" >"$WORK/overlay.preflight.out" 2>"$WORK/overlay.preflight.err"
        OVERLAY_PREFLIGHT_RC=$?
        if [ "$OVERLAY_PREFLIGHT_RC" -eq 0 ] &&
           grep -Fqx 'CAPABILITY_TOTAL=14' "$WORK/overlay.preflight.out" &&
           grep -Fqx 'CAPABILITY_PASS=14' "$WORK/overlay.preflight.out" &&
           grep -Fqx 'CAPABILITY_FAIL=0' "$WORK/overlay.preflight.out" &&
           grep -Fqx 'CAPABILITY_GATE=PASS' "$WORK/overlay.preflight.out" &&
           grep -Fqx 'RESULT=PASS' "$WORK/overlay.preflight.out"; then
            OVERLAY_PREFLIGHT_GATE='PASS'
        else
            OVERLAY_PREFLIGHT_GATE='FAIL'
            REASON='FROZEN_OVERLAY_CAPABILITY_POSTCHECK_FAILED'
        fi
    else
        OVERLAY_PREFLIGHT_RC='N/A'
    fi

    if [ "$OVERLAY_PREFLIGHT_GATE" = PASS ]; then
        NETWORK_SNAPSHOT_AFTER="$(network_snapshot)"
        UCI_AFTER="$(
            {
                uci -q changes network
                uci -q changes firewall
                uci -q changes dhcp
                uci -q changes system
                uci -q changes wireless
            } 2>/dev/null
        )"

        if [ "$NETWORK_SNAPSHOT_AFTER" = "$NETWORK_SNAPSHOT_BEFORE" ] &&
           [ -z "$UCI_AFTER" ]; then
            NETWORK_SAFETY_GATE='PASS'
        else
            NETWORK_SAFETY_GATE='FAIL'
            REASON='GENERIC_NETWORK_STATE_CHANGED_DURING_DEPENDENCY_INSTALL'
        fi
    fi

    if [ "$PACKAGE_INSTALL_GATE" = PASS ] &&
       [ "$R1_POST_GATE" = PASS ] &&
       [ "$OVERLAY_PREFLIGHT_GATE" = PASS ] &&
       [ "$NETWORK_SAFETY_GATE" = PASS ]; then

        pkg_list >"$PREIMAGE/packages.after" 2>/dev/null || true
        R2_ACCEPTANCE='CLOSED_PASS'
        RESULT='PASS'
        REASON='NONE'
    else
        # Roll back only if package installation may have changed installed packages.
        if [ "$PACKAGE_INSTALL_EXECUTED" = YES ]; then
            rollback_packages
        fi
    fi
fi

# If update/availability failed before install, no package rollback is needed.
if [ "$RESULT" != PASS ] && [ "$PACKAGE_INSTALL_EXECUTED" != YES ]; then
    ROLLBACK='NOT_REQUIRED'
    ROLLBACK_GATE='N/A'
fi

# If rollback succeeded, prove the generic network snapshot is restored.
if [ "$ROLLBACK" = ATTEMPTED ] && [ "$ROLLBACK_GATE" = PASS ]; then
    NETWORK_SAFETY_GATE='PASS_AFTER_ROLLBACK'
fi

REQUESTED_PACKAGES="$(awk 'NF{printf "%s%s",sep,$0; sep=","} END{if(NR==0)printf "NONE"}' "$WORK/requested-packages" 2>/dev/null)"
NEW_REQUESTED_PACKAGES="$(awk 'NF{printf "%s%s",sep,$0; sep=","} END{if(NR==0)printf "NONE"}' "$WORK/new-requested-packages" 2>/dev/null)"

POST_VERDICT="$(awk -F= '$1=="PLATFORM_VERDICT"{v=$2} END{print v}' "$WORK/r1.after.out" 2>/dev/null)"
POST_CAP_PASS="$(awk -F= '$1=="CAPABILITY_PASS"{v=$2} END{print v}' "$WORK/r1.after.out" 2>/dev/null)"
POST_CAP_FAIL="$(awk -F= '$1=="CAPABILITY_FAIL"{v=$2} END{print v}' "$WORK/r1.after.out" 2>/dev/null)"

HOSTNAME_NOW="$(uci -q get system.@system[0].hostname 2>/dev/null || hostname 2>/dev/null || echo UNKNOWN)"
PREIMAGE_OUT="${PREIMAGE:-NONE}"

cat <<EOF_SUMMARY
===== P5-R11E5G INSTALL-1 R2 DOWNLOAD + NATIVE DEPENDENCIES =====

VERDICT=$(if [ "$RESULT" = PASS ]; then echo PASS; else echo FAIL; fi)

--- PRE-R2 PLATFORM ---
PLATFORM_VERDICT=$PLATFORM_PRE_VERDICT
NATIVE_PACKAGE_MANAGER=$PACKAGE_MANAGER
MISSING_CAPABILITIES=${MISSING_CAPABILITIES:-NONE}
MISSING_PROVIDER_PLAN=${MISSING_PROVIDER_PLAN:-NONE}
REQUESTED_PACKAGES=${REQUESTED_PACKAGES:-NONE}

===== SUMMARY =====
HOSTNAME=$HOSTNAME_NOW
RUN_MODE=$RUN_MODE
DECISION=$DECISION
R2_ACCEPTANCE=$R2_ACCEPTANCE

ROOT_GATE=$ROOT_GATE
TOOL_MISSING=${TOOL_MISSING:-NONE}
TOOL_GATE=$TOOL_GATE
UCI_GATE=$UCI_GATE

R1_DOWNLOAD_GATE=$R1_DOWNLOAD_GATE
R1_SHA256=$R1_SHA
EXPECTED_R1_SHA256=$EXPECTED_R1_SHA
R1_SHA_GATE=$R1_SHA_GATE
R1_PRE_RC=$R1_PRE_RC
R1_PRE_GATE=$R1_PRE_GATE
PLATFORM_PRE_VERDICT=$PLATFORM_PRE_VERDICT
NATIVE_PACKAGE_MANAGER=$PACKAGE_MANAGER
DEPENDENCY_PLAN_GATE=$DEPENDENCY_PLAN_GATE
DEPENDENCY_PLAN_UNRESOLVED_COUNT=$PLAN_UNRESOLVED
REQUESTED_PACKAGE_COUNT=$REQUESTED_COUNT
REQUESTED_PACKAGES=${REQUESTED_PACKAGES:-NONE}
DECISION_GATE=$DECISION_GATE

OVERLAY_CACHE_PATH=$OVERLAY_CACHE
OVERLAY_DOWNLOAD_GATE=$OVERLAY_DOWNLOAD_GATE
OVERLAY_SHA256=$OVERLAY_SHA
EXPECTED_OVERLAY_SHA256=$EXPECTED_OVERLAY_SHA
OVERLAY_SHA_GATE=$OVERLAY_SHA_GATE
OVERLAY_SUM_DOWNLOAD_GATE=$OVERLAY_SUM_DOWNLOAD_GATE
PUBLISHED_SHA256=${PUBLISHED_SHA:-N/A}
PUBLISHED_SHA_GATE=$PUBLISHED_SHA_GATE

OVERLAY_EXTRACTED_PATH=$OVERLAY_DIR
EXTRACT_GATE=$EXTRACT_GATE
MANIFEST_SHA256=$MANIFEST_SHA
EXPECTED_MANIFEST_SHA256=$EXPECTED_MANIFEST_SHA
MANIFEST_GATE=$MANIFEST_GATE
OVERLAY_FILE_COUNT=$FILE_COUNT
OVERLAY_BAD_COUNT=$BAD_COUNT
PAYLOAD_GATE=$PAYLOAD_GATE

LOCK_GATE=$LOCK_GATE
PREIMAGE_PATH=$PREIMAGE_OUT
PREIMAGE_GATE=$PREIMAGE_GATE
REPOSITORY_GATE=$REPOSITORY_GATE
PACKAGE_AVAILABILITY_GATE=$PACKAGE_AVAILABILITY_GATE
NEW_REQUESTED_PACKAGES=${NEW_REQUESTED_PACKAGES:-NONE}
PACKAGE_INSTALL_GATE=$PACKAGE_INSTALL_GATE

R1_POST_GATE=$R1_POST_GATE
PLATFORM_POST_VERDICT=${POST_VERDICT:-N/A}
POST_CAPABILITY_PASS=${POST_CAP_PASS:-N/A}
POST_CAPABILITY_FAIL=${POST_CAP_FAIL:-N/A}
OVERLAY_PREFLIGHT_GATE=$OVERLAY_PREFLIGHT_GATE
NETWORK_SAFETY_GATE=$NETWORK_SAFETY_GATE

PACKAGE_UPDATE_EXECUTED=$PACKAGE_UPDATE_EXECUTED
PACKAGE_INSTALL_EXECUTED=$PACKAGE_INSTALL_EXECUTED
PACKAGE_MUTATION=$PACKAGE_MUTATION
OVERLAY_APPLY_EXECUTED=$OVERLAY_APPLY_EXECUTED
GENERIC_NETWORK_CONFIG_MUTATION=NO_BY_INSTALLER
GENERIC_FIREWALL_CONFIG_MUTATION=NO_BY_INSTALLER
GENERIC_DHCP_CONFIG_MUTATION=NO_BY_INSTALLER
EXPLICIT_SERVICE_RELOAD=NO
EXPLICIT_SERVICE_RESTART=NO
PACKAGE_MANAGER_MAINTAINER_SCRIPTS=POSSIBLE
PERSISTENT_CONFIG_MUTATION=$PERSISTENT_CONFIG_MUTATION

ROLLBACK=$ROLLBACK
ROLLBACK_GATE=$ROLLBACK_GATE

NEXT_IF_PASS=$(if [ "$R2_ACCEPTANCE" = CLOSED_PASS ]; then echo DESIGN_INSTALL1_R3_DEPLOY_ZERO_PROFILE; else echo COMPLETE_R2_DEPENDENCY_INSTALL; fi)
RESULT=$RESULT
REASON=$REASON
===== END SUMMARY =====
EOF_SUMMARY

[ "$RESULT" = PASS ]
