#!/bin/sh
# ============================================================================
# roo_fix — ROOter 24.10 live-fixes installer (generated monolith)
#
# Applies three generic fixes to ROOter 24.10 boxes built from the same
# ./build ecosystem (the routers listed in router2410.json):
#   1. IPv6 end-to-end  (firewall _6 members + masq6, lan ip6*, wan6 PD,
#                        odhcpd RA, mwan3 numeric tracking)
#   2. TTL/HL nft fix   (handlettl.sh broken nft syntax on fw4 builds)
#   3. Preserve fix     (skip AT writes / hard reset when the modem already
#                        owns the session; UI toggle for it)
#
# Self-contained: payloads are embedded base64 at build time by build.sh.
# POSIX sh / busybox-compatible — runs on the router itself.
#
# Usage:
#   sh install.sh [--check]             # --check = read-only audit
#   sh -c "$(wget -qO- <url>)"          # default: apply
#   sh -c "$(wget -qO- <url>)" --check  # audit first
#
# Test-harness env (offline only, see tests/):
#   ROOTUP_ROOT=<dir>    operate on <dir> as the root filesystem (fake root)
#   ROOTUP_TEST=1        skip real-root checks and service restarts
#   ROOTUP_PROCFS=<dir>  procfs mount point to read for the IPv6 gate
#   ROOTUP_SKIP_NFT=1    skip live nft verification
# ============================================================================

VERSION="1.0.0"
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