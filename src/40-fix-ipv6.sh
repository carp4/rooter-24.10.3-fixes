# ---------------------------------------------------------------------------
# Fix 1: IPv6 end-to-end
# Mirrors exactly what is BAKED into the 24.10 images:
#   - initialize.sh do_zone()   : wan zone gets wan<N>_6 members + masq6 1
#   - config_generate           : lan ip6assign 64 / ip6hint 0000 /
#                                 ip6class local / multipath off;
#                                 wan6 reqaddress try / reqprefix 60 /
#                                 norelease 1 / multipath off / metric 1
#   - odhcpd.defaults           : piofolder / odhcpd ra_default 1 /
#                                 ra_preference medium
#   - mwan3 config (baked)      : numeric track targets, no hostnames
# (For an EXISTING box the first-boot hooks never re-run, so we apply the
#  same values as live uci changes — discovered generically per modem.)
# ---------------------------------------------------------------------------

fix_ipv6() {
	[ "$IPV6_OK" = 1 ] || { note "IPv6 fix skipped (no kernel IPv6)"; return 0; }

	printf '\n== IPv6 ==\n'
	need_reload=0

	# --- firewall: add every existing wan<N>_6 to the wan zone, masq6 1 ---
	if [ -n "$WAN_ZONE" ]; then
		z="$WAN_ZONE"
		i=1
		while [ "$i" -le 5 ]; do
			iv6="wan${i}_6"
			proto="$(uciq get network.$iv6.proto)"
			if [ "$proto" = "dhcpv6" ]; then
				# uci returns list values space-separated; token-match the member
				now="$(uciq get firewall.@zone[$z].network)"
				found=0
				for t in $now; do [ "$t" = "$iv6" ] && found=1; done
				if [ "$found" = 1 ]; then
					debug "firewall already covers $iv6"
				else
					note "firewall: adding $iv6 to wan zone"
					if [ "$MODE" = "apply" ]; then
						uciq add_list firewall.@zone[$z].network="$iv6"
						need_reload=1
					fi
				fi
			fi
			i=$((i+1))
		done
		# masq6 (IPv6 NAT) — gold truth, baked into do_zone()
		mq="$(uciq get firewall.@zone[$z].masq6)"
		if [ "$mq" != "1" ]; then
			note "firewall: setting masq6 1 on wan zone"
			if [ "$MODE" = "apply" ]; then
				uciq set firewall.@zone[$z].masq6="1"
				need_reload=1
			fi
		fi
	else
		debug "no wan zone resolved — firewall part skipped"
	fi

	# --- network: lan ip6 options (config_generate parity) ---
	if uciq show network.lan >/dev/null 2>&1; then
		for kv in "ip6assign=64" "ip6hint=0000" "ip6class=local" "multipath=off"; do
			k="${kv%%=*}"; v="${kv#*=}"
			cur="$(uciq get network.lan.$k)"
			if [ "$cur" != "$v" ]; then
				note "network.lan.$k: '$cur' -> '$v'"
				if [ "$MODE" = "apply" ]; then
					uciq set network.lan.$k="$v"
					need_reload=1
				fi
			fi
		done
	fi

	# --- network: wan6 PD options (config_generate parity; gold reqprefix 60) ---
	w6="$(uciq get network.wan6.proto)"
	if [ "$w6" = "dhcpv6" ]; then
		for kv in "reqaddress=try" "reqprefix=60" "norelease=1" "multipath=off" "metric=1"; do
			k="${kv%%=*}"; v="${kv#*=}"
			cur="$(uciq get network.wan6.$k)"
			if [ "$cur" != "$v" ]; then
				note "network.wan6.$k: '$cur' -> '$v'"
				if [ "$MODE" = "apply" ]; then
					uciq set network.wan6.$k="$v"
					need_reload=1
				fi
			fi
		done
	fi

	# --- dhcp: odhcpd RA tuning + piofolder (odhcpd.defaults parity) ---
	for kv in "dhcp.lan.ra_default=1" "dhcp.lan.ra_preference=medium" "dhcp.odhcpd.piofolder=/tmp/odhcpd-piofolder"; do
		k="${kv%%=*}"; v="${kv#*=}"
		cur="$(uciq get $k)"
		if [ "$cur" != "$v" ]; then
			note "$k: '$cur' -> '$v'"
			if [ "$MODE" = "apply" ]; then
				uciq set "$k=$v"
				need_reload=1
			fi
		fi
	done

	# --- mwan3: numeric track targets on all members (no hostnames) ---
	fix_mwan3_numeric

	# --- mwan3: v6 members must not flush conntrack on tracker churn ---
	fix_mwan3_v6_flush

	if [ "$MODE" = "apply" ] && [ "$need_reload" = 1 ]; then
		note "committing + reloading network/firewall/odhcpd"
		uciq commit network; uciq commit firewall; uciq commit dhcp; uciq commit mwan3
		svc network reload
		svc firewall restart
		svc odhcpd restart
	elif [ "$MODE" = "apply" ]; then
		debug "no uci changes in IPv6 fix"
		uciq commit network 2>/dev/null
		uciq commit firewall 2>/dev/null
		uciq commit dhcp 2>/dev/null
		uciq commit mwan3 2>/dev/null
	fi

	# Deliberately OUTSIDE the apply branch above. --check must still tell the
	# operator that applying would bounce mwan3: a tracker restart interrupts
	# WAN tracking on every member, so it is part of the cost of the fix and
	# must be visible before anyone runs it for real, not discovered after.
	# activate_mwan3 announces in both modes and only executes in apply.
	activate_mwan3
	ok "IPv6 fix"
}

# mwan3 members of the given family, one name per line.
#
# Enumerates NAMED sections (mwan3.wan1, mwan3.wan1_6, ...). It must not use
# mwan3.@interface[$i]: every mwan3 interface on a ROOter box is a named
# section, so the indexed form enumerates zero members and silently does
# nothing. That was a real defect in the previous fix_mwan3_numeric.
#
# Filtering has two conditions, both required:
#   1. section TYPE must be `interface` -- filtering on family alone also
#      matches policy rules such as `rule_v6` (a `rule`, not an `interface`),
#      which would otherwise get a meaningless flush_conntrack option.
#   2. the family option must equal the requested family.
#
# The section list is discovered, never hardcoded: how many wan<N>_6 members
# exist depends on the "Multiple Modems" setting (maxmodem.maxmodem.maxmodem),
# which the operator can change at runtime. A 4-modem box and an 8-modem box
# have different member sets, so any fixed list would be wrong on one of them.
#
# Note on `uci show`: values are QUOTED (mwan3.wan1_6.family='ipv6'), so a
# regex of the form family=ipv6$ matches nothing. Select the section list on
# `=interface`, which is unquoted, and test family per section with uci get.
mwan3_members() {
	want_family="$1"
	uciq show mwan3 2>/dev/null \
		| sed -n "s/^mwan3\.\([^.=]*\)=interface\$/\1/p" \
		| while read -r sec; do
			[ "$(uciq get "mwan3.$sec.family" 2>/dev/null)" = "$want_family" ] \
				&& echo "$sec"
		done
}

# mwan3 numeric track targets (baked config values; v4 + v6)
fix_mwan3_numeric() {
	# Discover members per family and walk them by NAME.
	#
	# Deliberately NOT a `mwan3_members | while read` pipeline: a pipeline
	# runs the loop in a subshell, so the need_reload=1 assignment would be
	# discarded and the change would be applied without ever being activated.
	# For-loop over command substitution keeps the assignment in this shell.
	for fam in ipv4 ipv6; do
		for sec in $(mwan3_members "$fam"); do
			tracklist="$(uciq get "mwan3.$sec.track_ip" 2>/dev/null)"
			hostname_track=0
			for one in $tracklist; do
				if is_hostname "$one"; then hostname_track=1; fi
			done
			[ "$hostname_track" = 1 ] || continue
			# replace with baked numerics for that family
			if [ "$fam" = "ipv6" ]; then
				repl="2606:4700::1001 2001:4860:4860::8888 2620:fe::9"
			else
				repl="1.1.1.1 8.8.8.8 9.9.9.9"
			fi
			note "mwan3 interface '$sec': replace hostname track_ip with $repl"
			# Intent is recorded in BOTH modes so --check can report the
			# restart it would cause; the mutation itself stays apply-only.
			MWAN3_UCI_CHANGED=1
			if [ "$MODE" = "apply" ]; then
				# delete existing track_ip list, then add numerics
				uciq -q delete "mwan3.$sec.track_ip" 2>/dev/null
				for v in $repl; do
					uciq add_list "mwan3.$sec.track_ip=$v"
				done
				need_reload=1
			fi
		done
	done
}

# mwan3 v6 members: drop conntrack flushes on the tracker's own
# connected/disconnected events.
#
# The stock baseline sets, on every member:
#     flush_conntrack = connected disconnected ifup ifdown
# Carriers here rotate the delegated /64 on renew, so the tracker can fail
# every target during a rotation while the link is perfectly fine. Each such
# churn fires connected/disconnected, which flushes conntrack and kills every
# live LAN session. netifd still fires ifup/ifdown on a genuine link
# transition, so real outages are still covered.
#
# IPv4 members keep the stock list deliberately: they are not on rotating
# carriers, and removing their flush would change behaviour that is not
# broken. Only family=ipv6 is touched.
fix_mwan3_v6_flush() {
	for sec in $(mwan3_members ipv6); do
		cur="$(uciq get "mwan3.$sec.flush_conntrack" 2>/dev/null)"
		# uci returns list values space-separated; compare as a token set so
		# ordering differences do not cause a pointless rewrite
		have_ifup=0; have_ifdown=0; have_churn=0
		for t in $cur; do
			case "$t" in
				ifup)    have_ifup=1 ;;
				ifdown)  have_ifdown=1 ;;
				connected|disconnected) have_churn=1 ;;
			esac
		done
		# Only the churn events are the defect. If a member has neither
		# `connected` nor `disconnected` there is nothing to remove, and
		# forcing 'ifup ifdown' onto it would ADD flushing that the member
		# never had -- a behaviour change beyond the stated fix.
		if [ "$have_churn" = 0 ]; then
			debug "mwan3 $sec: no connected/disconnected flush ($cur) - nothing to remove"
			continue
		fi
		# Rebuild the list keeping exactly the link-transition events this
		# member already had. The stock baseline is
		# 'connected disconnected ifup ifdown', so in practice this yields
		# 'ifup ifdown'; a member trimmed to the churn events alone
		# correctly ends up with no list at all.
		new=""
		[ "$have_ifup" = 1 ] && new="ifup"
		[ "$have_ifdown" = 1 ] && new="${new:+$new }ifdown"
		note "mwan3 interface '$sec': flush_conntrack '$cur' -> '${new:-<none>}'"
		MWAN3_UCI_CHANGED=1
		if [ "$MODE" = "apply" ]; then
			uciq -q delete "mwan3.$sec.flush_conntrack" 2>/dev/null
			if [ "$have_ifup" = 1 ]; then
				uciq add_list "mwan3.$sec.flush_conntrack=ifup"
			fi
			if [ "$have_ifdown" = 1 ]; then
				uciq add_list "mwan3.$sec.flush_conntrack=ifdown"
			fi
			need_reload=1
		fi
	done
}

# Restart mwan3 only when this run actually changed something mwan3 owns.
#
# Replacing /usr/sbin/mwan3track on disk does NOT affect the already-running
# tracker: it is a spawned process holding the old code. The trackers must be
# respawned or the fix is inert until the next reboot. Likewise, a committed
# uci change to flush_conntrack is not applied until mwan3 re-reads it.
#
# This is the only payload in the set that needs activation -- the other six
# are per-invocation AT/LuCI handlers or CBI models that are re-read on each
# use, so replacing their files takes effect immediately.
activate_mwan3() {
	[ "${MWAN3_UCI_CHANGED:-0}" = 1 ] || [ "${MWAN3TRACK_REPLACED:-0}" = 1 ] || return 0
	if [ "${ROOTUP_DEBUG:-0}" = 1 ]; then
		printf '  [ dbg ] activate_mwan3: uci=%s tracker=%s mode=%s\n' \
			"${MWAN3_UCI_CHANGED:-0}" "${MWAN3TRACK_REPLACED:-0}" "$MODE" >&2
	fi
	if [ "$MODE" != "apply" ]; then
		note "mwan3: would restart so the tracker respawns with the new code/config"
		note "mwan3: brief WAN tracking interruption is expected (all members)"
		return 0
	fi
	note "mwan3: restarting so the tracker respawns with the new code/config"
	note "mwan3: brief WAN tracking interruption is expected (all members)"
	svc mwan3 reload
}

# is_hostname V: true if V is not an IP literal (used for track targets)
# IPv6 literal = contains ':'. IPv4 literal = digits/dots only.
# Letters with no colon = hostname.
is_hostname() {
	case "$1" in
		*:*)          return 1 ;;   # IPv6 literal (hex letters are fine)
		*[a-zA-Z]*)   return 0 ;;   # letters, no ':' -> hostname
		*)            return 1 ;;   # digits/dots only -> IPv4 literal
	esac
}