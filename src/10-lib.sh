# ---------------------------------------------------------------------------
# Common helpers (POSIX sh / busybox-safe)
# ---------------------------------------------------------------------------

# rootpath PATH -> full path under the active root (real / or fake root)
rp() { printf '%s' "$ROOT$1"; }

ok()   { printf '  [ OK ] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# uci wrapper: plain `uci` on the box; test harness injects a stub via PATH.
uciq() { uci -q "$@"; }

# md5 of a file under the active root ("" if absent)
fmd5() {
	[ -f "$(rp "$1")" ] || { printf ''; return; }
	md5sum "$(rp "$1")" | cut -d' ' -f1
}

# service wrapper (no-op in test mode / for missing init scripts)
svc() {
	[ "$TESTMODE" = 1 ] && { debug "svc(skip) $1 $2"; return 0; }
	s="$1" a="$2"
	if [ -x "/etc/init.d/$s" ]; then
		"/etc/init.d/$s" "$a" 2>/dev/null
	else
		debug "svc(missing) /etc/init.d/$s"
	fi
}

debug() { [ "${ROOTUP_DEBUG:-0}" = 1 ] && printf '  [ dbg ] %s\n' "$*" >&2; }

note() { printf '  [NOTE] %s\n' "$*"; }

# has_cmd CMD  -> 0 if a command exists (respects a PATH that includes stubs)
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- backup ----
BK=""
BK_FILES=""
make_backup() {
	ts=""
	[ "$MODE" = "check" ] && return 0
	ts="$(date +%Y%m%d-%H%M%S)"
	BK="$(rp /root)/rooter-upgrade-bk-$ts"
	mkdir -p "$BK/files" || die "cannot create backup dir $BK"
	BK_FILES="$BK/files"
	if has_cmd uci; then
		for p in network firewall dhcp mwan3 profile; do
			uci -q export "$p" > "$BK/$p.uci" 2>/dev/null || rm -f "$BK/$p.uci"
		done
	fi
	note "backup dir: $BK"
}

# back up one file (as it exists now) before we replace it
backup_file() { # dest-path (absolute, no leading /)
	dest="$1" rel=""
	[ "$MODE" = "apply" ] || return 0
	[ -n "$BK_FILES" ] || return 0
	rel="$(printf '%s' "$dest" | tr '/' '_')"
	if [ -f "$(rp "$dest")" ]; then
		cp -p "$(rp "$dest")" "$BK_FILES/$rel" 2>/dev/null || warn "backup copy failed: $dest"
	fi
}

write_rollback() {
	[ "$MODE" = "check" ] && return 0
	cat > "$BK/rollback.sh" <<EOF
#!/bin/sh
# Restore state captured before running roo_fix on $(date).
# Sourced by the operator if the fixes must be reverted.
set -e
BK="$BK"
for f in \$(ls "\$BK/files"); do
  dest="\$(printf '%s' "\$f" | tr '_' '/')"
  [ -f "\$BK/files/\$f" ] || continue
  echo "restore: /\$dest"
  cp -p "\$BK/files/\$f" "/\$dest"
done
for p in network firewall dhcp mwan3 profile; do
  [ -f "\$BK/\$p.uci" ] && { echo "uci import \$p"; uci import "\$p" < "\$BK/\$p.uci" 2>/dev/null; }
done
echo "Restart services to apply reverted config (network, firewall, odhcpd, mwan3)."
EOF
	chmod +x "$BK/rollback.sh"
	note "rollback: sh $BK/rollback.sh"
}