#!/bin/bash
#
# traffic_shaper.sh — SpeedWave module: per-user traffic shaper (eBPF + EDT).
#
# Front-end (Claude-coral styled) for an eBPF/EDT bandwidth limiter. The kernel
# engine (shaper.bpf.c) and its bpftool-based controller (shaper_ctrl.py) are
# vendored from DonMatteoVPN/Reshala-Remnawave-Bedolaga (GPL) under
# src/traffic-shaper/ and used unchanged; this module is a full rewrite of the
# original bash front-end (traffic_limiter.sh) onto SpeedWave's helpers/palette.
#
# Limits download/upload speed PER user IP on the ports the node (Xray) listens
# on, so a single user can't saturate the channel. Works on kernel 5.4+.
#
# Sourced into install_remnawave.sh: reuses COLOR_*, msg_*, menu_*, reading,
# spinner, print_header, download_with_mirrors().

# Vendored engine location (downloaded on demand) + runtime paths.
TS_BASE="${LANG_BASE_URL%/lang}/traffic-shaper"
TS_DIR="${DIR_REMNAWAVE}traffic-shaper"
TS_CONFIG_DIR="/etc/speedwave/traffic_shaper"
TS_BPF_SRC="${TS_DIR}/shaper.bpf.c"
TS_BPF_OBJ="${TS_CONFIG_DIR}/shaper.bpf.o"
TS_CTRL_PY="${TS_DIR}/shaper_ctrl.py"
TS_SERVICE_NAME="speedwave-traffic-shaper.service"
TS_SERVICE_PATH="/etc/systemd/system/${TS_SERVICE_NAME}"
TS_PIN_DIR="/sys/fs/bpf/speedwave"
TS_MAPS_DIR="${TS_PIN_DIR}/maps"
TS_RULES="${TS_CONFIG_DIR}/rules.json"
TS_WHITELIST="${TS_CONFIG_DIR}/whitelist.txt"
TS_IFACE_CONF="${TS_CONFIG_DIR}/iface.conf"

IFACE=""

# ── Download the eBPF source + Python controller into $TS_DIR ──────────────────
ts_fetch() {
    local f
    mkdir -p "$TS_DIR"
    for f in shaper.bpf.c shaper_ctrl.py; do
        # .c/.py have no bash shebang → use the "raw" validator type.
        if ! download_with_mirrors "${TS_BASE}/${f}" "${TS_DIR}/${f}" "raw"; then
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL "${TS_BASE}/${f}" -o "${TS_DIR}/${f}" 2>/dev/null
            elif command -v wget >/dev/null 2>&1; then
                wget -q "${TS_BASE}/${f}" -O "${TS_DIR}/${f}" 2>/dev/null
            fi
        fi
        [ -s "${TS_DIR}/${f}" ] || { msg_err "${LANG[TS_FETCH_FAIL]:-Failed to download traffic-shaper engine files.}"; return 1; }
    done
    return 0
}

# Thin wrapper around the controller with our pinned paths.
ts_py() { python3 "$TS_CTRL_PY" --pin-dir "$TS_MAPS_DIR" --rules-file "$TS_RULES" "$@"; }

ts_active() { systemctl is-active --quiet "$TS_SERVICE_NAME"; }
ts_pause()  { echo; reading "${LANG[TS_ENTER]:-Press Enter to continue}" _ts_dummy; }

# ── Small input helpers (replace Reshala ask_* on top of reading) ─────────────
# ts_ask_int <prompt> <min> <max> <default> ; echoes value, returns 1 on 'q'
ts_ask_int() {
    local prompt="$1" min="$2" max="$3" def="$4" val
    while true; do
        reading "$prompt [$def]:" val
        [ -z "$val" ] && val="$def"
        [[ "$val" == "q" || "$val" == "Q" ]] && return 1
        if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge "$min" ] && [ "$val" -le "$max" ]; then
            echo "$val"; return 0
        fi
        msg_warn "$(printf "${LANG[TS_BAD_INT]:-Enter a whole number %s..%s}" "$min" "$max")" >&2
    done
}

# ts_ask_float <prompt> <min> <max> <default> ; echoes value, returns 1 on 'q'
ts_ask_float() {
    local prompt="$1" min="$2" max="$3" def="$4" val
    while true; do
        reading "$prompt [$def]:" val
        [ -z "$val" ] && val="$def"
        [[ "$val" == "q" || "$val" == "Q" ]] && return 1
        if [[ "$val" =~ ^[0-9]+([.][0-9]+)?$ ]] && \
           awk -v v="$val" -v a="$min" -v b="$max" 'BEGIN{exit !(v>=a && v<=b)}'; then
            echo "$val"; return 0
        fi
        msg_warn "$(printf "${LANG[TS_BAD_FLOAT]:-Enter a number %s..%s}" "$min" "$max")" >&2
    done
}

# ts_yesno <prompt> [default y|n] ; returns 0 for yes
ts_yesno() {
    local prompt="$1" def="${2:-y}" ans
    reading "$prompt (y/n) [$def]:" ans
    [ -z "$ans" ] && ans="$def"
    [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# Pick the network interface (auto if single), echoes name, returns 1 if none.
ts_select_iface() {
    local ifaces=() i n
    mapfile -t ifaces < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$')
    n=${#ifaces[@]}
    [ "$n" -eq 0 ] && return 1
    if [ "$n" -eq 1 ]; then echo "${ifaces[0]}"; return 0; fi
    {
        menu_head "${LANG[TS_PICK_IFACE]:-Select network interface}"
        for i in "${!ifaces[@]}"; do menu_item "$((i+1))" "${ifaces[$i]}"; done
    } >&2
    local sel
    sel="$(ts_ask_int "${LANG[TS_IFACE_NUM]:-Interface number}" 1 "$n" 1)" || return 1
    echo "${ifaces[$((sel-1))]}"
}

# ── Dependencies / compile ────────────────────────────────────────────────────
ts_ensure_deps() {
    msg_info "${LANG[TS_DEPS]:-Checking eBPF dependencies...}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y clang llvm libbpf-dev python3 bc kmod bpftool jq iproute2 >/dev/null 2>&1 || true

    if ! command -v bpftool >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y bpftool >/dev/null 2>&1 || true
        if ! command -v bpftool >/dev/null 2>&1; then
            if uname -r | grep -qi xanmod; then
                apt-get install -y linux-tools-xanmod linux-cloud-tools-xanmod \
                    "linux-tools-$(uname -r)" "linux-cloud-tools-$(uname -r)" >/dev/null 2>&1 || true
            else
                apt-get install -y linux-tools-common linux-tools-generic \
                    "linux-tools-$(uname -r)" >/dev/null 2>&1 || true
            fi
        fi
        # Symlink bpftool if it sits only under /usr/lib/linux-tools/...
        local p
        for p in "/usr/lib/linux-tools/$(uname -r)/bpftool" \
                 "/usr/lib/linux-tools-generic/bpftool" \
                 "/usr/sbin/bpftool" "/usr/local/sbin/bpftool"; do
            [ -x "$p" ] && { ln -sf "$p" /usr/local/bin/bpftool 2>/dev/null || true; break; }
        done
    fi

    local kh="linux-headers-$(uname -r)"
    if ! dpkg -s "$kh" >/dev/null 2>&1; then
        msg_info "$(printf "${LANG[TS_HEADERS]:-Installing kernel headers %s...}" "$kh")"
        apt-get install -y "$kh" >/dev/null 2>&1 || true
    fi
    sysctl -w kernel.unprivileged_bpf_disabled=0 >/dev/null 2>&1 || true

    command -v clang >/dev/null 2>&1 || { msg_err "${LANG[TS_NO_CLANG]:-clang is not installed.}"; return 1; }
    command -v bpftool >/dev/null 2>&1 || { msg_err "${LANG[TS_NO_BPFTOOL]:-bpftool not found. Install it: apt install bpftool}"; return 1; }
    return 0
}

ts_compile_bpf() {
    msg_info "${LANG[TS_COMPILING]:-Compiling the eBPF program...}"
    mkdir -p "$TS_CONFIG_DIR"
    local inc="" p
    for p in "/usr/include/$(uname -m)-linux-gnu" \
             "/usr/include/x86_64-linux-gnu" \
             "/usr/include/aarch64-linux-gnu"; do
        [ -d "$p/asm" ] && { inc="-I$p"; break; }
    done
    if ! clang -O2 -g -target bpf $inc -c "$TS_BPF_SRC" -o "$TS_BPF_OBJ" 2>/tmp/ts_clang.log; then
        msg_err "${LANG[TS_COMPILE_FAIL]:-eBPF compilation failed (check kernel headers).}"
        tail -n 5 /tmp/ts_clang.log 2>/dev/null
        return 1
    fi
    msg_ok "${LANG[TS_COMPILED]:-Compilation succeeded.}"
    return 0
}

# Remove old qdiscs/service/pinned maps so the engine starts clean.
ts_cleanup_engine() {
    systemctl stop "$TS_SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$TS_SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$TS_SERVICE_PATH"
    systemctl daemon-reload >/dev/null 2>&1 || true
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$' | while read -r ifc; do
        tc qdisc del dev "$ifc" root   >/dev/null 2>&1 || true
        tc qdisc del dev "$ifc" clsact >/dev/null 2>&1 || true
    done
    rm -rf "$TS_PIN_DIR" >/dev/null 2>&1 || true
}

# Emit the systemd unit (oneshot, RemainAfterExit) to stdout. Needs $IFACE set.
ts_generate_service() {
    local pin_progs="${TS_PIN_DIR}/progs"
    local pin_maps="${TS_MAPS_DIR}"
    local bpftool_path tc_path py_path
    bpftool_path="$(command -v bpftool 2>/dev/null || echo /usr/local/bin/bpftool)"
    tc_path="$(command -v tc 2>/dev/null || echo /sbin/tc)"
    py_path="$(command -v python3 2>/dev/null || echo /usr/bin/python3)"

    cat <<EOF
[Unit]
Description=SpeedWave eBPF Traffic Shaper (Multi-Rule)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes

# Preparation
ExecStartPre=-/sbin/sysctl -w kernel.unprivileged_bpf_disabled=0
ExecStartPre=-${tc_path} qdisc del dev ${IFACE} root
ExecStartPre=-${tc_path} qdisc del dev ${IFACE} clsact
ExecStartPre=-/bin/bash -c "/bin/rm -rf ${TS_PIN_DIR}/*"
ExecStartPre=-/bin/rm -rf ${TS_PIN_DIR}
ExecStartPre=/bin/mkdir -p ${pin_progs} ${pin_maps}

# Load programs + pin maps
ExecStartPre=${bpftool_path} --debug prog loadall ${TS_BPF_OBJ} ${pin_progs} type classifier pinmaps ${pin_maps}

# Attach shaper: download via egress, upload via ingress
ExecStartPre=${tc_path} qdisc add dev ${IFACE} root fq
ExecStartPre=${tc_path} qdisc add dev ${IFACE} clsact
ExecStartPre=/bin/bash -c '\\
    PROG_DOWN=\$(ls ${pin_progs} | grep "down" | head -n 1); \\
    if [ -n "\$PROG_DOWN" ]; then \\
        ${tc_path} filter add dev ${IFACE} egress bpf direct-action pinned ${pin_progs}/\$PROG_DOWN; \\
    else echo "ERROR: down program not found" >&2; exit 1; fi'
ExecStartPre=/bin/bash -c '\\
    PROG_UP=\$(ls ${pin_progs} | grep "up" | head -n 1); \\
    if [ -n "\$PROG_UP" ]; then \\
        ${tc_path} filter add dev ${IFACE} ingress bpf direct-action pinned ${pin_progs}/\$PROG_UP; \\
    else echo "ERROR: up program not found" >&2; exit 1; fi'

# Restore saved rules + whitelist
ExecStart=${py_path} ${TS_CTRL_PY} --pin-dir ${pin_maps} --rules-file ${TS_RULES} restore
ExecStartPost=-${py_path} ${TS_CTRL_PY} --pin-dir ${pin_maps} whitelist-sync --file ${TS_WHITELIST}

# Teardown
ExecStop=-/bin/bash -c "/bin/rm -rf ${TS_PIN_DIR}/*"
ExecStop=-/bin/rm -rf ${TS_PIN_DIR}
ExecStop=-${tc_path} qdisc del dev ${IFACE} root
ExecStop=-${tc_path} qdisc del dev ${IFACE} clsact

[Install]
WantedBy=multi-user.target
EOF
}

# Ensure the engine is compiled, installed and running for $IFACE.
ts_ensure_engine() {
    local iface="$1"
    if ts_active && [ -e "${TS_MAPS_DIR}/config_map" ]; then return 0; fi

    ts_ensure_deps   || return 1
    ts_cleanup_engine
    ts_compile_bpf   || return 1

    mkdir -p "$TS_CONFIG_DIR"
    echo "IFACE=\"${iface}\"" > "$TS_IFACE_CONF"
    IFACE="$iface"

    systemctl unmask "$TS_SERVICE_NAME" >/dev/null 2>&1 || true
    ts_generate_service > "$TS_SERVICE_PATH"
    systemctl daemon-reload
    systemctl enable "$TS_SERVICE_NAME" >/dev/null 2>&1 || true
    msg_info "${LANG[TS_STARTING]:-Starting the eBPF engine...}"
    systemctl restart "$TS_SERVICE_NAME"

    local timeout=15
    while [ ! -e "${TS_MAPS_DIR}/config_map" ] && [ "$timeout" -gt 0 ]; do
        sleep 1; timeout=$((timeout-1))
    done
    if [ ! -e "${TS_MAPS_DIR}/config_map" ]; then
        msg_err "${LANG[TS_ENGINE_FAIL]:-Engine failed to start (config_map not created).}"
        msg_err "$(printf "${LANG[TS_ENGINE_DIAG]:-Diagnose: journalctl -u %s --no-pager -n 30}" "$TS_SERVICE_NAME")"
        uname -r | grep -qi xanmod && msg_warn "${LANG[TS_XANMOD_HINT]:-XanMod detected — try: apt install linux-tools-xanmod linux-cloud-tools-xanmod}"
        return 1
    fi
    msg_ok "${LANG[TS_ENGINE_OK]:-Engine is up.}"
    return 0
}

# ── Reference helpers (coral-styled, concise) ─────────────────────────────────
ts_speed_reference() {
    menu_head "${LANG[TS_REF_TITLE]:-Speed reference (per user)}"
    printf "  %bVoIP/calls%b      0.1–1 MB/s\n"        "$COLOR_GRAY" "$COLOR_RESET"
    printf "  %bMusic/Telegram%b  0.3–0.5 MB/s\n"      "$COLOR_GRAY" "$COLOR_RESET"
    printf "  %bYouTube 1080p%b   2–3 MB/s\n"          "$COLOR_GRAY" "$COLOR_RESET"
    printf "  %b4K/Netflix%b      6–12 MB/s\n"         "$COLOR_GRAY" "$COLOR_RESET"
    printf "  %b%s%b\n" "$COLOR_CORAL" "${LANG[TS_REF_REC]:-Recommended: 3-5 MB/s is comfortable for most.}" "$COLOR_RESET"
}

ts_show_listening_ports() {
    menu_head "${LANG[TS_LISTEN_TITLE]:-Listening ports on this server}"
    msg_info "${LANG[TS_LISTEN_HINT]:-xray/v2ray = VPN port (shape it). sshd = console (leave it).}"
    ss -tulnp 2>/dev/null | grep LISTEN | while read -r line; do
        local addr port proc
        addr=$(echo "$line" | awk '{print $5}')
        port="${addr##*:}"
        proc=$(echo "$line" | grep -oE '\("[^"]*"' | head -n1 | tr -d '"(')
        [ -z "$proc" ] && proc="?"
        printf "    %b%s%b → %s\n" "$COLOR_YELLOW" "$port" "$COLOR_RESET" "$proc"
    done | sort -u
}

# ── Menu actions ──────────────────────────────────────────────────────────────
ts_list_rules() {
    print_header
    printf "\n  %b%s%b\n" "$COLOR_CORAL_B" "${LANG[TS_RULES_TITLE]:-Active rules}" "$COLOR_RESET"
    echo
    if ts_active; then
        ts_py rules 2>/dev/null || msg_warn "${LANG[TS_NO_RULES]:-No rules / engine not ready.}"
    else
        msg_warn "${LANG[TS_NOT_RUNNING]:-Shaper is not running.}"
    fi
}

ts_status() {
    if ! ts_active; then
        msg_warn "${LANG[TS_NOT_RUNNING]:-Shaper is not running.}"
        if ts_yesno "${LANG[TS_START_NOW]:-Start the shaper now?}" n; then
            systemctl start "$TS_SERVICE_NAME" && msg_ok "${LANG[TS_STARTED]:-Started.}"
        fi
        return
    fi
    print_header
    printf "\n  %b%s%b\n" "$COLOR_CORAL_B" "${LANG[TS_STATUS_TITLE]:-Shaper statistics}" "$COLOR_RESET"
    echo
    ts_py status 2>/dev/null
    echo
    if ts_yesno "${LANG[TS_STATUS_FULL]:-Show full per-IP list?}" n; then
        echo; ts_py status --full 2>/dev/null
    fi
}

ts_apply_wizard() {
    ts_ensure_deps || return

    # Step 0 — rule id
    print_header
    printf "\n  %b%s%b\n" "$COLOR_CORAL_B" "${LANG[TS_W_TITLE]:-Add / edit rule}" "$COLOR_RESET"
    if ts_active; then echo; ts_py rules 2>/dev/null || true; fi
    menu_head "${LANG[TS_W_RULEID]:-Rule ID (0..31). New = free number; existing = its ID.}"
    local rule_id; rule_id="$(ts_ask_int "${LANG[TS_W_RULEID_Q]:-Rule ID}" 0 31 0)" || return

    # Interface (only ask when engine not yet running)
    local iface
    if ts_active && [ -f "$TS_IFACE_CONF" ]; then
        iface="$(grep 'IFACE=' "$TS_IFACE_CONF" | cut -d'"' -f2)"
        msg_info "$(printf "${LANG[TS_W_IFACE_KEEP]:-Engine already running on %s.}" "$iface")"
    else
        iface="$(ip route 2>/dev/null | awk '/default/{print $5; exit}')"
        [ -z "$iface" ] && iface="$(ts_select_iface)" || true
        menu_head "${LANG[TS_W_IFACE]:-Network interface}"
        msg_info "$(printf "${LANG[TS_W_IFACE_DET]:-Detected main interface: %s}" "${iface:-?}")"
        if ! ts_yesno "$(printf "${LANG[TS_W_IFACE_OK]:-Use %s?}" "${iface:-?}")" y; then
            iface="$(ts_select_iface)" || return
        fi
    fi
    [ -z "$iface" ] && { msg_err "${LANG[TS_W_NOIFACE]:-No interface selected.}"; return; }

    # Step 2 — mode
    print_header
    menu_head "${LANG[TS_W_MODE]:-Shaping mode}"
    menu_item 1 "${LANG[TS_W_MODE1]:-Static — hard per-user limit (predictable)}"
    menu_item 2 "${LANG[TS_W_MODE2]:-Dynamic — burst then penalty (fair-use)}"
    menu_item 3 "${LANG[TS_W_MODE3]:-Shared — one pipe split across all users}"
    local mode; mode="$(ts_ask_int "${LANG[TS_W_MODE_Q]:-Mode}" 1 3 1)" || return

    # Step 3 — ports
    print_header
    ts_show_listening_ports
    echo
    msg_info "${LANG[TS_W_PORTS_HINT]:-Comma-separated ports (e.g. 443,8080) or 0 for all.}"
    local ports; reading "${LANG[TS_W_PORTS_Q]:-Ports (0 = all)} [0]:" ports
    [ -z "$ports" ] && ports="0"
    ports="$(echo "$ports" | tr -d ' ')"

    # Step 4 — speeds
    print_header
    local dflt=5
    if [ "$mode" = "3" ]; then
        dflt=100
        menu_head "${LANG[TS_W_SHARED_REF]:-Shared pool — set the total channel capacity (MB/s).}"
    else
        ts_speed_reference
    fi
    echo
    local down up; down="$(ts_ask_float "${LANG[TS_W_DOWN]:-Download (DL) MB/s}" 0.1 50000 "$dflt")" || return
    up="$(ts_ask_float "${LANG[TS_W_UP]:-Upload (UL) MB/s}" 0.1 50000 "$dflt")" || return

    local pen=0.5 burst=100 win=10 pensec=60
    if [ "$mode" = "2" ]; then
        menu_head "${LANG[TS_W_DYN]:-Dynamic: full speed up to quota in a window, then penalty speed.}"
        pen="$(ts_ask_float  "${LANG[TS_W_PEN]:-Penalty speed (MB/s, 0=block)}" 0 1000 0.5)"  || return
        burst="$(ts_ask_int  "${LANG[TS_W_BURST]:-Burst quota (MB)}" 1 50000 100)"            || return
        win="$(ts_ask_int    "${LANG[TS_W_WIN]:-Measurement window (sec)}" 1 3600 10)"        || return
        pensec="$(ts_ask_int "${LANG[TS_W_PENSEC]:-Penalty duration (sec)}" 0 86400 60)"      || return
    fi

    # Confirm
    print_header
    menu_head "${LANG[TS_W_CONFIRM]:-Review}"
    printf "    %-14s %s\n" "${LANG[TS_W_F_RULE]:-Rule #}"   "$rule_id"
    printf "    %-14s %s\n" "${LANG[TS_W_F_IFACE]:-Iface}"   "$iface"
    printf "    %-14s %s\n" "${LANG[TS_W_F_MODE]:-Mode}"     "$mode"
    printf "    %-14s %s\n" "${LANG[TS_W_F_PORTS]:-Ports}"   "$([ "$ports" = 0 ] && echo "${LANG[TS_W_ALLPORTS]:-ALL}" || echo "$ports")"
    printf "    %-14s %s\n" "${LANG[TS_W_F_DL]:-Download}"   "${down} MB/s"
    printf "    %-14s %s\n" "${LANG[TS_W_F_UL]:-Upload}"     "${up} MB/s"
    if [ "$mode" = "2" ]; then
        printf "    %-14s %s\n" "${LANG[TS_W_F_BURST]:-Burst}" "${burst} MB / ${win}s"
        printf "    %-14s %s\n" "${LANG[TS_W_F_PEN]:-Penalty}" "${pen} MB/s / ${pensec}s"
    fi
    echo
    ts_yesno "${LANG[TS_W_APPLY]:-Apply?}" y || return

    ts_ensure_engine "$iface" || return

    msg_info "$(printf "${LANG[TS_W_APPLYING]:-Applying rule #%s...}" "$rule_id")"
    ts_py set --rule-id "$rule_id" --mode "$mode" --ports "$ports" \
        --down "$down" --up "$up" --pen "$pen" --burst "$burst" \
        --win "$win" --pen-sec "$pensec"
}

ts_delete_rule() {
    print_header
    printf "\n  %b%s%b\n" "$COLOR_CORAL_B" "${LANG[TS_DEL_TITLE]:-Delete rule}" "$COLOR_RESET"
    echo
    ts_active && ts_py rules 2>/dev/null
    echo
    local rid; rid="$(ts_ask_int "${LANG[TS_DEL_Q]:-Rule ID to delete}" 0 31 0)" || return
    ts_yesno "$(printf "${LANG[TS_DEL_CONFIRM]:-Delete rule #%s?}" "$rid")" n || return
    ts_py delete --rule-id "$rid"
}

ts_restart() {
    msg_info "${LANG[TS_RESTART]:-Restarting the engine...}"
    [ -f "$TS_BPF_SRC" ] && ts_compile_bpf || true
    modprobe cls_bpf 2>/dev/null || true
    modprobe sch_fq  2>/dev/null || true
    systemctl unmask "$TS_SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$TS_SERVICE_NAME" && msg_ok "${LANG[TS_RESTARTED]:-Restarted.}"
}

ts_view_log() {
    print_header
    printf "\n  %b%s%b\n\n" "$COLOR_CORAL_B" "${LANG[TS_LOG_TITLE]:-Service log}" "$COLOR_RESET"
    journalctl -u "$TS_SERVICE_NAME" -n 50 --no-pager 2>/dev/null || msg_warn "${LANG[TS_NO_LOG]:-No log available.}"
}

ts_monitor() {
    command -v iftop >/dev/null 2>&1 || { apt-get install -y iftop >/dev/null 2>&1 || true; }
    command -v iftop >/dev/null 2>&1 || { msg_err "${LANG[TS_NO_IFTOP]:-iftop is not installed.}"; return; }
    local iface; iface="$(ts_select_iface)" || return
    msg_info "$(printf "${LANG[TS_MON]:-Monitoring %s (bytes). Q to quit.}" "$iface")"
    sleep 1
    iftop -B -n -N -i "$iface"
}

ts_edit_whitelist() {
    print_header
    printf "\n  %b%s%b\n" "$COLOR_CORAL_B" "${LANG[TS_WL_TITLE]:-Whitelist (bypass shaping)}" "$COLOR_RESET"
    mkdir -p "$TS_CONFIG_DIR"
    menu_head "${LANG[TS_WL_HINT]:-IPs here ignore the shaper (full speed). Format: IP # comment}"
    ts_yesno "${LANG[TS_WL_OPEN]:-Open the whitelist editor?}" y || return
    if [ ! -f "$TS_WHITELIST" ]; then
        printf '# SpeedWave traffic-shaper whitelist\n# Format: IP-address # comment\n' > "$TS_WHITELIST"
    fi
    "${EDITOR:-nano}" "$TS_WHITELIST"
    msg_info "${LANG[TS_WL_SYNC]:-Applying changes...}"
    local out; out="$(ts_py whitelist-sync --file "$TS_WHITELIST" 2>&1)"
    echo "$out"
    echo "$out" | grep -q "whitelist_map" && msg_warn "${LANG[TS_WL_NEEDSTART]:-Engine not loaded yet — restart it to apply.}"
}

ts_full_cleanup() {
    print_header
    printf "\n  %b%s%b\n" "$COLOR_CORAL_B" "${LANG[TS_CLEAN_TITLE]:-Full cleanup}" "$COLOR_RESET"
    echo
    msg_warn "${LANG[TS_CLEAN_WARN]:-This removes all shaper rules, the service and qdiscs.}"
    ts_yesno "${LANG[TS_CLEAN_CONFIRM]:-Really remove the shaper?}" n || return
    local keep_wl="n"
    if [ -f "$TS_WHITELIST" ]; then
        ts_yesno "${LANG[TS_CLEAN_KEEPWL]:-Keep the whitelist file?}" y && keep_wl="y"
    fi
    ts_cleanup_engine
    if [ "$keep_wl" = "y" ]; then
        find "$TS_CONFIG_DIR" -mindepth 1 -maxdepth 1 ! -name 'whitelist.txt' -exec rm -rf {} + 2>/dev/null || true
    else
        rm -rf "$TS_CONFIG_DIR"
    fi
    msg_ok "${LANG[TS_CLEAN_DONE]:-Cleanup complete.}"
}

# ── Kernel gate + main menu ───────────────────────────────────────────────────
ts_kernel_ok() {
    local maj min
    maj="$(uname -r | cut -d. -f1)"; min="$(uname -r | cut -d. -f2)"
    [[ "$maj" =~ ^[0-9]+$ ]] || return 0
    [ "$maj" -gt 5 ] && return 0
    [ "$maj" -eq 5 ] && [ "${min:-0}" -ge 4 ] && return 0
    return 1
}

show_traffic_shaper_menu() {
    print_header
    printf "\n  %b%s%b\n" "$COLOR_CORAL_B" "${LANG[TS_TITLE]:-Traffic shaper (eBPF + EDT)}" "$COLOR_RESET"
    printf "  %b%s%b\n"   "$COLOR_DIM"     "${LANG[TS_SUBTITLE]:-Per-user speed limits on the node ports}" "$COLOR_RESET"

    local status="${LANG[TS_ST_OFF]:-not configured}"
    ts_active && status="${LANG[TS_ST_ON]:-running (eBPF active)}"
    local wl=0
    [ -f "$TS_WHITELIST" ] && wl="$(grep -vcE '^\s*(#|$)' "$TS_WHITELIST" 2>/dev/null || echo 0)"
    printf "  %b%s %s%b\n" "$COLOR_GRAY" "${LANG[TS_ST_LABEL]:-Status:}" "$status" "$COLOR_RESET"

    menu_head "${LANG[TS_GROUP_RULES]:-Rules}"
    menu_item 1 "${LANG[TS_M_LIST]:-Active rules}"
    menu_item 2 "${LANG[TS_M_STATUS]:-Statistics (top IPs)}"
    menu_item 3 "${LANG[TS_M_ADD]:-Add / edit rule}"
    menu_item 4 "${LANG[TS_M_DEL]:-Delete rule}"

    menu_head "${LANG[TS_GROUP_ENGINE]:-Engine}"
    menu_item 5 "${LANG[TS_M_RESTART]:-Restart engine}"
    menu_item 6 "${LANG[TS_M_LOG]:-Service log}"
    menu_item 7 "${LANG[TS_M_MON]:-Traffic monitor (iftop)}"
    menu_item 8 "$(printf "${LANG[TS_M_WL]:-Whitelist}  [%s]" "$wl")"
    menu_item 9 "${LANG[TS_M_CLEAN]:-Full cleanup}"

    echo
    menu_item 0 "${LANG[NA_BACK]:-Back}"
    echo
    printf "  %b%s%b\n" "$COLOR_DIM" "${LANG[TS_CREDIT]:-Engine: Reshala (GPL, eBPF+EDT) · adapted for SpeedWave}" "$COLOR_RESET"
    echo
}

manage_traffic_shaper() {
    if ! ts_kernel_ok; then
        print_header
        msg_err "$(printf "${LANG[TS_OLD_KERNEL]:-Kernel %s is too old for the eBPF shaper (need 5.4+).}" "$(uname -r | cut -d- -f1)")"
        msg_info "${LANG[TS_OLD_KERNEL_FIX]:-Update the kernel (e.g. the node accelerator XanMod) and reboot.}"
        ts_pause
        return 0
    fi
    ts_fetch || return 1
    while true; do
        show_traffic_shaper_menu
        reading "${LANG[NA_PROMPT]:-Select option:}" TS_OPTION
        case "$TS_OPTION" in
            1) ts_list_rules ;;
            2) ts_status ;;
            3) ts_apply_wizard ;;
            4) ts_delete_rule ;;
            5) ts_restart ;;
            6) ts_view_log ;;
            7) ts_monitor ;;
            8) ts_edit_whitelist ;;
            9) ts_full_cleanup ;;
            0) return 0 ;;
            *) msg_warn "${LANG[NA_INVALID]:-Invalid choice.}"; sleep 1; continue ;;
        esac
        ts_pause
    done
}
