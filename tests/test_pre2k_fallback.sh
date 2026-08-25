#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/adautopwn-pre2k-test.XXXXXX")
ACTUAL="$TEST_TMP/candidates.tsv"

# Load the framework functions without starting a full assessment.
source <(sed '/^main "\$@"$/,$d' "$ROOT/adautopwn.sh")
# Sourcing installs ADAutoPwn's runtime cleanup trap; replace it with the
# fixture cleanup appropriate for this isolated test process.
trap 'rm -rf "$TEST_TMP"' EXIT

_pre2k_build_candidates \
    "$ROOT/tests/fixtures/pre2k_computers.ldif" \
    "$ROOT/tests/fixtures/pre2k_group.ldif" \
    "$ACTUAL"

diff -u "$ROOT/tests/fixtures/pre2k_expected.tsv" "$ACTUAL"

# The regression fixture proves that a Vintage-like FS01$ account is selected
# solely because of group membership despite populated password/logon metadata.
grep -q $'^FS01\\$\t.*pre-windows-2000-compatible-access$' "$ACTUAL"
! grep -q '^NORMAL\$' "$ACTUAL"
! grep -q '^DC01\$' "$ACTUAL"

# Exercise the complete phase with an installed-but-empty NetExec module.  The
# LDAP and Kerberos clients are deterministic shell doubles, so this verifies
# the original regression: module availability must not suppress the fallback,
# and the FS01$ group member must be queued with its lowercase legacy password.
NXC=nxc_fixture
OUTDIR="$TEST_TMP"
LOGFILE="$TEST_TMP/run.log"
DCT=dc01.vintage.htb
DC_FQDN=dc01.vintage.htb
DC_IP=192.0.2.10
DOMAIN=vintage.htb
KERB_TICKET="$TEST_TMP/p.rosa.ccache"
HAVE_AUTH=1
STEALTH=0
CAP_LDAP=1
PRECREATED_DONE=0
QUEUED=()

nxc_has_module() { return 0; }
nxc_cred_args() { return 0; }
nxc_fixture() { return 0; }
ldapsearch() {
    if [[ "$*" == *'objectSid=S-1-5-32-554'* ]]; then
        command cat "$ROOT/tests/fixtures/pre2k_group.ldif"
    else
        command cat "$ROOT/tests/fixtures/pre2k_computers.ldif"
    fi
}
impacket-getTGT() {
    if [[ "$*" == *'vintage.htb/FS01$:fs01'* ]]; then
        echo 'Saving ticket in FS01$.ccache'
        return 0
    fi
    echo 'KDC_ERR_PREAUTH_FAILED'
    return 1
}
queue_cred() { QUEUED+=("$1|$2"); }
add_secret() { return 0; }
note_cred_source() { return 0; }

# ADAutoPwn intentionally does not use errexit; mirror that runtime behaviour
# while exercising the complete phase (post-increment arithmetic returns 1 on
# its first iteration even though it is not an error).
set +e
phase_precreated_computers >/dev/null
set -e

printf '%s\n' "${QUEUED[@]}" | grep -Fqx 'FS01$|fs01'
grep -q 'NetExec pre2k returned no usable accounts' "$LOGFILE"

echo "pre2k LDAP fallback regression test: PASS"
