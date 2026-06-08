<div align="center">

```
 █████╗ ██████╗      █████╗ ██╗   ██╗████████╗ ██████╗
██╔══██╗██╔══██╗    ██╔══██╗██║   ██║╚══██╔══╝██╔═══██╗
███████║██║  ██║    ███████║██║   ██║   ██║   ██║   ██║
██╔══██║██║  ██║    ██╔══██║██║   ██║   ██║   ██║   ██║
██║  ██║██████╔╝    ██║  ██║╚██████╔╝   ██║   ╚██████╔╝
╚═╝  ╚═╝╚═════╝     ╚═╝  ╚═╝ ╚═════╝    ╚═╝    ╚═════╝
        ██████╗ ██╗    ██╗███╗   ██╗
        ██╔══██╗██║    ██║████╗  ██║   Active Directory
        ██████╔╝██║ █╗ ██║██╔██╗ ██║   Automated Pwnage
        ██╔═══╝ ██║███╗██║██║╚██╗██║   Framework
        ██║     ╚███╔███╔╝██║ ╚████║
        ╚═╝      ╚══╝╚══╝ ╚═╝  ╚═══╝
```

# ⚡ ADAutoPwn

**From zero to Domain Admin — fully automated.**

A single-command Active Directory assessment engine that chains the best of the
offensive toolchain (`netexec`, `impacket`, `certipy`, `bloodyAD`, `kerbrute`,
`bloodhound-python`…) into one coherent, recursive, colorful workflow.

<sub>Crafted & weaponized by **c4sh3r** · authorized engagements only</sub>

![bash](https://img.shields.io/badge/bash-5%2B-1f425f?style=flat-square&logo=gnubash&logoColor=white)
![platform](https://img.shields.io/badge/platform-Kali%20%7C%20Parrot-2ea44f?style=flat-square&logo=linux&logoColor=white)
![kerberos](https://img.shields.io/badge/auth-Kerberos--first-blueviolet?style=flat-square)
![license](https://img.shields.io/badge/license-MIT-orange?style=flat-square)

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support%20the%20project-FFDD00?style=for-the-badge&logo=buymeacoffee&logoColor=black)](https://www.buymeacoffee.com/C4sh3R)

</div>

---

## ✨ Why ADAutoPwn?

Most AD engagements start the same way: scan, fingerprint the DC, fix `/etc/hosts`,
sync the clock, hunt users, roast tickets, enumerate, look for ACL paths, check
ADCS, dump hashes. **ADAutoPwn does all of it for you — and then keeps going.**

Its core idea is a **recursive pivot loop**: the moment it recovers a new identity
(a cracked hash, a LAPS/gMSA secret, a password it reset via an abused ACL), that
identity is fed straight back into the engine and the *entire* enumeration +
exploitation chain runs again as that user — until nothing new appears.

Every user, hash, ticket and finding is **printed live and saved to disk**.

> ⚠️ **Legal:** Use only against systems you are explicitly authorized to test —
> a signed engagement, your own lab, or a CTF you're entitled to play. You are
> responsible for your actions.

---

## 🚀 Features

| Stage | What happens |
|------:|--------------|
| **0 · Discovery** | `nmap` of key AD ports → **capability matrix** (Kerberos/SMB/LDAP/RPC/WinRM). Domain/FQDN via SMB **or LDAP rootDSE + LDAPS cert** (works on Kerberos-only DCs) |
| **1 · Host & Time** | Auto-append to `/etc/hosts` (idempotent) + clock sync with the DC (Kerberos prerequisite) |
| **2 · Unauth enum** | null/guest sessions, anonymous shares, RID brute, `rpcclient`, LDAP anon bind, `enum4linux-ng`, `kerbrute` userenum |
| **3 · AS-REP Roast** | `GetNPUsers` — **dynamic**: authenticated LDAP sweep, discovered-user list, or capped seed |
| **4 · Validate + TGT** | **TGT-first** (`getTGT -dc-ip`, DNS-independent) → proves creds, cached & reused everywhere via `-k --use-kcache` |
| **5 · Auth enum** | users, groups, password policy, descriptions, shares, MachineAccountQuota (LDAP, or `rpcclient` fallback when LDAP is closed) |
| **★ Username variants** | `ryan.naylor` → `rnaylor`, `r.naylor`, `naylor`… validated with `kerbrute` (no lockout) |
| **★ Share looting** | spider readable shares, download files, **crack** password-protected Office/zip/pdf/keepass, **decrypt & read** their contents, **harvest** passwords inside |
| **★ Secrets** | **GPP cpassword**, **LAPS**, **gMSA**, **DPAPI** → auto-pivot on everything recovered |
| **★ WinRM + privesc** | who can WinRM; `whoami /priv` + `/groups` → maps **SeImpersonate→Potato**, SeBackup/SeDebug/SeRestore, Backup Operators, DnsAdmins… |
| **★ ACL analysis** | `GenericAll`, `WriteDACL`, `ForceChangePassword`, `AddSelf`, `WriteOwner`, **WriteSPN** — reported, and **abused** with `--abuse`: add-to-group, password reset, **WriteSPN→Kerberoast**, **Shadow Credentials** (recover NT hash), **RBCD** (impersonate Administrator) |
| **★ Relay & coercion** | SMB/LDAP signing checks, `coerce_plus` (PetitPotam/PrinterBug/DFSCoerce), spooler, WebDAV → **relay playbook** with your IP |
| **★ Trusts** | domain & **cross-forest** trusts, foreign security principals, cross-forest Kerberoast |
| **6 · Kerberoast** | `GetUserSPNs` for SPN accounts (incl. cross-forest) |
| **7 · ADCS** | `certipy` scan for **ESC1…ESC16** vulnerable templates |
| **8 · BloodHound** | full `All` collection → importable `.zip` |
| **9 · DCSync** | `secretsdump -just-dc` when privileges allow → **entire domain's NTLM hashes** |
| **★ NTDS offline** | if `NTDS.dit` + `SYSTEM` are looted from shares → `secretsdump -ntds LOCAL` |
| **∞ · Pivot + spray** | every recovered identity/secret re-enters the engine; recovered passwords are **sprayed** across all users to find more |

Plus:

- 🔐 **Kerberos-first** by default — works even when NTLM is disabled, and is quieter. `--ntlm` to force NTLM.
- 🧠 **Domain-focused wordlist** auto-generated from the target (`Season+Year`, `Name+123!`, …) and tried **first** for offline cracking; optional capped online spray with `--spray`.
- ♻️ **Self-feed / resume** — got creds or users by hand? Pass them with `--creds-file` / `--users-file` (or reuse the same `-o` loot dir) and the engine continues from there.
- 🩹 **Crack by default** — captured AS-REP / Kerberoast / NTLM hashes are cracked automatically (`--no-crack` to disable); cracked creds re-pivot.
- 🥷 **`--stealth`** — skips noisy techniques and adds jitter between actions.
- 🧹 **Responsible cleanup** — every change the tool makes (group adds, password
  resets, owner/SPN edits, `/etc/hosts`) is tracked in `rollback.log` and revertible
  with `--cleanup`. *No event-log wiping / anti-forensics — by design.*
- 🎨 Modern, colorful, real-time output (every user, hash and step printed live). Plain-text log saved alongside.

---

## 📦 Installation

```bash
git clone https://github.com/c4sh3r/ADAutoPwn.git
cd ADAutoPwn
chmod +x install.sh adautopwn.sh
./install.sh          # installs the whole toolchain (apt + pipx + kerbrute + rockyou)
```

On **Kali/Parrot** most dependencies are already present; `install.sh` fills the gaps.

> Python tools are listed in [`requirements.txt`](requirements.txt) and installed
> in isolation via `pipx` (with a `pip --user` fallback). `kerbrute` is fetched as
> a Go binary into `/opt/kerbrute`.

### Run it from anywhere

```bash
ln -sf "$PWD/adautopwn.sh" ~/.local/bin/adautopwn   # ~/.local/bin is on PATH
# now just:  adautopwn -t <DC_IP> ...
```

(`install.sh` also creates a `/usr/local/bin/adautopwn` symlink when it can.)

---

## 🧰 Requirements

**System (apt):** `nmap` · `smbclient` · `smbmap` · `rpcclient` · `ldap-utils` ·
`ntpdate` · `enum4linux-ng` · `john` · `hashcat` · `seclists`

**Python (pipx/pip):** `netexec` · `impacket` · `certipy-ad` · `bloodhound` ·
`bloodyAD` · `ldapdomaindump`

**Standalone:** `kerbrute` → `/opt/kerbrute` *(override with `KERBRUTE_BIN=...`)*

`sudo` is requested once, for clock sync and the `/etc/hosts` entry.

---

## 💻 Usage

```text
adautopwn -t <DC_IP> [-d <domain>] [-u <user>] [-p <pass> | -H <nt_hash>] [options]
```

| Flag | Description |
|------|-------------|
| `-t <ip>` | Domain Controller IP **(required)** |
| `-d <domain>` | Domain FQDN (auto-detected if omitted) |
| `-u <user>` | Domain username |
| `-p <pass>` | Cleartext password |
| `-H <hash>` | NT hash (pass-the-hash) |
| `-o <dir>` | Output/loot directory (reuse it to **resume**) |
| `-w <list>` | Cracking wordlist (default: rockyou) |
| `--sudo-pass <p>` | Sudo password for unattended `/etc/hosts` + time sync (or `SUDO_PASS=…`) |
| `--creds-file <f>` | Feed extra credentials to continue from (`user:password` / `user:nthash`) |
| `--users-file <f>` | Merge an external username list (spray / AS-REP / variants) |
| `--no-crack` | Disable hash cracking (**cracking is ON by default**) |
| `--spray` | Also spray the domain-focused wordlist **online** ⚠️ *account-lockout risk* |
| `--abuse` | Actively exploit ACLs (group adds, password resets, WriteSPN roast) — tracked for rollback |
| `--cleanup` | Revert every tracked change and exit |
| `--stealth` | OPSEC mode: skip noisy techniques + jitter |
| `--ntlm` | Force NTLM (default is Kerberos-first) |
| `--no-bh` | Skip BloodHound collection |
| `-y, --yes` | Assume yes — fully unattended |
| `--no-color` | Disable colors |
| `-h, --help` | Help |

> **Only `-t` is required.** With no credentials it runs every unauthenticated phase;
> add `-u/-p` (or `-H`) and it unlocks the rest and pivots recursively. The only
> opt-in (loud/destructive) extras are `--abuse` and `--spray`.

### Examples

```bash
# Zero-credential recon (users, AS-REP, anon shares, trusts)
adautopwn -t 10.10.10.10

# Full authenticated, auto-cracking, unattended (Kerberos by default)
adautopwn -t 10.10.10.10 -d corp.local -u jdoe -p 'P@ssw0rd' --crack -y

# Go loud: also abuse ACLs (add to groups / reset passwords) with rollback
adautopwn -t 10.10.10.10 -d corp.local -u jdoe -p 'P@ssw0rd' --crack --abuse

# Pass-the-hash straight through to DCSync
adautopwn -t 10.10.10.10 -d corp.local -u admin -H 31d6cfe0d16ae931b73c59d7e0c089c0

# Quiet engagement
adautopwn -t 10.10.10.10 -d corp.local -u jdoe -p 'P@ssw0rd' --stealth

# Clean up after yourself
adautopwn -t 10.10.10.10 --cleanup -o loot_corp.local_20260607_2210
```

### Self-feed / resume

Got a credential or a list of users by other means? Hand them over and the
engine continues from there (reusing the same `-o` keeps all prior loot):

```bash
# Continue an engagement with creds you found manually
printf 'svc_sql:Summer2025!\nbackupadmin:31d6cfe0d16ae931b73c59d7e0c089c0\n' > creds.txt
adautopwn -t 10.10.10.10 -d corp.local --creds-file creds.txt -o loot_corp.local_20260607_2210

# Seed a custom user list (for spray / AS-REP / variant generation)
adautopwn -t 10.10.10.10 -d corp.local -u jdoe -p 'P@ss' --users-file users.txt
```

---

## 📂 Loot layout

Everything is printed live **and** written to a timestamped loot directory:

```
loot_<domain>_<date>/
├── adautopwn.log              # full plain-text transcript
├── nmap_dc.txt                # port scan
├── users_all.txt              # consolidated, de-duplicated user list
├── users_variants*.txt        # generated + validated username variants
├── domain_wordlist.txt        # target-specific password candidates
├── asrep_hashes.txt           # AS-REP roast (hashcat -m 18200)
├── kerberoast_hashes.txt      # Kerberoast (hashcat -m 13100)
├── kerberoast_xforest_*.txt   # cross-forest roast
├── secretsdump.txt / ntds_local.txt  # DCSync / offline NTDS dump
├── gpp.txt / laps.txt / gmsa.txt / dpapi.txt   # recovered secrets
├── shares/                    # files looted from readable shares
├── decrypted_*  content_*.txt # decrypted documents + harvested text
├── cracked_files.txt          # cracked document passwords
├── found_passwords.txt        # every recovered password (sprayed + resumed)
├── whoami_priv_<user>.txt     # token privileges & dangerous rights
├── winrm_users.txt            # who can WinRM
├── acl_writable_<user>.txt    # exploitable ACLs per identity
├── relay_ldap.txt / coerce.txt # relay & coercion findings
├── trusts.txt                 # domain/forest trusts
├── certipy_find.txt           # ADCS findings
├── cracked_passwords.txt      # cracked hashes → plaintext
├── bloodhound/*.zip           # BloodHound data
└── rollback.log               # undo actions for --cleanup
```

---

## ♻️ Cleanup & OPSEC philosophy

ADAutoPwn is built for **professional engagements**, so it cleans up after *itself*:

- Every mutation (group membership added, password reset, owner changed,
  `/etc/hosts` entry) is recorded as an **undo command** in `rollback.log`.
- `--cleanup` reads that file and reverts the environment.

What it deliberately **does not** do: clear Windows event logs or perform
anti-forensics. That breaks the client's evidence chain and is out of scope for
legitimate testing. Stealth here means *being quiet* (`--stealth`, Kerberos,
jitter), not *destroying evidence*.

---

## ☕ Support the project

ADAutoPwn is free and open-source, built and maintained on a lot of late nights
(testing against real labs, adding attack techniques, fixing edge cases). If it
saved you time on an engagement or helped you learn, consider buying me a coffee —
it directly fuels the next feature. 🙏

<div align="center">

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-c4sh3r-FFDD00?style=for-the-badge&logo=buymeacoffee&logoColor=black)](https://www.buymeacoffee.com/C4sh3R)

**→ https://www.buymeacoffee.com/C4sh3R**

</div>

## 🤝 Contributing

Contributions are very welcome — this is a community tool and the AD attack
surface is huge. Whether you fix a parser edge-case or add a whole new technique,
PRs and issues are appreciated.

### How to contribute

```bash
# 1. Fork & clone
git clone https://github.com/<you>/ADAutoPwn.git && cd ADAutoPwn
# 2. Branch
git checkout -b feature/my-technique
# 3. Hack on adautopwn.sh — keep the house style:
#    - one `phase_*` function per stage, wired into assess_current_credential()
#    - gate techniques on the CAP_* capability flags
#    - print findings with info/ok/warn/loot, save artifacts to $OUTDIR
#    - anything that changes the target → rb_record for --cleanup
#    - run `bash -n adautopwn.sh` (must stay clean) and test on a lab/HTB box
# 4. PR with a short description + sample output
```

> Please test against a lab or a box you're allowed to use, and **never commit
> loot/credentials** (the `.gitignore` already blocks the usual files).

### 🌱 Good first issues

- **Parser hardening** — make the bloodyAD / netexec output parsing more robust
  across versions (the ACL and trust parsers are the juiciest targets).
- **`add dcsync` abuse** — when a principal has `WriteDACL`/`GenericAll` on the
  domain object, grant + use DCSync rights (`bloodyAD add dcsync`).
- **ADCS ESC auto-exploit** — go beyond `certipy find`: auto-run `certipy req`
  for ESC1/ESC4/ESC8 when a vulnerable template is found.
- **Offline DPAPI** — decrypt masterkey + credential blobs looted from shares.
- **More document types** — OneNote, `.kdb`, `.config` connection strings, etc.
- **Output formats** — JSON/Markdown engagement report from the loot dir.
- **WinRM post-ex** — pull `cmdkey /list`, scheduled tasks, saved creds when a
  shell is available.
- **Coercion-to-relay glue** — optional `--relay` that launches `ntlmrelayx`
  + a coercion trigger end-to-end (opt-in).

Pick one, open an issue to claim it, and go 🚀

## 📜 License

MIT — see [`LICENSE`](LICENSE). Provided for **authorized security testing and
education only**. The author assumes no liability for misuse.

<div align="center">
<sub>Made with ☕ and too many <code>impacket</code> flags by <b>c4sh3r</b></sub>
</div>
