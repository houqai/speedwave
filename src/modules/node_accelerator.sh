#!/bin/bash
#
# node_accelerator.sh — remnawave-reverse-proxy module.
#
# Native, localized (RU/EN), Claude-styled front-end for the node-accelerator
# toolkit (⚡ kernel/network optimizer · 🛡 nftables+CrowdSec firewall · 🩺
# diagnostics). The heavy operational logic lives unchanged in
# src/node-accelerator/ (vendored, MIT — © jestivald/node-accelerator); this
# module only provides the integrated menu, download and orchestration so the
# feature looks and behaves like a first-class part of remnawave-reverse-proxy.
#
# Sourced into install_remnawave.sh, so it reuses the shared UI helpers
# (print_header, menu_item, menu_head, msg_*, reading), palette (COLOR_*),
# LANG[] strings and download_with_mirrors().

# Base URL of the vendored toolkit. Derived from LANG_BASE_URL so it always
# follows the same fork/branch as the rest of the script.
NA_BASE="${LANG_BASE_URL%/lang}/node-accelerator"
NA_DIR="${DIR_REMNAWAVE}node-accelerator"
NA_LIB_DIR="/usr/local/lib/node-accelerator"

# Download the toolkit (lib + modules) into $NA_DIR. Each module does
# `. $SCRIPT_DIR/lib/common.sh`, so lib/common.sh must sit alongside them.
na_fetch() {
    local f
    mkdir -p "$NA_DIR/lib"
    for f in lib/common.sh optimize.sh protect.sh diagnose.sh rollback.sh na-report.sh; do
        if ! download_with_mirrors "${NA_BASE}/${f}" "${NA_DIR}/${f}" "script"; then
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL "${NA_BASE}/${f}" -o "${NA_DIR}/${f}" 2>/dev/null
            elif command -v wget >/dev/null 2>&1; then
                wget -q "${NA_BASE}/${f}" -O "${NA_DIR}/${f}" 2>/dev/null
            fi
        fi
        [ -s "${NA_DIR}/${f}" ] || { msg_err "${LANG[NA_FETCH_FAIL]:-Failed to download node-accelerator modules.}"; return 1; }
    done
    chmod +x "${NA_DIR}"/*.sh 2>/dev/null || true
    return 0
}

# Persist read-only CLI (na-diagnose / na-report) so monitoring/panels keep a
# stable command after the toolkit dir is cleaned. Mirrors upstream install.sh.
na_persist() {
    install -d -m 0755 "$NA_LIB_DIR/lib" 2>/dev/null || return 0
    install -m 0644 "$NA_DIR/lib/common.sh" "$NA_LIB_DIR/lib/common.sh" 2>/dev/null || true
    install -m 0755 "$NA_DIR/diagnose.sh"   "$NA_LIB_DIR/diagnose.sh"   2>/dev/null || true
    cat > /usr/local/sbin/na-diagnose <<EOF
#!/usr/bin/env bash
# node-accelerator CLI (created by remnawave-reverse-proxy). Removed on rollback.
exec bash "$NA_LIB_DIR/diagnose.sh" "\$@"
EOF
    chmod +x /usr/local/sbin/na-diagnose 2>/dev/null || true
    if [ -f "$NA_DIR/na-report.sh" ]; then
        install -m 0755 "$NA_DIR/na-report.sh" "$NA_LIB_DIR/na-report.sh" 2>/dev/null || true
        cat > /usr/local/sbin/na-report <<EOF
#!/usr/bin/env bash
exec bash "$NA_LIB_DIR/na-report.sh" "\$@"
EOF
        chmod +x /usr/local/sbin/na-report 2>/dev/null || true
    fi
}

na_run() {
    local action="$1"
    na_fetch || return 1
    echo
    case "$action" in
        optimize) bash "$NA_DIR/optimize.sh"; na_persist ;;
        protect)  bash "$NA_DIR/protect.sh";  na_persist ;;
        diagnose) bash "$NA_DIR/diagnose.sh" ;;
        all)      bash "$NA_DIR/optimize.sh"; bash "$NA_DIR/protect.sh"; bash "$NA_DIR/diagnose.sh"; na_persist ;;
    esac
}

na_rollback_menu() {
    na_fetch || return 1
    echo
    printf "  %b%s%b\n" "$COLOR_CORAL_B" "${LANG[NA_ROLLBACK_TITLE]:-Rollback}" "$COLOR_RESET"
    menu_item a "${LANG[NA_RB_OPT]:-Roll back optimizer}"
    menu_item b "${LANG[NA_RB_PROT]:-Roll back firewall}"
    menu_item c "${LANG[NA_RB_ALL]:-Roll back everything}"
    echo
    menu_item 0 "${LANG[NA_BACK]:-Back}"
    echo
    local r
    reading "${LANG[NA_PROMPT]:-Select option:}" r
    case "$r" in
        a|A) bash "$NA_DIR/rollback.sh" optimize ;;
        b|B) bash "$NA_DIR/rollback.sh" protect ;;
        c|C) bash "$NA_DIR/rollback.sh" all ;;
        *)   return 0 ;;
    esac
}

show_node_accelerator_menu() {
    print_header
    printf "\n  %b%s%b\n"  "$COLOR_CORAL_B" "${LANG[NA_TITLE]:-Node accelerator}" "$COLOR_RESET"
    printf "  %b%s%b\n"    "$COLOR_DIM"     "${LANG[NA_SUBTITLE]:-Kernel & network tuning · firewall · diagnostics}" "$COLOR_RESET"

    menu_head "${LANG[NA_GROUP_APPLY]:-Apply}"
    menu_item 1 "${LANG[NA_OPT]:-Optimizer — XanMod (BBRv3) + sysctl + RPS/RFS + limits + swap}"
    menu_item 2 "${LANG[NA_PROT]:-Protection — nftables firewall (anti-scan/flood) + CrowdSec}"
    menu_item 3 "${LANG[NA_DIAG]:-Diagnostics (read-only health report)}"
    menu_item 4 "${LANG[NA_ALL]:-Everything (optimize → protect → diagnose)}"

    menu_head "${LANG[NA_GROUP_MAINT]:-Maintenance}"
    menu_item 5 "${LANG[NA_ROLLBACK]:-Rollback}"

    echo
    menu_item 0 "${LANG[NA_BACK]:-Back}"
    echo
    printf "  %b%s%b\n" "$COLOR_DIM" "${LANG[NA_CREDIT]:-Engine: node-accelerator (MIT) · adapted for remnawave-reverse-proxy}" "$COLOR_RESET"
    echo
}

manage_node_accelerator() {
    while true; do
        show_node_accelerator_menu
        reading "${LANG[NA_PROMPT]:-Select option:}" NA_OPTION
        case "$NA_OPTION" in
            1) na_run optimize ;;
            2) na_run protect ;;
            3) na_run diagnose ;;
            4) na_run all ;;
            5) na_rollback_menu ;;
            0) return 0 ;;
            *) msg_warn "${LANG[NA_INVALID]:-Invalid choice.}"; sleep 1; continue ;;
        esac
        echo
        reading "${LANG[NA_CONTINUE]:-Press Enter to return to the menu}" _na_dummy
    done
}
