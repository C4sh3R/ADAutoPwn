#!/usr/bin/env bash
#
#  ADAutoPwn — dependency installer
#  Sets up everything the framework orchestrates. Tested on Parrot/Kali/Debian.
#
set -e

C_G=$'\e[38;5;46m'; C_Y=$'\e[38;5;226m'; C_R=$'\e[38;5;196m'; C_B=$'\e[38;5;39m'; C_0=$'\e[0m'
ok(){ echo -e "${C_G}[+]${C_0} $1"; }
inf(){ echo -e "${C_B}[*]${C_0} $1"; }
wrn(){ echo -e "${C_Y}[!]${C_0} $1"; }
err(){ echo -e "${C_R}[-]${C_0} $1"; }

[[ $EUID -ne 0 ]] && SUDO="sudo" || SUDO=""

inf "ADAutoPwn installer — this will install the required toolchain"

# ---------------------------------------------------------------------------
# 1. APT packages (most are preinstalled on Kali/Parrot)
# ---------------------------------------------------------------------------
APT_PKGS=(nmap smbclient smbmap rpcclient ldap-utils ntpdate enum4linux-ng \
          john hashcat python3 python3-pip pipx git golang-go seclists wordlists \
          openssl unzip p7zip-full libreoffice-calc)
# john ships the *2john helpers (office2john, zip2john, keepass2john, ssh2john, …)
inf "Installing APT packages: ${APT_PKGS[*]}"
$SUDO apt-get update -qq || wrn "apt update failed (continuing)"
$SUDO apt-get install -y "${APT_PKGS[@]}" 2>/dev/null || wrn "Some APT packages failed; install them manually if missing"
ok "APT stage done"

# ---------------------------------------------------------------------------
# 2. Python tooling via pipx (isolated, recommended) with pip fallback
# ---------------------------------------------------------------------------
ensure_pipx() { command -v pipx >/dev/null || $SUDO apt-get install -y pipx; pipx ensurepath >/dev/null 2>&1 || true; }
pyinstall() {  # pyinstall <pipx-name> <pip-spec>
    if command -v "$1" >/dev/null 2>&1; then ok "$1 already present"; return; fi
    ensure_pipx
    inf "Installing $1 …"
    pipx install "$2" >/dev/null 2>&1 || pip3 install --user "$2" >/dev/null 2>&1 || \
        pip3 install --break-system-packages "$2" >/dev/null 2>&1 || wrn "Could not install $1"
    command -v "$1" >/dev/null 2>&1 && ok "$1 installed" || wrn "$1 still missing"
}

pyinstall netexec          "git+https://github.com/Pennyw0rth/NetExec"
pyinstall impacket-secretsdump impacket
pyinstall certipy          certipy-ad
pyinstall bloodhound-python bloodhound
pyinstall bloodyAD         bloodyAD
pyinstall ldapdomaindump   ldapdomaindump
pyinstall msoffcrypto-tool msoffcrypto-tool

# ---------------------------------------------------------------------------
# 3. kerbrute (Go binary) → /opt/kerbrute
# ---------------------------------------------------------------------------
if [[ ! -x /opt/kerbrute ]]; then
    inf "Installing kerbrute → /opt/kerbrute"
    ARCH=$(uname -m); KB="kerbrute_linux_amd64"; [[ "$ARCH" == "aarch64" ]] && KB="kerbrute_linux_arm64"
    if command -v curl >/dev/null; then
        $SUDO curl -fsSL "https://github.com/ropnop/kerbrute/releases/latest/download/${KB}" -o /opt/kerbrute \
            && $SUDO chmod +x /opt/kerbrute && ok "kerbrute installed" || wrn "kerbrute download failed"
    else
        wrn "curl missing — install kerbrute manually to /opt/kerbrute"
    fi
else
    ok "kerbrute already at /opt/kerbrute"
fi

# ---------------------------------------------------------------------------
# 4. rockyou
# ---------------------------------------------------------------------------
if [[ -f /usr/share/wordlists/rockyou.txt.gz && ! -f /usr/share/wordlists/rockyou.txt ]]; then
    inf "Extracting rockyou.txt"; $SUDO gunzip -k /usr/share/wordlists/rockyou.txt.gz && ok "rockyou ready"
fi

# ---------------------------------------------------------------------------
# 5. Optional exploit helpers used by --abuse when a safe automation path exists
# ---------------------------------------------------------------------------
EXT_DIR="$(realpath "$(dirname "$0")/external" 2>/dev/null || echo "$(dirname "$0")/external")"
mkdir -p "$EXT_DIR"
clone_helper() {  # clone_helper <name> <url>
    local name="$1" url="$2" dst="$EXT_DIR/$name"
    if [[ -d "$dst/.git" || -f "$dst/noPac.py" || -f "$dst/cve-2020-1472-exploit.py" || -f "$dst/CVE-2021-1675.py" ]]; then
        ok "$name helper already present → $dst"
    elif command -v git >/dev/null; then
        inf "Cloning optional helper $name → $dst"
        git clone --depth 1 "$url" "$dst" >/dev/null 2>&1 \
            && ok "$name helper installed" \
            || wrn "$name clone failed — $url"
    else
        wrn "git missing — cannot clone optional helper $name"
    fi
}
clone_helper noPac          https://github.com/Ridter/noPac
clone_helper CVE-2020-1472  https://github.com/dirkjanm/CVE-2020-1472
clone_helper CVE-2021-1675  https://github.com/cube0x0/CVE-2021-1675
clone_helper krbrelayx      https://github.com/dirkjanm/krbrelayx
clone_helper sccmhunter     https://github.com/garrettfoster13/sccmhunter
for _req in noPac sccmhunter; do
    if [[ -f "$EXT_DIR/$_req/requirements.txt" ]]; then
        pip3 install --user -r "$EXT_DIR/$_req/requirements.txt" >/dev/null 2>&1 || \
            pip3 install --break-system-packages -r "$EXT_DIR/$_req/requirements.txt" >/dev/null 2>&1 || \
            wrn "Could not install $_req Python requirements (it may still work with system impacket)"
    fi
done

# ---------------------------------------------------------------------------
# 6. ADAutoGraph — local BloodHound-style web UI (separate repo, pure stdlib)
#    Cloned beside this repo so ADAutoPwn auto-detects and launches it at the end
#    of a run (web UI on http://127.0.0.1:8765, BloodHound data imported for you).
# ---------------------------------------------------------------------------
AG_DIR="$(realpath "$(dirname "$0")/../ADAutoGraph" 2>/dev/null || echo "$(dirname "$0")/../ADAutoGraph")"
if [[ -f "$AG_DIR/server.py" ]]; then
    ok "ADAutoGraph already present → $AG_DIR"
elif command -v git >/dev/null; then
    inf "Cloning ADAutoGraph → $AG_DIR"
    git clone --depth 1 https://github.com/C4sh3R/ADAutoGraph "$AG_DIR" >/dev/null 2>&1 \
        && ok "ADAutoGraph installed (web UI on http://127.0.0.1:8765)" \
        || wrn "ADAutoGraph clone failed — get it manually: git clone https://github.com/C4sh3R/ADAutoGraph"
else
    wrn "git missing — install ADAutoGraph manually: git clone https://github.com/C4sh3R/ADAutoGraph"
fi
# Put `adautograph` on PATH (server.py resolves its own dir, so a symlink is fine).
if [[ -f "$AG_DIR/server.py" ]]; then
    chmod +x "$AG_DIR/server.py" 2>/dev/null
    if [[ -w /usr/local/bin ]] || [[ -n "$SUDO" ]]; then
        $SUDO ln -sf "$AG_DIR/server.py" /usr/local/bin/adautograph 2>/dev/null \
            && ok "Symlinked → run the web UI anywhere as: adautograph" \
            || wrn "Could not symlink adautograph into /usr/local/bin"
    else
        mkdir -p "$HOME/.local/bin" && ln -sf "$AG_DIR/server.py" "$HOME/.local/bin/adautograph" \
            && ok "Symlinked → adautograph (~/.local/bin)"
    fi
fi

# ---------------------------------------------------------------------------
# 7. Make the framework executable + optional PATH symlink
# ---------------------------------------------------------------------------
chmod +x "$(dirname "$0")/adautopwn.sh"
ok "adautopwn.sh is executable"
if [[ -w /usr/local/bin ]] || [[ -n "$SUDO" ]]; then
    $SUDO ln -sf "$(realpath "$(dirname "$0")/adautopwn.sh")" /usr/local/bin/adautopwn 2>/dev/null \
        && ok "Symlinked → run it anywhere as: adautopwn" || wrn "Could not create /usr/local/bin symlink"
fi

echo
ok "Installation complete. Verify with:  ./adautopwn.sh --help"
wrn "If pipx added ~/.local/bin to PATH, open a new shell or run: source ~/.bashrc"
