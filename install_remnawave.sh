#!/bin/bash

SCRIPT_VERSION="3.2.1"
UPDATE_AVAILABLE=false
DIR_REMNAWAVE="/usr/local/speedwave/"
LANG_FILE="${DIR_REMNAWAVE}selected_language"
CACHE_VERSION_FILE="${DIR_REMNAWAVE}.cache_version"
SCRIPT_URL="https://raw.githubusercontent.com/houqai/speedwave/refs/heads/main/install_remnawave.sh"
LANG_BASE_URL="https://raw.githubusercontent.com/houqai/speedwave/refs/heads/main/src/lang"

# ─── Palette (Claude-style coral theme) ──────────────────────────────────────
# Truecolor ANSI. Auto-disabled on non-tty / NO_COLOR / dumb terminals so piped
# output and log files stay clean. COLOR_GREEN is remapped to coral on purpose:
# it is the script-wide "primary accent" token (titles/prompts), so every existing
# call site repaints to the Claude look without being touched individually.
#
# We key on stdin (-t 0), not stdout: log_entry redirects stdout into a `tee` pipe
# (exec > >(tee ...)), so on re-entry to the menu via the `speedwave`
# command stdout is no longer a tty and `-t 1` alone would wrongly drop all colors.
# stdin stays attached to the terminal in interactive use, so it is the reliable
# signal. Keep -t 1 too for the rare stdout-tty/stdin-piped case.
if { [ -t 0 ] || [ -t 1 ]; } && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    COLOR_RESET="\033[0m"
    COLOR_CORAL="\033[38;2;217;119;87m"      # Claude signature coral #D97757
    COLOR_CORAL_B="\033[1;38;2;217;119;87m"  # bold coral
    COLOR_GREEN="\033[1;38;2;217;119;87m"    # primary accent -> coral
    COLOR_YELLOW="\033[38;2;221;181;126m"    # warm sand (menu items / warnings)
    COLOR_WHITE="\033[1;38;2;245;245;245m"   # bright text
    COLOR_RED="\033[38;2;224;104;90m"        # soft red (errors)
    COLOR_GRAY="\033[38;2;138;138;138m"      # dim secondary
    COLOR_DIM="\033[38;2;110;110;110m"       # rules / borders
    COLOR_OK="\033[38;2;127;176;105m"        # success green (status glyphs)
else
    COLOR_RESET=""; COLOR_CORAL=""; COLOR_CORAL_B=""; COLOR_GREEN=""; COLOR_YELLOW=""
    COLOR_WHITE=""; COLOR_RED=""; COLOR_GRAY=""; COLOR_DIM=""; COLOR_OK=""
fi

# ─── UI helpers (Claude-style) ───────────────────────────────────────────────
UI_WIDTH=58
_ui_rule() { local n="${1:-$UI_WIDTH}" ch="${2:-─}" out="" i; for ((i=0; i<n; i++)); do out+="$ch"; done; printf '%s' "$out"; }
ui_hr()      { printf "%b%s%b\n" "$COLOR_DIM" "$(_ui_rule "${1:-$UI_WIDTH}")" "$COLOR_RESET"; }
ui_box_top() { printf "%b╭%s╮%b\n" "$COLOR_CORAL" "$(_ui_rule "$UI_WIDTH")" "$COLOR_RESET"; }
ui_box_bot() { printf "%b╰%s╯%b\n" "$COLOR_CORAL" "$(_ui_rule "$UI_WIDTH")" "$COLOR_RESET"; }
ui_box_line() { # <text> [text-color]
    local text="$1" col="${2:-$COLOR_RESET}" len pad
    len=${#text}; pad=$(( UI_WIDTH - 2 - len )); (( pad < 0 )) && pad=0
    printf "%b│%b %b%s%b%*s %b│%b\n" "$COLOR_CORAL" "$COLOR_RESET" "$col" "$text" "$COLOR_RESET" "$pad" "" "$COLOR_CORAL" "$COLOR_RESET"
}
menu_item()  { printf "  %b%2s%b  %s\n" "$COLOR_CORAL_B" "$1" "$COLOR_RESET" "$2"; }
menu_head()  { printf "\n%b  %s%b\n" "$COLOR_DIM" "$1" "$COLOR_RESET"; }
msg_ok()     { printf "%b ✓%b %s\n" "$COLOR_OK"     "$COLOR_RESET" "$*"; }
msg_warn()   { printf "%b !%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "$*"; }
msg_err()    { printf "%b ✗%b %s\n" "$COLOR_RED"    "$COLOR_RESET" "$*" >&2; }
msg_info()   { printf "%b ·%b %s\n" "$COLOR_CORAL"  "$COLOR_RESET" "$*"; }

print_header() {
    clear 2>/dev/null || true
    local ver="v${SCRIPT_VERSION}"
    [[ "${UPDATE_AVAILABLE:-false}" == true ]] && ver="v${SCRIPT_VERSION}   ·   update available"
    echo
    ui_box_top
    ui_box_line "✻  SpeedWave" "$COLOR_CORAL_B"
    ui_box_line "Remnawave reverse-proxy & node manager" "$COLOR_GRAY"
    ui_box_line "$ver" "$COLOR_GRAY"
    ui_box_bot
}

# Download file with multiple mirrors and validation
download_with_mirrors() {
    local file_url="$1"
    local dest_file="$2"
    local file_type="${3:-script}"  # script, lang, module
    
    # Mirror URLs (GitHub raw content proxies)
    local mirrors=(
        "$file_url"
        "https://cdn.jsdelivr.net/gh/houqai/speedwave@main/${file_url#*main/}"
        "https://raw.githack.com/houqai/speedwave/main/${file_url#*main/}"
        "https://ghproxy.com/${file_url}"
    )
    
    local temp_file="${dest_file}.tmp"
    local download_success=false
    local http_code=""
    
    # Try each mirror
    for mirror_url in "${mirrors[@]}"; do
        if command -v curl &> /dev/null; then
            http_code=$(curl -sL -w "%{http_code}" --connect-timeout 10 --max-time 30 "$mirror_url" -o "$temp_file" 2>/dev/null)
            if [ "$http_code" = "200" ] && [ -s "$temp_file" ]; then
                # Validate file content
                if validate_downloaded_file "$temp_file" "$file_type"; then
                    download_success=true
                    break
                fi
            fi
        elif command -v wget &> /dev/null; then
            if wget -q --timeout=10 --tries=1 "$mirror_url" -O "$temp_file" 2>/dev/null; then
                if [ -s "$temp_file" ]; then
                    # Validate file content
                    if validate_downloaded_file "$temp_file" "$file_type"; then
                        download_success=true
                        break
                    fi
                fi
            fi
        fi
    done
    
    if [ "$download_success" = "true" ]; then
        mv "$temp_file" "$dest_file"
        rm -f "${dest_file}.bak"
        return 0
    else
        rm -f "$temp_file"
        return 1
    fi
}

# Validate downloaded file content
validate_downloaded_file() {
    local file="$1"
    local file_type="$2"
    
    if [ ! -s "$file" ]; then
        return 1
    fi
    
    # Check for HTTP error responses or rate limit errors
    if grep -q "429" "$file" && grep -q "Too Many Requests" "$file"; then
        return 1
    fi
    
    if grep -q "404" "$file" && grep -q "Not Found" "$file"; then
        return 1
    fi
    
    # Check for Terms of Service warnings (GitHub scraping warning)
    if grep -q "Terms of Service" "$file" && grep -q "scraping" "$file"; then
        return 1
    fi
    
    # For bash scripts, check for proper shebang
    if [[ "$file_type" == "script" ]] || [[ "$file_type" == "lang" ]] || [[ "$file_type" == "module" ]]; then
        if ! head -1 "$file" | grep -q "^#!/bin/bash"; then
            return 1
        fi
    fi
    
    # For language files, check for LANG array declaration
    if [ "$file_type" = "lang" ]; then
        if ! grep -q "declare -gA LANG" "$file"; then
            return 1
        fi
    fi
    
    return 0
}

# Drop cached lang/modules when the running script version differs from the one
# that produced the cache. Without this, an old cached lang/module file lingers
# and new strings (e.g. menu items) fall back to English — translations then look
# "unstable" (present on fresh installs, missing on upgraded hosts). Runs before
# load_language so this very run picks up fresh files.
invalidate_stale_cache() {
    [ -d "$DIR_REMNAWAVE" ] || return 0
    local cached=""
    [ -f "$CACHE_VERSION_FILE" ] && cached="$(cat "$CACHE_VERSION_FILE" 2>/dev/null)"
    if [ "$cached" != "$SCRIPT_VERSION" ]; then
        rm -f "${DIR_REMNAWAVE}lang/"*.sh \
              "${DIR_REMNAWAVE}modules/"*.sh \
              "${DIR_REMNAWAVE}nginx/"*.sh \
              "${DIR_REMNAWAVE}api/"*.sh 2>/dev/null
        echo "$SCRIPT_VERSION" > "$CACHE_VERSION_FILE" 2>/dev/null || true
    fi
}

load_language() {
    if [ -f "$LANG_FILE" ]; then
        local saved_lang=$(cat "$LANG_FILE")
        case $saved_lang in
            1) set_language en ;;
            2) set_language ru ;;
            *)
                rm -f "$LANG_FILE"
                return 1 ;;
        esac
        return 0
    fi
    return 1
}

# Language variables
declare -gA LANG=(
    [CHOOSE_LANG]="Select language:"
    [LANG_EN]="English"
    [LANG_RU]="Русский"
)

show_language() {
    print_header
    menu_head "${LANG[CHOOSE_LANG]}"
    menu_item 1 "${LANG[LANG_EN]}"
    menu_item 2 "${LANG[LANG_RU]}"
    echo
}

set_language() {
     local lang="$1"
     local lang_file="${DIR_REMNAWAVE}lang/${lang}.sh"
     local force_update="${2:-false}"

     unset LANG
     declare -gA LANG

     if [ "$force_update" = "true" ] || [ ! -f "$lang_file" ]; then
         local lang_url="${LANG_BASE_URL}/${lang}.sh"
         mkdir -p "${DIR_REMNAWAVE}lang"
         
         # Use download_with_mirrors for reliable download
         if ! download_with_mirrors "$lang_url" "$lang_file" "lang"; then
             # Fallback: try direct download if mirrors fail
             if command -v curl &> /dev/null; then
                 curl -sL "$lang_url" -o "$lang_file" 2>/dev/null
             elif command -v wget &> /dev/null; then
                 wget -q "$lang_url" -O "$lang_file" 2>/dev/null
             fi
         fi
     fi

     if [ -f "$lang_file" ]; then
         source "$lang_file"
     else
         # Emergency fallback: download English from mirrors
         local en_url="${LANG_BASE_URL}/en.sh"
         local temp_en_file="${DIR_REMNAWAVE}lang/en_temp.sh"
         
         if download_with_mirrors "$en_url" "$temp_en_file" "lang"; then
             source "$temp_en_file"
             mv "$temp_en_file" "${DIR_REMNAWAVE}lang/en.sh"
         else
             # Last resort: direct download
             if command -v curl &> /dev/null; then
                 source <(curl -sL "$en_url" 2>/dev/null)
             elif command -v wget &> /dev/null; then
                 source <(wget -qO- "$en_url" 2>/dev/null)
             fi
         fi
     fi
}

question() {
    echo -e "${COLOR_GREEN}[?]${COLOR_RESET} ${COLOR_YELLOW}$*${COLOR_RESET}"
}

reading() {
    read -rp " $(question "$1")" "$2"
}

error() {
    echo -e "${COLOR_RED}$*${COLOR_RESET}"
    exit 1
}

check_os() {
    if ! grep -q "bullseye" /etc/os-release && ! grep -q "bookworm" /etc/os-release && ! grep -q "jammy" /etc/os-release && ! grep -q "noble" /etc/os-release && ! grep -q "resolute" /etc/os-release && ! grep -q "trixie" /etc/os-release; then
        error "${LANG[ERROR_OS]}"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "${LANG[ERROR_ROOT]}"
    fi
}

log_clear() {
  sed -i -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOGFILE"
}

log_entry() {
  mkdir -p ${DIR_REMNAWAVE}
  LOGFILE="${DIR_REMNAWAVE}speedwave.log"
  exec > >(tee -a "$LOGFILE") 2>&1
}

update_speedwave() {
    local remote_version=$(curl -s "$SCRIPT_URL" | grep -m 1 "SCRIPT_VERSION=" | sed -E 's/.*SCRIPT_VERSION="([^"]+)".*/\1/')
    local update_script="${DIR_REMNAWAVE}speedwave"
    local bin_link="/usr/local/bin/speedwave"

    if [ -z "$remote_version" ]; then
        echo -e "${COLOR_YELLOW}${LANG[VERSION_CHECK_FAILED]}${COLOR_RESET}"
        return 1
    fi

    if [ -f "$update_script" ]; then
        if [ "$SCRIPT_VERSION" = "$remote_version" ]; then
            printf "${COLOR_GREEN}${LANG[LATEST_VERSION]}${COLOR_RESET}\n" "$SCRIPT_VERSION"
            return 0
        fi
    else
        echo -e "${COLOR_YELLOW}${LANG[LOCAL_FILE_NOT_FOUND]}${COLOR_RESET}"
    fi

    printf "${COLOR_YELLOW}${LANG[UPDATE_AVAILABLE]}${COLOR_RESET}\n" "$remote_version" "$SCRIPT_VERSION"
    reading "${LANG[UPDATE_CONFIRM]}" confirm_update

    if [[ "$confirm_update" != "y" && "$confirm_update" != "Y" ]]; then
        echo -e "${COLOR_YELLOW}${LANG[UPDATE_CANCELLED]}${COLOR_RESET}"
        return 0
    fi

    mkdir -p "${DIR_REMNAWAVE}"

    local current_lang="en"
    if [ -f "$LANG_FILE" ]; then
        case $(cat "$LANG_FILE") in
            1) current_lang="en" ;;
            2) current_lang="ru" ;;
        esac
    fi

	#Update LANG
    echo -e "${COLOR_YELLOW}${LANG[UPDATING_LANG_FILES]}${COLOR_RESET}"
    set_language "$current_lang" "true"  # force_update=true
    printf "${COLOR_GREEN}${LANG[LANG_FILE_UPDATED]}${COLOR_RESET}\n" "${current_lang}.sh"
    echo -e ""

	#Update modules
    echo -e "${COLOR_YELLOW}${LANG[UPDATING_MODULES]}${COLOR_RESET}"

    # Nginx modules
    local nginx_modules=("install_panel_node" "install_panel" "install_node")
    for module in "${nginx_modules[@]}"; do
        local module_file="${DIR_REMNAWAVE}nginx/${module}.sh"
        if [ -f "$module_file" ]; then
            if load_module "$module" "nginx" "true"; then
                printf "${COLOR_GREEN}${LANG[LANG_FILE_UPDATED]}${COLOR_RESET}\n" "nginx/${module}.sh"
            else
                printf "${COLOR_RED}${LANG[LANG_FILE_UPDATE_FAILED]}${COLOR_RESET}\n" "nginx/${module}.sh"
            fi
        fi
    done

    # Modules (common)
    local common_modules=("add_node" "manage_panel" "warp" "ipv6" "selfsteal_templates" "node_accelerator" "rw_core")
    for module in "${common_modules[@]}"; do
        local module_file="${DIR_REMNAWAVE}modules/${module}.sh"
        if [ -f "$module_file" ]; then
            if load_module "$module" "modules" "true"; then
                printf "${COLOR_GREEN}${LANG[LANG_FILE_UPDATED]}${COLOR_RESET}\n" "modules/${module}.sh"
            else
                printf "${COLOR_RED}${LANG[LANG_FILE_UPDATE_FAILED]}${COLOR_RESET}\n" "modules/${module}.sh"
            fi
        fi
    done

    local api_file="${DIR_REMNAWAVE}api/remnawave_api.sh"
    if [ -f "$api_file" ]; then
        if load_module "remnawave_api" "api" "true"; then
            printf "${COLOR_GREEN}${LANG[LANG_FILE_UPDATED]}${COLOR_RESET}\n" "remnawave_api.sh"
        else
            printf "${COLOR_RED}${LANG[LANG_FILE_UPDATE_FAILED]}${COLOR_RESET}\n" "remnawave_api.sh"
        fi
    fi

    echo -e ""

    local temp_script="${DIR_REMNAWAVE}speedwave.tmp"
    
    # Use download_with_mirrors for reliable script download
    if download_with_mirrors "$SCRIPT_URL" "$temp_script" "script"; then
        local downloaded_version=$(grep -m 1 "SCRIPT_VERSION=" "$temp_script" | sed -E 's/.*SCRIPT_VERSION="([^"]+)".*/\1/')
        if [ "$downloaded_version" != "$remote_version" ]; then
            echo -e "${COLOR_RED}${LANG[UPDATE_FAILED]}${COLOR_RESET}"
            rm -f "$temp_script"
            return 1
        fi

        if [ -f "$update_script" ]; then
            rm -f "$update_script"
        fi
        mv "$temp_script" "$update_script"
        chmod +x "$update_script"

        if [ -e "$bin_link" ]; then
            rm -f "$bin_link"
        fi
        ln -s "$update_script" "$bin_link"

        hash -r

        printf "${COLOR_GREEN}${LANG[UPDATE_SUCCESS]}${COLOR_RESET}\n" "$remote_version"
        echo -e ""
        echo -e "${COLOR_YELLOW}${LANG[RESTART_REQUIRED]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}${LANG[RELAUNCH_CMD]}${COLOR_GREEN} speedwave${COLOR_RESET}"
        exit 0
    else
        # Fallback: try direct download with wget
        if wget -q -O "$temp_script" "$SCRIPT_URL" 2>/dev/null; then
            local downloaded_version=$(grep -m 1 "SCRIPT_VERSION=" "$temp_script" | sed -E 's/.*SCRIPT_VERSION="([^"]+)".*/\1/')
            if [ "$downloaded_version" != "$remote_version" ]; then
                echo -e "${COLOR_RED}${LANG[UPDATE_FAILED]}${COLOR_RESET}"
                rm -f "$temp_script"
                return 1
            fi

            if [ -f "$update_script" ]; then
                rm -f "$update_script"
            fi
            mv "$temp_script" "$update_script"
            chmod +x "$update_script"

            if [ -e "$bin_link" ]; then
                rm -f "$bin_link"
            fi
            ln -s "$update_script" "$bin_link"

            hash -r

            printf "${COLOR_GREEN}${LANG[UPDATE_SUCCESS]}${COLOR_RESET}\n" "$remote_version"
            echo -e ""
            echo -e "${COLOR_YELLOW}${LANG[RESTART_REQUIRED]}${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}${LANG[RELAUNCH_CMD]}${COLOR_GREEN} speedwave${COLOR_RESET}"
            exit 0
        fi
        
        echo -e "${COLOR_RED}${LANG[UPDATE_FAILED]}${COLOR_RESET}"
        rm -f "$temp_script"
        return 1
    fi
}

remove_script() {
    menu_head "${LANG[MENU_10]}"
    menu_item 1 "${LANG[REMOVE_SCRIPT_ONLY]}"
    menu_item 2 "${LANG[REMOVE_SCRIPT_AND_PANEL]}"
    echo
    menu_item 0 "${LANG[EXIT]}"
    echo
    reading "${LANG[CERT_PROMPT1]}" SUB_OPTION

    case $SUB_OPTION in
        1)
            echo -e "${COLOR_RED}${LANG[CONFIRM_REMOVE_SCRIPT]}${COLOR_RESET}"
            read confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                return 0
            fi

            rm -rf /usr/local/speedwave 2>/dev/null
            rm -f /usr/local/bin/speedwave 2>/dev/null
            
            echo -e "${COLOR_GREEN}${LANG[SCRIPT_REMOVED]}${COLOR_RESET}"
            exit 0
            ;;
        2)
            echo -e "${COLOR_RED}${LANG[CONFIRM_REMOVE_ALL]}${COLOR_RESET}"
            read confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                return 0
            fi

            if [ -d "/opt/remnawave" ]; then
                cd /opt/remnawave || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} /opt/remnawave${COLOR_RESET}"; exit 1; }
                docker compose down -v --rmi all --remove-orphans > /dev/null 2>&1 &
                spinner $! "${LANG[WAITING]}"
                rm -rf /opt/remnawave 2>/dev/null
            fi
            if [ -d "/opt/remnanode" ]; then
                cd /opt/remnanode || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} /opt/remnanode${COLOR_RESET}"; exit 1; }
                docker compose down -v --rmi all --remove-orphans > /dev/null 2>&1 &
                spinner $! "${LANG[WAITING]}"
                rm -rf /opt/remnanode 2>/dev/null
            fi
            docker system prune -a --volumes -f > /dev/null 2>&1 &
            spinner $! "${LANG[WAITING]}"
            rm -rf /usr/local/speedwave 2>/dev/null
            rm -f /usr/local/bin/speedwave 2>/dev/null

            echo -e "${COLOR_GREEN}${LANG[ALL_REMOVED]}${COLOR_RESET}"
            exit 0
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            return 0
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}"
            sleep 2
            remove_script
            ;;
    esac
}

install_script_if_missing() {
    if [ ! -f "${DIR_REMNAWAVE}speedwave" ] || [ ! -f "/usr/local/bin/speedwave" ]; then
        mkdir -p "${DIR_REMNAWAVE}"
        
        # Use download_with_mirrors for reliable download
        if ! download_with_mirrors "$SCRIPT_URL" "${DIR_REMNAWAVE}speedwave" "script"; then
            # Fallback: try direct download
            if ! wget -q -O "${DIR_REMNAWAVE}speedwave" "$SCRIPT_URL" 2>/dev/null; then
                exit 1
            fi
        fi
        
        chmod +x "${DIR_REMNAWAVE}speedwave"
        ln -sf "${DIR_REMNAWAVE}speedwave" /usr/local/bin/speedwave
    fi

    local bashrc_file="/etc/bash.bashrc"
    local alias_line="alias sw='speedwave'"

    if [ ! -f "$bashrc_file" ]; then
        touch "$bashrc_file"
        chmod 644 "$bashrc_file"
    fi

    if [ -s "$bashrc_file" ] && [ "$(tail -c 1 "$bashrc_file")" != "" ]; then
        echo >> "$bashrc_file"
    fi

    if ! grep -E "^[[:space:]]*alias sw='speedwave'[[:space:]]*$" "$bashrc_file" > /dev/null; then
        echo "$alias_line" >> "$bashrc_file"
        printf "${COLOR_GREEN}${LANG[ALIAS_ADDED]}${COLOR_RESET}\n" "$bashrc_file"
        printf "${COLOR_YELLOW}${LANG[ALIAS_ACTIVATE_GLOBAL]}${COLOR_RESET}\n" "$bashrc_file"
    fi
}

generate_user() {
    local length=8
    tr -dc 'a-zA-Z' < /dev/urandom | fold -w $length | head -n 1
}

generate_password() {
    local length=24
    local password=""
    local upper_chars='A-Z'
    local lower_chars='a-z'
    local digit_chars='0-9'
    local special_chars='!@#%^&*()_+'
    local all_chars='A-Za-z0-9!@#%^&*()_+'

    password+=$(head /dev/urandom | tr -dc "$upper_chars" | head -c 1)
    password+=$(head /dev/urandom | tr -dc "$lower_chars" | head -c 1)
    password+=$(head /dev/urandom | tr -dc "$digit_chars" | head -c 1)
    password+=$(head /dev/urandom | tr -dc "$special_chars" | head -c 3)
    password+=$(head /dev/urandom | tr -dc "$all_chars" | head -c $(($length - 6)))

    password=$(echo "$password" | fold -w1 | shuf | tr -d '\n')

    echo "$password"
}

#Displaying the availability of the update in the menu
check_update_status() {
    local TEMP_REMOTE_VERSION_FILE
    TEMP_REMOTE_VERSION_FILE=$(mktemp)

    if ! curl -fsSL "$SCRIPT_URL" 2>/dev/null | head -n 100 > "$TEMP_REMOTE_VERSION_FILE"; then
        UPDATE_AVAILABLE=false
        rm -f "$TEMP_REMOTE_VERSION_FILE"
        return
    fi

    local REMOTE_VERSION
    REMOTE_VERSION=$(grep -m 1 "^SCRIPT_VERSION=" "$TEMP_REMOTE_VERSION_FILE" | cut -d'"' -f2)
    rm -f "$TEMP_REMOTE_VERSION_FILE"

    if [[ -z "$REMOTE_VERSION" ]]; then
        UPDATE_AVAILABLE=false
        return
    fi

    compare_versions_for_check() {
        local v1="$1"
        local v2="$2"

        local v1_num="${v1//[^0-9.]/}"
        local v2_num="${v2//[^0-9.]/}"

        local v1_sfx="${v1//$v1_num/}"
        local v2_sfx="${v2//$v2_num/}"

        if [[ "$v1_num" == "$v2_num" ]]; then
            if [[ -z "$v1_sfx" && -n "$v2_sfx" ]]; then
                return 0
            elif [[ -n "$v1_sfx" && -z "$v2_sfx" ]]; then
                return 1
            elif [[ "$v1_sfx" < "$v2_sfx" ]]; then
                return 0
            else
                return 1
            fi
        else
            if printf '%s\n' "$v1_num" "$v2_num" | sort -V | head -n1 | grep -qx "$v1_num"; then
                return 0
            else
                return 1
            fi
        fi
    }

    if compare_versions_for_check "$SCRIPT_VERSION" "$REMOTE_VERSION"; then
        UPDATE_AVAILABLE=true
    else
        UPDATE_AVAILABLE=false
    fi
}

show_menu() {
    print_header

    menu_head "${LANG[MENU_GROUP_INSTALL]:-Install & manage}"
    menu_item 1 "${LANG[MENU_1]}"   # Install Remnawave Components
    menu_item 2 "${LANG[MENU_2]}"   # Reinstall panel/node
    menu_item 3 "${LANG[MENU_3]}"   # Manage panel/node

    menu_head "${LANG[MENU_GROUP_TOOLS]:-Tools}"
    menu_item 4 "${LANG[MENU_4]}"   # Apply IP-blocked template
    menu_item 5 "${LANG[MENU_6]}"   # WARP Native
    menu_item 6 "${LANG[MENU_7]}"   # Backup and Restore
    menu_item 7 "${LANG[MENU_12]:-Node accelerator (optimize / protect / diagnose)}"
    menu_item 8 "${LANG[MENU_13]:-Update node core (rw-core / Xray) from source}"

    menu_head "${LANG[MENU_GROUP_SYSTEM]:-System}"
    menu_item 9  "${LANG[MENU_8]}"  # Manage IPv6
    menu_item 10 "${LANG[MENU_9]}"  # Manage certificates domain
    menu_item 11 "${LANG[MENU_10]}" # Check for updates
    menu_item 12 "${LANG[MENU_11]}" # Remove script

    echo
    menu_item 0 "${LANG[EXIT]}"
    echo
    printf "  %b%s%b\n" "$COLOR_DIM" "SpeedWave: https://github.com/houqai/speedwave" "$COLOR_RESET"
    printf "  %b%s%b\n" "$COLOR_DIM" "${LANG[FAST_START]}" "$COLOR_RESET"
    echo
}

# Node install type selection (with or without a selfsteal site/domain)
show_node_install_options() {
    menu_head "${LANG[NODE_INSTALL_TYPE_TITLE]:-Node install type}"
    menu_item 1 "${LANG[NODE_WITH_SELFSTEAL]:-With selfsteal site (domain + IP-blocked page)}"
    menu_item 2 "${LANG[NODE_WITHOUT_SELFSTEAL]:-Without selfsteal domain (node only)}"
    echo
    menu_item 0 "${LANG[EXIT]}"
    echo
}

#Manage Install Remnawave Components
show_install_menu() {
    menu_head "${LANG[INSTALL_MENU_TITLE]}"
    menu_item 1 "${LANG[INSTALL_PANEL_NODE]}"
    menu_item 2 "${LANG[INSTALL_PANEL]}"
    menu_item 3 "${LANG[INSTALL_ADD_NODE]}"
    menu_item 4 "${LANG[INSTALL_NODE]}"
    echo
    menu_item 0 "${LANG[EXIT]}"
    echo
}

manage_install() {
    show_install_menu
    reading "${LANG[INSTALL_PROMPT]}" INSTALL_OPTION
    case $INSTALL_OPTION in
        1)
            echo -e ""
            echo -e "${COLOR_RED}${LANG[WARNING_LABEL]}${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}${LANG[PANEL_NODE_SINGLE_SERVER_WARNING]}${COLOR_RESET}"
            echo -e ""
            echo -e "${COLOR_YELLOW}${LANG[PANEL_NODE_SINGLE_SERVER_RECOMMENDATION]}${COLOR_RESET}"
            echo -e ""
            reading "${LANG[CONFIRM_CONTINUE]}" confirm_install
            
            if [[ "$confirm_install" != "y" && "$confirm_install" != "Y" ]]; then
                echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                exit 0
            fi
            
            load_install_panel_node_module
            load_api_module
            if [ ! -f "${DIR_REMNAWAVE}install_packages" ] || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
                install_packages || {
                    echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}"
                    log_clear
                    exit 1
                }
            fi
            installation
            sleep 2
            log_clear
            ;;
        2)
            load_install_panel_module
            load_api_module
            if [ ! -f "${DIR_REMNAWAVE}install_packages" ] || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
                install_packages || {
                    echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}"
                    log_clear
                    exit 1
                }
            fi
            installation_panel
            sleep 2
            log_clear
            ;;
        3)
            load_add_node_module
            load_api_module
            add_node_to_panel
            log_clear
            ;;
        4)
            show_node_install_options
            reading "${LANG[INSTALL_PROMPT]}" NODE_INSTALL_OPTION
            case $NODE_INSTALL_OPTION in
                1)
                    load_install_node_module
                    if [ ! -f "${DIR_REMNAWAVE}install_packages" ] || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
                        install_packages || {
                            echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}"
                            log_clear
                            exit 1
                        }
                    fi
                    installation_node
                    ;;
                2)
                    load_install_node_module
                    if [ ! -f "${DIR_REMNAWAVE}install_packages" ] || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
                        install_packages || {
                            echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}"
                            log_clear
                            exit 1
                        }
                    fi
                    installation_node_no_domain
                    ;;
                0)
                    echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                    log_clear
                    speedwave
                    return
                    ;;
                *)
                    echo -e "${COLOR_YELLOW}${LANG[INSTALL_INVALID_CHOICE]}${COLOR_RESET}"
                    sleep 2
                    log_clear
                    manage_install
                    return
                    ;;
            esac
            sleep 2
            log_clear
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            log_clear
            speedwave
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[INSTALL_INVALID_CHOICE]}${COLOR_RESET}"
            sleep 2
            log_clear
            manage_install
            ;;
    esac
}
#Manage Install Remnawave Components

#Show Reinstall Options
show_reinstall_options() {
    menu_head "${LANG[REINSTALL_TYPE_TITLE]}"
    menu_item 1 "${LANG[INSTALL_PANEL_NODE]}"
    menu_item 2 "${LANG[INSTALL_PANEL]}"
    menu_item 3 "${LANG[INSTALL_NODE]}"
    echo
    menu_item 0 "${LANG[EXIT]}"
    echo
}

choose_reinstall_type() {
    show_reinstall_options
    reading "${LANG[REINSTALL_PROMPT]}" REINSTALL_OPTION
    case $REINSTALL_OPTION in
        1|2|3)
                echo -e "${COLOR_RED}${LANG[REINSTALL_WARNING]}${COLOR_RESET}"
                read confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    reinstall_remnawave
                    if [ ! -f ${DIR_REMNAWAVE}install_packages ]; then
                        install_packages
                    fi
                    case $REINSTALL_OPTION in
                        1) load_install_panel_node_module; load_api_module; installation ;;
                        2) load_install_panel_module; load_api_module; installation_panel ;;
                        3) load_install_node_module; load_api_module; installation_node ;;
                    esac
                    log_clear
                else
                    echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                    exit 0
                fi
                ;;
            0)
                echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                speedwave
                ;;
            *)
                echo -e "${COLOR_YELLOW}${LANG[INVALID_REINSTALL_CHOICE]}${COLOR_RESET}"
                exit 1
                ;;
        esac
}

reinstall_remnawave() {
    if [ -d "/opt/remnawave" ]; then
        cd /opt/remnawave || return
        docker compose down -v --rmi all --remove-orphans > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
        rm -rf /opt/remnawave 2>/dev/null
    fi
    if [ -d "/opt/remnanode" ]; then
        cd /opt/remnanode || return
        docker compose down -v --rmi all --remove-orphans > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
        rm -rf /opt/remnanode 2>/dev/null
    fi
    docker system prune -a --volumes -f > /dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"
}
#Show Reinstall Options

#Extensions by legiz
show_custom_legiz_menu() {
    menu_head "${LANG[MENU_5]}"
    menu_item 1 "${LANG[SELECT_SUB_PAGE_CUSTOM1]}"   # Custom sub page
    menu_item 2 "${LANG[CUSTOM_APP_LIST_MENU]}"      # Edit custom app list and branding
    echo
    menu_item 0 "${LANG[EXIT]}"
    echo
}

manage_custom_legiz() {
    show_custom_legiz_menu
    reading "${LANG[LEGIZ_EXTENSIONS_PROMPT]}" LEGIZ_OPTION
    case $LEGIZ_OPTION in
        1)
            if ! command -v yq >/dev/null 2>&1; then
                echo -e "${COLOR_YELLOW}${LANG[INSTALLING_YQ]}${COLOR_RESET}"
                
                if ! wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq >/dev/null 2>&1; then
                    echo -e "${COLOR_RED}${LANG[ERROR_DOWNLOADING_YQ]}${COLOR_RESET}"
                    sleep 2
                    log_clear
                    manage_custom_legiz
                    return 1
                fi
                
                if ! chmod +x /usr/bin/yq; then
                    echo -e "${COLOR_RED}${LANG[ERROR_SETTING_YQ_PERMISSIONS]}${COLOR_RESET}"
                    sleep 2
                    log_clear
                    manage_custom_legiz
                    return 1
                fi
                
                echo -e "${COLOR_GREEN}${LANG[YQ_SUCCESSFULLY_INSTALLED]}${COLOR_RESET}"
                sleep 1
            fi
            
            if ! /usr/bin/yq --version >/dev/null 2>&1; then
                echo -e "${COLOR_RED}${LANG[YQ_DOESNT_WORK_AFTER_INSTALLATION]}${COLOR_RESET}"
                sleep 2
                log_clear
                manage_custom_legiz
                return 1
            fi
            
            manage_sub_page_upload
            log_clear
            manage_custom_legiz
            ;;
        2)
            echo -e ""
            echo -e "${COLOR_GREEN}${LANG[CUSTOM_APP_LIST_PANEL_MESSAGE]}${COLOR_RESET}"
            echo -e ""
            sleep 2
            log_clear
            manage_custom_legiz
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            return 0
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[IPV6_INVALID_CHOICE]}${COLOR_RESET}"
            sleep 2
            log_clear
            manage_custom_legiz
            ;;
    esac
}

show_sub_page_menu() {
    menu_head "${LANG[SELECT_SUB_PAGE_CUSTOM2]}"
    menu_item 1 "Orion web page template (support custom app list)"
    menu_item 2 "${LANG[RESTORE_SUB_PAGE]}"
    echo
    menu_item 0 "${LANG[EXIT]}"
    echo
}

download_with_fallback() {
    local primary_url="$1"
    local fallback_url="$2"
    local output_file="$3"

    if curl -s -L -f -o "$output_file" "$primary_url"; then
        return 0
    else
        echo -e "${COLOR_YELLOW}${LANG[DOWNLOAD_FALLBACK]}${COLOR_RESET}"
        if curl -s -L -f -o "$output_file" "$fallback_url"; then
            return 0
        else
            return 1
        fi
    fi
}

branding_add_to_appconfig() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        echo -e "${COLOR_RED}Config file not found: $config_file${COLOR_RESET}"
        return 1
    fi
    
    menu_head "${LANG[BRANDING_SUPPORT_ASK]}"
    menu_item 1 "${LANG[BRANDING_SUPPORT_YES]}"
    menu_item 2 "${LANG[BRANDING_SUPPORT_NO]}"
    echo
    reading "${LANG[EXTENSIONS_PROMPT]}" BRANDING_OPTION

    case $BRANDING_OPTION in
        1)
            reading "${LANG[BRANDING_NAME_PROMPT]}" BRAND_NAME
            reading "${LANG[BRANDING_SUPPORT_URL_PROMPT]}" SUPPORT_URL
            reading "${LANG[BRANDING_LOGO_URL_PROMPT]}" LOGO_URL
            
            jq --arg name "$BRAND_NAME" \
               --arg supportUrl "$SUPPORT_URL" \
               --arg logoUrl "$LOGO_URL" \
               '.config.branding = {
                   "name": $name,
                   "supportUrl": $supportUrl,
                   "logoUrl": $logoUrl
               }' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
            
            echo -e ""
            echo -e "${COLOR_GREEN}${LANG[BRANDING_ADDED_SUCCESS]}${COLOR_RESET}"
            ;;
        2)
            echo -e "${COLOR_YELLOW}${LANG[BRANDING_SUPPORT_NO]}${COLOR_RESET}"
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[INVALID_CHOICE]}${COLOR_RESET}"
            ;;
    esac
}

manage_sub_page_upload() {
    if [ -d "/opt/remnawave/index.html" ] || [ -d "/opt/remnawave/app-config.json" ]; then
        rm -rf "/opt/remnawave/index.html" "/opt/remnawave/app-config.json"
    fi
    
    if ! docker ps -a --filter "name=remnawave-subscription-page" --format '{{.Names}}' | grep -q "^remnawave-subscription-page$"; then
        printf "${COLOR_RED}${LANG[CONTAINER_NOT_FOUND]}${COLOR_RESET}\n" "remnawave-subscription-page"
        sleep 2
        log_clear
        exit 1
    fi
    
    show_sub_page_menu
    reading "${LANG[SELECT_SUB_PAGE_CUSTOM]}" SUB_PAGE_OPTION

    local config_file="/opt/remnawave/app-config.json"
    local index_file="/opt/remnawave/index.html"
    local docker_compose_file="/opt/remnawave/docker-compose.yml"

    case $SUB_PAGE_OPTION in
        1)
            [ -f "$config_file" ] && rm -f "$config_file"
            [ -f "$index_file" ] && rm -f "$index_file"

            echo -e "${COLOR_YELLOW}${LANG[UPLOADING_SUB_PAGE]}${COLOR_RESET}"
            echo -e ""
            local primary_index_url="https://raw.githubusercontent.com/legiz-ru/Orion/refs/heads/main/index.html"
            local fallback_index_url="https://cdn.jsdelivr.net/gh/legiz-ru/Orion@main/index.html"
            if ! download_with_fallback "$primary_index_url" "$fallback_index_url" "$index_file"; then
                echo -e "${COLOR_RED}${LANG[ERROR_FETCH_SUB_PAGE]}${COLOR_RESET}"
                sleep 2
                log_clear
                return 1
            fi

            /usr/bin/yq eval 'del(.services."remnawave-subscription-page".volumes)' -i "$docker_compose_file"
            /usr/bin/yq eval '.services."remnawave-subscription-page".volumes += ["./index.html:/opt/app/frontend/index.html"]' -i "$docker_compose_file"
            ;;

        2)
            [ -f "$config_file" ] && rm -f "$config_file"
            [ -f "$index_file" ] && rm -f "$index_file"

            /usr/bin/yq eval 'del(.services."remnawave-subscription-page".volumes)' -i "$docker_compose_file"
            ;;

        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            log_clear
            manage_custom_legiz
            ;;

        *)
            echo -e "${COLOR_YELLOW}${LANG[SUB_PAGE_SELECT_CHOICE]}${COLOR_RESET}"
            sleep 2
            log_clear
            manage_sub_page_upload
            return 1
            ;;
    esac

    /usr/bin/yq eval -i '... comments=""' "$docker_compose_file" 
    
    sed -i -e '/^  [a-zA-Z-]\+:$/ { x; p; x; }' "$docker_compose_file"
    
    sed -i '/./,$!d' "$docker_compose_file"
    
    sed -i -e '/^networks:/i\' -e '' "$docker_compose_file"
    sed -i -e '/^volumes:/i\' -e '' "$docker_compose_file"

    cd /opt/remnawave || return 1
    docker compose down remnawave-subscription-page > /dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"
    docker compose up -d remnawave-subscription-page > /dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"
    echo -e "${COLOR_GREEN}${LANG[SUB_PAGE_UPDATED_SUCCESS]}${COLOR_RESET}"
}

show_custom_app_menu() {
    menu_head "${LANG[CUSTOM_APP_LIST_MENU]}"
    menu_item 1 "${LANG[EDIT_BRANDING]}"
    menu_item 2 "${LANG[DELETE_APPS]}"
    echo
    menu_item 0 "${LANG[EXIT]}"
    echo
}

manage_custom_app_list() {
    local config_file="/opt/remnawave/app-config.json"
    
    if [ ! -f "$config_file" ]; then
        echo -e "${COLOR_RED}${LANG[CUSTOM_APP_LIST_NOT_FOUND]}${COLOR_RESET}"
        sleep 2
        return 1
    fi
    
    show_custom_app_menu
    reading "${LANG[IPV6_PROMPT]}" APP_OPTION
    
    case $APP_OPTION in
        1)
            edit_branding "$config_file"
            ;;
        2)
            delete_applications "$config_file"
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            return 0
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[INVALID_CHOICE]}${COLOR_RESET}"
            sleep 2
            manage_custom_app_list
            ;;
    esac
}

edit_branding() {
    local config_file="$1"
    local needs_restart=false
    
    # Check if branding exists
    if jq -e '.config.branding' "$config_file" > /dev/null 2>&1; then
        echo -e ""
        echo -e "${COLOR_GREEN}${LANG[BRANDING_CURRENT_VALUES]}${COLOR_RESET}"
        local logo_url=$(jq -r '.config.branding.logoUrl // "N/A"' "$config_file")
        local name=$(jq -r '.config.branding.name // "N/A"' "$config_file")
        local support_url=$(jq -r '.config.branding.supportUrl // "N/A"' "$config_file")
        
        echo -e "${COLOR_YELLOW}${LANG[BRANDING_LOGO_URL]} ${COLOR_WHITE}$logo_url${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}${LANG[BRANDING_NAME]} ${COLOR_WHITE}$name${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}${LANG[BRANDING_SUPPORT_URL]} ${COLOR_WHITE}$support_url${COLOR_RESET}"
    fi
    
    menu_head "${LANG[EDIT_BRANDING]}"
    menu_item 1 "${LANG[EDIT_LOGO]}"
    menu_item 2 "${LANG[EDIT_NAME]}"
    menu_item 3 "${LANG[EDIT_SUPPORT_URL]}"
    echo
    menu_item 0 "${LANG[EXIT]}"
    echo
    reading "${LANG[IPV6_PROMPT]}" BRANDING_OPTION
    
    case $BRANDING_OPTION in
        1)
            reading "${LANG[ENTER_NEW_LOGO]}" new_logo
            reading "${LANG[CONFIRM_CHANGE]}" confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                jq --arg logo "$new_logo" '.config.branding.logoUrl = $logo' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
                needs_restart=true
            fi
            ;;
        2)
            reading "${LANG[ENTER_NEW_NAME]}" new_name
            reading "${LANG[CONFIRM_CHANGE]}" confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                jq --arg name "$new_name" '.config.branding.name = $name' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
                needs_restart=true
            fi
            ;;
        3)
            reading "${LANG[ENTER_NEW_SUPPORT]}" new_support
            reading "${LANG[CONFIRM_CHANGE]}" confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                jq --arg support "$new_support" '.config.branding.supportUrl = $support' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
                needs_restart=true
            fi
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            return 0
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[INVALID_CHOICE]}${COLOR_RESET}"
            sleep 2
            edit_branding "$config_file"
            ;;
    esac
    
    # Restart container if changes were made
    if [ "$needs_restart" = true ]; then
        echo -e ""
        echo -e "${COLOR_GREEN}${LANG[BRANDING_ADDED_SUCCESS]}${COLOR_RESET}"
        
        # Restart subscription page container
        cd /opt/remnawave || return 1
        docker compose down remnawave-subscription-page > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
        docker compose up -d remnawave-subscription-page > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
    fi
}

delete_applications() {
    local config_file="$1"
    
    # Get platforms with non-empty arrays
    local platforms=$(jq -r '.platforms | to_entries[] | select(.value | length > 0) | .key' "$config_file" 2>/dev/null)
    
    if [ -z "$platforms" ]; then
        echo -e "${COLOR_RED}${LANG[NO_APPS_FOUND]}${COLOR_RESET}"
        sleep 2
        return 1
    fi
    
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[PLATFORM_SELECT]}${COLOR_RESET}"
    echo -e ""
    
    local i=1
    declare -A platform_map
    while IFS= read -r platform; do
        menu_item "$i" "$platform"
        platform_map[$i]="$platform"
        ((i++))
    done <<< "$platforms"

    echo
    menu_item 0 "${LANG[EXIT]}"
    echo
    reading "${LANG[IPV6_PROMPT]}" PLATFORM_OPTION
    
    if [ "$PLATFORM_OPTION" == "0" ]; then
        echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
        return 0
    fi
    
    if [ -z "${platform_map[$PLATFORM_OPTION]}" ]; then
        echo -e "${COLOR_RED}${LANG[INVALID_CHOICE]}${COLOR_RESET}"
        sleep 2
        delete_applications "$config_file"
        return 1
    fi
    
    local selected_platform=${platform_map[$PLATFORM_OPTION]}
    
    # Get applications from selected platform
    local apps=$(jq -r --arg platform "$selected_platform" '.platforms[$platform][] | .name // .id' "$config_file" 2>/dev/null)
    
    if [ -z "$apps" ]; then
        echo -e "${COLOR_RED}${LANG[NO_APPS_FOUND]}${COLOR_RESET}"
        sleep 2
        return 1
    fi
    
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[APP_SELECT]}${COLOR_RESET}"
    echo -e ""
    
    local j=1
    declare -A app_map
    while IFS= read -r app; do
        menu_item "$j" "$app"
        app_map[$j]="$app"
        ((j++))
    done <<< "$apps"

    echo
    menu_item 0 "${LANG[EXIT]}"
    echo
    reading "${LANG[IPV6_PROMPT]}" APP_DELETE_OPTION
    
    if [ "$APP_DELETE_OPTION" == "0" ]; then
        echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
        return 0
    fi
    
    if [ -z "${app_map[$APP_DELETE_OPTION]}" ]; then
        echo -e "${COLOR_RED}${LANG[INVALID_CHOICE]}${COLOR_RESET}"
        sleep 2
        delete_applications "$config_file"
        return 1
    fi
    
    local selected_app=${app_map[$APP_DELETE_OPTION]}
    
    printf "${COLOR_YELLOW}${LANG[CONFIRM_DELETE_APP]}${COLOR_RESET}\n" "$selected_app" "$selected_platform"
    read confirm
    
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        # Remove the application from the platform array
        jq --arg platform "$selected_platform" --arg app_name "$selected_app" '
        .platforms[$platform] = [.platforms[$platform][] | select((.name // .id) != $app_name)]
        ' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
        
        echo -e "${COLOR_GREEN}${LANG[APP_DELETED_SUCCESS]}${COLOR_RESET}"
        
        # Restart subscription page container
        cd /opt/remnawave || return 1
        docker compose down remnawave-subscription-page > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
        docker compose up -d remnawave-subscription-page > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
    else
        echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
    fi
}
#Extensions by legiz

add_cron_rule() {
    local rule="$1"
    local logged_rule="${rule} >> ${DIR_REMNAWAVE}cron_jobs.log 2>&1"

    if ! crontab -u root -l > /dev/null 2>&1; then
        crontab -u root -l 2>/dev/null | crontab -u root -
    fi

    if ! crontab -u root -l | grep -Fxq "$logged_rule"; then
        (crontab -u root -l 2>/dev/null; echo "$logged_rule") | crontab -u root -
    fi
}

spinner() {
  local pid=$1
  local text=$2

  export LC_ALL=C.UTF-8
  export LANG=C.UTF-8

  local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local text_code="$COLOR_GREEN"
  local bg_code=""
  local effect_code="\033[1m"
  local delay=0.1
  local reset_code="$COLOR_RESET"

  printf "${effect_code}${text_code}${bg_code}%s${reset_code}" "$text" > /dev/tty

  while kill -0 "$pid" 2>/dev/null; do
    for (( i=0; i<${#spinstr}; i++ )); do
      printf "\r${effect_code}${text_code}${bg_code}[%s] %s${reset_code}" "$(echo -n "${spinstr:$i:1}")" "$text" > /dev/tty
      sleep $delay
    done
  done

  printf "\r\033[K" > /dev/tty
}

#Extensions by legiz
show_custom_legiz_menu() {
    menu_head "${LANG[MENU_5]}"
    menu_item 1 "${LANG[SELECT_SUB_PAGE_CUSTOM1]}"
    menu_item 2 "${LANG[CUSTOM_APP_LIST_MENU]}"
    echo
    menu_item 0 "${LANG[EXIT]}"
    echo
}

install_packages() {
    echo -e "${COLOR_YELLOW}${LANG[INSTALL_PACKAGES]}${COLOR_RESET}"

    if ! apt-get update -y; then
        echo -e "${COLOR_RED}${LANG[ERROR_UPDATE_LIST]}${COLOR_RESET}" >&2
        return 1
    fi

    if ! apt-get install -y ca-certificates curl jq ufw wget gnupg unzip nano dialog git certbot python3-certbot-dns-cloudflare unattended-upgrades locales dnsutils coreutils grep gawk python3-pip; then
        echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_PACKAGES]}${COLOR_RESET}" >&2
        return 1
    fi

    if ! dpkg -l | grep -q '^ii.*cron '; then
        if ! apt-get install -y cron; then
            echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_CRON]}" "${COLOR_RESET}" >&2
            return 1
        fi
    fi

    if ! systemctl is-active --quiet cron; then
        if ! systemctl start cron; then
            echo -e "${COLOR_RED}${LANG[START_CRON_ERROR]}${COLOR_RESET}" >&2
            return 1
        fi
    fi
    if ! systemctl is-enabled --quiet cron; then
        if ! systemctl enable cron; then
            echo -e "${COLOR_RED}${LANG[START_CRON_ERROR]}${COLOR_RESET}" >&2
            return 1
        fi
    fi

    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        echo -e "${COLOR_YELLOW}Installing Docker via get.docker.com...${COLOR_RESET}"

        # Docker + images need a few GB. A disk-full failure from apt/dpkg is
        # cryptic ("disk full error" buried in apport noise), so warn up front.
        local _root_free_mb
        _root_free_mb="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
        if [ -n "$_root_free_mb" ] && [ "$_root_free_mb" -lt 2500 ]; then
            echo -e "${COLOR_YELLOW}$(printf "${LANG[WARN_LOW_DISK_DOCKER]:-Warning: only %s MB free on / — Docker needs ~2.5 GB. Install may fail; free up space or grow the disk.}" "$_root_free_mb")${COLOR_RESET}" >&2
        fi

        if ! curl -fsSL https://get.docker.com -o /tmp/get-docker.sh; then
            echo -e "${COLOR_RED}${LANG[ERROR_DOWNLOAD_DOCKER_KEY]}${COLOR_RESET}" >&2
            return 1
        fi

        if ! sh /tmp/get-docker.sh; then
            # Distinguish a disk-full failure from a generic one for a clear message.
            _root_free_mb="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
            if [ -n "$_root_free_mb" ] && [ "$_root_free_mb" -lt 500 ]; then
                echo -e "${COLOR_RED}$(printf "${LANG[ERROR_INSTALL_DOCKER_DISK]:-Docker install failed: no free disk space (%s MB left on /). Grow the disk or free space, then re-run.}" "$_root_free_mb")${COLOR_RESET}" >&2
            else
                echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}" >&2
            fi
            return 1
        fi
    fi

    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[ERROR_DOCKER_NOT_INSTALLED]}${COLOR_RESET}" >&2
        return 1
    fi

    if ! systemctl is-active --quiet docker; then
        if ! systemctl start docker; then
            echo -e "${COLOR_RED}${LANG[ERROR_START_DOCKER]}${COLOR_RESET}" >&2
            return 1
        fi
    fi

    if ! systemctl is-enabled --quiet docker; then
        if ! systemctl enable docker; then
            echo -e "${COLOR_RED}${LANG[ERROR_ENABLE_DOCKER]}${COLOR_RESET}" >&2
            return 1
        fi
    fi

    if ! docker info >/dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[ERROR_DOCKER_NOT_WORKING]}${COLOR_RESET}" >&2
        return 1
    fi

    # BBR
    if ! grep -q "net.core.default_qdisc = fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    fi
    sysctl -p >/dev/null

    # UFW
    if ! ufw allow 22/tcp comment 'SSH' || ! ufw allow 443/tcp comment 'HTTPS' || ! ufw --force enable; then
        echo -e "${COLOR_RED}${LANG[ERROR_CONFIGURE_UFW]}${COLOR_RESET}" >&2
        return 1
    fi

    # Unattended-upgrades
    echo 'Unattended-Upgrade::Mail "root";' >> /etc/apt/apt.conf.d/50unattended-upgrades
    echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections
    if ! dpkg-reconfigure -f noninteractive unattended-upgrades || ! systemctl restart unattended-upgrades; then
        echo -e "${COLOR_RED}${LANG[ERROR_CONFIGURE_UPGRADES]}" "${COLOR_RESET}" >&2
        return 1
    fi

    touch ${DIR_REMNAWAVE}install_packages
    echo -e "${COLOR_GREEN}${LANG[SUCCESS_INSTALL]}${COLOR_RESET}"
    clear
}

extract_domain() {
    local SUBDOMAIN=$1
    echo "$SUBDOMAIN" | awk -F'.' '{if (NF > 2) {print $(NF-1)"."$NF} else {print $0}}'
}

check_domain() {
    local domain="$1"
    local show_warning="${2:-true}"
    local allow_cf_proxy="${3:-true}"

    local domain_ip=$(dig +short A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
    local server_ip=$(curl -s -4 ifconfig.me || curl -s -4 api.ipify.org || curl -s -4 ipinfo.io/ip)

    if [ -z "$domain_ip" ] || [ -z "$server_ip" ]; then
        if [ "$show_warning" = true ]; then
            echo -e "${COLOR_YELLOW}${LANG[WARNING_LABEL]}${COLOR_RESET}"
            echo -e "${COLOR_RED}${LANG[CHECK_DOMAIN_IP_FAIL]}${COLOR_RESET}"
            printf "${COLOR_YELLOW}${LANG[CHECK_DOMAIN_IP_FAIL_INSTRUCTION]}${COLOR_RESET}\n" "$domain" "$server_ip"
            reading "${LANG[CONFIRM_PROMPT]}" confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                return 2
            fi
        fi
        return 1
    fi

    local cf_ranges=$(curl -s https://www.cloudflare.com/ips-v4)
    local cf_array=()
    if [ -n "$cf_ranges" ]; then
        IFS=$'\n' read -r -d '' -a cf_array <<<"$cf_ranges"
    fi

    local ip_in_cloudflare=false
    local IFS='.'
    read -r a b c d <<<"$domain_ip"
    local domain_ip_int=$(( (a << 24) + (b << 16) + (c << 8) + d ))

    if [ ${#cf_array[@]} -gt 0 ]; then
        for cidr in "${cf_array[@]}"; do
            if [[ -z "$cidr" ]]; then
                continue
            fi
            local network=$(echo "$cidr" | cut -d'/' -f1)
            local mask=$(echo "$cidr" | cut -d'/' -f2)
            read -r a b c d <<<"$network"
            local network_int=$(( (a << 24) + (b << 16) + (c << 8) + d ))
            local mask_bits=$(( 32 - mask ))
            local range_size=$(( 1 << mask_bits ))
            local min_ip_int=$network_int
            local max_ip_int=$(( network_int + range_size - 1 ))

            if [ "$domain_ip_int" -ge "$min_ip_int" ] && [ "$domain_ip_int" -le "$max_ip_int" ]; then
                ip_in_cloudflare=true
                break
            fi
        done
    fi

    if [ "$domain_ip" = "$server_ip" ]; then
        return 0
    elif [ "$ip_in_cloudflare" = true ]; then
        if [ "$allow_cf_proxy" = true ]; then
            return 0
        else
            if [ "$show_warning" = true ]; then
                echo -e "${COLOR_YELLOW}${LANG[WARNING_LABEL]}${COLOR_RESET}"
                printf "${COLOR_RED}${LANG[CHECK_DOMAIN_CLOUDFLARE]}${COLOR_RESET}\n" "$domain" "$domain_ip"
                echo -e "${COLOR_YELLOW}${LANG[CHECK_DOMAIN_CLOUDFLARE_INSTRUCTION]}${COLOR_RESET}"
                reading "${LANG[CONFIRM_PROMPT]}" confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    return 1
                else
                    return 2
                fi
            fi
            return 1
        fi
    else
        if [ "$show_warning" = true ]; then
            echo -e "${COLOR_YELLOW}${LANG[WARNING_LABEL]}${COLOR_RESET}"
            printf "${COLOR_RED}${LANG[CHECK_DOMAIN_MISMATCH]}${COLOR_RESET}\n" "$domain" "$domain_ip" "$server_ip"
            echo -e "${COLOR_YELLOW}${LANG[CHECK_DOMAIN_MISMATCH_INSTRUCTION]}${COLOR_RESET}"
            reading "${LANG[CONFIRM_PROMPT]}" confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                return 1
            else
                return 2
            fi
        fi
        return 1
    fi

    return 0
}

is_wildcard_cert() {
    local domain=$1
    local cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"

    if [ ! -f "$cert_path" ]; then
        return 1
    fi

    if openssl x509 -noout -text -in "$cert_path" | grep -q "\*\.$domain"; then
        return 0
    else
        return 1
    fi
}

check_certificates() {
    local DOMAIN=$1
    local cert_dir="/etc/letsencrypt/live"

    if [ ! -d "$cert_dir" ]; then
        echo -e "${COLOR_RED}${LANG[CERT_NOT_FOUND]} $DOMAIN${COLOR_RESET}"
        return 1
    fi

    local live_dir=$(find "$cert_dir" -maxdepth 1 -type d -name "${DOMAIN}*" 2>/dev/null | sort -V | tail -n 1)
    if [ -n "$live_dir" ] && [ -d "$live_dir" ]; then
        local files=("cert.pem" "chain.pem" "fullchain.pem" "privkey.pem")
        for file in "${files[@]}"; do
            local file_path="$live_dir/$file"
            if [ ! -f "$file_path" ]; then
                echo -e "${COLOR_RED}${LANG[CERT_NOT_FOUND]} $DOMAIN (missing $file)${COLOR_RESET}"
                return 1
            fi
            if [ ! -L "$file_path" ]; then
                fix_letsencrypt_structure "$(basename "$live_dir")"
                if [ $? -ne 0 ]; then
                    echo -e "${COLOR_RED}${LANG[CERT_NOT_FOUND]} $DOMAIN (failed to fix structure)${COLOR_RESET}"
                    return 1
                fi
            fi
        done
        echo -e "${COLOR_GREEN}${LANG[CERT_FOUND]}$(basename "$live_dir")${COLOR_RESET}"
        return 0
    fi

    local base_domain=$(extract_domain "$DOMAIN")
    if [ "$base_domain" != "$DOMAIN" ]; then
        live_dir=$(find "$cert_dir" -maxdepth 1 -type d -name "${base_domain}*" 2>/dev/null | sort -V | tail -n 1)
        if [ -n "$live_dir" ] && [ -d "$live_dir" ] && is_wildcard_cert "$base_domain"; then
            echo -e "${COLOR_GREEN}${LANG[WILDCARD_CERT_FOUND]}$base_domain ${LANG[FOR_DOMAIN]} $DOMAIN${COLOR_RESET}"
            return 0
        fi
    fi

    echo -e "${COLOR_RED}${LANG[CERT_NOT_FOUND]} $DOMAIN${COLOR_RESET}"
    return 1
}

check_api() {
    local attempts=3
    local attempt=1

    while [ $attempt -le $attempts ]; do
        if [[ $CLOUDFLARE_API_KEY =~ [A-Z] ]]; then
            api_response=$(curl --silent --request GET --url https://api.cloudflare.com/client/v4/zones --header "Authorization: Bearer ${CLOUDFLARE_API_KEY}" --header "Content-Type: application/json")
        else
            api_response=$(curl --silent --request GET --url https://api.cloudflare.com/client/v4/zones --header "X-Auth-Key: ${CLOUDFLARE_API_KEY}" --header "X-Auth-Email: ${CLOUDFLARE_EMAIL}" --header "Content-Type: application/json")
        fi

        if echo "$api_response" | grep -q '"success":true'; then
            echo -e "${COLOR_GREEN}${LANG[CF_VALIDATING]}${COLOR_RESET}"
            return 0
        else
            echo -e "${COLOR_RED}$(printf "${LANG[CF_INVALID_ATTEMPT]}" "$attempt" "$attempts")${COLOR_RESET}"
            if [ $attempt -lt $attempts ]; then
                reading "${LANG[ENTER_CF_TOKEN]}" CLOUDFLARE_API_KEY
                reading "${LANG[ENTER_CF_EMAIL]}" CLOUDFLARE_EMAIL
            fi
            attempt=$((attempt + 1))
        fi
    done
    error "$(printf "${LANG[CF_INVALID]}" "$attempts")"
}

get_certificates() {
    local DOMAIN=$1
    local CERT_METHOD=$2
    local LETSENCRYPT_EMAIL=$3
    local BASE_DOMAIN=$(extract_domain "$DOMAIN")
    local WILDCARD_DOMAIN="*.$BASE_DOMAIN"

    printf "${COLOR_YELLOW}${LANG[GENERATING_CERTS]}${COLOR_RESET}\n" "$DOMAIN"

    case $CERT_METHOD in
        1)
            # Cloudflare API (DNS-01 support wildcard)
            reading "${LANG[ENTER_CF_TOKEN]}" CLOUDFLARE_API_KEY
            reading "${LANG[ENTER_CF_EMAIL]}" CLOUDFLARE_EMAIL

            check_api

            mkdir -p ~/.secrets/certbot
            if [[ $CLOUDFLARE_API_KEY =~ [A-Z] ]]; then
                cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_api_token = $CLOUDFLARE_API_KEY
EOL
            else
                cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_email = $CLOUDFLARE_EMAIL
dns_cloudflare_api_key = $CLOUDFLARE_API_KEY
EOL
            fi
            chmod 600 ~/.secrets/certbot/cloudflare.ini

            certbot certonly \
                --dns-cloudflare \
                --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini \
                --dns-cloudflare-propagation-seconds 60 \
                -d "$BASE_DOMAIN" \
                -d "$WILDCARD_DOMAIN" \
                --email "$CLOUDFLARE_EMAIL" \
                --agree-tos \
                --non-interactive \
                --key-type ecdsa \
                --elliptic-curve secp384r1
            ;;
        2)
            # ACME HTTP-01 (without wildcard)
            ufw allow 80/tcp comment 'HTTP for ACME challenge' > /dev/null 2>&1

            certbot certonly \
                --standalone \
                -d "$DOMAIN" \
                --email "$LETSENCRYPT_EMAIL" \
                --agree-tos \
                --non-interactive \
                --http-01-port 80 \
                --key-type ecdsa \
                --elliptic-curve secp384r1

            ufw delete allow 80/tcp > /dev/null 2>&1
            ufw reload > /dev/null 2>&1
            ;;
        3)
            # Gcore DNS-01 (wildcard)

            if ! certbot plugins 2>/dev/null | grep -q "dns-gcore"; then
                echo -e "${COLOR_YELLOW}Installing certbot-dns-gcore plugin...${COLOR_RESET}"
                
                if python3 -m pip install --help 2>&1 | grep -q "break-system-packages"; then
                    python3 -m pip install --break-system-packages certbot-dns-gcore >/dev/null 2>&1
                else
                python3 -m pip install certbot-dns-gcore >/dev/null 2>&1
                fi
                    
                if certbot plugins 2>/dev/null | grep -q "dns-gcore"; then
                    echo -e "${COLOR_GREEN}Plugin installed successfully.${COLOR_RESET}"
                else
                    echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_GCORE_PLUGIN]}${COLOR_RESET}"
                    exit 1
                fi
            else
                echo -e "${COLOR_GREEN}Gcore plugin already available.${COLOR_RESET}"
            fi

            reading "${LANG[ENTER_GCORE_TOKEN]}" GCORE_API_KEY

            mkdir -p ~/.secrets/certbot
            cat > ~/.secrets/certbot/gcore.ini <<EOL
dns_gcore_apitoken = $GCORE_API_KEY
EOL
            chmod 600 ~/.secrets/certbot/gcore.ini

            certbot certonly \
                --authenticator dns-gcore \
                --dns-gcore-credentials ~/.secrets/certbot/gcore.ini \
                --dns-gcore-propagation-seconds 80 \
                -d "$BASE_DOMAIN" \
                -d "$WILDCARD_DOMAIN" \
                --email "$LETSENCRYPT_EMAIL" \
                --agree-tos \
                --non-interactive \
                --key-type ecdsa \
                --elliptic-curve secp384r1
            ;;
        *)
            echo -e "${COLOR_RED}${LANG[INVALID_CERT_METHOD]}${COLOR_RESET}"
            exit 1
            ;;
    esac

    if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        echo -e "${COLOR_RED}${LANG[CERT_GENERATION_FAILED]} $DOMAIN${COLOR_RESET}"
        exit 1
    fi
}

#Manage Certificates
show_manage_certificates() {
    menu_head "${LANG[MENU_8]}"
    menu_item 1 "${LANG[CERT_UPDATE]}"
    menu_item 2 "${LANG[CERT_GENERATE]}"
    echo
    menu_item 0 "${LANG[EXIT]}"
    echo
}

manage_certificates() {
    show_manage_certificates
    reading "${LANG[CERT_PROMPT1]}" CERT_OPTION
    case $CERT_OPTION in
        1)
            if ! command -v certbot >/dev/null 2>&1; then
                install_packages || {
                    echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_CERTBOT]}${COLOR_RESET}"
                    log_clear
                    exit 1
                }
            fi
            update_current_certificates
            log_clear
            ;;
        2)
            if ! command -v certbot >/dev/null 2>&1; then
                install_packages || {
                    echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_CERTBOT]}${COLOR_RESET}"
                    log_clear
                    exit 1
                }
            fi
            generate_new_certificates
            log_clear
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            speedwave
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}"
            exit 1
            ;;
    esac
}

update_current_certificates() {
    local cert_dir="/etc/letsencrypt/live"
    if [ ! -d "$cert_dir" ]; then
        echo -e "${COLOR_RED}${LANG[CERT_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    declare -A unique_domains
    declare -A cert_status
    local renew_threshold=30
    local log_dir="/var/log/letsencrypt"

    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
        chmod 755 "$log_dir"
    fi

    for domain_dir in "$cert_dir"/*; do
        if [ -d "$domain_dir" ]; then
            local domain=$(basename "$domain_dir")
            local cert_domain
            cert_domain=$(echo "$domain" | sed -E 's/(-[0-9]+)$//')
            unique_domains["$cert_domain"]="$domain_dir"
        fi
    done

    for cert_domain in "${!unique_domains[@]}"; do
        local domain_dir="${unique_domains[$cert_domain]}"
        local domain
        domain=$(basename "$domain_dir")

        local cert_method="2" # 2 = ACME HTTP-01
        local renewal_conf="/etc/letsencrypt/renewal/$domain.conf"

        if [ -f "$renewal_conf" ]; then
            if grep -q "dns_cloudflare" "$renewal_conf"; then
                cert_method="1" # Cloudflare DNS-01
            elif grep -q "dns-gcore" "$renewal_conf"; then
                cert_method="3" # Gcore DNS-01
            fi
        fi

        local cert_file="$domain_dir/fullchain.pem"
        local cert_mtime_before
        cert_mtime_before=$(stat -c %Y "$cert_file" 2>/dev/null || echo 0)

        fix_letsencrypt_structure "$cert_domain"

        local days_left
        days_left=$(check_cert_expiry "$domain")
        if [ $? -ne 0 ]; then
            cert_status["$cert_domain"]="${LANG[ERROR_PARSING_CERT]}"
            continue
        fi

        if [ "$cert_method" == "1" ]; then
            # Cloudflare
            local cf_credentials_file
            cf_credentials_file=$(grep "dns_cloudflare_credentials" "$renewal_conf" | cut -d'=' -f2 | tr -d ' ')
            if [ -n "$cf_credentials_file" ] && [ ! -f "$cf_credentials_file" ]; then
                echo -e "${COLOR_RED}${LANG[CERT_CLOUDFLARE_FILE_NOT_FOUND]}${COLOR_RESET}"
                reading "${COLOR_YELLOW}${LANG[ENTER_CF_EMAIL]}${COLOR_RESET}" CLOUDFLARE_EMAIL
                reading "${COLOR_YELLOW}${LANG[ENTER_CF_TOKEN]}${COLOR_RESET}" CLOUDFLARE_API_KEY

                check_api

                mkdir -p "$(dirname "$cf_credentials_file")"
                cat > "$cf_credentials_file" <<EOL
dns_cloudflare_email = $CLOUDFLARE_EMAIL
dns_cloudflare_api_key = $CLOUDFLARE_API_KEY
EOL
                chmod 600 "$cf_credentials_file"
            fi
        elif [ "$cert_method" == "3" ]; then
            # Gcore
            local gcore_credentials_file
            gcore_credentials_file=$(grep "dns-gcore-credentials" "$renewal_conf" | cut -d'=' -f2 | tr -d ' ')
            if [ -n "$gcore_credentials_file" ] && [ ! -f "$gcore_credentials_file" ]; then
                echo -e "${COLOR_RED}${LANG[CERT_GCORE_FILE_NOT_FOUND]}${COLOR_RESET}"
                reading "${COLOR_YELLOW}${LANG[ENTER_GCORE_TOKEN]}${COLOR_RESET}" GCORE_API_KEY

                mkdir -p "$(dirname "$gcore_credentials_file")"
                cat > "$gcore_credentials_file" <<EOL
dns_gcore_apitoken = $GCORE_API_KEY
EOL
                chmod 600 "$gcore_credentials_file"
            fi
        fi

        if [ "$days_left" -le "$renew_threshold" ]; then
            if [ "$cert_method" == "2" ]; then
                ufw allow 80/tcp && ufw reload >/dev/null 2>&1
            fi

            certbot renew --cert-name "$domain" --no-random-sleep-on-renew >> /var/log/letsencrypt/letsencrypt.log 2>&1 &
            local cert_pid=$!
            spinner $cert_pid "${LANG[WAITING]}"
            wait $cert_pid
            local certbot_exit_code=$?

            if [ "$cert_method" == "2" ]; then
                ufw delete allow 80/tcp && ufw reload >/dev/null 2>&1
            fi

            if [ "$certbot_exit_code" -ne 0 ]; then
                cert_status["$cert_domain"]="${LANG[ERROR_UPDATE]}: ${LANG[RATE_LIMIT_EXCEEDED]}"
                continue
            fi

            local new_cert_dir
            new_cert_dir=$(find "$cert_dir" -maxdepth 1 -type d -name "$cert_domain*" | sort -V | tail -n 1)
            local new_domain
            new_domain=$(basename "$new_cert_dir")
            local cert_mtime_after
            cert_mtime_after=$(stat -c %Y "$new_cert_dir/fullchain.pem" 2>/dev/null || echo 0)

            if check_certificates "$new_domain" > /dev/null 2>&1 && [ "$cert_mtime_before" != "$cert_mtime_after" ]; then
                local new_days_left
                new_days_left=$(check_cert_expiry "$new_domain")
                if [ $? -eq 0 ]; then
                    cert_status["$cert_domain"]="${LANG[UPDATED]}"
                else
                    cert_status["$cert_domain"]="${LANG[ERROR_PARSING_CERT]}"
                fi
            else
                cert_status["$cert_domain"]="${LANG[ERROR_UPDATE]}"
            fi
        else
            cert_status["$cert_domain"]="${LANG[REMAINING]} $days_left ${LANG[DAYS]}"
            continue
        fi
    done

    echo -e "${COLOR_YELLOW}${LANG[RESULTS_CERTIFICATE_UPDATES]}${COLOR_RESET}"
    for cert_domain in "${!cert_status[@]}"; do
        if [[ "${cert_status[$cert_domain]}" == "${LANG[UPDATED]}" ]]; then
            echo -e "${COLOR_GREEN}${LANG[CERTIFICATE_FOR]}$cert_domain ${LANG[SUCCESSFULLY_UPDATED]}${COLOR_RESET}"
        elif [[ "${cert_status[$cert_domain]}" =~ "${LANG[ERROR_UPDATE]}" ]]; then
            echo -e "${COLOR_RED}${LANG[FAILED_TO_UPDATE_CERTIFICATE_FOR]}$cert_domain: ${cert_status[$cert_domain]}${COLOR_RESET}"
        elif [[ "${cert_status[$cert_domain]}" == "${LANG[ERROR_PARSING_CERT]}" ]]; then
            echo -e "${COLOR_RED}${LANG[ERROR_CHECKING_EXPIRY_FOR]}$cert_domain${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}${LANG[CERTIFICATE_FOR]}$cert_domain ${LANG[DOES_NOT_REQUIRE_UPDATE]}${cert_status[$cert_domain]})${COLOR_RESET}"
        fi
    done

    sleep 2
    log_clear
    speedwave
}

generate_new_certificates() {
    reading "${LANG[CERT_GENERATE_PROMPT]}" NEW_DOMAIN

    menu_head "${LANG[CERT_METHOD_PROMPT]}"
    menu_item 1 "${LANG[CERT_METHOD_CF]}"
    menu_item 2 "${LANG[CERT_METHOD_ACME]}"
    menu_item 3 "${LANG[CERT_METHOD_GCORE]}"
    echo
    menu_item 0 "${LANG[EXIT]}"
    echo
    reading "${LANG[CERT_METHOD_CHOOSE]}" CERT_METHOD

    if [ "$CERT_METHOD" == "0" ]; then
        echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
        exit 1
    fi

    local LETSENCRYPT_EMAIL=""
    if [ "$CERT_METHOD" == "2" ] || [ "$CERT_METHOD" == "3" ]; then
        reading "${LANG[EMAIL_PROMPT]}" LETSENCRYPT_EMAIL
    fi

    if [ "$CERT_METHOD" == "1" ] || [ "$CERT_METHOD" == "3" ]; then
        # 1 = CF DNS-01, 3 = Gcore DNS-01 — wildcard
        echo -e "${COLOR_YELLOW}${LANG[GENERATING_WILDCARD_CERT]} *.$NEW_DOMAIN...${COLOR_RESET}"
        get_certificates "$NEW_DOMAIN" "$CERT_METHOD" "$LETSENCRYPT_EMAIL"
    elif [ "$CERT_METHOD" == "2" ]; then
        # 2 = ACME HTTP-01
        echo -e "${COLOR_YELLOW}${LANG[GENERATING_CERTS]} $NEW_DOMAIN...${COLOR_RESET}"
        get_certificates "$NEW_DOMAIN" "2" "$LETSENCRYPT_EMAIL"
    else
        echo -e "${COLOR_RED}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}"
        exit 1
    fi

    if check_certificates "$NEW_DOMAIN"; then
        echo -e "${COLOR_GREEN}${LANG[CERT_UPDATE_SUCCESS]}${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}${LANG[CERT_GENERATION_FAILED]}${COLOR_RESET}"
    fi

    sleep 2
    log_clear
    speedwave
}

check_cert_expiry() {
    local domain="$1"
    local cert_dir="/etc/letsencrypt/live"
    local live_dir=$(find "$cert_dir" -maxdepth 1 -type d -name "${domain}*" | sort -V | tail -n 1)
    if [ -z "$live_dir" ] || [ ! -d "$live_dir" ]; then
        return 1
    fi
    local cert_file="$live_dir/fullchain.pem"
    if [ ! -f "$cert_file" ]; then
        return 1
    fi
    local expiry_date=$(openssl x509 -in "$cert_file" -noout -enddate | sed 's/notAfter=//')
    if [ -z "$expiry_date" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_PARSING_CERT]}${COLOR_RESET}"
        return 1
    fi
    local expiry_epoch=$(TZ=UTC date -d "$expiry_date" +%s 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_PARSING_CERT]}${COLOR_RESET}"
        return 1
    fi
    local current_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
    echo "$days_left"
    return 0
}

fix_letsencrypt_structure() {
    local domain=$1
    local live_dir="/etc/letsencrypt/live/$domain"
    local archive_dir="/etc/letsencrypt/archive/$domain"
    local renewal_conf="/etc/letsencrypt/renewal/$domain.conf"

    if [ ! -d "$live_dir" ]; then
        echo -e "${COLOR_RED}${LANG[CERT_NOT_FOUND]}${COLOR_RESET}"
        return 1
    fi
    if [ ! -d "$archive_dir" ]; then
        echo -e "${COLOR_RED}${LANG[ARCHIVE_NOT_FOUND]}${COLOR_RESET}"
        return 1
    fi
    if [ ! -f "$renewal_conf" ]; then
        echo -e "${COLOR_RED}${LANG[RENEWAL_CONF_NOT_FOUND]}${COLOR_RESET}"
        return 1
    fi

    local conf_archive_dir=$(grep "^archive_dir" "$renewal_conf" | cut -d'=' -f2 | tr -d ' ')
    if [ "$conf_archive_dir" != "$archive_dir" ]; then
        echo -e "${COLOR_RED}${LANG[ARCHIVE_DIR_MISMATCH]}${COLOR_RESET}"
        return 1
    fi

    local latest_version=$(ls -1 "$archive_dir" | grep -E 'cert[0-9]+.pem' | sort -V | tail -n 1 | sed -E 's/.*cert([0-9]+)\.pem/\1/')
    if [ -z "$latest_version" ]; then
        echo -e "${COLOR_RED}${LANG[CERT_VERSION_NOT_FOUND]}${COLOR_RESET}"
        return 1
    fi

    local files=("cert" "chain" "fullchain" "privkey")
    for file in "${files[@]}"; do
        local archive_file="$archive_dir/$file$latest_version.pem"
        local live_file="$live_dir/$file.pem"
        if [ ! -f "$archive_file" ]; then
            echo -e "${COLOR_RED}${LANG[FILE_NOT_FOUND]} $archive_file${COLOR_RESET}"
            return 1
        fi
        if [ -f "$live_file" ] && [ ! -L "$live_file" ]; then
            rm "$live_file"
        fi
        ln -sf "$archive_file" "$live_file"
    done

    local cert_path="$live_dir/cert.pem"
    local chain_path="$live_dir/chain.pem"
    local fullchain_path="$live_dir/fullchain.pem"
    local privkey_path="$live_dir/privkey.pem"
    if ! grep -q "^cert = $cert_path" "$renewal_conf"; then
        sed -i "s|^cert =.*|cert = $cert_path|" "$renewal_conf"
    fi
    if ! grep -q "^chain = $chain_path" "$renewal_conf"; then
        sed -i "s|^chain =.*|chain = $chain_path|" "$renewal_conf"
    fi
    if ! grep -q "^fullchain = $fullchain_path" "$renewal_conf"; then
        sed -i "s|^fullchain =.*|fullchain = $fullchain_path|" "$renewal_conf"
    fi
    if ! grep -q "^privkey = $privkey_path" "$renewal_conf"; then
        sed -i "s|^privkey =.*|privkey = $privkey_path|" "$renewal_conf"
    fi

    local expected_hook="renew_hook = sh -c 'cd /opt/remnawave && docker compose down remnawave-nginx && docker compose up -d remnawave-nginx && docker compose exec remnawave-nginx nginx -s reload'"
    sed -i '/^renew_hook/d' "$renewal_conf"
    echo "$expected_hook" >> "$renewal_conf"

    chmod 644 "$live_dir/cert.pem" "$live_dir/chain.pem" "$live_dir/fullchain.pem"
    chmod 600 "$live_dir/privkey.pem"
    return 0
}
#Manage Certificates

handle_certificates() {
    local -n domains_to_check_ref=$1
    local cert_method="$2"
    local letsencrypt_email="$3"
    local target_dir="${4:-/opt/remnawave}"

    declare -A unique_domains
    local need_certificates=false
    local min_days_left=9999

    echo -e "${COLOR_YELLOW}${LANG[CHECK_CERTS]}${COLOR_RESET}"
    sleep 1

    echo -e "${COLOR_YELLOW}${LANG[REQUIRED_DOMAINS]}${COLOR_RESET}"
    for domain in "${!domains_to_check_ref[@]}"; do
        echo -e "${COLOR_WHITE}- $domain${COLOR_RESET}"
    done

    for domain in "${!domains_to_check_ref[@]}"; do
        if ! check_certificates "$domain"; then
            need_certificates=true
        else
            days_left=$(check_cert_expiry "$domain")
            if [ $? -eq 0 ] && [ "$days_left" -lt "$min_days_left" ]; then
                min_days_left=$days_left
            fi
        fi
    done

    if [ "$need_certificates" = true ]; then
        menu_head "${LANG[CERT_METHOD_PROMPT]}"
        menu_item 1 "${LANG[CERT_METHOD_CF]}"
        menu_item 2 "${LANG[CERT_METHOD_ACME]}"
        menu_item 3 "${LANG[CERT_METHOD_GCORE]}"
        echo
        menu_item 0 "${LANG[EXIT]}"
        echo
        reading "${LANG[CERT_METHOD_CHOOSE]}" cert_method

        if [ "$cert_method" == "0" ]; then
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            exit 1
        elif [ "$cert_method" == "2" ] || [ "$cert_method" == "3" ]; then
            reading "${LANG[EMAIL_PROMPT]}" letsencrypt_email
        elif [ "$cert_method" != "1" ]; then
            echo -e "${COLOR_RED}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}"
            exit 1
        fi
    else
        echo -e "${COLOR_GREEN}${LANG[CERTS_SKIPPED]}${COLOR_RESET}"
        cert_method="1"
    fi

    declare -A cert_domains_added

    if [ "$need_certificates" = true ] && [ "$cert_method" == "1" ]; then
        for domain in "${!domains_to_check_ref[@]}"; do
            local base_domain
            base_domain=$(extract_domain "$domain")
            unique_domains["$base_domain"]="1"
        done

        for domain in "${!unique_domains[@]}"; do
            get_certificates "$domain" "1" ""
            if [ $? -ne 0 ]; then
                echo -e "${COLOR_RED}${LANG[CERT_GENERATION_FAILED]} $domain${COLOR_RESET}"
                return 1
            fi
            min_days_left=90
            if [ -z "${cert_domains_added[$domain]}" ]; then
                echo "      - /etc/letsencrypt/live/$domain/fullchain.pem:/etc/nginx/ssl/$domain/fullchain.pem:ro" >> "$target_dir/docker-compose.yml"
                echo "      - /etc/letsencrypt/live/$domain/privkey.pem:/etc/nginx/ssl/$domain/privkey.pem:ro" >> "$target_dir/docker-compose.yml"
                cert_domains_added["$domain"]="1"
            fi
        done

    elif [ "$need_certificates" = true ] && [ "$cert_method" == "3" ]; then
        for domain in "${!domains_to_check_ref[@]}"; do
            local base_domain
            base_domain=$(extract_domain "$domain")
            unique_domains["$base_domain"]="1"
        done

        for domain in "${!unique_domains[@]}"; do
            get_certificates "$domain" "3" "$letsencrypt_email"
            if [ $? -ne 0 ]; then
                echo -e "${COLOR_RED}${LANG[CERT_GENERATION_FAILED]} $domain${COLOR_RESET}"
                return 1
            fi
            min_days_left=90
            if [ -z "${cert_domains_added[$domain]}" ]; then
                echo "      - /etc/letsencrypt/live/$domain/fullchain.pem:/etc/nginx/ssl/$domain/fullchain.pem:ro" >> "$target_dir/docker-compose.yml"
                echo "      - /etc/letsencrypt/live/$domain/privkey.pem:/etc/nginx/ssl/$domain/privkey.pem:ro" >> "$target_dir/docker-compose.yml"
                cert_domains_added["$domain"]="1"
            fi
        done

    elif [ "$need_certificates" = true ] && [ "$cert_method" == "2" ]; then
        for domain in "${!domains_to_check_ref[@]}"; do
            get_certificates "$domain" "2" "$letsencrypt_email"
            if [ $? -ne 0 ]; then
                echo -e "${COLOR_RED}${LANG[CERT_GENERATION_FAILED]} $domain${COLOR_RESET}"
                continue
            fi
            if [ -z "${cert_domains_added[$domain]}" ]; then
                echo "      - /etc/letsencrypt/live/$domain/fullchain.pem:/etc/nginx/ssl/$domain/fullchain.pem:ro" >> "$target_dir/docker-compose.yml"
                echo "      - /etc/letsencrypt/live/$domain/privkey.pem:/etc/nginx/ssl/$domain/privkey.pem:ro" >> "$target_dir/docker-compose.yml"
                cert_domains_added["$domain"]="1"
            fi
        done
    else
        for domain in "${!domains_to_check_ref[@]}"; do
            local base_domain
            base_domain=$(extract_domain "$domain")
            local cert_domain="$domain"
            if [ -d "/etc/letsencrypt/live/$base_domain" ] && is_wildcard_cert "$base_domain"; then
                cert_domain="$base_domain"
            fi
            if [ -z "${cert_domains_added[$cert_domain]}" ]; then
                echo "      - /etc/letsencrypt/live/$cert_domain/fullchain.pem:/etc/nginx/ssl/$cert_domain/fullchain.pem:ro" >> "$target_dir/docker-compose.yml"
                echo "      - /etc/letsencrypt/live/$cert_domain/privkey.pem:/etc/nginx/ssl/$cert_domain/privkey.pem:ro" >> "$target_dir/docker-compose.yml"
                cert_domains_added["$cert_domain"]="1"
            fi
        done
    fi

    local cron_command
    if [ "$cert_method" == "2" ]; then
        cron_command="ufw allow 80 && /usr/bin/certbot renew --quiet && ufw delete allow 80 && ufw reload && cd $target_dir && docker compose down && docker compose up"
    else
        cron_command="/usr/bin/certbot renew --quiet"
    fi

    if ! crontab -u root -l 2>/dev/null | grep -q "/usr/bin/certbot renew"; then
        echo -e "${COLOR_YELLOW}${LANG[ADDING_CRON_FOR_EXISTING_CERTS]}${COLOR_RESET}"
        add_cron_rule "0 5 * * 0 $cron_command"
    elif [ "$min_days_left" -le 30 ] && ! crontab -u root -l 2>/dev/null | grep -q "0 5 * * 0.*$cron_command"; then
        echo -e "${COLOR_YELLOW}${LANG[CERT_EXPIRY_SOON]} $min_days_left ${LANG[DAYS]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}${LANG[UPDATING_CRON]}${COLOR_RESET}"
        crontab -u root -l 2>/dev/null | grep -v "/usr/bin/certbot renew" | crontab -u root -
        add_cron_rule "0 5 * * 0 $cron_command"
    else
        echo -e "${COLOR_YELLOW}${LANG[CRON_ALREADY_EXISTS]}${COLOR_RESET}"
    fi

    for domain in "${!unique_domains[@]}"; do
        if [ -f "/etc/letsencrypt/renewal/$domain.conf" ]; then
            desired_hook="renew_hook = sh -c 'cd $target_dir && docker compose down remnawave-nginx && docker compose up -d remnawave-nginx'"
            if ! grep -q "renew_hook" "/etc/letsencrypt/renewal/$domain.conf"; then
                echo "$desired_hook" >> "/etc/letsencrypt/renewal/$domain.conf"
            elif ! grep -Fx "$desired_hook" "/etc/letsencrypt/renewal/$domain.conf"; then
                sed -i "/renew_hook/c\\$desired_hook" "/etc/letsencrypt/renewal/$domain.conf"
                echo -e "${COLOR_YELLOW}${LANG[UPDATED_RENEW_AUTH]}${COLOR_RESET}"
            fi
        fi
    done
}

# Module loader
load_module() {
    local module_name="$1"
    local module_type="${2:-modules}"
    local module_file="${DIR_REMNAWAVE}${module_type}/${module_name}.sh"
    local module_url="https://raw.githubusercontent.com/houqai/speedwave/refs/heads/main/src/${module_type}/${module_name}.sh"
    local force_update="${3:-false}"

    if [ "$force_update" = "true" ] || [ ! -f "$module_file" ]; then
        mkdir -p "${DIR_REMNAWAVE}${module_type}"

        local backup_file="${module_file}.bak"
        if [ -f "$module_file" ]; then
            cp "$module_file" "$backup_file"
        fi

        # Use download_with_mirrors for reliable download
        if download_with_mirrors "$module_url" "$module_file" "module"; then
            rm -f "$backup_file"
        else
            # Fallback: try direct download if mirrors fail
            if command -v curl &> /dev/null; then
                local http_code
                http_code=$(curl -sL -w "%{http_code}" "$module_url" -o "$module_file" 2>/dev/null)
                if [ "$http_code" != "200" ] || [ ! -s "$module_file" ]; then
                    if [ -f "$backup_file" ]; then
                        mv "$backup_file" "$module_file"
                    fi
                    return 1
                fi
            elif command -v wget &> /dev/null; then
                wget -q "$module_url" -O "$module_file" 2>/dev/null
                if [ ! -s "$module_file" ]; then
                    if [ -f "$backup_file" ]; then
                        mv "$backup_file" "$module_file"
                    fi
                    return 1
                fi
            else
                if [ -f "$backup_file" ]; then
                    mv "$backup_file" "$module_file"
                fi
                return 1
            fi
            rm -f "$backup_file"
        fi
    fi

    if [ -f "$module_file" ]; then
        source "$module_file"
        return 0
    else
        error "Failed to load ${module_name} module"
        return 1
    fi
}

# Module loaders (wrappers for load_module)
load_install_panel_node_module() { load_module "install_panel_node" "nginx" "${1:-false}"; }
load_install_panel_module() { load_module "install_panel" "nginx" "${1:-false}"; }
load_install_node_module() { load_module "install_node" "nginx" "${1:-false}"; }
load_add_node_module() { load_module "add_node" "modules" "${1:-false}"; }
load_manage_panel_module() { load_module "manage_panel" "modules" "${1:-false}"; }
load_api_module() { load_module "remnawave_api" "api" "${1:-false}"; }
load_warp_module() { load_module "warp" "modules" "${1:-false}"; }
load_ipv6_module() { load_module "ipv6" "modules" "${1:-false}"; }
load_selfsteal_templates_module() { load_module "selfsteal_templates" "modules" "${1:-false}"; }
load_node_accelerator_module() { load_module "node_accelerator" "modules" "${1:-false}"; }
load_rw_core_module() { load_module "rw_core" "modules" "${1:-false}"; }

log_entry
invalidate_stale_cache

if ! load_language; then
    show_language
    reading "Choose option (1-2):" LANG_OPTION

    case $LANG_OPTION in
        1) set_language en; echo "1" > "$LANG_FILE" ;;
        2) set_language ru; echo "2" > "$LANG_FILE" ;;
        *) error "Invalid choice. Please select 1-2." ;;
    esac
fi

check_root
check_os
install_script_if_missing
check_update_status
show_menu

reading "${LANG[PROMPT_ACTION]}" OPTION

case $OPTION in
    1)
        manage_install
        ;;
    2)
        choose_reinstall_type
        ;;
    3)
        load_manage_panel_module
        show_manage_panel_menu
        ;;
    4)
        load_selfsteal_templates_module
        if [[ ! -d "/opt/remnawave" && ! -d "/opt/remnanode" ]]; then
            echo -e "${COLOR_YELLOW}${LANG[NO_PANEL_NODE_INSTALLED]}${COLOR_RESET}"
            exit 1
        else
            install_blocked_template
            sleep 2
            log_clear
            speedwave
        fi
        ;;
    5)
        load_warp_module
        manage_warp_native
        sleep 2
        log_clear
        speedwave
        ;;
    6)
        if [ -f ~/backup-restore.sh ]; then
            rw-backup
        else
            curl -o ~/backup-restore.sh https://raw.githubusercontent.com/distillium/remnawave-backup-restore/main/backup-restore.sh && chmod +x ~/backup-restore.sh && ~/backup-restore.sh
        fi
        sleep 2
        log_clear
        speedwave
        ;;
    9)
        load_ipv6_module
        manage_ipv6
        sleep 2
        log_clear
        speedwave
        ;;
    10)
        manage_certificates
        sleep 2
        log_clear
        speedwave
        ;;
    11)
        update_speedwave
        sleep 2
        log_clear
        speedwave
        ;;
    12)
        remove_script
        ;;
    7)
        load_node_accelerator_module
        manage_node_accelerator
        sleep 2
        log_clear
        speedwave
        ;;
    8)
        load_rw_core_module
        manage_rw_core
        sleep 2
        log_clear
        speedwave
        ;;
    0)
        echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
        exit 0
        ;;
    *)
        echo -e "${COLOR_YELLOW}${LANG[INVALID_CHOICE]}${COLOR_RESET}"
        exit 1
        ;;
esac
exit 0
