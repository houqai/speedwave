#!/bin/bash
#
# rw_core.sh — speedwave module: build & update the remnanode Xray
# core ("rw-core") from source.
#
# Inside the remnawave/node image the proxy engine is XTLS/Xray-core, installed at
# /usr/local/bin/xray with a symlink rw-core -> xray, launched by supervisord as
# `/usr/local/bin/rw-core`. This module builds the LATEST Xray-core release from
# source (Go) and bind-mounts the resulting binary over /usr/local/bin/xray via a
# docker-compose.override.yml, then recreates the node. It tracks the built version
# and can rebuild only when upstream has a newer release. All build artifacts (Go
# toolchain, sources, caches) are removed afterwards so nothing lingers on the SSD.
#
# Sourced into install_remnawave.sh: reuses COLOR_*, msg_*, menu_*, reading,
# question, spinner, print_header.

RW_REPO="https://github.com/XTLS/Xray-core"
RW_BRANCH="main"

# Locate the directory whose docker-compose runs the remnanode container.
rw_node_dir() {
    local d
    for d in /opt/remnanode /opt/remnawave; do
        if [ -f "$d/docker-compose.yml" ] && grep -q "remnanode" "$d/docker-compose.yml" 2>/dev/null; then
            echo "$d"; return 0
        fi
    done
    return 1
}

# Latest commit on the default branch — i.e. the newest source changes, not a
# packaged release. Returns a short commit SHA. We build this exact commit so the
# node runs bleeding-edge Xray-core straight from the repository.
rw_latest_ref() {
    git ls-remote "$RW_REPO" "refs/heads/${RW_BRANCH}" 2>/dev/null | awk 'NR==1{print substr($1,1,12)}'
}

# .rw-core-version holds the built commit SHA on line 1 and its commit date on
# line 2. Comparisons use the SHA only; the date is shown to the user as a
# human-readable freshness indicator.
rw_installed_ver() {
    local dir="$1"
    [ -f "$dir/.rw-core-version" ] && sed -n '1p' "$dir/.rw-core-version" || echo ""
}

rw_installed_date() {
    local dir="$1"
    [ -f "$dir/.rw-core-version" ] && sed -n '2p' "$dir/.rw-core-version" || echo ""
}

rw_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "" ;;
    esac
}

# Building Xray from source needs the Go toolchain (~250 MB unpacked), the
# sources and the build/module caches. Require a safe margin of free space on
# the build filesystem (/var/tmp) and try to reclaim apt cache first if low.
# RW_MIN_FREE_MB is the floor below which we refuse to start.
RW_MIN_FREE_MB=1200

rw_free_mb() {
    # Free megabytes on the filesystem backing the given path.
    df -Pm "$1" 2>/dev/null | awk 'NR==2{print $4}'
}

rw_precheck_space() {
    local path="$1" free
    free="$(rw_free_mb "$path")"
    [ -z "$free" ] && return 0   # can't tell — don't block
    if [ "$free" -lt "$RW_MIN_FREE_MB" ]; then
        msg_warn "$(printf "${LANG[RW_LOWDISK]:-Low disk space: %s MB free, ~%s MB needed. Cleaning apt cache...}" "$free" "$RW_MIN_FREE_MB")"
        apt-get clean >/dev/null 2>&1 || true
        free="$(rw_free_mb "$path")"
    fi
    if [ -n "$free" ] && [ "$free" -lt "$RW_MIN_FREE_MB" ]; then
        msg_err "$(printf "${LANG[RW_LOWDISK_ABORT]:-Not enough free disk space to build (%s MB free, ~%s MB needed). Free up space and retry.}" "$free" "$RW_MIN_FREE_MB")"
        return 1
    fi
    return 0
}

# Download the Go toolchain version required by Xray into $1; echoes nothing, sets
# global RW_GO_BIN. Caller removes the temp dir afterwards.
rw_fetch_go() {
    local tmp="$1" arch="$2"
    local gv
    gv="$(curl -fsSL 'https://go.dev/VERSION?m=text' 2>/dev/null | head -1)"   # e.g. go1.26.4
    [ -z "$gv" ] && { msg_err "${LANG[RW_GO_FAIL]:-Could not determine latest Go version}"; return 1; }
    local url="https://go.dev/dl/${gv}.linux-${arch}.tar.gz"
    msg_info "$(printf "${LANG[RW_GO_DL]:-Downloading Go toolchain (%s)...}" "$gv")"
    curl -fsSL "$url" -o "$tmp/go.tgz" || { msg_err "${LANG[RW_GO_FAIL]:-Go download failed}"; return 1; }
    tar -C "$tmp" -xzf "$tmp/go.tgz" || { msg_err "${LANG[RW_GO_FAIL]:-Go unpack failed}"; return 1; }
    rm -f "$tmp/go.tgz"
    RW_GO_BIN="$tmp/go/bin/go"
    [ -x "$RW_GO_BIN" ]
}

# Build the latest Xray-core source into $tmp/xray. Clones the default branch HEAD
# (newest changes) and records the exact built commit in the global RW_BUILT_REF.
# Everything (sources, caches, toolchain) lives under $tmp so a single rm -rf
# cleans the disk.
RW_BUILT_REF=""
RW_BUILT_DATE=""
rw_build() {
    local tmp="$1" arch="$2"
    local log="$tmp/build.log"

    rw_fetch_go "$tmp" "$arch" || return 1

    msg_info "${LANG[RW_CLONING]:-Cloning latest Xray-core source...}"
    git clone --depth 1 --branch "$RW_BRANCH" "$RW_REPO" "$tmp/src" >"$log" 2>&1 || {
        msg_err "${LANG[RW_CLONE_FAIL]:-git clone failed}"; tail -n 5 "$log"; return 1; }

    # The exact commit we are about to build (full source state) + its date.
    RW_BUILT_REF="$(git -C "$tmp/src" rev-parse --short=12 HEAD 2>/dev/null)"
    RW_BUILT_DATE="$(git -C "$tmp/src" log -1 --format=%cd --date=short HEAD 2>/dev/null)"

    export GOROOT="$tmp/go" GOPATH="$tmp/gopath" GOCACHE="$tmp/gocache" GOMODCACHE="$tmp/gomod"
    export PATH="$tmp/go/bin:$PATH" CGO_ENABLED=0

    msg_info "${LANG[RW_BUILDING]:-Building (this can take a few minutes)...}"
    ( cd "$tmp/src" && "$RW_GO_BIN" build -o "$tmp/xray" -trimpath -buildvcs=false \
        -ldflags="-s -w -buildid=" ./main ) >>"$log" 2>&1 &
    local pid=$!
    spinner "$pid" "${LANG[RW_BUILDING]:-Building...}"
    wait "$pid" || { msg_err "${LANG[RW_BUILD_FAIL]:-Build failed}"; tail -n 8 "$log"; return 1; }

    [ -x "$tmp/xray" ] || { msg_err "${LANG[RW_BUILD_FAIL]:-Build produced no binary}"; return 1; }
    # Sanity-check the binary runs
    "$tmp/xray" version >/dev/null 2>&1 || { msg_err "${LANG[RW_BUILD_FAIL]:-Built binary does not run}"; return 1; }
    return 0
}

# Wire the built core into the node and recreate it.
rw_install_into_node() {
    local dir="$1" tmp="$2" tag="$3"
    install -m 0755 "$tmp/xray" "$dir/rw-core" || { msg_err "${LANG[RW_BUILD_FAIL]:-install failed}"; return 1; }

    # Bind-mount our binary over the image's /usr/local/bin/xray (rw-core -> xray).
    # An override file keeps the user's main docker-compose.yml untouched.
    cat > "$dir/docker-compose.override.yml" <<EOF
# Managed by speedwave (rw-core updater). Mounts a locally built
# Xray-core over the image core. Remove this file to revert to the bundled core.
services:
  remnanode:
    volumes:
      - $dir/rw-core:/usr/local/bin/xray:ro
EOF

    # Line 1: commit SHA (used for comparisons). Line 2: commit date (display).
    printf '%s\n%s\n' "${tag:-$RW_BUILT_REF}" "$RW_BUILT_DATE" > "$dir/.rw-core-version"

    msg_info "${LANG[RW_RESTARTING]:-Recreating node container...}"
    ( cd "$dir" && docker compose up -d --force-recreate remnanode ) >/dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"
}

rw_cleanup() {
    local tmp="$1"
    [ -n "$tmp" ] && [ -d "$tmp" ] || return 0
    chmod -R u+w "$tmp" 2>/dev/null
    rm -rf "$tmp"
}

# Full update flow: build the latest source and install it.
rw_update_to() {
    local dir ref arch tmp
    dir="$(rw_node_dir)" || { msg_err "${LANG[RW_NO_NODE]:-remnanode is not installed on this server.}"; return 1; }
    arch="$(rw_arch)" || true
    [ -z "$arch" ] && { msg_err "$(printf "${LANG[RW_ARCH]:-Unsupported architecture: %s}" "$(uname -m)")"; return 1; }
    command -v docker >/dev/null 2>&1 || { msg_err "${LANG[RW_NO_DOCKER]:-Docker is not installed.}"; return 1; }
    command -v git >/dev/null 2>&1 || { msg_err "git is required"; return 1; }

    ref="$(rw_latest_ref)"   # informational; actual built commit captured during build

    echo
    msg_info "$(printf "${LANG[RW_TARGET]:-Target: latest source %s   node dir: %s}" "${ref:-HEAD}" "$dir")"

    # Build under a disk-backed temp dir (not /tmp which may be tmpfs/RAM).
    tmp="$(mktemp -d -p /var/tmp rw-core.XXXXXX)" || { msg_err "mktemp failed"; return 1; }
    if ! rw_precheck_space "$tmp"; then rw_cleanup "$tmp"; return 1; fi
    if rw_build "$tmp" "$arch" && rw_install_into_node "$dir" "$tmp" "$RW_BUILT_REF"; then
        rw_cleanup "$tmp"
        echo
        msg_ok "$(printf "${LANG[RW_DONE]:-rw-core rebuilt from source (commit %s, %s). Build files cleaned up.}" "$RW_BUILT_REF" "${RW_BUILT_DATE:-?}")"
        return 0
    fi
    rw_cleanup "$tmp"
    msg_err "${LANG[RW_FAILED]:-rw-core update failed (node left unchanged).}"
    return 1
}

rw_check_update() {
    local dir cur curdate latest
    dir="$(rw_node_dir)" || { msg_err "${LANG[RW_NO_NODE]:-remnanode is not installed on this server.}"; return 1; }
    cur="$(rw_installed_ver "$dir")"
    curdate="$(rw_installed_date "$dir")"
    latest="$(rw_latest_ref)"
    [ -z "$latest" ] && { msg_err "${LANG[RW_NO_TAG]:-Could not determine the latest version.}"; return 1; }

    local curshow="${cur:-${LANG[RW_STOCK]:-stock (image bundled)}}"
    [ -n "$cur" ] && [ -n "$curdate" ] && curshow="$cur ($curdate)"
    echo
    msg_info "$(printf "${LANG[RW_CUR]:-Installed: %s}" "$curshow")"
    msg_info "$(printf "${LANG[RW_LATEST]:-Latest source commit: %s}" "$latest")"

    if [ -n "$cur" ] && [ "$cur" = "$latest" ]; then
        echo; msg_ok "${LANG[RW_UPTODATE]:-Already on the latest source commit.}"
        return 0
    fi
    echo
    local ans
    reading "${LANG[RW_REBUILD_CONFIRM]:-Newer source is available. Rebuild now? (y/n):}" ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] && rw_update_to
}

rw_revert() {
    local dir
    dir="$(rw_node_dir)" || { msg_err "${LANG[RW_NO_NODE]:-remnanode is not installed on this server.}"; return 1; }
    [ -f "$dir/docker-compose.override.yml" ] || { msg_warn "${LANG[RW_NOTHING]:-No custom core is active.}"; return 0; }
    rm -f "$dir/docker-compose.override.yml" "$dir/rw-core" "$dir/.rw-core-version"
    msg_info "${LANG[RW_RESTARTING]:-Recreating node container...}"
    ( cd "$dir" && docker compose up -d --force-recreate remnanode ) >/dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"
    echo; msg_ok "${LANG[RW_REVERTED]:-Reverted to the image-bundled core.}"
}

show_rw_core_menu() {
    print_header
    printf "\n  %b%s%b\n" "$COLOR_CORAL_B" "${LANG[RW_TITLE]:-Node core (rw-core / Xray)}" "$COLOR_RESET"
    printf "  %b%s%b\n"   "$COLOR_DIM"     "${LANG[RW_SUBTITLE]:-Build the latest Xray-core from source for remnanode}" "$COLOR_RESET"

    menu_head "${LANG[RW_GROUP]:-Actions}"
    menu_item 1 "${LANG[RW_M_UPDATE]:-Update to latest (build from source)}"
    menu_item 2 "${LANG[RW_M_CHECK]:-Check for update (rebuild only if newer)}"
    menu_item 3 "${LANG[RW_M_REVERT]:-Revert to bundled core}"
    echo
    menu_item 0 "${LANG[NA_BACK]:-Back}"
    echo
}

manage_rw_core() {
    while true; do
        show_rw_core_menu
        reading "${LANG[NA_PROMPT]:-Select option:}" RW_OPTION
        case "$RW_OPTION" in
            1) rw_update_to "" ;;
            2) rw_check_update ;;
            3) rw_revert ;;
            0) return 0 ;;
            *) msg_warn "${LANG[NA_INVALID]:-Invalid choice.}"; sleep 1; continue ;;
        esac
        echo
        reading "${LANG[NA_CONTINUE]:-Press Enter to return to the menu}" _rw_dummy
    done
}
