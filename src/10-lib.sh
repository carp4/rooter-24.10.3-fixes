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

# ------------------------------------------------------------------ decode ----
# b64dec — base64 decode stdin -> stdout. Pure awk, busybox-safe: ROOter 24.10
# images have NO `base64` binary (probed live: not in PATH, not a busybox
# applet), so GNU `base64 -d` is a hard no-go on the target. awk is
# guaranteed (busybox). LC_ALL=C is forced so printf "%c" emits raw bytes
# for values >= 128 (payloads are text; md5-gating still requires byte
# exactness). Output is then md5-verified against the canonical fingerprint.
b64dec() {
	LC_ALL=C awk '
		function val(c,    i) {
			i = index("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", c)
			return i ? i - 1 : 0
		}
		{
			s = $0
			n = length(s)
			for (i = 1; i <= n; i += 4) {
				c1 = substr(s, i, 1)
				c2 = substr(s, i + 1, 1)
				c3 = substr(s, i + 2, 1)
				c4 = substr(s, i + 3, 1)
				v = val(c1) * 262144 + val(c2) * 4096
				if (c3 != "" && c3 != "=") v += val(c3) * 64
				if (c4 != "" && c4 != "=") v += val(c4)
				printf "%c", int(v / 65536)
				if (c3 != "" && c3 != "=") printf "%c", int((v % 65536) / 256)
				if (c4 != "" && c4 != "=") printf "%c", v % 256
			}
		}' 2>/dev/null || return 1
	return 0
}

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
		cp -p "$(rp "$dest")" "$BK_FILES/$rel" 2>/dev/null || { warn "backup copy failed: $dest"; return 0; }
		# manifest: backup-name<space>dest-path — the filesystem name alone is
		# NOT reversible (underscores in filenames corrupt tr '_' '/'), so
		# record the real destination explicitly (see write_rollback). A space
		# delimiter is safe here (no path has spaces) and, unlike a tab via
		# printf, survives the unquoted heredoc without backslash mangling.
		printf '%s %s\n' "$rel" "$dest" >> "$BK/manifest"
	fi
}

write_rollback() {
	[ "$MODE" = "check" ] && return 0
	cat > "$BK/rollback.sh" <<EOF
#!/bin/sh
# Restore state captured before running roo_fix on $(date).
# Sourced by the operator if the fixes must be reverted.
# Set ROOT_PREFIX=<dir> to restore under <dir> instead of / (test/dry-run).
set -e
BK="$BK"
R="\${ROOT_PREFIX:-}"
if [ -s "\$BK/manifest" ]; then
  while read -r rel dest || [ -n "\$rel" ]; do
    [ -f "\$BK/files/\$rel" ] || continue
    echo "restore: \$R/\$dest"
    cp -p "\$BK/files/\$rel" "\$R/\$dest"
  done < "\$BK/manifest"
else
  for f in \$(ls "\$BK/files"); do
    dest="\$(printf '%s' "\$f" | tr '_' '/')"
    [ -f "\$BK/files/\$f" ] || continue
    echo "restore: \$R/\$dest"
    cp -p "\$BK/files/\$f" "\$R/\$dest"
  done
fi
for p in network firewall dhcp mwan3 profile; do
  [ -f "\$BK/\$p.uci" ] && { echo "uci import \$p"; uci import "\$p" < "\$BK/\$p.uci" 2>/dev/null; }
done
echo "Restart services to apply reverted config (network, firewall, odhcpd, mwan3)."
EOF
	chmod +x "$BK/rollback.sh"
	note "rollback: sh $BK/rollback.sh"
}