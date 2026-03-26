#!/bin/bash

# ==============================
# DATAFETCH 2.1
# Live System Dashboard
# ==============================

# Standard colors only
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

BAR_WIDTH=18

# ------------------------------
# Cleanup on exit
# ------------------------------
cleanup() {
    tput cnorm 2>/dev/null
    printf "${RESET}"
    clear
    exit
}

trap cleanup INT TERM

# ------------------------------
# Static info
# ------------------------------
get_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${PRETTY_NAME:-$NAME}"
    else
        echo "Not available"
    fi
}

get_host() {
    if [ -r /proc/sys/kernel/hostname ]; then
        cat /proc/sys/kernel/hostname
    else
        uname -n 2>/dev/null || echo "Not available"
    fi
}

get_kernel() {
    uname -r 2>/dev/null || echo "Not available"
}

get_shell() {
    basename "${SHELL:-}" 2>/dev/null || echo "Not available"
}

get_cpu_model() {
    if command -v lscpu >/dev/null 2>&1; then
        lscpu \
        | awk -F: '/Model name:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' \
        | sed 's/ with Radeon Graphics//' \
        | sed 's/ CPU @.*//' \
        | sed 's/(R)//g; s/(TM)//g'
    else
        echo "Not available"
    fi
}

get_cpu_cores() {
    if command -v lscpu >/dev/null 2>&1; then
        lscpu | awk -F: '/Core\(s\) per socket/ {gsub(/^[ \t]+/, "", $2); print $2; exit}'
    else
        echo "Not available"
    fi
}

get_cpu_threads() {
    if command -v lscpu >/dev/null 2>&1; then
        lscpu | awk -F: '/^CPU\(s\)/ {gsub(/^[ \t]+/, "", $2); print $2; exit}'
    else
        echo "Not available"
    fi
}

get_gpu() {
    if ! command -v lspci >/dev/null 2>&1; then
        echo "Not available"
        return
    fi

    local all_gpus
    all_gpus=$(lspci 2>/dev/null | grep -Ei 'VGA compatible controller|3D controller|Display controller')

    [ -z "$all_gpus" ] && { echo "Not available"; return; }

    local chosen=""

    # Priorità: NVIDIA > AMD dedicata (RX/Navi/RDNA) > AMD generica > Intel > fallback
    chosen=$(printf '%s\n' "$all_gpus" | grep -i 'NVIDIA' | head -n1)

    if [ -z "$chosen" ]; then
        chosen=$(printf '%s\n' "$all_gpus" \
            | grep -Ei 'AMD|ATI|Radeon' \
            | grep -Ei 'RX [0-9]|Navi|RDNA' \
            | head -n1)
    fi

    if [ -z "$chosen" ]; then
        chosen=$(printf '%s\n' "$all_gpus" | grep -Ei 'AMD|ATI|Radeon' | head -n1)
    fi

    if [ -z "$chosen" ]; then
        chosen=$(printf '%s\n' "$all_gpus" | grep -i 'Intel' | head -n1)
    fi

    [ -z "$chosen" ] && chosen=$(printf '%s\n' "$all_gpus" | head -n1)

    local line
    line=$(printf '%s\n' "$chosen" \
        | sed -E 's/^[0-9a-fA-F:.]+[[:space:]]+(VGA compatible controller|3D controller|Display controller):[[:space:]]*//' \
        | sed -E 's/[[:space:]]*\(rev[[:space:]]+[0-9a-fA-F]+\)[[:space:]]*$//')

    # ============================================================
    # NVIDIA
    # ============================================================
    if printf '%s\n' "$line" | grep -qi 'NVIDIA'; then
        local clean
        # Cerca GeForce, Quadro, RTX, Tesla, Titan tra parentesi quadre
        clean=$(printf '%s\n' "$line" \
            | grep -oE '\[(GeForce|Quadro|RTX|Tesla|Titan)[^]]+\]' \
            | tr -d '[]' | head -n1)

        # Fallback: estrae dopo "NVIDIA Corporation"
        if [ -z "$clean" ]; then
            clean=$(printf '%s\n' "$line" \
                | sed -E 's/.*NVIDIA Corporation[[:space:]]*//' \
                | sed -E 's/[[:space:]]*\[.*//' \
                | sed -E 's/[[:space:]]+$//')
        fi

        echo "${clean:-NVIDIA GPU} [Dedicated]"
        return
    fi

    # ============================================================
    # AMD / ATI
    # ============================================================
    if printf '%s\n' "$line" | grep -Eqi 'AMD|ATI|Radeon'; then

        local gpu_type clean

        if printf '%s\n' "$line" | grep -Eqi 'RX [0-9]|Navi|RDNA'; then
            gpu_type="[Dedicated]"
        else
            gpu_type="[Integrated]"
        fi

        # Tentativo 1: campo tra parentesi quadre (nome human-readable)
        clean=$(printf '%s\n' "$line" \
            | grep -oE '\[[^\]]+\]' \
            | grep -Ev '^(AMD|ATI|AMD/ATI)$' \
            | tail -n1 \
            | tr -d '[]' \
            | sed -E 's/[[:space:]]+$//')

        case "$clean" in
            "Radeon Vega Series / Radeon Vega Mobile Series" \
            |"Radeon Vega Series" \
            |"Radeon Vega Mobile Series" \
            |"Radeon Graphics")
                clean="Radeon Vega" ;;
        esac

        # Tentativo 2: mapping CPU AMD mobile → Vega preciso
        if [ -z "$clean" ] || [ "$clean" = "Radeon Vega" ]; then
            local cpu_model=""
            if command -v lscpu >/dev/null 2>&1; then
                cpu_model=$(lscpu 2>/dev/null \
                    | awk -F: '/Model name:/ {gsub(/^[[:space:]]+/,"",$2); print $2; exit}')
            fi

            case "$cpu_model" in
                *"Ryzen 3 2200U"*) clean="Radeon Vega 3"  ;;
                *"Ryzen 3 3200U"*) clean="Radeon Vega 3"  ;;
                *"Ryzen 5 2500U"*) clean="Radeon Vega 8"  ;;
                *"Ryzen 5 3500U"*) clean="Radeon Vega 8"  ;;
                *"Ryzen 5 3450U"*) clean="Radeon Vega 8"  ;;
                *"Ryzen 5 7430U"*) clean="Radeon Vega 7"  ;;
                *"Ryzen 7 2700U"*) clean="Radeon Vega 10" ;;
                *"Ryzen 7 3700U"*) clean="Radeon Vega 10" ;;
                *"Ryzen 7 7730U"*) clean="Radeon Vega 8"  ;;
            esac
        fi

        # Tentativo 3: Radeon RX diretto nella stringa
        if [ -z "$clean" ]; then
            clean=$(printf '%s\n' "$line" \
                | grep -oE 'Radeon RX [0-9A-Z]+' | head -n1)
            [ -n "$clean" ] && gpu_type="[Dedicated]"
        fi

        [ -z "$clean" ] && clean="Radeon GPU"

        echo "$clean $gpu_type"
        return
    fi

    # ============================================================
    # Intel
    # ============================================================
    if printf '%s\n' "$line" | grep -qi 'Intel'; then
        local clean
        clean=$(printf '%s\n' "$line" \
            | grep -oE '\[[^\]]+\]' \
            | grep -iv 'Intel' \
            | head -n1 \
            | tr -d '[]' \
            | sed -E 's/[[:space:]]+$//')

        if [ -z "$clean" ]; then
            clean=$(printf '%s\n' "$line" \
                | sed -E 's/.*Intel Corporation[[:space:]]*//' \
                | sed -E 's/[[:space:]]*\[.*//' \
                | sed -E 's/[[:space:]]+$//')
        fi

        echo "${clean:-Intel Graphics} [Integrated]"
        return
    fi

    # ============================================================
    # Fallback finale
    # ============================================================
    echo "GPU [Unknown]"
}

get_package_manager() {
    if command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    elif command -v apt >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v zypper >/dev/null 2>&1; then
        echo "zypper"
    elif command -v xbps-install >/dev/null 2>&1; then
        echo "xbps"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    else
        echo "Not detected"
    fi
}

get_package_count() {
    if command -v pacman >/dev/null 2>&1; then
        pacman -Qq 2>/dev/null | wc -l
    elif command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -f '.\n' -W 2>/dev/null | wc -l
    elif command -v dnf >/dev/null 2>&1; then
        dnf list installed 2>/dev/null | tail -n +2 | wc -l
    elif command -v rpm >/dev/null 2>&1; then
        rpm -qa 2>/dev/null | wc -l
    elif command -v xbps-query >/dev/null 2>&1; then
        xbps-query -l 2>/dev/null | wc -l
    elif command -v apk >/dev/null 2>&1; then
        apk info 2>/dev/null | wc -l
    else
        echo "Not available"
    fi
}

get_init() {
    ps -p 1 -o comm= 2>/dev/null || echo "Not available"
}

get_de() {
    echo "${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-Not detected}}"
}

get_arch() {
    uname -m 2>/dev/null || echo "Not available"
}

get_filesystem() {
    df -T / 2>/dev/null | awk 'NR==2 {print $2}'
}

get_display_server() {
    echo "${XDG_SESSION_TYPE:-Not detected}"
}

get_audio_server() {
    if pgrep -x pipewire >/dev/null 2>&1; then
        echo "PipeWire"
    elif pgrep -x pulseaudio >/dev/null 2>&1; then
        echo "PulseAudio"
    elif pgrep -x wireplumber >/dev/null 2>&1; then
        echo "WirePlumber"
    else
        echo "Not detected"
    fi
}

get_aur_helper() {
    if command -v pacman >/dev/null 2>&1; then
        if command -v paru >/dev/null 2>&1; then
            echo "paru"
        elif command -v yay >/dev/null 2>&1; then
            echo "yay"
        elif command -v pikaur >/dev/null 2>&1; then
            echo "pikaur"
        elif command -v trizen >/dev/null 2>&1; then
            echo "trizen"
        else
            echo "Not detected"
        fi
    fi
}

OS_NAME="$(get_os)"
HOST_NAME="$(get_host)"
KERNEL_VER="$(get_kernel)"
SHELL_NAME="$(get_shell)"
CPU_MODEL="$(get_cpu_model)"
CPU_CORES="$(get_cpu_cores)"
CPU_THREADS="$(get_cpu_threads)"
GPU_NAME="$(get_gpu)"
PKG_MANAGER="$(get_package_manager)"
PKG_COUNT="$(get_package_count)"
INIT_SYSTEM="$(get_init)"
DE_NAME="$(get_de)"
ARCH_NAME="$(get_arch)"
FILESYSTEM_NAME="$(get_filesystem)"
DISPLAY_SERVER="$(get_display_server)"
AUDIO_SERVER="$(get_audio_server)"
AUR_HELPER="$(get_aur_helper)"

# ------------------------------
# Dynamic info helpers
# ------------------------------
get_time_now() {
    date +"%H:%M:%S"
}

get_uptime_pretty() {
    awk '{
        total=int($1);
        days=int(total/86400);
        hours=int((total%86400)/3600);
        mins=int((total%3600)/60);

        if (days > 0)
            printf "%dd %dh %dm", days, hours, mins;
        else if (hours > 0)
            printf "%dh %dm", hours, mins;
        else
            printf "%dm", mins;
    }' /proc/uptime
}

get_cpu_freq() {
    local freq=""
    if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
        freq=$(awk '{printf "%.0f MHz", $1/1000}' /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)
    elif [ -r /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq ]; then
        freq=$(awk '{printf "%.0f MHz", $1/1000}' /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq)
    elif grep -q "cpu MHz" /proc/cpuinfo 2>/dev/null; then
        freq=$(awk -F: '/cpu MHz/ {gsub(/^[ \t]+/, "", $2); printf "%.0f MHz\n", $2; exit}' /proc/cpuinfo)
    fi
    echo "${freq:-Not available}"
}

get_cpu_temp() {
    local temp_raw=""
    local temp_c=""

    for zone in /sys/class/thermal/thermal_zone*/temp; do
        if [ -r "$zone" ]; then
            temp_raw=$(cat "$zone" 2>/dev/null)
            if [ -n "$temp_raw" ] && [ "$temp_raw" -gt 0 ] 2>/dev/null; then
                temp_c=$((temp_raw / 1000))
                echo "${temp_c}°C"
                return
            fi
        fi
    done

    for hwmon in /sys/class/hwmon/hwmon*/temp1_input; do
        if [ -r "$hwmon" ]; then
            temp_raw=$(cat "$hwmon" 2>/dev/null)
            if [ -n "$temp_raw" ] && [ "$temp_raw" -gt 0 ] 2>/dev/null; then
                temp_c=$((temp_raw / 1000))
                echo "${temp_c}°C"
                return
            fi
        fi
    done

    echo "Not available"
}

get_cpu_usage() {
    local cpu user nice system idle iowait irq softirq steal guest guest_nice
    read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat

    local idle_now=$((idle + iowait))
    local total_now=$((user + nice + system + idle + iowait + irq + softirq + steal))

    if [ -z "$PREV_TOTAL" ]; then
        PREV_TOTAL=$total_now
        PREV_IDLE=$idle_now
        CPU_USAGE="0.0"
        CPU_USAGE_INT=0
        return
    fi

    local diff_total=$((total_now - PREV_TOTAL))
    local diff_idle=$((idle_now - PREV_IDLE))

    if [ "$diff_total" -gt 0 ]; then
        CPU_USAGE=$(awk -v dt="$diff_total" -v di="$diff_idle" 'BEGIN {printf "%.1f", ((dt-di)/dt)*100}')
        CPU_USAGE_INT=$(awk -v v="$CPU_USAGE" 'BEGIN {printf "%d", v}')
    else
        CPU_USAGE="0.0"
        CPU_USAGE_INT=0
    fi

    PREV_TOTAL=$total_now
    PREV_IDLE=$idle_now
}

get_ram_values() {
    free -b 2>/dev/null | awk '/^Mem:/ {print $2, $3}'
}

get_swap_values() {
    free -b 2>/dev/null | awk '/^Swap:/ {print $2, $3}'
}

human_bytes() {
    awk -v bytes="$1" '
    BEGIN {
        split("B K M G T", unit)
        i = 1
        value = bytes

        while (value >= 1024 && i < 5) {
            value /= 1024
            i++
        }

        if (i == 1)
            printf "%d%s", value, unit[i]
        else
            printf "%.1f%s", value, unit[i]
    }'
}

# ------------------------------
# Bar builder
# ------------------------------
make_bar() {
    local percent="$1"
    local width="${2:-$BAR_WIDTH}"
    local color="$3"

    [ "$percent" -lt 0 ] && percent=0
    [ "$percent" -gt 100 ] && percent=100

    local filled=$(( percent * width / 100 ))
    local empty=$(( width - filled ))
    local bar_filled=""
    local bar_empty=""

    if [ "$filled" -gt 0 ]; then
        bar_filled=$(printf '%*s' "$filled" '' | tr ' ' '#')
    fi

    if [ "$empty" -gt 0 ]; then
        bar_empty=$(printf '%*s' "$empty" '' | tr ' ' '-')
    fi

    printf "${color}[%s%s]${RESET}" "$bar_filled" "$bar_empty"
}

# ------------------------------
# Drawing helpers
# ------------------------------
line() {
    printf "${GREEN}────────────────────────────────────────────────────────${RESET}\n"
}

header() {
    printf "${RED}════════════════════ DATAFETCH 2.0 ════════════════════${RESET}\n"
    printf "${GREEN}DATAFETCH – Live System Dashboard${RESET}\n\n"
}

# ------------------------------
# Main loop
# ------------------------------
tput civis 2>/dev/null
clear

while true; do
    TIME_NOW="$(get_time_now)"
    UPTIME_NOW="$(get_uptime_pretty)"
    get_cpu_usage
    CPU_FREQ_NOW="$(get_cpu_freq)"
    CPU_TEMP_NOW="$(get_cpu_temp)"

    read -r RAM_TOTAL RAM_USED <<< "$(get_ram_values)"
    read -r SWAP_TOTAL SWAP_USED <<< "$(get_swap_values)"

    if [ -n "$RAM_TOTAL" ] && [ "$RAM_TOTAL" -gt 0 ]; then
        RAM_PERCENT=$(( 100 * RAM_USED / RAM_TOTAL ))
        RAM_USED_HUMAN="$(human_bytes "$RAM_USED")"
        RAM_TOTAL_HUMAN="$(human_bytes "$RAM_TOTAL")"
    else
        RAM_PERCENT=0
        RAM_USED_HUMAN="Not available"
        RAM_TOTAL_HUMAN="Not available"
    fi

    if [ -n "$SWAP_TOTAL" ] && [ "$SWAP_TOTAL" -gt 0 ]; then
        SWAP_PERCENT=$(( 100 * SWAP_USED / SWAP_TOTAL ))
        SWAP_USED_HUMAN="$(human_bytes "$SWAP_USED")"
        SWAP_TOTAL_HUMAN="$(human_bytes "$SWAP_TOTAL")"
    else
        SWAP_PERCENT=0
        SWAP_USED_HUMAN="0.0G"
        SWAP_TOTAL_HUMAN="0.0G"
    fi

    tput cup 0 0
    header

    printf " Host: %-24s Time: %s\n" "$HOST_NAME" "$TIME_NOW"
    printf " OS: %-26s Uptime: %s\n" "$OS_NAME" "$UPTIME_NOW"
    printf " Kernel: %-22s Shell: %s\n" "$KERNEL_VER" "$SHELL_NAME"

    line
    printf "${RED}CPU${RESET}\n"
    printf " Model: %s\n" "$CPU_MODEL"
    printf " Cores: %s / Threads: %s\n" "$CPU_CORES" "$CPU_THREADS"
    printf " Frequency: %s\n" "$CPU_FREQ_NOW"
    printf " Temperature: ${GREEN}%s${RESET}\n" "$CPU_TEMP_NOW"
    printf " Usage: %-5s%% %24b\n" "$CPU_USAGE" "$(make_bar "$CPU_USAGE_INT" "$BAR_WIDTH" "$GREEN")"

    line
    printf "${RED}MEMORY${RESET}\n"
    printf " RAM: %-18s %24b\n" "$RAM_USED_HUMAN / $RAM_TOTAL_HUMAN" "$(make_bar "$RAM_PERCENT" "$BAR_WIDTH" "$GREEN")"
    printf " Usage: %s%%\n" "$RAM_PERCENT"
    printf "\n"
    printf " Swap: %-17s %24b\n" "$SWAP_USED_HUMAN / $SWAP_TOTAL_HUMAN" "$(make_bar "$SWAP_PERCENT" "$BAR_WIDTH" "$GREEN")"
    printf " Usage: %s%%\n" "$SWAP_PERCENT"

    line
    printf "${RED}SYSTEM${RESET}\n"
    printf " GPU: %s\n" "$GPU_NAME"
    printf " Display: %-18s Audio: %s\n" "$DISPLAY_SERVER" "$AUDIO_SERVER"
    printf " Packages: %-17s Manager: %s\n" "$PKG_COUNT" "$PKG_MANAGER"
    printf " DE: %-23s Init: %s\n" "$DE_NAME" "$INIT_SYSTEM"
    printf " Arch: %-21s Filesystem: %s\n" "$ARCH_NAME" "$FILESYSTEM_NAME"
    if [ -n "$AUR_HELPER" ]; then
        printf " AUR Helper: %s\n" "$AUR_HELPER"
    fi

    line
    printf " Press CTRL+C to exit\n"

    sleep 1
done
