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

	# --- firewall: rebuild the wan zone membership, masq6 1 ---
	fix_wan_zone

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

	# --- mwan3: no member may flush conntrack on tracker churn (all members) ---
	fix_mwan3_flush

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

# ---------------------------------------------------------------------------
# Wan zone membership: REBUILD, do not append.
#
# The defect this replaces
# -----------------------
# ROOter's own first-boot script /usr/lib/rooter/initialize.sh do_zone() does:
#
#     config_get network $1 network
#     newnet=$network
#     ...  newnet="$newnet wan$COUNTER"  (loop, hardcoded to 5)
#     uci_set firewall "$config" network "$newnet"
#
# uci_set is a bare `uci set` (lib/config/uci.sh:78) with no quoting, and
# `uci set` does NOT split whitespace on a list option. The result is a
# SINGLE list element holding a space-separated string:
#
#     list network 'wan wan6 wan1 wan2 wan3 wan4 wan5 wwan2 wwan5'
#
# fw4 looks up each list element as one network name. There is no network
# called "wan wan6 wan1 ...", so the element resolves to NOTHING and is
# dropped. Verified on the reference box: the only wan-zone device in the
# rendered nft ruleset was usb1, and it was there only because roo_fix had
# appended a properly-formed `list network 'wan2_6'`. eth1 (the box's own
# wan/wan6) and usb0 (wan1) were in no zone at all, falling through to
# `jump handle_reject`.
#
# The previous version of this fix APPENDED wan<N>_6 entries, which both
# inherited the hardcoded 5 and could never repair the collapsed string.
#
# Why delete-then-rebuild
# -----------------------
# Delete-then-rebuild is idempotent AND self-repairing: a string built by the
# old code is replaced outright rather than skipped. The original do_zone()
# guard (`echo $network | grep wan1`) matches its OWN output, so on any box
# where it has already run it can never run again -- which is precisely why a
# fresh flash is the only thing that currently clears this. Rebuilding is
# also order-stable, so re-running this installer produces no diff.
#
# Modem count is read from maxmodem.maxmodem.maxmodem rather than hardcoded,
# matching the pattern already used a few lines away in initialize.sh (which
# loops `while [ $COUNTER -le $MODCNT ]` to CREATE wan<N>). maxmodem is only
# READ here: this installer never writes it.
#
# The upper clamp is what keeps the CEILING meaningful. initialize.sh keeps a
# second loop, hardcoded to 5, that deletes stale network.wan<N>/wan<N>_6
# sections left over from a previously-larger setting; that loop must stay at
# the true maximum. maxmodem.sh does no validation, so an operator can set
# anything at all through the LuCI XHR endpoint; clamping here keeps a bogus
# value from generating wan6..wan99 zone members no hardware backs.
# ---------------------------------------------------------------------------

# ROOter's "Multiple Modems" ceiling, as offered by the LuCI select in
# /usr/lib/lua/luci/view/rooter/multimodem.htm (1..5).
MAXMODEM_CEILING=5

# modem_count: the box's configured maximum modem count, clamped to
# 1..MAXMODEM_CEILING. Falls back to 2 (ROOter's own non-mwan3 default) on
# anything missing or non-numeric.
modem_count() {
	_mc="$(uciq get maxmodem.maxmodem.maxmodem)"
	case "$_mc" in
		''|*[!0-9]*) _mc=2 ;;
	esac
	[ "$_mc" -lt 1 ] && _mc=1
	[ "$_mc" -gt "$MAXMODEM_CEILING" ] && _mc="$MAXMODEM_CEILING"
	printf '%s' "$_mc"
}

# The wan zone's network list as discrete tokens.
#
# `uci get` on a list returns space-separated values, and word-splitting on
# whitespace turns BOTH the correct form ('wan wan6' -> two tokens) and the
# collapsed form ('wan wan6 wan1' -> also two tokens, but the second one is
# not a network name) back into a token list. So a plain token comparison
# cannot tell a healthy zone from a broken one -- hence the rebuild.
wan_zone_tokens() {
	uciq get "firewall.@zone[$WAN_ZONE].network" 2>/dev/null
}

# norm: collapse runs of whitespace and trim, so a token-list comparison is
# insensitive to how uci happens to render it.
norm() { printf '%s' "$*" | tr -s ' \t\n' ' ' | sed 's/^ *//;s/ *$//'; }

fix_wan_zone() {
	if [ -z "$WAN_ZONE" ]; then
		debug "no wan zone resolved — firewall part skipped"
		return 0
	fi

	_mc="$(modem_count)"

	# Desired membership, in order:
	#   wan / wan6            -- the box's own upstream (eth1); always present
	#   wan<N> / wan<N>_6     -- one pair per configured modem slot, N=1..maxmodem
	#   wwan2 / wwan5         -- the wifi-hotspot-as-wan interfaces, always present
	#
	# This is the 25.12 gold SHAPE (z8102-custom-config 93-firewall-config:
	#   add_list ...network='wan' / 'wan6' / 'wan1' / 'wan1_6' / 'wan2' / 'wan2_6')
	# with membership computed instead of listed. The gold hardcodes six
	# members because the Z8102 topology is a known two-modem box; ROOter
	# cannot, because the modem count is a runtime setting and sizing itself
	# to it is the whole purpose of do_zone(). So the structure is matched,
	# the list is derived.
	#
	# wwan2/wwan5 are added UNCONDITIONALLY, matching the stock do_zone() output
	# on the reference box and matching initialize.sh's own construction. They
	# are not filtered on the network existing, because on a ROOter box they do.
	#
	# Variable names are prefixed because this installer is ONE flat namespace:
	# `n`, `z` and `i` are already used by 50-fix-ttl.sh, 60-fix-preserve.sh,
	# 70-main.sh and 20-detect.sh, and there is no `local` in POSIX sh here.
	WZ_WANT="wan wan6"
	WZ_I=1
	while [ "$WZ_I" -le "$_mc" ]; do
		WZ_WANT="$WZ_WANT wan$WZ_I wan${WZ_I}_6"
		WZ_I=$((WZ_I+1))
	done
	WZ_WANT="$WZ_WANT wwan2 wwan5"

	WZ_HAVE="$(wan_zone_tokens)"

	# Compare as whitespace-collapsed token strings. Order is deterministic on
	# both sides, so a match means "already correct" and re-running is a no-op.
	if [ "$(norm "$WZ_HAVE")" = "$(norm "$WZ_WANT")" ]; then
		debug "wan zone membership already correct ($_mc modem slots)"
	else
		note "firewall: rebuilding wan zone network list (maxmodem=$_mc)"
		note "firewall:   from: $WZ_HAVE"
		note "firewall:   to:   $WZ_WANT"
		if [ "$MODE" = "apply" ]; then
			# delete the whole option -- this is what removes the collapsed
			# single-element string. add_list then creates it back as discrete
			# entries, which is what fw4 can actually resolve. uciq already
			# passes -q, so a missing option stays silent.
			uciq delete "firewall.@zone[$WAN_ZONE].network" 2>/dev/null
			for WZ_N in $WZ_WANT; do
				uciq add_list "firewall.@zone[$WAN_ZONE].network=$WZ_N"
			done
			need_reload=1
		fi
	fi

	# masq6 (IPv6 NAT) — kept. This is NOT part of the collapsed-string
	# defect; it is a separate scalar option, so the string bug never
	# touched it. Present in the 25.12 gold
	# (z8102-custom-config 93-firewall-config line 60:
	#   set firewall.@zone[-1].masq6='1')
	# and in our initialize.sh since commit 713ee9db, which aligned it.
	z="$WAN_ZONE"
	mq="$(uciq get firewall.@zone[$z].masq6)"
	if [ "$mq" != "1" ]; then
		note "firewall: setting masq6 1 on wan zone"
		if [ "$MODE" = "apply" ]; then
			uciq set firewall.@zone[$z].masq6="1"
			need_reload=1
		fi
	fi

	# wan forward policy: REJECT -> DROP.
	#
	# Divergence from the 25.12 gold, verified live on the reference box
	# (wan zone @zone[1] had forward=REJECT while the gold sets DROP).
	# This is inherited from the stock OpenWrt firewall4 default, not
	# something ROOter chose, so it is a genuine alignment gap rather than
	# a bug in ROOter's script.
	#
	# Deliberately NOT bundled with the zone-membership rebuild: membership
	# fixes which interfaces are zoned, this changes what the zone DOES with
	# them. Separate concerns, so one run should be able to attribute any
	# behaviour change to one of them.
	fw="$(uciq get firewall.@zone[$z].forward)"
	if [ "$fw" = "REJECT" ]; then
		note "firewall: wan zone forward REJECT -> DROP (25.12 parity)"
		if [ "$MODE" = "apply" ]; then
			uciq set firewall.@zone[$z].forward="DROP"
			need_reload=1
		fi
	fi
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
#
# With no argument (or the literal 'all') every interface section is listed,
# regardless of family. Callers that only want one family still pass it.
mwan3_members() {
	want_family="$1"
	uciq show mwan3 2>/dev/null \
		| sed -n "s/^mwan3\.\([^.=]*\)=interface\$/\1/p" \
		| while read -r sec; do
			if [ -z "$want_family" ] || [ "$want_family" = all ]; then
				echo "$sec"
			elif [ "$(uciq get "mwan3.$sec.family" 2>/dev/null)" = "$want_family" ]; then
				echo "$sec"
			fi
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

# mwan3 members: drop conntrack flushes on the tracker's own
# connected/disconnected events.
#
# The stock baseline sets, on every member:
#     flush_conntrack = connected disconnected ifup ifdown
#
# mwan3_flush_conntrack() performs `echo f > nf_conntrack_flush`, which is a
# GLOBAL kernel flush, not a per-member one -- the interface argument only
# selects whose list is tested, but on a match the whole conntrack table is
# wiped for the entire router. So one member's mistaken event costs every
# OTHER member its live sessions too, and there is no "only the v6 legs are
# sensitive" nuance to preserve.
#
# The two remaining events split cleanly by source of truth:
#     ifup / ifdown    -> the kernel really changed the link. Trustworthy.
#     connected /
#     disconnected     -> mwan3track's ping opinion. Fallible, and routinely
#                         wrong here: the carrier rotates the delegated /64 on
#                         renew, so the tracker can fail ALL targets mid-
#                         rotation while the link is perfectly fine.
#
# Hence ONE rule for EVERY member, v4 and v6 alike: keep only the events the
# member already had among ifup/ifdown. netifd still fires those on a genuine
# link transition, so real outages are still covered, and not flushing on a
# real transition only leaves stale NAT that ages out on its own within
# minutes -- whereas flushing on a false one drops every live session.
fix_mwan3_flush() {
	for sec in $(mwan3_members); do
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