# ---------------------------------------------------------------------------
# Fix 3: Already-connected ECM preserve fix
# Payload engine ships the canonical create_hostless.sh (47c26fbe...),
# get_profile.sh (43889f4a...) and profiles.lua (61d7dc18...). restartrun.sh
# is canonical in-tree already (a5cec911...) and is report-only.
# The UI toggle default is Yes: profile.default.preserve = 1.
# ---------------------------------------------------------------------------

fix_preserve() {
	printf '\n== Preserve (already-connected ECM) ==\n'

	# payload install of create_hostless.sh / get_profile.sh / profiles.lua
	# happens in install_payloads(); here we handle the profile default and
	# the restartrun.sh report-only check.

	# shipped default: preserve=1 (Yes). Set it if unset so the toggle
	# behaves identically to a fresh flash.
	cur="$(uciq get profile.default.preserve)"
	if [ -z "$cur" ]; then
		note "profile.default.preserve unset -> defaulting to 1 (Yes)"
		if [ "$MODE" = "apply" ]; then
			uciq set profile.default.preserve="1"
			uciq commit profile 2>/dev/null
		fi
	fi

	# restartrun.sh: canonical in-tree (a5cec911...). Any divergent state is
	# worth flagging — the guard lives there too.
	rr="$(fmd5 /usr/lib/rooter/luci/restartrun.sh)"
	if [ -n "$rr" ]; then
		if [ "$rr" = "a5cec9111a57ff4a3e8d7a3f04ae9527" ]; then
			ok "restartrun.sh: canonical (guard present)"
		else
			warn "restartrun.sh differs from canonical (md5 $rr) — preserving an existing session may not be guarded until replaced"
		fi
	else
		note "restartrun.sh not present"
	fi

	# connection state: nothing to force here; the preserve branch triggers
	# on the next ROOter connect cycle when the modem already owns the link.
	ok "Preserve fix"
}