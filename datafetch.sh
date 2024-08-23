#!/bin/bash

# Definire i colori
BOLD="\e[1m"
RESET="\e[0m"
BLUE="\e[38;5;32m"  # Colore blu/azzurro arch linux
GREEN="\e[38;2;1;121;111m"  # Colore verde 01796f

# Logo ASCII
logo="\
${GREEN} ____________________________________${RESET}
${GREEN}/                                    \\
${GREEN}|${RESET}${BOLD}${BLUE} DATAFETCH: Advanced Data Retrieval ${RESET}${GREEN}|${RESET}
${GREEN}\\                                    /${RESET}
${GREEN} ------------------------------------${RESET}
"

# Funzione per ottenere le informazioni sull'host
get_host_info() {
    host=$(hostnamectl | grep "Static hostname:" | awk '{print $3}')
    echo -e "${BOLD}${BLUE}Host:${RESET} $host"
}

# Funzione per ottenere le informazioni sulla CPU
get_cpu_info() {
    cpu_model=$(lscpu | grep "Model name:" | sed 's/Model name:\s*//')
    cores=$(lscpu | grep "^CPU(s):" | awk '{print $2}')
    threads_per_core=$(lscpu | grep "Thread(s) per core:" | awk '{print $4}')
    echo -e "${BOLD}${BLUE}CPU:${RESET} $cpu_model"
    echo -e "${BOLD}${BLUE}Cores:${RESET} $cores"
    echo -e "${BOLD}${BLUE}Threads per core:${RESET} $threads_per_core"
}

# Funzione per ottenere le informazioni sulla RAM
get_ram_info() {
    total_ram=$(free -h --si | awk '/^Mem:/ {print $2}')
    echo -e "${BOLD}${BLUE}RAM:${RESET} $total_ram"
}

# Funzione per ottenere le informazioni sulla GPU
get_gpu_info() {
    gpu_model=$(lspci | grep -E "VGA|3D" | head -n 1 | sed -E 's/.*\[([^]]*)\].*/\1/')
    echo -e "${BOLD}${BLUE}GPU:${RESET} $gpu_model"
}

# Funzione per ottenere le informazioni sullo swap
get_swap_info() {
    total_swap=$(free -h --si | awk '/^Swap:/ {print $2}')
    echo -e "${BOLD}${BLUE}Swap:${RESET} $total_swap"
}

# Funzione per ottenere le informazioni sul bootloader
get_bootloader_info() {
    bootloader="Non definito"
    if [ -d /sys/firmware/efi ]; then
        if [ -f /boot/grub/grub.cfg ]; then
            bootloader="GRUB"
        elif [ -f /boot/loader/loader.conf ]; then
            bootloader="systemd-boot"
        elif [ -f /boot/EFI/refind/refind.conf ]; then
            bootloader="rEFInd"
        elif [ -f /etc/lilo.conf ]; then
            bootloader="LILO"
        elif [ -f /boot/syslinux/syslinux.cfg ]; then
            bootloader="Syslinux"
        elif [ -f /boot/EFI/CLOVER/CLOVERX64.efi ]; then
            bootloader="Clover"
        elif [ -f /boot/limine/limine.cfg ]; then
            bootloader="Limine"
        elif [ -f /boot/burg/burg.cfg ]; then
            bootloader="BURG"
        fi
    else
        if [ -f /etc/lilo.conf ]; then
            bootloader="LILO"
        elif [ -f /boot/grub/menu.lst ] || [ -f /boot/grub/grub.conf ]; then
            bootloader="GRUB Legacy"
        fi
    fi
    echo -e "${BOLD}${BLUE}Bootloader:${RESET} $bootloader"
}

# Funzione per ottenere il sistema di init
get_init_system_info() {
    init_system=$(ps -p 1 -o comm=)
    echo -e "${BOLD}${BLUE}Init System:${RESET} $init_system"
}

# Funzione per ottenere il filesystem
get_filesystem_info() {
    filesystem=$(df -hT | awk '$7 == "/" {print $2}')
    echo -e "${BOLD}${BLUE}Filesystem:${RESET} $filesystem"
}

# Funzione per ottenere le informazioni sul sistema operativo
get_os_info() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        os_name=$NAME
    else
        os_name="Non disponibile"
    fi
    echo -e "${BOLD}${BLUE}Sistema operativo:${RESET} $os_name"
}

# Funzione per ottenere il livello dell'utente in base alla distribuzione
get_user_level() {
    distribution=$(lsb_release -is 2>/dev/null || echo "Non disponibile")
    case $distribution in
        "Ubuntu" | "LinuxMint" | "Zorin" | "Elementary" | "LinuxLite" | "Peppermint" | "Bodhi" | "Kubuntu" | "Lubuntu" | "Xubuntu" | "Q4OS" | "Deepin" | "KDE neon" | "Feren OS" | "Trisquel" | "MakuluLinux" | "Netrunner")
            level="Facile"
            ;;
        "Fedora" | "openSUSE" | "Pop!_OS" | "Solus" | "Linux Lite" | "Peppermint")
            level="Intermedio"
            ;;
        "Manjaro" | "Debian" | "MX" | "Puppy" | "EndeavourOS" | "Garuda" | "Rhino" | "Artix" | "RebornOS" | "Alpine Linux" | "Mageia")
            level="Avanzato"
            ;;
        "Arch" | "Slackware" | "CRUX" | "Void")
            level="Esperto"
            ;;
        "Gentoo" | "LFS" | "NixOS" | "Clear Linux")
            level="Power"
            ;;
        *)
            level="Non definito"
            ;;
    esac
    echo -e "${BOLD}${BLUE}Livello:${RESET} $level"
}

# Funzione per ottenere le informazioni sull'architettura
get_arch_info() {
    arch=$(uname -m)
    echo -e "${BOLD}${BLUE}Architettura:${RESET} $arch"
}

# Funzione per ottenere le informazioni sul kernel
get_kernel_info() {
    kernel=$(uname -r)
    echo -e "${BOLD}${BLUE}Kernel:${RESET} $kernel"
}

# Funzione per ottenere le informazioni sull'ambiente desktop (DE)
get_de_info() {
    de=${XDG_CURRENT_DESKTOP:-"Non definito"}
    echo -e "${BOLD}${BLUE}DE:${RESET} $de"
}

# Funzione per ottenere le informazioni sul gestore dei pacchetti
get_package_info() {
    if command -v pacman &> /dev/null; then
        package_manager="pacman"
    elif command -v apt &> /dev/null; then
        package_manager="apt"
    elif command -v dnf &> /dev/null; then
        package_manager="dnf"
    elif command -v zypper &> /dev/null; then
        package_manager="zypper"
    elif command -v slackpkg &> /dev/null; then
        package_manager="slackpkg"
    elif command -v nala &> /dev/null; then
        package_manager="nala"
    else
        package_manager="Non definito"
    fi
    echo -e "${BOLD}${BLUE}Package:${RESET} $package_manager"
}

# Funzione per ottenere le informazioni sui pacchetti installati
get_package_count() {
    if command -v pacman &> /dev/null; then
        package_count=$(pacman -Q | wc -l)
    elif command -v apt &> /dev/null; then
        package_count=$(dpkg-query -f '.\n' -W | wc -l)
    elif command -v dnf &> /dev/null; then
        package_count=$(dnf list installed | wc -l)
    elif command -v zypper &> /dev/null; then
        package_count=$(zypper se --installed-only | wc -l)
    elif command -v slackpkg &> /dev/null; then
        package_count=$(ls /var/log/packages | wc -l)
    elif command -v nala &> /dev/null; then
        package_count=$(dpkg-query -f '.\n' -W | wc -l)
    else
        package_count="Non definito"
    fi
    echo -e "${BOLD}${BLUE}Packages:${RESET} $package_count"
}

# Funzione per ottenere le informazioni sulla shell
get_shell_info() {
    shell=$(echo $SHELL)
    echo -e "${BOLD}${BLUE}Shell:${RESET} $shell"
}

# Funzione per ottenere le informazioni sull'helper AUR
get_aur_helper_info() {
    if command -v yay &> /dev/null; then
        aur_helper="yay"
    elif command -v paru &> /dev/null; then
        aur_helper="paru"
    elif command -v trizen &> /dev/null; then
        aur_helper="trizen"
    elif command -v pikaur &> /dev/null; then
        aur_helper="pikaur"
    elif command -v pacaur &> /dev/null; then
        aur_helper="pacaur"
    elif command -v aura &> /dev/null; then
        aur_helper="aura"
    elif command -v pakku &> /dev/null; then
        aur_helper="pakku"
    elif command -v burgaur &> /dev/null; then
        aur_helper="burgaur"
    elif command -v ruya &> /dev/null; then
        aur_helper="ruya"
    else
        aur_helper="Non definito"
    fi
    echo -e "${BOLD}${BLUE}AUR Helper:${RESET} $aur_helper"
}

# Funzione per ottenere le informazioni sul server grafico
get_server_info() {
    server=${XDG_SESSION_TYPE:-"Non definito"}
    echo -e "${BOLD}${BLUE}Server:${RESET} $server"
}

# Funzione per ottenere le informazioni sul server audio
get_audio_server_info() {
    if pgrep -x "pipewire" > /dev/null; then
        audio_server="PipeWire"
    elif pgrep -x "pulseaudio" > /dev/null; then
        audio_server="PulseAudio"
    else
        audio_server="Non definito"
    fi
    echo -e "${BOLD}${BLUE}Audio Server:${RESET} $audio_server"
}

# Funzione per raccogliere tutte le informazioni di sistema
gather_system_info() {
    hardware_info="$(get_host_info)\n$(get_cpu_info)\n$(get_ram_info)\n$(get_swap_info)\n$(get_gpu_info)\n"
    software_info="$(get_os_info)\n$(get_user_level)\n$(get_package_info)\n$(get_package_count)\n$(get_shell_info)\n$(get_aur_helper_info)\n$(get_bootloader_info)\n$(get_init_system_info)\n$(get_arch_info)\n$(get_kernel_info)\n$(get_de_info)\n$(get_filesystem_info)\n$(get_server_info)\n$(get_audio_server_info)\n"

    echo -e "$logo"
    echo -e "${GREEN}|____________________________________________________________|${RESET}"
    echo -e "${BOLD}${BLUE}                        Hardware Information                        ${RESET}"
    echo -e "${GREEN}|____________________________________________________________|${RESET}"
    echo -e "$hardware_info"
    echo -e "${GREEN}|____________________________________________________________|${RESET}"
    echo -e "${BOLD}${BLUE}                        Software Information                        ${RESET}"
    echo -e "${GREEN}|____________________________________________________________|${RESET}"
    echo -e "$software_info"
    echo -e "${GREEN}|____________________________________________________________|${RESET}"
    echo -e "${BOLD}${BLUE}                        Sviluppato da Klod Cripta                        ${RESET}"
    echo -e "${GREEN}|____________________________________________________________|${RESET}"
}

# Eseguire la raccolta delle informazioni di sistema
gather_system_info
