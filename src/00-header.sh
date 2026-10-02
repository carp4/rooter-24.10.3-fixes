#!/bin/sh
# ============================================================================
# roo_fix — ROOter 24.10 live-fixes installer (generated monolith)
#
# Applies four generic fixes to ROOter 24.10 boxes built from the same
# ./build ecosystem (the routers listed in router2410.json):
#   1. IPv6 end-to-end  (firewall _6 members + masq6, lan ip6*, wan6 PD,
#                        odhcpd RA, mwan3 numeric tracking, mwan3 v6
#                        conntrack-flush removal)
#   2. TTL/HL nft fix   (handlettl.sh broken nft syntax on fw4 builds)
#   3. Preserve fix     (skip AT writes / hard reset when the modem already
#                        owns the session; UI toggle for it)
#   4. mwan3 diag fix   (luci-mwan3 reported phantom "missing rule / table"
#                        for wan<N>_6 by always using IPv4-only ip commands;
#                        diagnostic-only, no routing behaviour change)
#   5. mwan3track fix   (tracker pinned one ipv6 source address while the
#                        carrier rotates the delegated /64, so every track
#                        target failed with "Address not available"; the
#                        patched tracker re-derives its source in place)
#
# 1 and 5 both require ACTIVATION: mwan3 is restarted (its reload_service is
# { stop; start; }, which does respawn trackers) when, and only when, this run
# actually changed mwan3 config or replaced the tracker binary.
#
# Self-contained: payloads are embedded base64 at build time by build.sh.
# POSIX sh / busybox-compatible — runs on the router itself.
#
# Usage:
#   sh install.sh [--check]             # --check = read-only audit
#   wget -qO- <url> | sh -s             # default: apply (pipe, NOT sh -c:
#   wget -qO- <url> | sh -s -- --check  # audit first)
#   NOTE: this script is ~150 KB and the kernel caps a single argv entry at
#   128 KiB, so `sh -c "$(curl …)"` fails with "Argument list too long" on
#   the router. Always pipe via stdin.
#
# Test-harness env (offline only, see tests/):
#   ROOTUP_ROOT=<dir>    operate on <dir> as the root filesystem (fake root)
#   ROOTUP_TEST=1        skip real-root checks and service restarts
#   ROOTUP_PROCFS=<dir>  procfs mount point to read for the IPv6 gate
#   ROOTUP_SKIP_NFT=1    skip live nft verification
# ============================================================================

VERSION="1.2.0"
ROOT="${ROOTUP_ROOT:-/}"
TESTMODE="${ROOTUP_TEST:-0}"
PROCFS="${ROOTUP_PROCFS:-/proc}"
SKIP_NFT="${ROOTUP_SKIP_NFT:-0}"

MODE="apply"
case "${1:-apply}" in
	--check|check)   MODE="check" ;;
	--apply|apply)   MODE="apply" ;;
	--help|-h)       cat >&2 <<'HELP'
roo_fix — ROOter 24.10 live-fixes installer
  --check   read-only audit: print what would change, write nothing
  --apply   apply the fixes with automatic backup + rollback script
  (default) --apply
HELP
		exit 0 ;;
	*)    echo "roo_fix: unknown argument '$1' (--check | --apply | --help)" >&2; exit 1 ;;
esac

TMPD=""
cleanup() { [ -n "$TMPD" ] && rm -rf "$TMPD" 2>/dev/null; }
trap cleanup EXIT HUP INT TERM
TMPD="$(mktemp -d /tmp/roofix.XXXXXX 2>/dev/null)"
if [ -z "$TMPD" ] || [ ! -d "$TMPD" ]; then
	TMPD="/tmp/roofix.$$"
	mkdir -p "$TMPD" 2>/dev/null || {
		printf 'FATAL: cannot create temp dir %s\n' "$TMPD" >&2
		exit 1
	}
fi

CHANGED=0