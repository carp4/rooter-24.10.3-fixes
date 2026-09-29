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
	ok "IPv6 fix"
}

# mwan3 numeric track targets (baked config values; v4 + v6)
fix_mwan3_numeric() {
	# enumerate mwan3 interface sections (config interface 'wan1', 'wan1_6', ...)
	idx=0
	while :; do
		sec="$(uciq get mwan3.@interface[$idx].name 2>/dev/null)"
		[ -z "$sec" ] && break
		fam="$(uciq get mwan3.@interface[$idx].family 2>/dev/null)"
		# does this member track hostnames? collect current values
		tracklist="$(uciq get mwan3.@interface[$idx].track_ip 2>/dev/null)"
		hostname_track=0
		for one in $tracklist; do
			if is_hostname "$one"; then hostname_track=1; fi
		done
		if [ "$hostname_track" = 1 ]; then
			# replace with baked numerics for that family
			if [ "$fam" = "ipv6" ]; then
				repl="2606:4700::1001 2001:4860:4860::8888 2620:fe::9"
			else
				repl="1.1.1.1 8.8.8.8 9.9.9.9"
			fi
			note "mwan3 interface '$sec': replace hostname track_ip with $repl"
			if [ "$MODE" = "apply" ]; then
				# delete existing track_ip list, then add numerics
				uciq -q delete mwan3.@interface[$idx].track_ip 2>/dev/null
				for v in $repl; do
					uciq add_list mwan3.@interface[$idx].track_ip="$v"
				done
				need_reload=1
			fi
		fi
		idx=$((idx+1))
	done
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