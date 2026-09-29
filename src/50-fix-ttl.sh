# ---------------------------------------------------------------------------
# Fix 2: TTL/HL nft syntax (handlettl.sh drop-in)
# The payload engine installs the fixed handlettl.sh (canonical md5
# 4618c693...) when the box carries the broken-nft stock version
# (9a9a287a...). After replacement we re-apply the rules for connected
# modems so the fix takes effect immediately, and verify via nft.
# ---------------------------------------------------------------------------

fix_ttl() {
	printf '\n== TTL/HL ==\n'

	handlettl="$(fmd5 /usr/lib/rooter/connect/handlettl.sh)"
	if [ -z "$handlettl" ]; then
		warn "handlettl.sh missing — cannot apply TTL fix"
		return 0
	fi

	# classify the on-box script (the payload engine just reported above)
	case "$handlettl" in
		4618c693588b30dfb6e0ba2e5af9970b)
			# canonical -> file is current; rules may still need re-apply
			;;
		9a9a287a44bfda16a394e19b4259bf1d)
			note "stock broken-nft handlettl.sh detected — payload engine reports it above"
			if [ "$MODE" = "apply" ]; then
				# re-read md5; if replacement failed, do not re-run an
				# unverified script against the live firewall
				handlettl="$(fmd5 /usr/lib/rooter/connect/handlettl.sh)"
				if [ "$handlettl" != "4618c693588b30dfb6e0ba2e5af9970b" ]; then
					warn "handlettl.sh replacement did not take (md5 $handlettl) — skipping re-apply"
					return 0
				fi
			fi
			;;
		*)
			warn "handlettl.sh is a non-standard variant (md5 $handlettl) — NOT re-running unverified script"
			return 0
			;;
	esac

	# re-apply rules for connected modems so the fix lands without a reboot
	apply_now=""
	i=1
	while [ "$i" -le 5 ]; do
		conn="$(uciq get modem.modem$i.connected)"
		if [ "$conn" = "1" ]; then
			iface="$(modem_iface "$i")"
			if [ -n "$iface" ]; then
				apply_now="$apply_now $i"
			fi
		fi
		i=$((i+1))
	done

	if [ -z "$apply_now" ]; then
		note "no connected modems right now — TTL/HL rules install on next connect"
		return 0
	fi

	for m in $apply_now; do
		if [ "$MODE" = "apply" ] && [ "$TESTMODE" != 1 ]; then
			note "re-applying TTL/HL for modem $m"
			sh "$(rp /usr/lib/rooter/connect/handlettl.sh)" "$m" 2>/dev/null \
				&& ok "handlettl $m re-run OK" \
				|| warn "handlettl $m re-run failed"
		else
			note "would re-apply TTL/HL for modem $m (skipped in test/check mode)"
		fi
	done

	# verify live nft rules (only meaningful on a real box)
	if [ "$MODE" = "apply" ] && [ "$SKIP_NFT" = 0 ] && has_cmd nft; then
		cnt="$(nft list chain inet fw4 mangle_postrouting 2>/dev/null | grep -c 'ttl set')"
		cnt6="$(nft list chain inet fw4 mangle_postrouting 2>/dev/null | grep -c 'hoplimit set')"
		if [ "${cnt:-0}" -ge 1 ] && [ "${cnt6:-0}" -ge 1 ]; then
			ok "nft: TTL ($cnt) + HL ($cnt6) rules live"
		else
			warn "nft shows ttl set:${cnt:-0} hoplimit set:${cnt6:-0} — check connect log"
		fi
	fi
	ok "TTL/HL fix"
}