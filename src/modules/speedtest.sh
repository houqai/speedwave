#!/bin/bash
#
# speedtest.sh — SpeedWave module: run an internet speed test on this server.
#
# Uses the official Ookla Speedtest CLI (static binary, no apt repo needed). If
# that can't be fetched, falls back to the Python speedtest-cli. Sourced into
# install_remnawave.sh: reuses COLOR_*, msg_*, print_header, reading.

ST_BIN="/usr/local/bin/speedtest"
ST_VER="1.2.0"

st_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l)        echo "armhf" ;;
        armv6l)        echo "armel" ;;
        *)             echo "" ;;
    esac
}

# Install the Ookla CLI to $ST_BIN (idempotent). Returns 1 if it can't.
st_install_ookla() {
    [ -x "$ST_BIN" ] && return 0
    local arch; arch="$(st_arch)"
    [ -z "$arch" ] && return 1
    command -v tar >/dev/null 2>&1 || return 1
    local url="https://install.speedtest.net/app/cli/ookla-speedtest-${ST_VER}-linux-${arch}.tgz"
    local tmp; tmp="$(mktemp -d)" || return 1
    msg_info "${LANG[ST_INSTALL]:-Installing Ookla Speedtest CLI...}"
    if curl -fsSL "$url" -o "$tmp/st.tgz" 2>/dev/null && tar -xzf "$tmp/st.tgz" -C "$tmp" speedtest 2>/dev/null; then
        install -m 0755 "$tmp/speedtest" "$ST_BIN" 2>/dev/null
        rm -rf "$tmp"
        [ -x "$ST_BIN" ] && return 0
    fi
    rm -rf "$tmp"
    return 1
}

run_speedtest() {
    print_header
    printf "\n  %b%s%b\n" "$COLOR_CORAL_B" "${LANG[ST_TITLE]:-Internet speed test}" "$COLOR_RESET"
    printf "  %b%s%b\n\n" "$COLOR_DIM" "${LANG[ST_SUBTITLE]:-Measures this server download/upload and ping}" "$COLOR_RESET"

    if st_install_ookla; then
        msg_info "${LANG[ST_RUNNING]:-Running speed test (this takes ~30s)...}"
        echo
        "$ST_BIN" --accept-license --accept-gdpr
        return 0
    fi

    # Fallback: Python speedtest-cli
    msg_warn "${LANG[ST_FALLBACK]:-Ookla CLI unavailable, trying speedtest-cli...}"
    if ! command -v speedtest-cli >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y speedtest-cli >/dev/null 2>&1 || true
    fi
    if command -v speedtest-cli >/dev/null 2>&1; then
        msg_info "${LANG[ST_RUNNING]:-Running speed test (this takes ~30s)...}"
        echo
        speedtest-cli
    else
        msg_err "${LANG[ST_FAIL]:-Could not install a speed-test tool. Check internet/DNS.}"
        return 1
    fi
}
