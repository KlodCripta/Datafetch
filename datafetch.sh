#!/usr/bin/env bash
# Datafetch — Live System Dashboard
# Copyright (c) 2024–2026 Klod Cripta. MIT License.
# Bash 4.3+; Linux /proc and /sys. Optional tools enrich static information.

VERSION='3.0.1'
INTERVAL=1
INTERVAL_CS=100
ONCE=0
COMPACT=0
DETAILS=0
DETAIL_PAGE=0
SYSTEM_PAGES=1
ASCII=0
ICONS=1
ICON_WIDTH=0
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
BLUE='' PINE='' VIOLET=''
BAR_ON='#' BAR_OFF='-' RULE_CHAR='-' MARK='>' DEG='C'
BOX_TL='+' BOX_TR='+' BOX_BL='+' BOX_BR='+' BOX_V='|' UNICODE=0
BOX_LJOIN='+' BOX_RJOIN='+'
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
  --no-icons          Hide field icons, keeping the current frame style
  --ascii             Use only ASCII characters
  --no-color          Disable colors (also respects NO_COLOR)
  --color MODE        auto, always or never
  -h, --help          Show this help
  -v, --version       Show the version

Live keys: p / space = pause, + = faster, - = slower, d = details/next page, q = quit.
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
            --no-icons) ICONS=0 ;;
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
    local root=${1:-/} count='' pkg path
    root=${root%/}
    PKG_MANAGER='n/a' PKG_COUNT='n/a' PKG_MANAGERS='' AUR_HELPERS='' FLATPAK_COUNT=''
    if command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER=pacman; count=$(set -o pipefail; pacman -Qq 2>/dev/null | wc -l) || count=''
    elif command -v dpkg-query >/dev/null 2>&1; then
        PKG_MANAGER=dpkg
        if command -v apt >/dev/null 2>&1 || command -v apt-get >/dev/null 2>&1; then PKG_MANAGER=apt; fi
        count=$(set -o pipefail; dpkg-query -W -f='${db:Status-Status}\n' 2>/dev/null | LC_ALL=C awk '$0=="installed"{n++} END{print n+0}') || count=''
    elif [[ -d $root/var/db/pkg ]] && command -v emerge >/dev/null 2>&1; then
        PKG_MANAGER=Portage; count=0
        for path in "$root"/var/db/pkg/*/*; do [[ -d $path ]] && ((count+=1)); done
    elif command -v rpm >/dev/null 2>&1; then
        PKG_MANAGER=rpm
        for pkg in dnf dnf5 zypper yum; do
            command -v "$pkg" >/dev/null 2>&1 && { PKG_MANAGER=$pkg; break; }
        done
        count=$(set -o pipefail; rpm -qa 2>/dev/null | wc -l) || count=''
    elif command -v xbps-query >/dev/null 2>&1; then
        PKG_MANAGER=xbps; count=$(set -o pipefail; xbps-query -l 2>/dev/null | wc -l) || count=''
    elif command -v apk >/dev/null 2>&1; then
        PKG_MANAGER=apk; count=$(set -o pipefail; apk info 2>/dev/null | wc -l) || count=''
    fi
    count=${count//[[:space:]]/}; unsigned "$count" && PKG_COUNT=$count
    [[ $PKG_MANAGER != n/a ]] && PKG_MANAGERS=$PKG_MANAGER
    # Report additional installed tools without contacting stores or snapd.
    for pkg in flatpak snap nix guix; do
        if command -v "$pkg" >/dev/null 2>&1; then PKG_MANAGERS+="${PKG_MANAGERS:+, }$pkg"; fi
    done
    PKG_MANAGERS=${PKG_MANAGERS:-n/a}
    if [[ $PKG_MANAGER == pacman ]]; then
        for pkg in paru yay pikaur aura trizen pakku; do
            command -v "$pkg" >/dev/null 2>&1 && AUR_HELPERS+="${AUR_HELPERS:+, }$pkg"
        done
    fi
    AUR_HELPERS=${AUR_HELPERS:-non pervenuto}
    if command -v flatpak >/dev/null 2>&1; then
        FLATPAK_COUNT=$(set -o pipefail; flatpak list --app --columns=application 2>/dev/null | wc -l) || FLATPAK_COUNT=''
        FLATPAK_COUNT=${FLATPAK_COUNT//[[:space:]]/}
    fi
    return 0
}

normalize_desktop_name() {
    local raw=$1 token name
    local -a tokens=()
    sanitize "$raw"; raw=$REPLY
    IFS=: read -r -a tokens <<< "$raw"
    for token in "${tokens[@]}"; do
        token=${token##*/}; token=${token%.desktop}
        case ${token,,} in
            kde|plasma|plasmax11|plasmawayland|'kde plasma') name='KDE Plasma' ;;
            gnome-classic) name='GNOME Classic' ;; gnome|gnome-xorg|gnome-wayland) name=GNOME ;;
            cinnamon|x-cinnamon) name=Cinnamon ;; lxqt) name=LXQt ;; lxde) name=LXDE ;;
            xfce|xfce4) name=Xfce ;; mate) name=MATE ;; budgie|budgie-desktop) name=Budgie ;;
            deepin|dde) name=Deepin ;; pantheon) name=Pantheon ;; cosmic) name=COSMIC ;;
            unity) name=Unity ;; trinity|tde) name=Trinity ;; enlightenment) name=Enlightenment ;;
            sway) name=Sway ;; hyprland) name=Hyprland ;; i3) name=i3 ;;
            *) continue ;;
        esac
        REPLY=$name; return
    done
    REPLY=${raw:-n/a}
}

get_shell() {
    local procroot=${1:-/proc} pid=${2:-$PPID} attempt name parent key value
    SHELL_NAME='n/a'
    # Find a launching shell through wrappers; do not report Datafetch's own
    # Bash interpreter as the user's shell. Fall back to the configured shell.
    for ((attempt=0; attempt<8; attempt++)); do
        unsigned "$pid" && ((pid > 1)) || break
        read_value "$procroot/$pid/comm"; name=${REPLY#-}
        case $name in
            bash|zsh|fish|dash|ash|ksh|ksh93|mksh|tcsh|csh|nu|elvish|xonsh|yash|osh)
                SHELL_NAME=$name; return ;;
        esac
        [[ -r $procroot/$pid/status ]] || break
        parent=''
        while read -r key value; do [[ $key == PPid: ]] && { parent=$value; break; }; done < "$procroot/$pid/status" 2>/dev/null
        [[ -n $parent && $parent != "$pid" ]] || break
        pid=$parent
    done
    name=${SHELL:-}
    SHELL_NAME=${name##*/}; SHELL_NAME=${SHELL_NAME:-n/a}
}

get_audio_server() {
    AUDIO_SERVER=''
    if command -v pgrep >/dev/null 2>&1; then
        if pgrep -x -u "$UID" pipewire >/dev/null 2>&1 || pgrep -x -u "$UID" pipewire-pulse >/dev/null 2>&1; then AUDIO_SERVER=PipeWire; fi
        if pgrep -x -u "$UID" pulseaudio >/dev/null 2>&1; then AUDIO_SERVER+="${AUDIO_SERVER:+, }PulseAudio"; fi
        if pgrep -x -u "$UID" jackd >/dev/null 2>&1 || pgrep -x -u "$UID" jackdbus >/dev/null 2>&1; then AUDIO_SERVER+="${AUDIO_SERVER:+, }JACK"; fi
    fi
    AUDIO_SERVER=${AUDIO_SERVER:-n/a}
}

normalize_gpu_name() {
    local name=$1 vendor='' label rest chip=''
    GPU_CODENAME=''
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
    rest=$name
    while [[ $rest == *'['*']'* ]]; do
        label=${rest#*\[}; label=${label%%\]*}
        case $label in
            *GeForce*|*Quadro*|*RTX*|*Radeon*|*Graphics*|*Arc*)
                [[ $vendor == AMD ]] && chip=${name%% \[*}
                name=$label; break ;;
        esac
        rest=${rest#*\]}
    done
    if [[ $vendor == AMD ]]; then
        case $name in
            Barcelo|Picasso|Raven|Raven2|Renoir|Cezanne|Lucienne|Rembrandt|Raphael|Phoenix|Phoenix1|Phoenix2)
                chip=$name; name=Radeon ;;
        esac
        if [[ $name == Radeon\ *\ Graphics && $name != 'Radeon Graphics' ]]; then name=${name% Graphics}; fi
    fi
    name=${name//Lite Hash Rate/LHR}
    name=${name//(R)/}; name=${name//(TM)/}
    name=${name#"$vendor "}
    REPLY="${vendor:+$vendor }$name"
    if [[ -n $chip && $REPLY != *"$chip"* ]] && ((${#REPLY}+${#chip}+3 <= 36)); then
        REPLY+=" ($chip)"
    fi
    GPU_CODENAME=$chip
}

gpu_vendor() {
    case $1 in
        1002) REPLY=AMD ;; 10de) REPLY=NVIDIA ;; 8086) REPLY=Intel ;;
        102b) REPLY=Matrox ;; 1a03) REPLY=ASPEED ;; 15ad) REPLY=VMware ;;
        1234) REPLY=QEMU ;; 1af4) REPLY=Virtio ;; *) REPLY='' ;;
    esac
}

lookup_pci_gpu() {
    local file=$1 vendor=$2 device=$3
    REPLY=''
    [[ -r $file && $vendor =~ ^[[:xdigit:]]{4}$ && $device =~ ^[[:xdigit:]]{4}$ ]] || return 0
    REPLY=$(LC_ALL=C awk -v vendor="$vendor" -v device="$device" '
        /^[[:xdigit:]]{4}[[:space:]]/ {
            if (found) exit
            if (tolower($1)==vendor) {found=1; sub(/^[^[:space:]]+[[:space:]]+/, ""); maker=$0}
            next
        }
        found && /^\t[^\t]/ && tolower($1)==device {
            sub(/^\t[^[:space:]]+[[:space:]]+/, ""); print maker " " $0; exit
        }
    ' "$file" 2>/dev/null)
}

lookup_amdgpu_name() {
    local file=$1 device=${2^^} revision=${3^^} id rev name found=''
    REPLY=''
    [[ -r $file && $device =~ ^[[:xdigit:]]{4}$ && $revision =~ ^[[:xdigit:]]{2}$ ]] || return 0
    while IFS=, read -r id rev name; do
        id=${id//[[:space:]]/}; rev=${rev//[[:space:]]/}
        [[ ${id^^} == "$device" && ${rev^^} == "$revision" ]] || continue
        name=${name#"${name%%[![:space:]]*}"}; name=${name%"${name##*[![:space:]]}"}
        [[ -n $name ]] || continue
        # Some IDs occur more than once with conflicting products. Do not pick
        # one arbitrarily or match only the device ID and discard its revision.
        [[ -z $found || $found == "$name" ]] || { REPLY=''; return; }
        found=$name
    done < "$file"
    REPLY=$found
}

cache_pci_gpu() {
    local slot=${1,,} class=$2 vendor=$3 device=$4 rev=${5,,} vid did
    [[ $slot =~ ^[[:xdigit:]]{4,8}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] || return 0
    [[ $class =~ \[03[[:xdigit:]]{2}\]$ ]] || return 0
    [[ $vendor =~ \[([[:xdigit:]]{4})\]$ ]] || return 0
    vid=${BASH_REMATCH[1],,}; vendor=${vendor% \[*}
    [[ $device =~ \[([[:xdigit:]]{4})\]$ ]] || return 0
    did=${BASH_REMATCH[1],,}; device=${device% \[*}
    pci_slots+=("$slot")
    if [[ $device == Device || ${device,,} == "$did" ]]; then pci_names[$slot]=''
    else pci_names[$slot]="$vendor $device"; fi
    pci_vendors[$slot]=$vid pci_devices[$slot]=$did pci_revisions[$slot]=$rev
}

read_pci_gpu_descriptions() {
    local key value slot='' class='' vendor='' device='' revision=''
    while IFS=$'\t' read -r key value || [[ -n $key ]]; do
        case $key in
            Slot:) slot=$value ;; Class:) class=$value ;; Vendor:) vendor=$value ;;
            Device:) device=$value ;; Rev:) revision=$value ;;
            '')
                cache_pci_gpu "$slot" "$class" "$vendor" "$device" "$revision"
                slot='' class='' vendor='' device='' revision='' ;;
        esac
    done
    cache_pci_gpu "$slot" "$class" "$vendor" "$device" "$revision"
}

resolve_gpu_name() {
    local path=$1 slot=$2 vendor=$3 device=$4 revision=$5 raw=$6 name chip model='' maker line driver
    if [[ -z $raw ]]; then lookup_pci_gpu "$pci_ids" "$vendor" "$device"; raw=$REPLY; fi
    normalize_gpu_name "$raw"; name=$REPLY; chip=$GPU_CODENAME
    read_value "$path/product_name"; model=$REPLY
    if [[ -z $model && $vendor == 1002 ]]; then
        lookup_amdgpu_name "$amd_ids" "$device" "$revision"; model=$REPLY
    elif [[ -z $model && $vendor == 10de && -r $nvidia_root/$slot/information ]]; then
        while IFS= read -r line; do
            [[ $line == Model:* ]] || continue
            model=${line#Model:}; model=${model#"${model%%[![:space:]]*}"}; break
        done < "$nvidia_root/$slot/information"
    fi
    if [[ -n $model ]]; then
        gpu_vendor "$vendor"; maker=$REPLY
        [[ -n $maker && $model != "$maker "* ]] && model="$maker $model"
        normalize_gpu_name "$model"
        # A generic database label must not replace a more useful PCI name.
        if [[ ! $REPLY =~ ^AMD[[:space:]]Radeon([[:space:]]RX)?([[:space:]]Vega)?([[:space:]](Graphics|Series))?$ || -z $name ]]; then
            name=$REPLY
            if [[ -n $chip && $name != *"$chip"* ]] && ((${#name}+${#chip}+3 <= 36)); then name+=" ($chip)"; fi
        fi
    fi
    if [[ -z $name ]]; then
        gpu_vendor "$vendor"; name="${REPLY:+$REPLY }GPU"
        if [[ $vendor =~ ^[[:xdigit:]]{4}$ && $device =~ ^[[:xdigit:]]{4}$ ]]; then
            name+=" [$vendor:$device]"
        else
            driver=$(readlink "$path/driver" 2>/dev/null); driver=${driver##*/}
            [[ -n $driver ]] && name+=" ($driver)"
        fi
    fi
    sanitize "$name"
}

get_gpus() {
    local sysroot=${1:-/sys} pci_ids=${2:-} amd_ids=${3:-/usr/share/libdrm/amdgpu.ids}
    local nvidia_root=${4:-/proc/driver/nvidia/gpus} path slot class vendor device revision canonical name candidate
    local -a pci_slots=()
    local -A pci_names=() pci_vendors=() pci_devices=() pci_revisions=() seen_paths=() seen_slots=()
    GPU_NAMES=()
    if (($# < 2)); then
        for candidate in /usr/share/hwdata/pci.ids /usr/share/misc/pci.ids /usr/share/pci.ids; do
            [[ -r $candidate ]] && { pci_ids=$candidate; break; }
        done
    fi
    if command -v lspci >/dev/null 2>&1; then
        # -vmm is the documented tag/value interface; -nn retains numeric IDs.
        # No DNS lookup, GPU wake-up query or external graphics utility needed.
        read_pci_gpu_descriptions < <(LC_ALL=C lspci -D -vmm -nn 2>/dev/null)
    fi
    for path in "$sysroot"/bus/pci/devices/*; do
        read_value "$path/class"; class=${REPLY,,}
        [[ $class == 0x03???? ]] || continue
        slot=${path##*/}; slot=${slot,,}
        read_value "$path/vendor"; vendor=${REPLY#0x}; vendor=${vendor,,}
        read_value "$path/device"; device=${REPLY#0x}; device=${device,,}
        read_value "$path/revision"; revision=${REPLY#0x}; revision=${revision,,}
        resolve_gpu_name "$path" "$slot" "$vendor" "$device" "$revision" "${pci_names[$slot]:-}"; name=$REPLY
        read_value "$path/boot_vga"
        if [[ $REPLY == 1 ]]; then GPU_NAMES=("$name" "${GPU_NAMES[@]}")
        else GPU_NAMES+=("$name"); fi
        canonical=$(readlink -f "$path" 2>/dev/null)
        [[ -n $canonical ]] && seen_paths[$canonical]=1
        seen_slots[$slot]=1
    done
    # DRM also exposes non-PCI/platform GPUs and compute cards. A physical
    # device seen in both PCI and DRM must be listed only once.
    for path in "$sysroot"/class/drm/card*/device; do
        [[ ${path%/device} =~ /card[0-9]+$ && -d $path ]] || continue
        canonical=$(readlink -f "$path" 2>/dev/null)
        [[ -n $canonical && ! ${seen_paths[$canonical]+seen} ]] || continue
        slot=${canonical##*/}; slot=${slot,,}
        read_value "$path/vendor"; vendor=${REPLY#0x}; vendor=${vendor,,}
        read_value "$path/device"; device=${REPLY#0x}; device=${device,,}
        read_value "$path/revision"; revision=${REPLY#0x}; revision=${revision,,}
        resolve_gpu_name "$path" "$slot" "$vendor" "$device" "$revision" "${pci_names[$slot]:-}"
        GPU_NAMES+=("$REPLY"); seen_paths[$canonical]=1; seen_slots[$slot]=1
    done
    # Keep lspci-only records when /sys is restricted or unavailable.
    for slot in "${pci_slots[@]}"; do
        [[ ${seen_slots[$slot]+seen} ]] && continue
        resolve_gpu_name "$sysroot/bus/pci/devices/$slot" "$slot" "${pci_vendors[$slot]}" \
            "${pci_devices[$slot]}" "${pci_revisions[$slot]}" "${pci_names[$slot]}"
        GPU_NAMES+=("$REPLY"); seen_slots[$slot]=1
    done
    GPU_NAME='n/a'
    if ((${#GPU_NAMES[@]})); then
        GPU_NAME=${GPU_NAMES[0]}
        ((${#GPU_NAMES[@]} > 1)) && GPU_NAME+=" (+$((${#GPU_NAMES[@]}-1)) GPU)"
    fi
    return 0
}

collect_static() {
    local key val info pid1 sockets=1 cores='' threads='' name path
    OS_NAME='Linux'
    if [[ -r /etc/os-release ]]; then
        OS_NAME=$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-${NAME:-Linux}}")
    fi
    read_value /proc/sys/kernel/hostname; HOST_NAME=${REPLY:-unknown}
    KERNEL_VER=$(uname -r); ARCH_NAME=$(uname -m)
    get_shell
    normalize_desktop_name "${XDG_CURRENT_DESKTOP:-${XDG_SESSION_DESKTOP:-${DESKTOP_SESSION:-}}}"; DE_NAME=$REPLY
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
    get_audio_server
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
    BLUE='' PINE='' VIOLET=''
    if [[ $COLOR_MODE == always || ($COLOR_MODE == auto && -t 1 && ! ${NO_COLOR+x} && ${TERM:-dumb} != dumb) ]]; then
        RESET=$'\e[0m'; BOLD=$'\e[1m'; TEXT=$'\e[37m'; ACCENT=$'\e[36m'
        DIM=$'\e[36m'; BORDER=$'\e[34m'; WARN=$'\e[33m'; BAD=$'\e[31m'
        BLUE=$'\e[34m'; PINE=$'\e[36m'; VIOLET=$'\e[35m'
        case ${TERM:-} in *256color*|*direct*|xterm-kitty|foot*)
            TEXT=$'\e[38;5;255m'; ACCENT=$'\e[38;5;117m'; DIM=$'\e[38;5;109m'
            BORDER=$'\e[38;5;67m'; BLUE=$'\e[38;5;110m'; PINE=$'\e[38;5;73m'; VIOLET=$'\e[38;5;98m'
            WARN=$'\e[38;5;180m'; BAD=$'\e[38;5;131m' ;;
        esac
        if [[ ${COLORTERM:-} == truecolor || ${COLORTERM:-} == 24bit || ${TERM:-} == *direct* ]]; then
            # A cold Nordic palette; each group has its own accent.
            TEXT=$'\e[38;2;232;239;245m'; ACCENT=$'\e[38;2;154;219;232m'
            DIM=$'\e[38;2;132;158;181m'; BORDER=$'\e[38;2;84;109;136m'
            BLUE=$'\e[38;2;130;173;222m'; PINE=$'\e[38;2;91;175;164m'; VIOLET=$'\e[38;2;148;116;206m'
            WARN=$'\e[38;2;216;185;138m'; BAD=$'\e[38;2;191;97;106m'
        fi
        GOOD=$PINE
    fi
    BAR_ON='#' BAR_OFF='-' RULE_CHAR='-' MARK='>' DEG=C UNICODE=0
    BOX_TL='+' BOX_TR='+' BOX_BL='+' BOX_BR='+' BOX_V='|'
    BOX_LJOIN='+' BOX_RJOIN='+'
    charmap=$(locale charmap 2>/dev/null)
    if ((ASCII == 0)) && [[ $charmap == UTF-8 || $charmap == UTF8 ]]; then
        BAR_ON='━'; BAR_OFF='─'; RULE_CHAR='─'; MARK='●'; DEG='°C'; UNICODE=1
        BOX_TL='╭'; BOX_TR='╮'; BOX_BL='╰'; BOX_BR='╯'; BOX_V='│'
        BOX_LJOIN='├'; BOX_RJOIN='┤'
    fi
    ICON_WIDTH=0
    ((ICONS && UNICODE)) && ICON_WIDTH=2
    return 0
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

icon_prefix() {
    REPLY=''
    ((ICON_WIDTH)) || return 0
    # Text symbols, without emoji presentation or private-use font glyphs.
    # One symbol and one space; --no-icons preserves Unicode panel borders.
    case $1 in
        OS) REPLY='◈' ;; HOST) REPLY='⌂' ;; KERNEL) REPLY='⌘' ;;
        CPU) REPLY='▣' ;; GPU) REPLY='▧' ;; ARCH) REPLY='◇' ;;
        DESKTOP) REPLY='▤' ;; UPTIME) REPLY='◷' ;; TEMP) REPLY='≋' ;;
        RAM) REPLY='▥' ;; SWAP) REPLY='⇄' ;; DISK|'ROOT FS') REPLY='◉' ;;
        NET) REPLY='⇅' ;; BAT) REPLY='▰' ;; POWER|EPP) REPLY='ϟ' ;;
        PACKAGES|MANAGERS|AUR) REPLY='▦' ;; SHELL) REPLY='›' ;; INIT) REPLY='↻' ;;
        AUDIO) REPLY='♪' ;; DRIVER) REPLY='↔' ;; GOVERNOR) REPLY='◌' ;;
        *) REPLY='·' ;;
    esac
    REPLY+=' '
}

icon_cell() {
    local prefix
    icon_prefix "$1"; prefix=$REPLY
    fit "$((CW-ICON_WIDTH))" "$2"
    CELLS+=("${4:-$ACCENT}$prefix${3:-$TEXT}$REPLY$RESET")
}

field() {
    local label value label_width=$((9+ICON_WIDTH))
    icon_prefix "$1"; label="$REPLY$1"
    fit "$label_width" "$label"; label=$REPLY
    fit "$((CW-label_width))" "$2"; value=$REPLY
    CELLS+=("${3:-$BLUE}$label$TEXT$value$RESET")
}

detail_field() {
    local label=$1 value=$2 tint=${3:-$BLUE} width=$((CW-9-ICON_WIDTH)) chunk
    sanitize "$value"; value=$REPLY
    # Long lists remain readable across pages; the label repeats on each line.
    while ((${#value} > width)); do
        chunk=${value:0:width}
        [[ $chunk == *' '* ]] && chunk=${chunk% *}
        [[ -n $chunk ]] || chunk=${value:0:width}
        field "$label" "$chunk" "$tint"
        value=${value:${#chunk}}; value=${value#"${value%%[! ]*}"}
    done
    field "$label" "$value" "$tint"
}

pair_cell() {
    local left
    fit "$((CW/2))" "$1"; left=$REPLY
    fit "$((CW-CW/2))" "$2"
    CELLS+=("$TEXT$left$REPLY$RESET")
}

pair_field() {
    local a b c d label_width=$((9+ICON_WIDTH))
    icon_prefix "$1"; a="$REPLY$1"
    fit "$label_width" "$a"; a=$REPLY
    fit "$((CW/2-label_width))" "$2"; b=$REPLY
    icon_prefix "$3"; c="$REPLY$3"
    fit "$label_width" "$c"; c=$REPLY
    fit "$((CW-CW/2-label_width))" "$4"; d=$REPLY
    CELLS+=("$BLUE$a$TEXT$b$BLUE$c$TEXT$d$RESET")
}

metric() {
    local label=$1 pct=$2 note=$3 length filled empty bar tail color suffix a n
    # Stable columns: changing a value's number of digits must not move its bar.
    length=8; ((CW < 48)) && length=4; ((CW >= 65)) && length=18
    n=${pct%.*}; [[ -n $n ]] || n=0
    ((n < 0)) && n=0; ((n > 100)) && n=100
    case $label in
        RAM|SWAP) color=$VIOLET ;;
        DISK) color=$BLUE ;;
        BAT) color=$PINE ;;
        *) color=$ACCENT ;;
    esac
    if [[ $label == BAT ]]; then
        if [[ $BAT_STATUS == Discharging ]]; then
            ((n < 30)) && color=$WARN
            ((n < 15)) && color=$BAD
        fi
    else
        ((n >= 75)) && color=$WARN; ((n >= 90)) && color=$BAD
    fi
    filled=$((n*length/100)); empty=$((length-filled))
    repeat "$filled" "$BAR_ON"; bar=$REPLY
    repeat "$empty" "$BAR_OFF"; tail=$REPLY
    icon_prefix "$label"; a="$REPLY$label"
    fit "$((5+ICON_WIDTH))" "$a"; a=$REPLY
    if [[ -n $pct ]]; then printf -v suffix '%5s%%' "$pct"; else suffix='   n/a'; fi
    fit "$((CW-14-length-ICON_WIDTH))" "$note"; note=$REPLY
    CELLS+=("$color$a$bar$BORDER$tail$TEXT $BOLD$suffix$RESET$TEXT  $note$RESET")
}

memory_note() {
    local used=$1 total=$2 a
    human_bytes "$used"; a=$REPLY
    human_bytes "$total"; REPLY="$a / $REPLY"
}

rule_row() {
    local left=$1 right=$2 title=${3:-} tint=${4:-$ACCENT} tail
    if [[ -z $title ]]; then
        repeat "$((CW+2))" "$RULE_CHAR"
        REPLY="$BORDER$left$REPLY$right$RESET"
        return
    fi
    fit "$((CW-1))" "$title"; title=${REPLY%"${REPLY##*[! ]}"}
    repeat "$((CW-1-${#title}))" "$RULE_CHAR"; tail=$REPLY
    REPLY="$BORDER$left$RULE_CHAR $tint$BOLD$title$RESET$BORDER $tail$right$RESET"
}

divider() {
    rule_row "$BOX_LJOIN" "$BOX_RJOIN" "$1" "${2:-$ACCENT}"
    # A private marker distinguishes full-width borders from padded data cells.
    # User-derived text is sanitized before insertion and cannot emit it.
    CELLS+=($'\037'"$REPLY")
}

history_section() {
    local value level text='' glyphs=' .:-=+*#%@' count=${#CPU_HISTORY[@]} capacity=$((CW-8))
    ((UNICODE)) && glyphs='▁▂▃▄▅▆▇█'
    ((count > capacity)) && count=$capacity
    divider "CPU USAGE / last $count samples" "$ACCENT"
    if ((count == 0)); then cell 'Waiting for CPU samples' "$DIM"; return; fi
    for value in "${CPU_HISTORY[@]: -count}"; do
        level=$((value*(${#glyphs}-1)/100)); text+=${glyphs:level:1}
    done
    cell "0-100%  $text" "$ACCENT"
}

panelize() {
    local title=$1 height=${2:-${#CELLS[@]}} i row empty
    PANEL=()
    rule_row "$BOX_TL" "$BOX_TR" "$title"; PANEL+=("$REPLY")
    fit "$CW" ''; empty=$REPLY
    for ((i=0;i<height;i++)); do
        row=${CELLS[i]:-$empty}
        if [[ $row == $'\037'* ]]; then PANEL+=("${row:1}")
        else PANEL+=("$BORDER$BOX_V$RESET $row $BORDER$BOX_V$RESET"); fi
    done
    rule_row "$BOX_BL" "$BOX_BR"; PANEL+=("$REPLY")
}

banner() {
    local status=$1 big=0 tag left right i CW=$((WIDTH-4)) BORDER=$VIOLET
    local -a CELLS=() PANEL=() logo=(
        '╔╦╗ ╔═╗ ╔╦╗ ╔═╗ ╔═╗ ╔═╗ ╔╦╗ ╔═╗ ╦ ╦'
        ' ║║ ╠═╣  ║  ╠═╣ ╠╣  ║╣   ║  ║   ╠═╣'
        '═╩╝ ╩ ╩  ╩  ╩ ╩ ╚   ╚═╝  ╩  ╚═╝ ╩ ╩'
    ) meta=("$status" "$VERSION" '')
    if ((ROWS < 18 && SMALL)); then
        fit "$((WIDTH-${#status}-4))" 'DATAFETCH'; tag=$REPLY
        FRAME+=("  $VIOLET[$TEXT$BOLD $tag$RESET$VIOLET] $PINE$status$RESET")
        return
    fi
    if ((WIDTH >= 69 && UNICODE && ((WIDE && ROWS >= 20) || ROWS >= 26))); then big=1; fi
    if ((big)); then
        for ((i=0;i<3;i++)); do
            fit 39 "${logo[i]}"; left=$REPLY
            fit "$((CW-39))" "${meta[i]}"; right=$REPLY
            tag=$BLUE; ((i == 0)) && tag=$PINE
            CELLS+=("$TEXT$left$tag$right$RESET")
        done
        panelize 'Klod Cripta'
    else
        fit "$((CW-${#status}))" 'D A T A F E T C H'; left=$REPLY
        CELLS+=("$TEXT$BOLD$left$RESET$PINE$status$RESET")
        panelize "Klod Cripta / $VERSION"
    fi
    for tag in "${PANEL[@]}"; do FRAME+=("  $tag"); done
}

system_cells() {
    local name
    CELLS=()
    if ((DETAILS)); then
        detail_field PACKAGES "$PKG_COUNT ($PKG_MANAGER)${FLATPAK_COUNT:+ / $FLATPAK_COUNT Flatpak}"
        detail_field MANAGERS "${PKG_MANAGERS:-$PKG_MANAGER}"
        detail_field AUR "${AUR_HELPERS:-non pervenuto}" "$VIOLET"
        detail_field SHELL "$SHELL_NAME"
        detail_field INIT "$INIT_SYSTEM"
        detail_field 'ROOT FS' "${FILESYSTEM_NAME:-n/a}"
        detail_field AUDIO "$AUDIO_SERVER" "$PINE"
        if ((SMALL)); then
            divider SESSION "$BLUE"
            detail_field DESKTOP "$DE_NAME / $DISPLAY_SERVER"
            detail_field HOST "$HOST_NAME"
            detail_field KERNEL "$KERNEL_VER"
            detail_field UPTIME "$UPTIME"
        fi
        divider 'CPU POLICY' "$VIOLET"
        detail_field DRIVER "$CPU_DRIVER" "$VIOLET"
        detail_field GOVERNOR "$CPU_GOVERNOR" "$VIOLET"
        detail_field EPP "${CPU_EPP:-n/a}" "$VIOLET"
        divider GRAPHICS "$VIOLET"
        if ((${#GPU_NAMES[@]})); then
            for name in "${GPU_NAMES[@]}"; do detail_field GPU "$name" "$VIOLET"; done
        else detail_field GPU 'n/a' "$VIOLET"; fi
    elif ((SMALL)); then
        icon_cell OS "$OS_NAME" "$TEXT$BOLD"
        field CPU "$CPU_MODEL" "$ACCENT"
        field GPU "$GPU_NAME" "$VIOLET"
    elif ((WIDE)); then
        icon_cell OS "$OS_NAME" "$TEXT$BOLD"
        field HOST "$HOST_NAME"
        field KERNEL "$KERNEL_VER"
        divider HARDWARE "$VIOLET"
        field CPU "$CPU_MODEL" "$ACCENT"
        icon_cell ARCH "$CPU_CORES cores / $CPU_THREADS threads / $ARCH_NAME" "$DIM"
        field GPU "$GPU_NAME" "$VIOLET"
        divider SESSION "$BLUE"
        field DESKTOP "$DE_NAME / $DISPLAY_SERVER"
        field UPTIME "$UPTIME"
    else
        pair_field OS "$OS_NAME" HOST "$HOST_NAME"
        field KERNEL "$KERNEL_VER"
        pair_field DESKTOP "$DE_NAME / $DISPLAY_SERVER" UPTIME "$UPTIME"
        field CPU "$CPU_MODEL / $CPU_CORES cores, $CPU_THREADS threads" "$ACCENT"
        field GPU "$GPU_NAME" "$VIOLET"
    fi
    if ((DETAILS == 0 && ${#CELLS[@]}+6 <= SYSTEM_CAPACITY)); then
        divider SOFTWARE "$BLUE"
        field MANAGERS "${PKG_MANAGERS:-$PKG_MANAGER}"
        field AUR "${AUR_HELPERS:-non pervenuto}" "$VIOLET"
        pair_field SHELL "$SHELL_NAME" INIT "$INIT_SYSTEM"
        field 'ROOT FS' "${FILESYSTEM_NAME:-n/a}"
        field AUDIO "$AUDIO_SERVER" "$PINE"
    fi
    return 0
}

paginate_system() {
    local total=${#CELLS[@]} offset
    SYSTEM_PAGES=1
    if ((DETAILS)); then
        SYSTEM_PAGES=$(((total+SYSTEM_CAPACITY-1)/SYSTEM_CAPACITY))
        ((SYSTEM_PAGES < 1)) && SYSTEM_PAGES=1
        ((DETAIL_PAGE >= SYSTEM_PAGES)) && DETAIL_PAGE=$((SYSTEM_PAGES-1))
        offset=$((DETAIL_PAGE*SYSTEM_CAPACITY))
        CELLS=("${CELLS[@]:offset:SYSTEM_CAPACITY}")
    else DETAIL_PAGE=0; fi
    return 0
}

live_cells() {
    local note raw_peak
    CELLS=()
    metric CPU "$CPU_PERCENT" "${CPU_FREQ:-n/a} (CPU0)"
    if [[ -n $CPU_TEMP ]]; then
        raw_peak=$(((CPU_PEAK+50)/100))
        printf -v note '%s%s / peak %d.%d%s' "$CPU_TEMP" "$DEG" "$((raw_peak/10))" "$((raw_peak%10))" "$DEG"
    else note='n/a'; fi
    field TEMP "$note" "$ACCENT"
    ((DIVIDER_LEVEL >= 1)) && divider 'MEMORY / STORAGE' "$VIOLET"
    memory_note "$RAM_USED" "$RAM_TOTAL"; metric RAM "$RAM_PERCENT" "$REPLY"
    if ((SWAP_TOTAL)); then
        memory_note "$SWAP_USED" "$SWAP_TOTAL"; metric SWAP "$SWAP_PERCENT" "$REPLY"
    else metric SWAP '' 'Disabled'; fi
    if ((DISK_TOTAL)); then
        human_bytes "$DISK_FREE"; metric DISK "$DISK_PERCENT" "/ $REPLY free"
    else metric DISK '' 'n/a'; fi
    if ((DIVIDER_LEVEL >= 2)); then
        if ((DIVIDER_LEVEL == 2)) && [[ -n $BAT_NAME ]]; then divider 'NETWORK / POWER' "$BLUE"
        else divider "NETWORK${NET_IFACE:+ / $NET_IFACE}" "$BLUE"; fi
    fi
    if [[ -n $NET_IFACE ]]; then
        human_bytes "$RX_RATE"; note="down $REPLY/s"
        human_bytes "$TX_RATE"; note+="  up $REPLY/s"
        ((DIVIDER_LEVEL < 3)) && note+=" / $NET_IFACE"
        field NET "$note" "$BLUE"
    else field NET 'No active interface' "$BLUE"; fi
    if [[ -n $BAT_NAME ]]; then
        ((DIVIDER_LEVEL >= 3)) && divider "POWER / $BAT_NAME" "$PINE"
        if ((SMALL)); then
            metric BAT "${BAT_PERCENT:-}" "$BAT_STATUS${BAT_POWER:+ ${BAT_POWER}W}"
        else
            note=$BAT_STATUS; ((DIVIDER_LEVEL < 3)) && note="$BAT_NAME / $note"
            metric BAT "${BAT_PERCENT:-}" "$note"
            field POWER "${BAT_POWER:-n/a}${BAT_POWER:+ W} / health ${BAT_HEALTH:-n/a}${BAT_HEALTH:+%}" "$PINE"
        fi
    fi
}

build_frame() {
    local status tag note info WIDE=0 DIVIDER_LEVEL=0 CW left_width right_width title header_rows height i budget base SYSTEM_CAPACITY
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
    banner "$status"
    header_rows=${#FRAME[@]}
    title=SYSTEM; ((DETAILS)) && title='SYSTEM / DETAILS'
    if ((WIDE)); then
        left_width=$(((WIDTH-2)*44/100)); right_width=$((WIDTH-2-left_width))
        budget=$((ROWS-header_rows-3)); SYSTEM_CAPACITY=$budget
        CW=$((left_width-4)); system_cells; paginate_system; system=("${CELLS[@]}")
        ((DETAILS && SYSTEM_PAGES > 1)) && title+=" $((DETAIL_PAGE+1))/$SYSTEM_PAGES"
        CW=$((right_width-4))
        DIVIDER_LEVEL=3; live_cells
        if ((budget >= ${#CELLS[@]}+2)); then history_section; fi
        live=("${CELLS[@]}")
        height=${#system[@]}; ((${#live[@]} > height)) && height=${#live[@]}
        # A multi-GPU details view must still leave room for the key bar.
        ((height > budget)) && height=$budget
        CW=$((left_width-4)); CELLS=("${system[@]}"); panelize "$title" "$height"; system=("${PANEL[@]}")
        CW=$((right_width-4)); CELLS=("${live[@]}"); panelize "LIVE METRICS / $TIME_NOW" "$height"
        for ((i=0;i<${#PANEL[@]};i++)); do FRAME+=("  ${system[i]}  ${PANEL[i]}"); done
    else
        base=6
        if [[ -n $BAT_NAME ]]; then ((SMALL)) && base=$((base+1)) || base=$((base+2)); fi
        SYSTEM_CAPACITY=$((ROWS-header_rows-base-5))
        ((SYSTEM_CAPACITY < 1)) && SYSTEM_CAPACITY=1
        CW=$((WIDTH-4)); system_cells; paginate_system
        ((DETAILS && SYSTEM_PAGES > 1)) && title+=" $((DETAIL_PAGE+1))/$SYSTEM_PAGES"
        panelize "$title"
        for tag in "${PANEL[@]}"; do FRAME+=("  $tag"); done
        # Reserve essential readings before assigning space to details pages.
        budget=$((ROWS-${#FRAME[@]}-3))
        DIVIDER_LEVEL=$((budget-base)); ((DIVIDER_LEVEL > 3)) && DIVIDER_LEVEL=3; ((DIVIDER_LEVEL < 0)) && DIVIDER_LEVEL=0
        live_cells
        if ((SMALL == 0 && budget >= ${#CELLS[@]}+2)); then history_section; fi
        panelize "LIVE METRICS / $TIME_NOW"
        for tag in "${PANEL[@]}"; do FRAME+=("  $tag"); done
    fi
    if ((ONCE)); then
        add_row 'Snapshot / run without --once for live metrics' "$DIM"
    else
        note='p pause'; ((PAUSED)) && note='p resume'
        info='d details'
        if ((DETAILS)); then
            info='d overview'; ((DETAIL_PAGE+1 < SYSTEM_PAGES)) && info='d next'
        fi
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
        d|D)
            if ((DETAILS == 0)); then DETAILS=1; DETAIL_PAGE=0
            elif ((DETAIL_PAGE+1 < SYSTEM_PAGES)); then ((DETAIL_PAGE+=1))
            else DETAILS=0; DETAIL_PAGE=0; fi ;;
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
