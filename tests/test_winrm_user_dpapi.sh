#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/adautopwn-winrm-dpapi-test.XXXXXX")

# Load functions without launching a full assessment, then replace ADAutoPwn's
# runtime exit trap with fixture cleanup for this isolated test process.
source <(sed '/^main "\$@"$/,$d' "$ROOT/adautopwn.sh")
trap 'rm -rf "$TEST_TMP"' EXIT

OUTDIR="$TEST_TMP/loot"
LOGFILE="$TEST_TMP/adautopwn.log"
USER='lab.user'
PASS='CurrentUserPass!42'
HASH=''
mkdir -p "$OUTDIR"

QUEUED=()
SECRETS=()
SOURCES=()

_winrm_exec() {
    printf '%s\n' \
        'ADPWN_DPAPI|SID|S-1-5-21-111-222-333-1104' \
        'ADPWN_DPAPI|CRED|ROAMING|AABBCCDDEEFF0011|ZHVtbXktY3JlZA==' \
        'ADPWN_DPAPI|MK|ROAMING|11111111-2222-3333-4444-555555555555|ZHVtbXktbWs='
}

impacket-dpapi() {
    case "$1" in
        masterkey)
            printf '%s\n' 'Decrypted key with User Key (MD4 protected)' \
                          'Decrypted key: 0x0123456789abcdef'
            ;;
        credential)
            if [[ " $* " == *' -key '* ]]; then
                printf '%s\n' '[CREDENTIAL]' \
                              'Target      : LegacyGeneric:target=admin_acc' \
                              'Username    : LAB\svc_admin' \
                              'Unknown     :' \
                              'Unknown     : M0ckedDPAPI!42'
            else
                printf '%s\n' '[BLOB]' \
                              'Guid MasterKey   : 11111111-2222-3333-4444-555555555555'
            fi
            ;;
        *) return 1 ;;
    esac
}

queue_cred() { QUEUED+=("$1|$2|$4"); }
add_secret() { SECRETS+=("$1|$2"); }
note_cred_source() { SOURCES+=("$1|$2"); }

_winrm_user_dpapi >/dev/null

printf '%s\n' "${QUEUED[@]}" | grep -Fqx 'svc_admin|M0ckedDPAPI!42|user Credential Manager DPAPI via WinRM'
printf '%s\n' "${SECRETS[@]}" | grep -Fqx 'M0ckedDPAPI!42|user DPAPI via WinRM (ROAMING_AABBCCDDEEFF0011)'
printf '%s\n' "${SOURCES[@]}" | grep -Fqx 'svc_admin:M0ckedDPAPI!42|user Credential Manager DPAPI via WinRM'

test -s "$OUTDIR/dpapi_user_lab.user/Credentials/ROAMING_AABBCCDDEEFF0011"
test -s "$OUTDIR/dpapi_user_lab.user/Protect/S-1-5-21-111-222-333-1104/11111111-2222-3333-4444-555555555555"
grep -q 'Username.*LAB\\svc_admin' "$OUTDIR/dpapi_user_lab.user/decrypted_ROAMING_AABBCCDDEEFF0011.txt"

echo "WinRM user DPAPI regression test: PASS"
