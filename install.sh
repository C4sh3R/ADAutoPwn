#!/usr/bin/env bash
#
#    █████╗ ██████╗      █████╗ ██╗   ██╗████████╗ ██████╗
#   ██╔══██╗██╔══██╗    ██╔══██╗██║   ██║╚══██╔══╝██╔═══██╗
#   ███████║██║  ██║    ███████║██║   ██║   ██║   ██║   ██║
#   ██╔══██║██║  ██║    ██╔══██║██║   ██║   ██║   ██║   ██║
#   ██║  ██║██████╔╝    ██║  ██║╚██████╔╝   ██║   ╚██████╔╝
#   ╚═╝  ╚═╝╚═════╝     ╚═╝  ╚═╝ ╚═════╝    ╚═╝    ╚═════╝
#           ██████╗ ██╗    ██╗███╗   ██╗
#           ██╔══██╗██║    ██║████╗  ██║   Active Directory
#           ██████╔╝██║ █╗ ██║██╔██╗ ██║   Automated Pwnage
#           ██╔═══╝ ██║███╗██║██║╚██╗██║   Framework
#           ██║     ╚███╔███╔╝██║ ╚████║
#           ╚═╝      ╚══╝╚══╝ ╚═╝  ╚═══╝
#
#	Author	    -	C4sh$R
#   Modified    -   Ch4rum
#	Repo	    -	https://github.com/C4sh3R/ADAutoPwn
#	ADAutoPwn   -   Dependency installer
#
#   Sets up everything the framework orchestrates. Tested on Parrot/Kali/Debian/Arch.
#

# ---------- Colors ----------
if [[ -t 1 ]] && [[ "${NO_COLOR:-0}" != "1" ]]; then
    C_RESET=$'\e[0m';  C_BOLD=$'\e[1m';   C_DIM=$'\e[2m'
    C_RED=$'\e[38;5;196m';    C_GREEN=$'\e[38;5;46m';   C_YELLOW=$'\e[38;5;226m'
    C_BLUE=$'\e[38;5;39m';    C_MAGENTA=$'\e[38;5;201m'; C_CYAN=$'\e[38;5;51m'
    C_ORANGE=$'\e[38;5;208m'; C_GREY=$'\e[38;5;245m';   C_PURPLE=$'\e[38;5;141m'
    COLORS=(
        "$C_CYAN"
        "$C_MAGENTA"
        "$C_GREEN"
        "$C_YELLOW"
        "$C_BLUE"
        "$C_ORANGE"
        "$C_PURPLE"
    )
else
    C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''
    C_BLUE=''; C_MAGENTA=''; C_CYAN=''; C_ORANGE=''; C_GREY=''; C_PURPLE=''
    COLORS=('')
fi

# ---------- Global Variables ----------
readonly VERSION="1.55.4"
readonly AUTHOR="C4sh3R"
ERROR_LOG="$PWD/ADautopwn.log"
PKG_MANAGER=""
DISTRO=""
OK="${C_BOLD}${C_GREEN}[+]${C_RESET}"
IFN="${C_BOLD}${C_BLUE}[*]${C_RESET}"
WRN="${C_BOLD}${C_YELLOW}[!]${C_RESET}"
ERR="${C_BOLD}${C_RED}[ERROR]:${C_RESET}"
[[ $EUID -ne 0 ]] && SUDO="sudo" || SUDO=""

# ---------- Banner ----------
banner() {
    # Modern gradient palette (true-color). Falls back to empty strings w/ --no-color.
    local g1 g2 g3 g4 g5 g6 b1 b2 acc box
    text="$1"
    if [[ -n "$C_RESET" ]]; then
        g1=$'\e[38;2;0;255;200m';   g2=$'\e[38;2;0;225;235m'   # teal → cyan
        g3=$'\e[38;2;60;180;255m';  g4=$'\e[38;2;130;120;255m' # blue → indigo
        g5=$'\e[38;2;190;90;255m';  g6=$'\e[38;2;255;70;200m'  # violet → magenta
        b1=$'\e[38;2;255;60;120m';  b2=$'\e[38;2;255;180;60m'  # pink / amber accents
        acc=$'\e[38;2;0;255;160m';  box=$'\e[38;2;90;100;120m'
    fi
cat <<EOF

${box}    ┌────────────────────────────────────────────────────────────────┐${C_RESET}
${g1}${C_BOLD}           █████╗ ██████╗  ${g4}█████╗ ██╗   ██╗████████╗ ██████╗${C_RESET}
${g1}${C_BOLD}          ██╔══██╗██╔══██╗${g4}██╔══██╗██║   ██║╚══██╔══╝██╔═══██╗${C_RESET}
${g2}${C_BOLD}          ███████║██║  ██║${g5}███████║██║   ██║   ██║   ██║   ██║${C_RESET}
${g2}${C_BOLD}          ██╔══██║██║  ██║${g5}██╔══██║██║   ██║   ██║   ██║   ██║${C_RESET}
${g3}${C_BOLD}          ██║  ██║██████╔╝${g6}██║  ██║╚██████╔╝   ██║   ╚██████╔╝${C_RESET}
${g3}${C_BOLD}          ╚═╝  ╚═╝╚═════╝ ${g6}╚═╝  ╚═╝ ╚═════╝    ╚═╝    ╚═════╝${C_RESET}
${g4}${C_BOLD}                    ██████╗ ██╗    ██╗███╗   ██╗${C_RESET}   ${acc}Active Directory${C_RESET}
${g5}${C_BOLD}                    ██╔══██╗██║    ██║████╗  ██║${C_RESET}   ${acc}Automated Pwnage${C_RESET}
${g5}${C_BOLD}                    ██████╔╝██║ █╗ ██║██╔██╗ ██║${C_RESET}   ${acc}Framework${C_RESET}
${g6}${C_BOLD}                    ██╔═══╝ ██║███╗██║██║╚██╗██║${C_RESET}
${g6}${C_BOLD}                    ██║     ╚███╔███╔╝██║ ╚████║${C_RESET}   ${b2}v${VERSION}${C_RESET}
${g6}${C_BOLD}                    ╚═╝      ╚══╝╚══╝ ╚═╝  ╚═══╝${C_RESET}
${box}    └────────────────────────────────────────────────────────────────┘${C_RESET}
       ${C_BOLD}     ⚡ From zero to Domain Admin — fully automated.${C_RESET}
       ${box}─────────────────────────────────────────────────────────${C_RESET}
       ${box}» crafted & weaponized by${C_RESET}  ${b1}${C_BOLD}▌${C_RESET} ${acc}${C_BOLD}${AUTHOR}${C_RESET} ${b1}${C_BOLD}▐${C_RESET}  ${box}«${C_RESET}
       ${box}» authorized engagements only · don't be the bad guy  ${box}«${C_RESET}
       ${box}» ${C_CYAN}${text}${C_RESET}  ${box}«${C_RESET}
       ${box}─────────────────────────────────────────────────────────${C_RESET}
EOF
}

# ---------- Logging ----------
log_error() {
    local error_msg="$1"
    local timestamp

    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    printf "%s\n" "[${timestamp}] ERROR: ${error_msg}" >> "$ERROR_LOG"
    printf "%s %s\n" "${ERR}" "${error_msg}" >&2
}

# ---------- Distribution Detection ----------
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release >/dev/null 2>&1
        DISTRO="${ID:-}"
    fi

    case "$DISTRO" in
        arch|manjaro)
            PKG_MANAGER="pacman"
            ;;
        debian|ubuntu|linuxmint|kali|parrot)
            PKG_MANAGER="apt"
            ;;
        *)
            log_error "Unsupported or unknown distro: $DISTRO"
            exit 1
            ;;
    esac
}

# ---------- System Preparation ----------
prepare_system() {
    case "$PKG_MANAGER" in
        pacman)
            if ! $SUDO pacman -Syu --noconfirm >>"$ERROR_LOG" 2>&1; then
                log_error "Arch Linux system upgrade failed. Fix the system before installing dependencies."
                return 1
            fi
            ;;
        apt)
            if ! $SUDO apt update -qq >>"$ERROR_LOG" 2>&1; then
                log_error "Failed to update APT repositories."
                return 1
            fi
            ;;
        *)
            log_error "Unsupported package manager: $PKG_MANAGER"
            return 1
            ;;
    esac
}

# ---------- Welcome ----------
welcome() {
    clear
    local C_USER=""
    for ((i=0; i<${#USER}; i++)); do
        C_USER+="${COLORS[RANDOM % ${#COLORS[@]}]}${USER:i:1}"
    done
    C_USER+="$C_RESET"
    banner "Welcome $C_USER"
    sleep 1

    printf " %b\n" "${C_BOLD}${C_GREEN}This script will set up the ADAutoPwn toolchain.${C_RESET}"
    printf " %b\n\n" "${C_BOLD}${C_GREEN}Here's what it will do:${C_RESET}"
    printf "  ${IFN} Detect your Linux distribution (Arch, Ubuntu, Kali, etc.).\n"
    printf "  ${IFN} Install required system packages.\n"
    printf "  ${IFN} Install required Python tools via pipx.\n"
    printf "  ${IFN} Install Kerbrute.\n"
    printf "  ${IFN} Prepare the RockYou wordlist.\n"
    printf "  ${IFN} Install SecLists.\n"
    printf "  ${IFN} Install optional external helpers.\n"
    printf "  ${IFN} Install ADAutoGraph.\n"
    printf "  ${IFN} Configure ADAutoPwn for command-line use.\n"
    printf "\n"
    printf "   ${WRN} ${C_BOLD}${C_RED}Run this installer in an authorized lab or pentesting environment.${C_RESET}\n"
    printf "   ${WRN} ${C_BOLD}${C_RED}The installer may require sudo privileges.${C_RESET}\n"
    printf "   ${WRN} ${C_BOLD}${C_RED}Be patient - some packages are large and may take several minutes.${C_RESET}\n"
    printf "\n"

    while :; do
        printf "%b" "${C_BOLD}${C_GREEN}Do you wish to continue?${C_RESET} [y/N]: "
        read -r yn < /dev/tty
        case "$yn" in
            [Yy])
                detect_distro
                prepare_system || exit 1
                break
                ;;
            [Nn]|"")
                printf "\n%b\n\n" "${C_BOLD}${C_YELLOW}Operation cancelled.${C_RESET}"
                exit 0
                ;;
            *)
                printf "\n%b\n\n" "${C_BOLD}${C_RED}Error:${C_RESET} Please type '${C_YELLOW}y${C_RESET}' or '${C_YELLOW}n${C_RESET}'."
                ;;
        esac
    done
}

# ---------- System Package Installation ----------
install_system_package() {
    local pkg="$1"

    case "$PKG_MANAGER" in
        pacman)
            if ! pacman -Qq "$pkg" &>/dev/null; then
                printf "%b\n" "${OK} ${C_BOLD}${C_BLUE}Installing ${C_YELLOW}${pkg}${C_RESET}${C_BOLD}${C_BLUE} with pacman.${C_RESET}"
                if ! $SUDO pacman -S --noconfirm "$pkg" >>"$ERROR_LOG" 2>&1; then
                    log_error "Failed to install $pkg with pacman."
                    return 1
                fi
            else
                printf "%b\n" "${WRN} ${C_BOLD}${C_ORANGE}${pkg}${C_RESET}${C_BOLD}${C_BLUE} is already installed.${C_RESET}"
            fi
            ;;
        apt)
            if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
                printf "%b\n" "${OK} ${C_BOLD}${C_BLUE}Installing ${C_YELLOW}${pkg}${C_RESET}${C_BOLD}${C_BLUE} with apt.${C_RESET}"
                if ! $SUDO apt install -y "$pkg" >>"$ERROR_LOG" 2>&1; then
                    log_error "Failed to install $pkg with apt."
                    return 1
                fi
            else
                printf "%b\n" "${WRN} ${C_BOLD}${C_ORANGE}${pkg}${C_RESET}${C_BOLD}${C_BLUE} is already installed.${C_RESET}"
            fi
            ;;
        *)
            log_error "Unsupported package manager: $PKG_MANAGER"
            return 1
            ;;
    esac
}

# ---------- AUR ----------
install_aur_package() {
    local pkg="$1"

    if [[ "$PKG_MANAGER" != "pacman" ]]; then
        return 0
    fi

    if pacman -Qq "$pkg" &>/dev/null; then
        printf "%b\n" "${WRN} ${C_BOLD}${C_ORANGE}${pkg}${C_RESET} ${C_BOLD}${C_BLUE}is already installed.${C_RESET}"
        return 0
    else
        if command -v yay >/dev/null 2>&1; then
            printf "%b\n" "${OK} Installing ${C_YELLOW}${pkg}${C_RESET} with yay."
            if yay -S --noconfirm "$pkg" >>"$ERROR_LOG" 2>&1; then
                return 0
            fi
            log_error "Failed to install $pkg with yay."
            return 1
        elif command -v paru >/dev/null 2>&1; then
            printf "%b\n" "${OK} Installing ${C_YELLOW}${pkg}${C_RESET} with paru."
            if paru -S --noconfirm "$pkg" >>"$ERROR_LOG" 2>&1; then
                return 0
            fi
            log_error "Failed to install $pkg with paru."
            return 1
        fi
        log_error "AUR helper not found. Cannot install $pkg automatically."
        return 1
    fi
}

# ---------- Evil-WinRM ----------
install_evilwinrm() {
    if command -v evil-winrm >/dev/null 2>&1; then
        printf "%b\n" "${WRN} ${C_BOLD}${C_ORANGE}evil-winrm${C_RESET} ${C_BOLD}${C_BLUE}is already installed.${C_RESET}"
        return 0
    fi

    printf "%b\n" "${OK} ${C_BOLD}${C_BLUE}Installing ${C_YELLOW}evil-winrm${C_RESET}${C_BOLD}${C_BLUE} with gem.${C_RESET}"
    if ! $SUDO gem install evil-winrm >>"$ERROR_LOG" 2>&1; then
        log_error "Failed to install evil-winrm with gem."
        return 1
    fi
    printf "%b\n" "${OK} ${C_BOLD}${C_YELLOW}evil-winrm${C_RESET} ${C_BOLD}${C_BLUE}installed.${C_RESET}"
}

# ---------- Rust Toolchain ----------
install_rust() {
    if ! command -v rustup >/dev/null 2>&1; then
        log_error "rustup not found — cannot set up Rust toolchain."
        return 1
    fi
    if rustup show 2>&1 | grep -q "no active toolchain"; then
        printf "%b\n" "${OK} ${C_BOLD}${C_BLUE}Setting up ${C_YELLOW}Rust toolchain${C_RESET}${C_BOLD}${C_BLUE} (needed to build aardwolf for NetExec). This may take a few minutes.${C_RESET}"
        if ! rustup default stable >>"$ERROR_LOG" 2>&1; then
            log_error "Failed to set up Rust default toolchain."
            return 1
        fi
        export PATH="$HOME/.cargo/bin:$PATH"
        printf "%b\n" "${OK} ${C_BOLD}${C_YELLOW}Rust toolchain${C_RESET} ${C_BOLD}${C_BLUE}activated.${C_RESET}"
    else
        printf "%b\n" "${WRN} ${C_BOLD}${C_ORANGE}Rust toolchain${C_RESET} ${C_BOLD}${C_BLUE}is already active.${C_RESET}"
        export PATH="$HOME/.cargo/bin:$PATH"
    fi
}

# ---------- Other Requirements ----------
install_other_requirements() {
    local ntpdate_path="/usr/local/bin/ntpdate"

    if [[ -x "$ntpdate_path" ]]; then
        printf "%b\n" "${WRN} ${C_BOLD}${C_ORANGE}ntpdate wrapper${C_RESET} ${C_BOLD}${C_BLUE}is already installed.${C_RESET}"
    else
        printf "%b\n" "${OK} ${C_BOLD}${C_BLUE}Installing ${C_YELLOW}ntpdate wrapper${C_RESET}${C_BOLD}${C_BLUE} (ntpd -q shim).${C_RESET}"
        if $SUDO tee "$ntpdate_path" > /dev/null << 'EOF'
#!/bin/bash
exec ntpd -q -g "$@"
EOF
        then
            $SUDO chmod +x "$ntpdate_path"
            printf "%b\n" "${OK} ${C_BOLD}${C_YELLOW}ntpdate wrapper${C_RESET} ${C_BOLD}${C_BLUE}installed at ${C_YELLOW}${ntpdate_path}${C_RESET}."
        else
            log_error "Failed to create ntpdate wrapper."
            return 1
        fi
    fi
}

# ---------- System Requiremnents ----------
setup_system_requirements() {
    sleep 5
    clear
    banner "Installing necessary packages..."
    sleep 2
    local packages=()

    case "$PKG_MANAGER" in
        pacman)
            packages=(nmap smbclient samba openldap ntp john hashcat python3 python-pip python-pipx git go openssl unzip 7zip libreoffice-fresh libguestfs curl zip jdk-openjdk ruby rustup)
            ;;
        apt)
            packages=(nmap smbclient smbmap ldap-utils ntpsec-ntpdate enum4linux-ng john hashcat python3 python3-pip pipx git golang-go seclists wordlists openssl unzip 7zip libreoffice-calc libguestfs-tools curl zip default-jdk ruby netexec)
            ;;
        *)
            log_error "Unsupported package manager: $PKG_MANAGER"
            return 1
            ;;
    esac

    for pkg in "${packages[@]}"; do
        install_system_package "$pkg"
        sleep 1
    done

    install_evilwinrm

    if [[ "$PKG_MANAGER" == "pacman" ]]; then
        local aur_packages=(smbmap enum4linux-ng seclists wordlists mdbtools metasploit netexec)
        install_rust
        for pkg in "${aur_packages[@]}"; do
            install_aur_package "$pkg" || true
            sleep 1
        done
        install_other_requirements
    fi
}

# ---------- Python ----------
install_requirements() {
    if command -v pip3 >/dev/null 2>&1; then
        pip3 install --user "$@" >/dev/null 2>&1 ||
            pip3 install --break-system-packages "$@" >/dev/null 2>&1
    else
        python3 -m pip install --user "$@" >/dev/null 2>&1 ||
            python3 -m pip install --break-system-packages "$@" >/dev/null 2>&1
    fi
}

# ---------- Impacket compatibility shims ----------
install_impacket_shims() {
    if [[ "$PKG_MANAGER" != "pacman" ]]; then
        return 0
    fi
    local venv_bin="$HOME/.local/share/pipx/venvs/impacket/bin"
    [[ ! -d "$venv_bin" ]] && { log_error "Impacket venv not found — cannot create shims."; return 1; }
    
    mkdir -p "$HOME/.local/bin"
    local script real_name shim_name created=0 skipped=0

    for script in "$venv_bin"/*.py; do
        [[ -f "$script" ]] || continue
        real_name="$(basename "$script" .py)"
        shim_name="impacket-${real_name}"
        if [[ -e "$HOME/.local/bin/$shim_name" ]]; then
            skipped=$((skipped+1))
            continue
        fi
        ln -sf "$script" "$HOME/.local/bin/$shim_name"
        created=$((created+1))
    done

    if [[ "$created" -eq 0 && "$skipped" -eq 0 ]]; then
        printf "%b\n" "${WRN} ${C_BOLD}${C_ORANGE}impacket-*${C_RESET} ${C_BOLD}${C_BLUE}no .py scripts found (Kali-style native entry points?) — no shims needed.${C_RESET}"
        return 0
    fi
    if [[ "$created" -gt 0 ]]; then
        printf "%b\n" "${OK} ${C_BOLD}${C_YELLOW}${created} impacket-*${C_RESET} ${C_BOLD}${C_BLUE}compatibility shim(s) created in ~/.local/bin.${C_RESET}"
    fi
    if [[ "$skipped" -gt 0 ]]; then
        printf "%b\n" "${WRN} ${C_BOLD}${C_ORANGE}${skipped} impacket-*${C_RESET} ${C_BOLD}${C_BLUE}shim(s) already present.${C_RESET}"
    fi
}

install_python_dependencies() {
    sleep 5
    clear
    banner "Installing Python dependencies..."
    sleep 2
    local dependencies=(impacket certipy-ad bloodhound bloodyad ldapdomaindump msoffcrypto-tool volatility3)

    export PATH="$HOME/.local/bin:$PATH"
    pipx ensurepath >/dev/null 2>&1 || true
    if ! command -v pipx >/dev/null 2>&1; then
        log_error "pipx not found."
        return 1
    fi
    if ! command -v pip3 >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
        log_error "Python/pip not found."
        return 1
    fi

    local failed=0
    local installed_pkgs
    installed_pkgs="$(pipx list --short 2>/dev/null | awk '{print $1}')"

    for package in "${dependencies[@]}"; do
        local check_bin="$package"
        [[ "$package" == "impacket" ]] && check_bin="impacket-atexec"

        if command -v "${check_bin}" >/dev/null 2>&1 || dpkg -s "python3-${package}" &>/dev/null; then
            printf "%b\n" "${WRN} ${C_BOLD}${C_ORANGE}${package}${C_RESET} ${C_BOLD}${C_BLUE}is already installed at the system level (apt).${C_RESET}"
            continue
        fi
        if grep -qx "$package" <<<"$installed_pkgs"; then
            printf "%b\n" "${WRN} ${C_BOLD}${C_ORANGE}${package}${C_RESET} ${C_BOLD}${C_BLUE}is already installed.${C_RESET}"
            continue
        fi
        printf "%b\n" "${OK} Installing ${C_YELLOW}${package}${C_RESET}."
        if pipx install "$package" >>"$ERROR_LOG" 2>&1; then
            printf "%b\n" "${OK} ${C_BOLD}${C_YELLOW}${package}${C_RESET} ${C_BOLD}${C_BLUE}installed with pipx.${C_RESET}"
        elif pipx install --pip-args="--use-deprecated=legacy-resolver" "$package" >>"$ERROR_LOG" 2>&1; then
            printf "%b\n" "${OK} ${C_BOLD}${C_YELLOW}${package}${C_RESET} ${C_BOLD}${C_BLUE}installed with pipx (legacy resolver).${C_RESET}"
        elif install_requirements "$package"; then
            printf "%b\n" "${OK} ${C_BOLD}${C_YELLOW}${package}${C_RESET} ${C_BOLD}${C_BLUE}installed with pip3.${C_RESET}"
        else
            log_error "Failed to install $package with pipx and pip3."
            failed=1
        fi
        sleep 1
    done

    install_impacket_shims

    if pipx list --short 2>/dev/null | awk '{print $1}' | grep -qx "volatility3"; then
        printf "%b\n" "${OK} Injecting ${C_YELLOW}pycryptodome${C_RESET} into Volatility3."
        if ! pipx inject volatility3 pycryptodome >>"$ERROR_LOG" 2>&1; then
            log_error "Failed to inject pycryptodome into Volatility3."
            failed=1
        fi
    else
        log_error "volatility3 not installed — skipping pycryptodome injection."
        failed=1
    fi
    return "$failed"
}

# ---------- Kerbrute ----------
install_kerbrute() {
    sleep 5
    clear
    banner "Installing Kerbrute, RockYou and External Helpers..."
    sleep 2
    local kerbrute_path="/opt/kerbrute"
    local arch
    local binary

    if [[ -x "$kerbrute_path" ]]; then
        printf "%b\n" "${WRN} ${C_BOLD}${C_ORANGE}Kerbrute${C_RESET} ${C_BOLD}${C_BLUE}is already installed.${C_RESET}"
        return 0
    fi
    arch="$(uname -m)"
    case "$arch" in
        x86_64)
            binary="kerbrute_linux_amd64"
            ;;
        aarch64|arm64)
            binary="kerbrute_linux_arm64"
            ;;
        *)
            log_error "Unsupported architecture for Kerbrute: $arch"
            return 1
            ;;
    esac

    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl not found. Cannot download Kerbrute."
        return 1
    fi
    printf "%b\n" "${OK} ${C_BOLD}${C_BLUE}Installing ${C_YELLOW}Kerbrute${C_RESET}${C_BOLD}${C_BLUE}.${C_RESET}"
    local url="https://github.com/ropnop/kerbrute/releases/latest/download/${binary}"

    if ! $SUDO curl -fsSL "$url" -o "$kerbrute_path"; then
        log_error "Failed to download Kerbrute."
        return 1
    fi
    if ! $SUDO chmod +x "$kerbrute_path"; then
        log_error "Failed to make Kerbrute executable."
        return 1
    fi
    printf "%b\n" "${OK} ${C_BOLD}${C_YELLOW}Kerbrute${C_RESET} ${C_BOLD}${C_BLUE}installed at ${C_YELLOW}${kerbrute_path}${C_RESET}."
}

# ---------- RockYou ----------
setup_rockyou() {
    local wordlist_dir="/usr/share/wordlists"
    local rockyou="$wordlist_dir/rockyou.txt"
    local rockyou_gz="$wordlist_dir/rockyou.txt.gz"

    if [[ -f "$rockyou" ]]; then
        printf "%b\n" "${WRN} ${C_BOLD}${C_ORANGE}rockyou.txt${C_RESET} ${C_BOLD}${C_BLUE}is already available.${C_RESET}"
        return 0
    fi
    $SUDO mkdir -p "$wordlist_dir"
    if [[ -f "$rockyou_gz" ]]; then
        printf "%b\n" "${OK} Extracting ${C_YELLOW}rockyou.txt${C_RESET}."
        if $SUDO gunzip -k "$rockyou_gz"; then
            printf "%b\n" "${OK} ${C_YELLOW}rockyou.txt${C_RESET} ready."
            return 0
        fi
        log_error "Failed to extract rockyou.txt.gz."
        return 1
    fi

    printf "%b\n" "${OK} Downloading ${C_YELLOW}rockyou.txt${C_RESET}."
    local url="https://github.com/brannondorsey/naive-hashcat/releases/download/data/rockyou.txt"
    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is required to download RockYou."
        return 1
    elif ! $SUDO curl -fsSL "$url" -o "$rockyou"; then
        log_error "Failed to download RockYou."
        return 1
    fi
    printf "%b\n" "${OK} ${C_YELLOW}rockyou.txt${C_RESET} ready."
}

# ---------- External Helpers ----------
install_external_helpers() {
    local EXT_DIR
    EXT_DIR="$(realpath "$(dirname "$0")/external" 2>/dev/null || echo "$(dirname "$0")/external")"
    mkdir -p "$EXT_DIR"
    local helpers=(
        "noPac|https://github.com/Ridter/noPac"
        "CVE-2020-1472|https://github.com/dirkjanm/CVE-2020-1472"
        "CVE-2021-1675|https://github.com/cube0x0/CVE-2021-1675"
        "krbrelayx|https://github.com/dirkjanm/krbrelayx"
        "sccmhunter|https://github.com/garrettfoster13/sccmhunter"
        "pywsus|https://github.com/GoSecure/pywsus"
    )

    for helper in "${helpers[@]}"; do
        local name="${helper%%|*}"
        local url="${helper#*|}"
        local dst="$EXT_DIR/$name"
        sleep 1
        if [[ -d "$dst/.git" ]]; then
            printf "%b\n" "${WRN} ${C_BOLD}${C_ORANGE}${name}${C_RESET} ${C_BOLD}${C_BLUE}already present.${C_RESET}"

        elif git clone --depth 1 "$url" "$dst" >/dev/null 2>>"$ERROR_LOG"; then
            printf "%b\n" "${OK} ${C_BOLD}${C_YELLOW}${name}${C_RESET} ${C_BOLD}${C_BLUE}installed.${C_RESET}"
        else
            log_error "Failed to clone $name."
        fi
    done

    for _req in noPac sccmhunter pywsus; do
        sleep 1
        if [[ -f "$EXT_DIR/$_req/requirements.txt" ]]; then
            if install_requirements -r "$EXT_DIR/$_req/requirements.txt"; then
                printf "%b\n" "${OK} ${C_BOLD}${C_YELLOW}${_req}${C_RESET} ${C_BOLD}${C_BLUE}requirements installed.${C_RESET}"
            else
                log_error "Failed to install $_req requirements."
            fi
        fi
    done
}

# ---------- Setup ADAutoPwn ----------
setup_adautopwn() {
    local script

    script="$(realpath "$(dirname "$0")/adautopwn.sh")"
    if [[ ! -f "$script" ]]; then
        log_error "adautopwn.sh not found at $script."
        return 1
    fi

    chmod +x "$script"

    if $SUDO ln -sf "$script" /usr/local/bin/adautopwn 2>/dev/null; then
        printf "%b\n" "${OK} ${C_BOLD}${C_YELLOW}ADAutoPwn${C_RESET} ${C_BOLD}${C_BLUE}symlinked.${C_RESET}"
    else
        log_error "Failed to create ADAutoPwn symlink."
        return 1
    fi
}

# ---------- ADAutoGraph ----------
install_adautograph() {
    sleep 5
    clear
    banner "Installing ADAutoGraph and Configuring ADAutoPwn..."
    sleep 2
    setup_adautopwn || true
    local AG_DIR
    AG_DIR="$(realpath "$(dirname "$0")/../ADAutoGraph" 2>/dev/null || echo "$(dirname "$0")/../ADAutoGraph")"

    if [[ -f "$AG_DIR/server.py" ]]; then
        printf "%b\n" "${WRN} ${C_BOLD}${C_ORANGE}ADAutoGraph${C_RESET} ${C_BOLD}${C_BLUE}already present.${C_RESET}"
    elif git clone --depth 1 \
        "https://github.com/C4sh3R/ADAutoGraph" \
        "$AG_DIR" >/dev/null 2>>"$ERROR_LOG"; then
        printf "%b\n" "${OK} ${C_BOLD}${C_YELLOW}ADAutoGraph${C_RESET} ${C_BOLD}${C_BLUE}installed.${C_RESET}"
    else
        log_error "Failed to install ADAutoGraph."
        return 1
    fi

    chmod +x "$AG_DIR/server.py" 2>/dev/null

    if $SUDO ln -sf "$AG_DIR/server.py" /usr/local/bin/adautograph 2>/dev/null; then
        printf "%b\n" "${OK} ${C_BOLD}${C_YELLOW}ADAutoGraph${C_RESET} ${C_BOLD}${C_BLUE}symlinked.${C_RESET}"
    else
        mkdir -p "$HOME/.local/bin"
        ln -sf "$AG_DIR/server.py" "$HOME/.local/bin/adautograph"
        printf "%b\n" "${OK} ${C_BOLD}${C_YELLOW}ADAutoGraph${C_RESET} ${C_BOLD}${C_BLUE}symlinked to ~/.local/bin.${C_RESET}"
    fi
}

# ---------- Completion ----------
all_done() {
    sleep 5
    clear
    banner "Installation complete!"
    sleep 2
    printf "%b\n" "${OK} Run: ./adautopwn.sh --help"
    printf "%b\n\n" "${WRN} Restart your shell if ~/.local/bin was added to PATH."
}

# ---------- Main Run ----------
welcome
setup_system_requirements
install_python_dependencies
install_kerbrute
setup_rockyou
install_external_helpers
install_adautograph
all_done
