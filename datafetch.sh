#!/usr/bin/env bash
# Datafetch — Live System Dashboard
# Copyright (c) 2024–2026 Klod Cripta. MIT License.
# Bash 4.3+; Linux /proc and /sys. Optional tools enrich static information.

VERSION='3.0.0-preview.2'
INTERVAL=1
INTERVAL_CS=100
ONCE=0
COMPACT=0
DETAILS=0
ASCII=0
COLOR_MODE=auto
REQUESTED_WIDTH=0
REQUESTED_INTERFACE=''
ACTIVE=0
SUSPENDED=0
PAUSED=0
RESIZE=1
PREV_CPU_TOTAL=''
PREV_CPU_IDLE=0
PREV_NET_TIME=''
PREV_NET_IFACE=''
CPU_PERCENT=''
CPU_TEMP=''
CPU_PEAK=''
RAM_TOTAL=0 RAM_USED=0 RAM_PERCENT=0
SWAP_TOTAL=0 SWAP_USED=0 SWAP_PERCENT=0
RX_RATE=0 TX_RATE=0
DISK_TOTAL=0 DISK_USED=0 DISK_FREE=0 DISK_PERCENT=0
DISK_NEXT=0
BAT_NAME='' BAT_PERCENT='' BAT_STATUS='' BAT_HEALTH='' BAT_POWER=''
CPU_FREQ=''
NET_IFACE=''
NOW_CS=0
UPTIME=''
RESET='' BOLD='' TEXT='' ACCENT='' DIM='' BORDER='' GOOD='' WARN='' BAD=''
BAR_ON='#' BAR_OFF='-' RULE_CHAR='-' MARK='>' DEG='C'
BOX_TL='+' BOX_TR='+' BOX_BL='+' BOX_BR='+' BOX_V='|' UNICODE=0
CPU_TEMP_FILES=()
CPU_HISTORY=()
FRAME=()
PREVIOUS_FRAME=()
GPU_NAMES=()

usage() {
    cat <<'HELP'
Datafetch — Live System Dashboard

Usage: datafetch [options]

  --once              Print a snapshot and exit (automatic when piped)
  --interval SECONDS  Refresh every 0.5–10 seconds; default: 1
  --compact           Use the compact layout
  --details           Start with the system details view
  --interface NAME    Monitor a specific network interface
  --width COLUMNS     Snapshot/content width, 48–160 columns
  --ascii             Use only ASCII characters
  --no-color          Disable colors (also respects NO_COLOR)
  --color MODE        auto, always or never
  -h, --help          Show this help
  -v, --version       Show the version

Live keys: p / space = pause, + = faster, - = slower, d = details, q = quit.
No root access needed. No network requests. Disk statistics refresh every 5s.
HELP
}

error() { printf 'Datafetch: %s\n' "$*" >&2; }

parse_args() {
    while (($#)); do
        case $1 in
            --once) ONCE=1 ;;
            --compact) COMPACT=1 ;;
            --details) DETAILS=1 ;;
            --ascii) ASCII=1 ;;
            --no-color) COLOR_MODE=never ;;
            -h|--help) usage; return 10 ;;
            -v|--version) printf 'Datafetch %s\n' "$VERSION"; return 10 ;;
            --interval|--width|--interface|--color)
                (($# >= 2)) || { error "Missing value for $1"; return 2; }
                case $1 in
                    --interval)
                        [[ $2 =~ ^[0-9]{1,2}(\.[0-9]{1,2})?$ ]] || { error 'Interval must be 0.5–10 seconds'; return 2; }
                        INTERVAL_CS=$(LC_ALL=C awk -v n="$2" 'BEGIN {if(n<0.5 || n>10) exit 1; printf "%.0f",n*100}') || { error 'Interval must be 0.5–10 seconds'; return 2; }
                        INTERVAL=$2 ;;
                    --width)
                        [[ $2 =~ ^[0-9]{2,3}$ ]] && ((10#$2 >= 48 && 10#$2 <= 160)) || { error 'Width must be 48–160 columns'; return 2; }
                        REQUESTED_WIDTH=$((10#$2)) ;;
                    --interface)
                        [[ $2 =~ ^[[:alnum:]_.:-]+$ && -d /sys/class/net/$2 ]] || { error "Network interface not found: $2"; return 2; }
                        REQUESTED_INTERFACE=$2 ;;
                    --color)
                        case $2 in auto|always|never) COLOR_MODE=$2 ;; *) error 'Color mode must be auto, always or never'; return 2 ;; esac ;;
                esac
                shift ;;
            *) error "Unknown option: $1 (see --help)"; return 2 ;;
        esac
        shift
    done
}

# Functions returning small strings use REPLY to avoid a subprocess per field.
read_value() {
    REPLY=''
    # Devices can disappear between the readability check and the read.
    [[ -r $1 ]] && { IFS= read -r REPLY < "$1"; } 2>/dev/null
    return 0
}

unsigned() { [[ $1 =~ ^[0-9]{1,15}$ ]]; }

sanitize() {
    REPLY=${1//[$'\001'-$'\037'$'\177']/ }
}

fit() {
    local width=$1 value=$2
    ((width > 0)) || { REPLY=''; return; }
    sanitize "$value"; value=$REPLY
    if ((${#value} > width)); then
        value="${value:0:width-1}~"
    fi
    # printf's string field width counts bytes, including UTF-8 degree signs.
    printf -v REPLY '%*s' "$((width-${#value}))" ''
    REPLY="$value$REPLY"
}

repeat() {
    local n=$1 char=$2
    printf -v REPLY '%*s' "$n" ''
    REPLY=${REPLY// /$char}
}

human_bytes() {
    local value=${1:-0} divisor=1 unit=0 tenths
    local units=(B KiB MiB GiB TiB PiB)
    unsigned "$value" || value=0
    while ((value/divisor >= 1024 && unit < 5)); do
        divisor=$((divisor*1024)); ((unit+=1))
    done
    if ((unit == 0)); then REPLY="$value B"
    else
        tenths=$(((value*10 + divisor/2)/divisor))
        printf -v REPLY '%d.%d %s' "$((tenths/10))" "$((tenths%10))" "${units[unit]}"
    fi
}

clock_sample() {
    local stamp rest seconds fraction
    read -r stamp rest < /proc/uptime
    seconds=${stamp%%.*}; fraction=${stamp#*.}00; fraction=${fraction:0:2}
    NOW_CS=$((10#$seconds*100 + 10#$fraction))
    if ((seconds >= 86400)); then
        printf -v UPTIME '%dd %dh %dm' "$((seconds/86400))" "$((seconds%86400/3600))" "$((seconds%3600/60))"
    elif ((seconds >= 3600)); then
        printf -v UPTIME '%dh %dm' "$((seconds/3600))" "$((seconds%3600/60))"
    else UPTIME="$((seconds/60))m"; fi
}

read_cpu() {
    local file=${1:-/proc/stat} cpu user nice system idle iowait irq softirq steal rest total idle_sum dt di tenths
    read -r cpu user nice system idle iowait irq softirq steal rest < "$file" || return 0
    # user/nice already contain guest time; do not count guest/guest_nice twice.
    total=$((user+nice+system+idle+${iowait:-0}+${irq:-0}+${softirq:-0}+${steal:-0}))
    idle_sum=$((idle+${iowait:-0}))
    CPU_PERCENT=''
    if [[ -n $PREV_CPU_TOTAL ]]; then
        dt=$((total-PREV_CPU_TOTAL)); di=$((idle_sum-PREV_CPU_IDLE))
        if ((dt > 0)); then
            tenths=$(((dt-di)*1000/dt))
            ((tenths < 0)) && tenths=0
            ((tenths > 1000)) && tenths=1000
            printf -v CPU_PERCENT '%d.%d' "$((tenths/10))" "$((tenths%10))"
        fi
    fi
    PREV_CPU_TOTAL=$total PREV_CPU_IDLE=$idle_sum
}

read_memory() {
    local file=${1:-/proc/meminfo} key val unit available='' free=0 buffers=0 cached=0 reclaim=0 shmem=0 swap_free=0
    RAM_TOTAL=0 RAM_USED=0 RAM_PERCENT=0 SWAP_TOTAL=0 SWAP_USED=0 SWAP_PERCENT=0
    while read -r key val unit; do
        unsigned "$val" || continue
        case $key in
            MemTotal:) RAM_TOTAL=$((val*1024)) ;;
            MemAvailable:) available=$((val*1024)) ;;
            MemFree:) free=$val ;; Buffers:) buffers=$val ;; Cached:) cached=$val ;;
            SReclaimable:) reclaim=$val ;; Shmem:) shmem=$val ;;
            SwapTotal:) SWAP_TOTAL=$((val*1024)) ;; SwapFree:) swap_free=$((val*1024)) ;;
        esac
    done < "$file"
    [[ -n $available ]] || available=$(((free+buffers+cached+reclaim-shmem)*1024))
    ((available < 0)) && available=0
    ((available > RAM_TOTAL)) && available=$RAM_TOTAL
    RAM_USED=$((RAM_TOTAL-available))
    ((RAM_TOTAL > 0)) && RAM_PERCENT=$((RAM_USED*100/RAM_TOTAL))
    SWAP_USED=$((SWAP_TOTAL-swap_free))
    ((SWAP_USED < 0)) && SWAP_USED=0
    ((SWAP_TOTAL > 0)) && SWAP_PERCENT=$((SWAP_USED*100/SWAP_TOTAL))
    return 0
}

# Select CPU-labelled sensors, never the first disk/GPU/ACPI temperature.
# Prefer physical Tdie over offset Tctl when both are exported by k10temp.
detect_temperature() {
    local hwroot=${1:-/sys/class/hwmon} throot=${2:-/sys/class/thermal} h driver input label selected priority best
    CPU_TEMP_FILES=()
    for h in "$hwroot"/hwmon*; do
        read_value "$h/name"; driver=$REPLY
        case $driver in coretemp|k10temp|k8temp|zenpower|cpu_thermal|cpu-thermal|soc_thermal) ;; *) continue ;; esac
        selected='' best=0
        for input in "$h"/temp*_input; do
            [[ -r $input ]] || continue
            read_value "${input%_input}_label"; label=$REPLY
            priority=1
            case $label in Tdie|'Package id '*|Tccd*|CPU*) priority=3 ;; Tctl) priority=2 ;; esac
            [[ $label == Tccd* ]] && priority=1
            if ((priority > best)); then selected=$input best=$priority; fi
        done
        [[ -n $selected ]] && CPU_TEMP_FILES+=("$selected")
    done
    ((${#CPU_TEMP_FILES[@]})) && return 0
    for h in "$throot"/thermal_zone*; do
        read_value "$h/type"
        case $REPLY in x86_pkg_temp|cpu-thermal|cpu_thermal|soc_thermal|*CPU*)
            [[ -r $h/temp ]] && CPU_TEMP_FILES+=("$h/temp") ;;
        esac
    done
    return 0
}

read_temperature() {
    local input value hottest=-1 tenths
    CPU_TEMP=''
    for input in "${CPU_TEMP_FILES[@]}"; do
        read_value "$input"; value=$REPLY
        unsigned "$value" || continue
        ((value > 0 && value < 200000 && value > hottest)) && hottest=$value
    done
    if ((hottest >= 0)); then
        tenths=$(((hottest+50)/100))
        printf -v CPU_TEMP '%d.%d' "$((tenths/10))" "$((tenths%10))"
        if [[ -z $CPU_PEAK ]] || ((hottest > CPU_PEAK)); then CPU_PEAK=$hottest; fi
    fi
}

read_frequency() {
    local key val
    CPU_FREQ=''
    read_value /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
    if unsigned "$REPLY"; then
        CPU_FREQ="$((REPLY/1000)) MHz"
    else
        while IFS=: read -r key val; do
            if [[ $key == 'cpu MHz'* ]]; then
                val=${val//[[:space:]]/}; CPU_FREQ="${val%%.*} MHz"; break
            fi
        done < /proc/cpuinfo
    fi
}

network_sample() {
    local now=$1 rx=$2 tx=$3 iface=$4 elapsed
    RX_RATE=0 TX_RATE=0
    if [[ -n $PREV_NET_TIME && $iface == "$PREV_NET_IFACE" ]]; then
        elapsed=$((now-PREV_NET_TIME))
        if ((elapsed > 0 && rx >= PREV_RX && tx >= PREV_TX)); then
            RX_RATE=$(((rx-PREV_RX)*100/elapsed))
            TX_RATE=$(((tx-PREV_TX)*100/elapsed))
        fi
    fi
    PREV_NET_TIME=$now PREV_RX=$rx PREV_TX=$tx PREV_NET_IFACE=$iface
}

select_interface() {
    local iface dest gateway flags rest candidate='' path
    NET_IFACE=$REQUESTED_INTERFACE
    [[ -n $NET_IFACE ]] && return 0
    # /proc route tables are local reads, not probes to an outside service.
    if [[ -r /proc/net/route ]]; then
        while read -r iface dest gateway flags rest; do
            if [[ $dest == 00000000 && $flags =~ ^[[:xdigit:]]+$ ]] && ((16#$flags & 1)); then
                [[ -r /sys/class/net/$iface/statistics/rx_bytes ]] && { NET_IFACE=$iface; return 0; }
            fi
        done < /proc/net/route
    fi
    if [[ -r /proc/net/ipv6_route ]]; then
        while read -r dest flags rest; do
            iface=${rest##* }
            if [[ $dest == 00000000000000000000000000000000 && $flags == 00 && $iface != lo && -d /sys/class/net/$iface ]]; then
                NET_IFACE=$iface; return 0
            fi
        done < /proc/net/ipv6_route
    fi
    for path in /sys/class/net/*; do
        iface=${path##*/}; [[ $iface == lo ]] && continue
        read_value "$path/operstate"
        [[ $REPLY == up ]] && { candidate=$iface; break; }
    done
    NET_IFACE=$candidate
}

read_network() {
    local rx tx
    select_interface
    RX_RATE=0 TX_RATE=0
    if [[ -n $NET_IFACE ]]; then
        read_value "/sys/class/net/$NET_IFACE/statistics/rx_bytes"; rx=$REPLY
        read_value "/sys/class/net/$NET_IFACE/statistics/tx_bytes"; tx=$REPLY
        if unsigned "$rx" && unsigned "$tx"; then
            network_sample "$NOW_CS" "$rx" "$tx" "$NET_IFACE"
            return
        fi
    fi
    PREV_NET_TIME='' PREV_NET_IFACE=''
}

read_disk() {
    local fs total used available percent mount
    DISK_TOTAL=0 DISK_USED=0 DISK_FREE=0 DISK_PERCENT=0
    while read -r fs total used available percent mount; do
        unsigned "$total" && unsigned "$used" && unsigned "$available" || continue
        DISK_TOTAL=$((total*1024)); DISK_USED=$((used*1024)); DISK_FREE=$((available*1024))
        percent=${percent%%%}; unsigned "$percent" && DISK_PERCENT=$percent
    done < <(LC_ALL=C df -Pk / 2>/dev/null)
}

# The first present system battery is selected; its name is always displayed.
# Do not combine charge (Ah) and energy (Wh) when calculating battery health.
read_battery() {
    local root=${1:-/sys/class/power_supply} b full design power current voltage
    BAT_NAME='' BAT_PERCENT='' BAT_STATUS='' BAT_HEALTH='' BAT_POWER=''
    for b in "$root"/*; do
        read_value "$b/type"; [[ $REPLY == Battery ]] || continue
        read_value "$b/present"; [[ $REPLY == 0 ]] && continue
        read_value "$b/scope"; [[ $REPLY == Device ]] && continue
        BAT_NAME=${b##*/}
        read_value "$b/capacity"; unsigned "$REPLY" && BAT_PERCENT=$REPLY
        [[ -n $BAT_PERCENT ]] && ((BAT_PERCENT > 100)) && BAT_PERCENT=100
        read_value "$b/status"; BAT_STATUS=${REPLY:-Unknown}
        read_value "$b/energy_full"; full=$REPLY
        read_value "$b/energy_full_design"; design=$REPLY
        if ! unsigned "$full" || ! unsigned "$design" || ((design == 0)); then
            read_value "$b/charge_full"; full=$REPLY
            read_value "$b/charge_full_design"; design=$REPLY
        fi
        if unsigned "$full" && unsigned "$design" && ((design > 0)); then BAT_HEALTH=$((full*100/design)); fi
        read_value "$b/power_now"; power=${REPLY#-}
        if ! unsigned "$power"; then
            # Sysfs permits negative current while discharging. Display the
            # magnitude in watts; BAT_STATUS supplies the charge direction.
            read_value "$b/current_now"; current=${REPLY#-}
            read_value "$b/voltage_now"; voltage=$REPLY
            if unsigned "$current" && unsigned "$voltage"; then power=$((current*voltage/1000000)); fi
        fi
        if unsigned "$power"; then
            power=$(((power+50000)/100000))
            printf -v BAT_POWER '%d.%d' "$((power/10))" "$((power%10))"
        fi
        break
    done
}

get_packages() {
    local count='' pkg path
    PKG_MANAGER='n/a' PKG_COUNT='n/a' AUR_HELPERS='' FLATPAK_COUNT=''
    if command -v pacman >/dev/null 2>&1; then PKG_MANAGER=pacman; count=$(pacman -Qq 2>/dev/null | wc -l)
    elif command -v dpkg-query >/dev/null 2>&1; then PKG_MANAGER=dpkg; count=$(dpkg-query -W -f='${db:Status-Status}\n' 2>/dev/null | LC_ALL=C awk '$0=="installed"{n++} END{print n+0}')
    elif [[ -d /var/db/pkg ]] && command -v emerge >/dev/null 2>&1; then
        PKG_MANAGER=Portage; count=0
        for path in /var/db/pkg/*/*; do [[ -d $path ]] && ((count+=1)); done
    elif command -v rpm >/dev/null 2>&1; then PKG_MANAGER=rpm; count=$(rpm -qa 2>/dev/null | wc -l)
    elif command -v xbps-query >/dev/null 2>&1; then PKG_MANAGER=xbps; count=$(xbps-query -l 2>/dev/null | wc -l)
    elif command -v apk >/dev/null 2>&1; then PKG_MANAGER=apk; count=$(apk info 2>/dev/null | wc -l)
    fi
    count=${count//[[:space:]]/}; [[ -n $count ]] && PKG_COUNT=$count
    if [[ $PKG_MANAGER == pacman ]]; then
        for pkg in paru yay pikaur aura trizen pakku; do
            command -v "$pkg" >/dev/null 2>&1 && AUR_HELPERS+="${AUR_HELPERS:+, }$pkg"
        done
    fi
    if command -v flatpak >/dev/null 2>&1; then
        FLATPAK_COUNT=$(flatpak list --app --columns=application 2>/dev/null | wc -l)
        FLATPAK_COUNT=${FLATPAK_COUNT//[[:space:]]/}
    fi
}

normalize_gpu_name() {
    local name=$1 cpu=${2:-} vendor='' label rest
    sanitize "$name"; name=${REPLY% (rev *}
    case $name in
        *'Advanced Micro Devices'*|*'[AMD/ATI]'*|AMD*) vendor=AMD ;;
        *NVIDIA*) vendor=NVIDIA ;;
        *Intel*) vendor=Intel ;;
    esac
    name=${name/Advanced Micro Devices, Inc. /}
    name=${name/\[AMD\/ATI\] /}
    name=${name/NVIDIA Corporation /}
    name=${name/Intel Corporation /}
    name=${name#"$vendor "}
    # PCI databases often put the useful marketing name after a chip codename.
    rest=$name
    while [[ $rest == *'['*']'* ]]; do
        label=${rest#*\[}; label=${label%%\]*}
        case $label in
            *GeForce*|*Quadro*|*RTX*|*Radeon*|*Graphics*|*Arc*) name=$label; break ;;
        esac
        rest=${rest#*\]}
    done
    if [[ $vendor == AMD && $name == Barcelo ]]; then
        # AMD's 7430U specification: Radeon Graphics, seven graphics cores.
        # Require the integrated PCI codename as well as the exact CPU model.
        if [[ $cpu =~ (^|[[:space:]])7430U($|[[:space:]]) ]]; then
            name='Radeon Graphics (7 CU)'
        else name='Radeon Graphics (Barcelo)'; fi
    fi
    name=${name//Lite Hash Rate/LHR}
    name=${name//(R)/}; name=${name//(TM)/}
    name=${name#"$vendor "}
    REPLY="${vendor:+$vendor }$name"
}

get_gpus() {
    local line name path driver id
    GPU_NAMES=()
    if command -v lspci >/dev/null 2>&1; then
        while IFS= read -r line; do
            case $line in
                *'VGA compatible controller: '*|*'3D controller: '*|*'Display controller: '*)
                    normalize_gpu_name "${line#*controller: }" "$CPU_MODEL"
                    GPU_NAMES+=("$REPLY") ;;
            esac
        done < <(LC_ALL=C lspci 2>/dev/null)
    fi
    if ((${#GPU_NAMES[@]} == 0)); then
        for path in /sys/class/drm/card*/device; do
            [[ ${path%/device} =~ /card[0-9]+$ ]] || continue
            read_value "$path/vendor"; id=$REPLY
            case $id in 0x1002) name='AMD GPU' ;; 0x8086) name='Intel GPU' ;; 0x10de) name='NVIDIA GPU' ;; *) name='GPU' ;; esac
            driver=$(readlink "$path/driver" 2>/dev/null); driver=${driver##*/}
            [[ -n $driver ]] && name+=" ($driver)"
            GPU_NAMES+=("$name")
        done
    fi
    GPU_NAME='n/a'
    if ((${#GPU_NAMES[@]})); then
        GPU_NAME=${GPU_NAMES[0]}
        ((${#GPU_NAMES[@]} > 1)) && GPU_NAME+=" (+$((${#GPU_NAMES[@]}-1)) GPU)"
    fi
}

collect_static() {
    local key val info pid1 sockets=1 cores='' threads='' name path
    OS_NAME='Linux'
    if [[ -r /etc/os-release ]]; then
        OS_NAME=$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-${NAME:-Linux}}")
    fi
    read_value /proc/sys/kernel/hostname; HOST_NAME=${REPLY:-unknown}
    KERNEL_VER=$(uname -r); ARCH_NAME=$(uname -m)
    SHELL_NAME=${SHELL##*/}; SHELL_NAME=${SHELL_NAME:-n/a}
    DE_NAME=${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-n/a}}
    DISPLAY_SERVER=${XDG_SESSION_TYPE:-n/a}
    [[ $DISPLAY_SERVER == n/a && -n ${WAYLAND_DISPLAY:-} ]] && DISPLAY_SERVER=wayland
    [[ $DISPLAY_SERVER == n/a && -n ${DISPLAY:-} ]] && DISPLAY_SERVER=x11
    CPU_MODEL='' CPU_CORES='n/a' CPU_THREADS='n/a'
    if command -v lscpu >/dev/null 2>&1; then
        while IFS=: read -r key val; do
            val=${val#"${val%%[![:space:]]*}"}
            case $key in
                'Model name') CPU_MODEL=$val ;;
                'CPU(s)') threads=$val ;;
                'Core(s) per socket') cores=$val ;;
                'Socket(s)') sockets=$val ;;
            esac
        done < <(LC_ALL=C lscpu 2>/dev/null)
        unsigned "$threads" && CPU_THREADS=$threads
        unsigned "$cores" && unsigned "$sockets" && CPU_CORES=$((cores*sockets))
    fi
    if [[ -z $CPU_MODEL ]]; then
        while IFS=: read -r key val; do
            if [[ $key == 'model name'* || $key == Hardware* ]]; then
                CPU_MODEL=${val#"${val%%[![:space:]]*}"}; break
            fi
        done < /proc/cpuinfo
    fi
    CPU_MODEL=${CPU_MODEL:-$ARCH_NAME}
    CPU_MODEL=${CPU_MODEL//(R)/}; CPU_MODEL=${CPU_MODEL//(TM)/}
    CPU_MODEL=${CPU_MODEL% with Radeon Graphics}
    get_gpus
    get_packages
    pid1=$(ps -p 1 -o comm= 2>/dev/null); INIT_SYSTEM=${pid1:-n/a}
    if [[ $pid1 == openrc-init || -d /run/openrc/started ]]; then INIT_SYSTEM=OpenRC; fi
    AUDIO_SERVER='n/a'
    if command -v pgrep >/dev/null 2>&1; then
        if pgrep -x -u "$UID" pipewire >/dev/null 2>&1; then AUDIO_SERVER=PipeWire
        elif pgrep -x -u "$UID" pulseaudio >/dev/null 2>&1; then AUDIO_SERVER=PulseAudio; fi
    fi
    FILESYSTEM_NAME=$(LC_ALL=C df -PT / 2>/dev/null | awk 'NR==2{print $2}')
    read_value /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver; CPU_DRIVER=${REPLY:-n/a}
    CPU_GOVERNOR='n/a'; CPU_EPP=''
    detect_temperature
}

sample() {
    clock_sample
    read_cpu
    read_memory
    read_temperature
    read_frequency
    read_network
    read_battery
    read_value /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor; CPU_GOVERNOR=${REPLY:-n/a}
    read_value /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference; CPU_EPP=$REPLY
    if ((NOW_CS >= DISK_NEXT)); then read_disk; DISK_NEXT=$((NOW_CS+500)); fi
    printf -v TIME_NOW '%(%H:%M:%S)T' -1
    if [[ -n $CPU_PERCENT ]]; then
        CPU_HISTORY+=("${CPU_PERCENT%.*}")
        ((${#CPU_HISTORY[@]} > 40)) && CPU_HISTORY=("${CPU_HISTORY[@]: -40}")
    fi
}

setup_style() {
    local charmap
    RESET='' BOLD='' TEXT='' ACCENT='' DIM='' BORDER='' GOOD='' WARN='' BAD=''
    if [[ $COLOR_MODE == always || ($COLOR_MODE == auto && -t 1 && ! ${NO_COLOR+x} && ${TERM:-dumb} != dumb) ]]; then
        RESET=$'\e[0m'; BOLD=$'\e[1m'; TEXT=$'\e[37m'; ACCENT=$'\e[36m'
        DIM=$'\e[37m'; BORDER=$'\e[34m'; GOOD=$'\e[32m'; WARN=$'\e[33m'; BAD=$'\e[31m'
        case ${TERM:-} in *256color*|*direct*|xterm-kitty|foot*)
            TEXT=$'\e[38;5;254m'; ACCENT=$'\e[38;5;110m'; DIM=$'\e[38;5;250m'
            BORDER=$'\e[38;5;109m'; GOOD=$'\e[38;5;150m'; WARN=$'\e[38;5;222m'; BAD=$'\e[38;5;131m' ;;
        esac
        if [[ ${COLORTERM:-} == truecolor || ${COLORTERM:-} == 24bit || ${TERM:-} == *direct* ]]; then
            # Nord-inspired foregrounds; preserve the user's terminal background.
            TEXT=$'\e[38;2;229;233;240m'; ACCENT=$'\e[38;2;136;192;208m'
            DIM=$'\e[38;2;184;197;214m'; BORDER=$'\e[38;2;129;161;193m'
            GOOD=$'\e[38;2;163;190;140m'; WARN=$'\e[38;2;235;203;139m'; BAD=$'\e[38;2;191;97;106m'
        fi
    fi
    BAR_ON='#' BAR_OFF='-' RULE_CHAR='-' MARK='>' DEG=C UNICODE=0
    BOX_TL='+' BOX_TR='+' BOX_BL='+' BOX_BR='+' BOX_V='|'
    charmap=$(locale charmap 2>/dev/null)
    if ((ASCII == 0)) && [[ $charmap == UTF-8 || $charmap == UTF8 ]]; then
        BAR_ON='━'; BAR_OFF='─'; RULE_CHAR='─'; MARK='●'; DEG='°C'; UNICODE=1
        BOX_TL='╭'; BOX_TR='╮'; BOX_BL='╰'; BOX_BR='╯'; BOX_V='│'
    fi
}

get_size() {
    local size rows cols
    if ((ACTIVE)); then
        size=$(stty size <&3 2>/dev/null)
        read -r rows cols <<< "$size"
    else rows=1000; cols=${COLUMNS:-80}; fi
    unsigned "${cols:-}" && ((cols >= 2 && cols <= 1000)) || cols=80
    unsigned "${rows:-}" && ((rows >= 2 && rows <= 1000)) || rows=24
    if ((ONCE)); then
        ((REQUESTED_WIDTH > 0)) && cols=$REQUESTED_WIDTH
        ((cols < 48)) && cols=48
    fi
    COLS=$cols ROWS=$rows
    WIDTH=$((cols-3))
    ((ONCE)) && WIDTH=$((cols-2))
    ((WIDTH > 158)) && WIDTH=158
    ((REQUESTED_WIDTH > 0 && REQUESTED_WIDTH-2 < WIDTH)) && WIDTH=$((REQUESTED_WIDTH-2))
    ((WIDTH < 1)) && WIDTH=1
    SMALL=$COMPACT
    ((WIDTH < 69 || rows < 23)) && SMALL=1
}

add_row() {
    fit "${3:-$WIDTH}" "$1"
    FRAME+=("  ${2:-$TEXT}$REPLY$RESET")
}

# CW and CELLS belong to the panel being built. Styled cells always occupy CW
# visible columns; framing never measures ANSI escape sequences as text.
cell() {
    fit "$CW" "$1"
    CELLS+=("${2:-$TEXT}$REPLY$RESET")
}

field() {
    local label value
    fit 9 "$1"; label=$REPLY
    fit "$((CW-9))" "$2"; value=$REPLY
    CELLS+=("$DIM$label$TEXT$value$RESET")
}

pair_cell() {
    local left
    fit "$((CW/2))" "$1"; left=$REPLY
    fit "$((CW-CW/2))" "$2"
    CELLS+=("$TEXT$left$REPLY$RESET")
}

metric() {
    local label=$1 pct=$2 note=$3 length filled empty bar tail color suffix a n
    # Stable columns: changing a value's number of digits must not move its bar.
    length=8; ((CW < 48)) && length=4; ((CW >= 65)) && length=18
    n=${pct%.*}; [[ -n $n ]] || n=0
    ((n < 0)) && n=0; ((n > 100)) && n=100
    color=$GOOD; ((n >= 75)) && color=$WARN; ((n >= 90)) && color=$BAD
    if [[ $label == BAT ]]; then
        color=$GOOD
        if [[ $BAT_STATUS == Discharging ]]; then
            ((n < 30)) && color=$WARN
            ((n < 15)) && color=$BAD
        fi
    fi
    filled=$((n*length/100)); empty=$((length-filled))
    repeat "$filled" "$BAR_ON"; bar=$REPLY
    repeat "$empty" "$BAR_OFF"; tail=$REPLY
    fit 5 "$label"; a=$REPLY
    if [[ -n $pct ]]; then printf -v suffix '%5s%%' "$pct"; else suffix='   n/a'; fi
    fit "$((CW-14-length))" "$note"; note=$REPLY
    CELLS+=("$DIM$a$color$bar$BORDER$tail$TEXT $BOLD$suffix$RESET$TEXT  $note$RESET")
}

memory_note() {
    local used=$1 total=$2 a
    human_bytes "$used"; a=$REPLY
    human_bytes "$total"; REPLY="$a / $REPLY"
}

history_cell() {
    local value level text='' glyphs=' .:-=+*#%@'
    ((UNICODE)) && glyphs='▁▂▃▄▅▆▇█'
    for value in "${CPU_HISTORY[@]}"; do
        level=$((value*(${#glyphs}-1)/100)); text+=${glyphs:level:1}
    done
    cell "HISTORY  $text" "$ACCENT"
}

panelize() {
    local title=$1 height=${2:-${#CELLS[@]}} i tail empty
    PANEL=()
    fit "$((CW-1))" "$title"; title=${REPLY%"${REPLY##*[! ]}"}
    repeat "$((CW-1-${#title}))" "$RULE_CHAR"; tail=$REPLY
    PANEL+=("$BORDER$BOX_TL$RULE_CHAR $ACCENT$BOLD$title$RESET$BORDER $tail$BOX_TR$RESET")
    fit "$CW" ''; empty=$REPLY
    for ((i=0;i<height;i++)); do
        PANEL+=("$BORDER$BOX_V$RESET ${CELLS[i]:-$empty} $BORDER$BOX_V$RESET")
    done
    repeat "$((CW+2))" "$RULE_CHAR"
    PANEL+=("$BORDER$BOX_BL$REPLY$BOX_BR$RESET")
}

system_cells() {
    local name gpu_text=''
    CELLS=()
    if ((DETAILS)); then
        field PACKAGES "$PKG_COUNT ($PKG_MANAGER)${FLATPAK_COUNT:+ / $FLATPAK_COUNT Flatpak}"
        if ((SMALL)); then
            cell "SHELL $SHELL_NAME / INIT $INIT_SYSTEM"
            if [[ -n $AUR_HELPERS ]]; then field AUR "$AUR_HELPERS"
            else field GOVERNOR "$CPU_GOVERNOR"; fi
        elif ((WIDE)); then
            field SHELL "$SHELL_NAME"
            field INIT "$INIT_SYSTEM"
            field AUDIO "$AUDIO_SERVER"
            field 'ROOT FS' "${FILESYSTEM_NAME:-n/a}"
            cell ''
            field DRIVER "$CPU_DRIVER"
            field GOVERNOR "$CPU_GOVERNOR"
            field EPP "${CPU_EPP:-n/a}"
            [[ -n $AUR_HELPERS ]] && field AUR "$AUR_HELPERS"
            cell ''
            if ((${#GPU_NAMES[@]})); then
                for name in "${GPU_NAMES[@]}"; do field GPU "$name"; done
            else field GPU 'n/a'; fi
        else
            pair_cell "SHELL $SHELL_NAME" "INIT $INIT_SYSTEM"
            pair_cell "AUDIO $AUDIO_SERVER" "ROOT FS ${FILESYSTEM_NAME:-n/a}"
            field DRIVER "$CPU_DRIVER"
            field GOVERNOR "$CPU_GOVERNOR${CPU_EPP:+ / $CPU_EPP}"
            if [[ -n $AUR_HELPERS ]]; then field AUR "$AUR_HELPERS"
            else field ARCH "$ARCH_NAME / $CPU_CORES cores / $CPU_THREADS threads"; fi
            for name in "${GPU_NAMES[@]}"; do gpu_text+="${gpu_text:+; }$name"; done
            field GPU "${gpu_text:-n/a}"
        fi
    elif ((SMALL)); then
        cell "$OS_NAME" "$TEXT$BOLD"
        field CPU "$CPU_MODEL"
        field GPU "$GPU_NAME"
    elif ((WIDE)); then
        cell "$OS_NAME" "$TEXT$BOLD"
        field HOST "$HOST_NAME"
        field KERNEL "$KERNEL_VER"
        field DESKTOP "$DE_NAME"
        field SESSION "$DISPLAY_SERVER"
        cell ''
        field CPU "$CPU_MODEL"
        cell "$CPU_CORES cores / $CPU_THREADS threads / $ARCH_NAME" "$DIM"
        field GPU "$GPU_NAME"
        cell ''
        field UPTIME "$UPTIME"
    else
        cell "$OS_NAME" "$TEXT$BOLD"
        pair_cell "HOST $HOST_NAME" "UPTIME $UPTIME"
        field KERNEL "$KERNEL_VER"
        pair_cell "DESKTOP $DE_NAME" "SESSION $DISPLAY_SERVER"
        field CPU "$CPU_MODEL"
        cell "$CPU_CORES cores / $CPU_THREADS threads / $ARCH_NAME" "$DIM"
        field GPU "$GPU_NAME"
    fi
}

live_cells() {
    local note raw_peak
    CELLS=()
    metric CPU "$CPU_PERCENT" "${CPU_FREQ:-n/a} (CPU0)"
    if [[ -n $CPU_TEMP ]]; then
        raw_peak=$(((CPU_PEAK+50)/100))
        printf -v note '%s%s / peak %d.%d%s' "$CPU_TEMP" "$DEG" "$((raw_peak/10))" "$((raw_peak%10))" "$DEG"
    else note='n/a'; fi
    field TEMP "$note"
    memory_note "$RAM_USED" "$RAM_TOTAL"; metric RAM "$RAM_PERCENT" "$REPLY"
    if ((SWAP_TOTAL)); then
        memory_note "$SWAP_USED" "$SWAP_TOTAL"; metric SWAP "$SWAP_PERCENT" "$REPLY"
    else metric SWAP '' 'Disabled'; fi
    if ((DISK_TOTAL)); then
        human_bytes "$DISK_FREE"; metric DISK "$DISK_PERCENT" "/ $REPLY free"
    else metric DISK '' 'n/a'; fi
    ((WIDE)) && cell ''
    if [[ -n $NET_IFACE ]]; then
        human_bytes "$RX_RATE"; note="down $REPLY/s"
        human_bytes "$TX_RATE"; note+="  up $REPLY/s"
        if ((SMALL)); then cell "NET  $note"
        else field NET "$NET_IFACE"; cell "     $note"; fi
    else
        field NET 'No active interface'
        ((SMALL == 0)) && cell ''
    fi
    if [[ -n $BAT_NAME ]]; then
        ((WIDE)) && cell ''
        if ((SMALL)); then
            metric BAT "${BAT_PERCENT:-}" "$BAT_STATUS${BAT_POWER:+ ${BAT_POWER}W}"
        else
            metric BAT "${BAT_PERCENT:-}" "$BAT_NAME / $BAT_STATUS"
            if ((WIDE)); then
                field POWER "${BAT_POWER:-n/a}${BAT_POWER:+ W}"
                field HEALTH "${BAT_HEALTH:-n/a}${BAT_HEALTH:+%}"
            else
                field POWER "${BAT_POWER:-n/a}${BAT_POWER:+ W} / health ${BAT_HEALTH:-n/a}${BAT_HEALTH:+%}"
            fi
        fi
    fi
}

build_frame() {
    local status tag note info WIDE=0 logo=0 CW left_width right_width title header_rows height i
    local -a CELLS=() PANEL=() system=() live=()
    FRAME=()
    if ((ACTIVE && (COLS < 48 || ROWS < 16))); then
        add_row 'DATAFETCH' "$ACCENT$BOLD"
        add_row 'Terminal too small.'
        add_row 'Minimum: 48 columns x 16 rows.' "$DIM"
        add_row 'Resize the window. Press q to exit.' "$DIM"
        return
    fi
    ((WIDTH >= 101 && COMPACT == 0 && ROWS >= 20)) && WIDE=1
    ((WIDE)) && SMALL=0
    ((WIDE == 0 && ROWS < 24)) && SMALL=1
    status="${MARK} LIVE  ${INTERVAL}s"
    ((PAUSED)) && status="${MARK} PAUSED"
    ((ONCE)) && status='SNAPSHOT'
    tag='DATAFETCH'
    if ((UNICODE && WIDTH >= 50 && (SMALL == 0 || ROWS >= 18))); then
        tag='█▀▄ ▄▀█ ▀█▀ ▄▀█ █▀▀ █▀▀ ▀█▀ █▀▀ █ █'
        logo=1
    fi
    fit "$((WIDTH-${#status}))" "$tag"; tag=$REPLY
    FRAME+=("  $ACCENT$BOLD$tag$RESET$GOOD$status$RESET")
    if ((SMALL == 0 || ROWS >= 18)); then
        if ((logo)); then add_row '█▄▀ █▀█  █  █▀█ █▀  ██▄  █  █▄▄ █▀█' "$ACCENT$BOLD"
        else add_row 'SYSTEM MONITOR' "$ACCENT"; fi
        add_row "DATAFETCH / $VERSION / Klod Cripta" "$DIM"
    fi
    header_rows=${#FRAME[@]}
    title=SYSTEM; ((DETAILS)) && title='SYSTEM / DETAILS'
    if ((WIDE)); then
        left_width=$(((WIDTH-2)*44/100)); right_width=$((WIDTH-2-left_width))
        CW=$((left_width-4)); system_cells; system=("${CELLS[@]}")
        CW=$((right_width-4)); live_cells; live=("${CELLS[@]}")
        if ((ROWS >= header_rows+${#live[@]}+5)); then
            cell ''; history_cell; live=("${CELLS[@]}")
        fi
        height=${#system[@]}; ((${#live[@]} > height)) && height=${#live[@]}
        # A multi-GPU details view must still leave room for the key bar.
        ((height > ROWS-header_rows-3)) && height=$((ROWS-header_rows-3))
        CW=$((left_width-4)); CELLS=("${system[@]}"); panelize "$title" "$height"; system=("${PANEL[@]}")
        CW=$((right_width-4)); CELLS=("${live[@]}"); panelize "LIVE METRICS / $TIME_NOW" "$height"
        for ((i=0;i<${#PANEL[@]};i++)); do FRAME+=("  ${system[i]}  ${PANEL[i]}"); done
    else
        CW=$((WIDTH-4)); system_cells; panelize "$title"
        for tag in "${PANEL[@]}"; do FRAME+=("  $tag"); done
        live_cells
        if ((SMALL == 0 && ROWS >= ${#FRAME[@]}+${#CELLS[@]}+5)); then cell ''; history_cell; fi
        panelize "LIVE METRICS / $TIME_NOW"
        for tag in "${PANEL[@]}"; do FRAME+=("  $tag"); done
    fi
    if ((ONCE)); then
        add_row 'Snapshot / run without --once for live metrics' "$DIM"
    else
        note='p pause'; ((PAUSED)) && note='p resume'
        info='d details'; ((DETAILS)) && info='d overview'
        if ((SMALL)); then add_row "$note  +/- speed  $info  q quit" "$DIM"
        else add_row "$note   +/- refresh   $info   q quit" "$DIM"; fi
    fi
}

# Changed rows are padded and written in one packet. No erase-before-redraw,
# no newline at the bottom edge, no repeated painting of the static header.
render() {
    local packet='' i row count=${#FRAME[@]} max=${#PREVIOUS_FRAME[@]} force=$RESIZE
    RESIZE=0
    ((count > max)) && max=$count
    ((force)) && max=$ROWS
    ((max > ROWS)) && max=$ROWS
    for ((i=0;i<max;i++)); do
        row=${FRAME[i]:-}
        if ((force)) || [[ $row != "${PREVIOUS_FRAME[i]:-}" ]]; then
            # EL clears only the unused tail after the new row has been written.
            printf -v packet '%s\e[%d;1H%s\e[0K' "$packet" "$((i+1))" "$row"
        fi
    done
    [[ -n $packet ]] && printf '%s' "$packet"
    PREVIOUS_FRAME=("${FRAME[@]}")
}

cleanup() {
    if ((ACTIVE)); then
        ACTIVE=0
        [[ -n ${SAVED_STTY:-} ]] && stty "$SAVED_STTY" <&3 2>/dev/null
        printf '\e[0m\e[?25h\e[?1049l'
        exec 3<&-
    fi
}

resize_terminal() { RESIZE=1; }

suspend_terminal() {
    if ((ACTIVE)); then
        stty "$SAVED_STTY" <&3 2>/dev/null
        printf '\e[0m\e[?25h\e[?1049l'
        ACTIVE=0 SUSPENDED=1
        # STOP is intentional: the TSTP handler has already restored the shell.
        kill -STOP "$$"
    fi
}

resume_terminal() {
    if ((SUSPENDED)); then
        ACTIVE=1 SUSPENDED=0
        stty -echo -icanon min 1 time 0 <&3
        printf '\e[?1049h\e[?25l'
        PREV_CPU_TOTAL='' PREV_NET_TIME=''
        RESIZE=1 NEXT_SAMPLE=0
    fi
}

handle_key() {
    case $1 in
        q|Q|$'\004') return 1 ;;
        p|P|' ')
            PAUSED=$((1-PAUSED))
            if ((PAUSED == 0)); then
                PREV_CPU_TOTAL='' PREV_NET_TIME=''
                sample
                NEXT_SAMPLE=$((NOW_CS+INTERVAL_CS))
            fi ;;
        d|D) DETAILS=$((1-DETAILS)) ;;
        +|=)
            if ((INTERVAL_CS > 500)); then INTERVAL=5 INTERVAL_CS=500
            elif ((INTERVAL_CS > 200)); then INTERVAL=2 INTERVAL_CS=200
            elif ((INTERVAL_CS > 100)); then INTERVAL=1 INTERVAL_CS=100
            else INTERVAL=0.5 INTERVAL_CS=50; fi
            NEXT_SAMPLE=0 ;;
        -|_)
            if ((INTERVAL_CS < 100)); then INTERVAL=1 INTERVAL_CS=100
            elif ((INTERVAL_CS < 200)); then INTERVAL=2 INTERVAL_CS=200
            elif ((INTERVAL_CS < 500)); then INTERVAL=5 INTERVAL_CS=500
            else INTERVAL=10 INTERVAL_CS=1000; fi
            NEXT_SAMPLE=0 ;;
    esac
    return 0
}

main() {
    local result key wait_cs wait_time dirty
    parse_args "$@"; result=$?
    ((result == 10)) && return 0
    ((result != 0)) && return "$result"
    [[ -r /proc/stat && -r /proc/meminfo && -r /proc/uptime ]] || { error 'Linux /proc is required'; return 1; }
    if [[ ! -t 1 || ! -t 0 || ${TERM:-dumb} == dumb ]]; then ONCE=1; fi
    setup_style
    collect_static
    sample
    # Prime delta-based counters for a meaningful initial CPU/network sample.
    sleep 0.12
    sample
    if ((ONCE)); then
        get_size
        build_frame
        printf '%s\n' "${FRAME[@]}"
        return 0
    fi
    exec 3<&0
    SAVED_STTY=$(stty -g <&3 2>/dev/null) || { error 'Cannot read terminal settings'; return 1; }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    trap resize_terminal WINCH
    trap suspend_terminal TSTP
    trap resume_terminal CONT
    ACTIVE=1
    stty -echo -icanon min 1 time 0 <&3
    printf '\e[?1049h\e[?25l'
    get_size; build_frame; render
    NEXT_SAMPLE=$((NOW_CS+INTERVAL_CS))
    while :; do
        dirty=0
        clock_sample
        wait_cs=$((NEXT_SAMPLE-NOW_CS))
        ((PAUSED)) && wait_cs=100
        ((wait_cs < 1)) && wait_cs=1
        # Bash may resume read after WINCH. Bound the wait so resizing stays
        # responsive even while paused or using a ten-second sample interval.
        ((wait_cs > 20)) && wait_cs=20
        printf -v wait_time '%d.%02d' "$((wait_cs/100))" "$((wait_cs%100))"
        key=''
        IFS= read -r -s -n 1 -t "$wait_time" -u 3 key
        result=$?
        if ((result == 0)); then
            # read -n 1 can return an empty key for Enter; it is harmless.
            handle_key "$key" || break
            dirty=1
        elif ((result == 1)); then
            break  # EOF / closed terminal: do not spin.
        fi
        if ((RESIZE)); then get_size; dirty=1; fi
        clock_sample
        if ((PAUSED == 0 && NOW_CS >= NEXT_SAMPLE)); then
            sample
            NEXT_SAMPLE=$((NOW_CS+INTERVAL_CS))
            dirty=1
        fi
        if ((dirty)); then build_frame; render; fi
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
