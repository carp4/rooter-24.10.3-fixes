# ---------------------------------------------------------------------------
# Payload engine: fingerprint-gated drop-in replacement.
# The payload table variable ROOTUP_TABLE is injected by build.sh as a
# single-quoted, newline-separated block (embedded after this file).
# Row format (pipe-separated):
#   name|destination|mode|canonical-md5|known-old-md5[,old2...]|base64
# Policy per file:
#   on-box == canonical                     -> SKIP (already current)
#   on-box in known-old set                 -> REPLACE (backup first)
#   on-box anything else                    -> REPORT-ONLY (backup + warn, never touch)
#   file missing                            -> NOTE  (box predates/lacks it; nothing to do)
# ---------------------------------------------------------------------------

# The payload table variable ROOTUP_TABLE is injected by build.sh as a
# single-quoted, newline-separated block (emitted before this file).
# Row format (pipe-separated):
#   name|destination|mode|canonical-md5|known-old-md5[,old2...]|base64
# Policy per file:
#   on-box == canonical                     -> SKIP (already current)
#   on-box in known-old set                 -> REPLACE (backup first)
#   on-box anything else                    -> REPORT-ONLY (backup + warn, never touch)
#   file missing                            -> NOTE  (box predates/lacks it; nothing to do)
# ---------------------------------------------------------------------------

# install_payloads: walk the embedded table
install_payloads() {
	[ -n "$ROOTUP_TABLE" ] || { warn "payload table empty — build artifact broken"; return 1; }

	OLDIFS="$IFS"; IFS='
'
	for row in $ROOTUP_TABLE; do
		IFS="|"
		set -- $row
		name="$1"; dest="$2"; mode="$3"; canon="$4"; olds="$5"; b64="$6"
		IFS="$OLDIFS"
		[ -n "$name" ] || continue
		payload_apply "$name" "$dest" "$mode" "$canon" "$olds" "$b64"
	done
	IFS="$OLDIFS"
}

# payload_apply NAME DEST MODE CANON OLDS B64
payload_apply() {
	name="$1"; dest="$2"; mode="$3"; canon="$4"; olds="$5"; b64="$6"
	onbox="$(fmd5 "$dest")"

	if [ -z "$onbox" ]; then
		note "$name: not present on box, nothing to do"
		return 0
	fi

	if [ "$onbox" = "$canon" ]; then
		ok "$name: already current (skip)"
		# No activation flag here, deliberately. The running tracker process
		# could in principle predate the on-disk file, but that is
		# unfalsifiable from outside the process, so flagging it would mean
		# EVERY run restarts mwan3 and the gate stops discriminating. The
		# contract roo_fix can actually keep is "if I changed it, I activate
		# it" -- a box that already carries the canonical bytes has nothing
		# outstanding from us.
		return 0
	fi

	# decode payload into a temp file and verify its md5 before install
	tmpb64="$TMPD/$name.b64"
	printf '%s' "$b64" > "$tmpb64"
	tmp="$TMPD/$name"
	b64dec < "$tmpb64" > "$tmp" 2>/dev/null || { fail "$name: payload decode failed"; return 1; }
	payloadmd5="$(md5sum "$tmp" | cut -d' ' -f1)"
	if [ "$payloadmd5" != "$canon" ]; then
		fail "$name: embedded payload md5 mismatch (got $payloadmd5, want $canon) — build artifact broken"
		return 1
	fi

	# known-old set contains the on-box fingerprint -> replace
	match=0
	OLDIFS="$IFS"; IFS=','
	for old in $olds; do
		IFS="$OLDIFS"
		[ -n "$old" ] && [ "$onbox" = "$old" ] && { match=1; break; }
		IFS=','
	done
	IFS="$OLDIFS"

	if [ "$match" = 1 ]; then
		# Per-payload activation signal, set in BOTH modes so --check reports
		# the restart that applying would cause. CHANGED is only a counter, so
		# fix_ipv6 cannot otherwise learn the tracker was replaced -- and a
		# replaced tracker on disk is inert until the process respawns.
		# Conditioned on $name so a payload swap never bounces mwan3 by accident.
		[ "$name" = "mwan3track" ] && MWAN3TRACK_REPLACED=1
		if [ "$MODE" = "check" ]; then
			note "$name: would replace (onbox $onbox -> canonical)"
			return 0
		fi
		backup_file "$dest"
		cp -f "$tmp" "$(rp "$dest")" || { fail "$name: install failed"; return 1; }
		chmod "$mode" "$(rp "$dest")"
		CHANGED=$((CHANGED+1))
		ok "$name: replaced with canonical"
		return 0
	fi

	warn "$name: unknown on-box state (md5 $onbox) — NOT touched, backed up for review"
	backup_file "$dest"
	return 0
}