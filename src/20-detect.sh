# ---------------------------------------------------------------------------
# Environment detection
# ---------------------------------------------------------------------------

# run_checks: verify we are on a supported ROOter 24.10 box (or a test root)
run_checks() {
	[ "$TESTMODE" = 1 ] && { debug "test mode: skipping live env checks"; env_probe; return 0; }

	[ "$(id -u)" = 0 ] || die "must run as root (uid 0) on the router"

	[ -f /etc/openwrt_release ] || die "not an OpenWrt box (/etc/openwrt_release missing)"

	. /etc/openwrt_release

	# 24.10-based only (the TTL nft fix and the preserve/IPv6 fixes are
	# validated on the OpenWrt 24.10 / firewall4 / nftables line).
	case "$DISTRIB_RELEASE" in
		24.*) : ;;
		*) die "unsupported base OpenWrt '$DISTRIB_RELEASE' — this installer targets 24.10 only" ;;
	esac

	[ -d /usr/lib/rooter/connect ] || die "ROOter not detected (/usr/lib/rooter/connect missing)"
	[ -f /usr/lib/rooter/connect/handlettl.sh ] || warn "handlettl.sh not found — TTL fix will no-op"

	# fw4 / nftables needed for the TTL fix (legacy iptables builds unaffected)
	if has_cmd nft; then
		NFT_OK=1
	else
		NFT_OK=0
		warn "nftables (nft) not found — TTL/HL fix skipped (iptables-era build unaffected)"
	fi

	env_probe
}

# modem_iface N -> interface name of modem N ("" if none)
modem_iface() { uciq get modem.modem$1.interface; }

# env_probe: resolve per-box values used by the fixes (modems, zones,
# fw4/nft + kernel IPv6 probing — real AND test mode)
env_probe() {
	# kernel ipv6 device
	if [ -e "$PROCFS/sys/net/ipv6" ]; then
		IPV6_OK=1
	else
		IPV6_OK=0
		warn "kernel IPv6 not visible ($PROCFS/sys/net/ipv6 missing) — IPv6 fix skipped"
	fi

	MODEMS=""            # space-separated modem indices with an interface
	i=1
	while [ "$i" -le 5 ]; do
		iface="$(modem_iface "$i")"
		if [ -n "$iface" ]; then
			MODEMS="$MODEMS $i"
		fi
		i=$((i+1))
	done
	WAN_ZONE=""          # firewall zone section named 'wan'
	z=0
	while :; do
		zn="$(uciq get firewall.@zone[$z].name)"
		[ -z "$zn" ] && break
		if [ "$zn" = "wan" ]; then WAN_ZONE="$z"; break; fi
		z=$((z+1))
	done
	[ -z "$WAN_ZONE" ] && warn "no firewall zone named 'wan' found — IPv6 firewall members/masq6 not applied"
}