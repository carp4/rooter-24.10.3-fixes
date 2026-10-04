# roo_fix — live fixes for ROOter 24.10 boxes

One-shot installer that applies seven validated fixes to an existing
ROOter 24.10 box **without a reflash**. Targeted at routers built from the
same build ecosystem (GoldenOrb 24.10.3 AutoBuild Firmware). The main goal
of this project was to fix problems that prevented Quectel modems in ECM to
work properly with IPV6 and mwan3. This allows modems that have MBN
automatic selection turned on or are running a management GUI inside the
modem (QManager or SimpleAdmin) to work without rooter changing settings
like APN.

## How to install

Pipe it into `sh` — **do not** use `sh -c "$(curl …)"`. The installer is
~200 KB and the kernel caps any single argument at 128 KiB, so the
`sh -c` form dies with `Argument list too long` on the router. Piping via
stdin has no such limit.

```sh
wget -qO- https://raw.githubusercontent.com/carp4/rooter-24.10.3-fixes/main/install.sh | sh -s
```

Or with `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/carp4/rooter-24.10.3-fixes/main/install.sh | sh -s
```

Prefer to inspect first — the installer ships a read-only audit mode that
changes nothing and prints exactly what it would do:

```sh
wget -qO- https://raw.githubusercontent.com/carp4/rooter-24.10.3-fixes/main/install.sh | sh -s -- --check
```

Pin a release by swapping `main` for a tag, e.g. `v1.4.0`.

Requirements: **root** on the router, and OpenWrt **24.10** (fw4/nftables).
Legacy iptables builds exit with a clear unsupported message.

There is no second step. The installer backs up what it touches to
`/root/rooter-upgrade-bk-<timestamp>/` — including a `rollback.sh` that
restores it — and rewrites config and scripts in one pass.

## What it fixes

| # | fix | file(s) |
|---|-----|---------|
| 1 | **IPv6 end-to-end** — firewall `wan<N>_6` zone members + `masq6`, LAN `ip6assign/ip6hint/ip6class/multipath`, `wan6` DHCPv6-PD options, odhcpd RA, mwan3 numeric track targets | uci config |
| 2 | **TTL/HL nft fix** — `handlettl.sh` emitted invalid nft syntax on fw4 builds, so TTL/HL silently did nothing | `handlettl.sh` |
| 3 | **Already-connected ECM preserve** — when a modem already owns the session, ROOter's connect flow skips the AT takeover + hard reset instead of dropping the link | `create_hostless.sh`, `get_profile.sh`, `profiles.lua`, `restartrun.sh` |
| 4 | **mwan3 IPv6 diagnostics** — LuCI reported a phantom "Missing fwmark" / "Routing table not found" for every `wan<N>_6` member, because the upstream helper always used the IPv4-only `ip rule` | `luci-mwan3` |
| 5 | **mwan3 stale IPv6 source pin** — the tracker pinned one IPv6 source for the life of the process while the carrier rotated the delegated /64, so every track target failed with `Address not available` on a healthy link | `mwan3track` |
| 6 | **mwan3 conntrack churn** — stock flushed conntrack on `connected`/`disconnected`, which fire on tracker churn during a prefix rotation and kill every live session on the box | uci config |
| 7 | **Withdrawal recovery** — when the carrier withdraws the last delegated prefix the kernel has no global address but netifd still reports the interface up, so nothing re-solicits DHCPv6 | `50-z8102-wan6-mwan3` |

Three things worth knowing before you apply it:

- **Fix 4 is a diagnostic fix.** It corrects what the LuCI page reports; it
  does not change routing or firewall behaviour.
- **Fixes 5 and 6 need mwan3 to restart, and roo_fix restarts it for you** —
  automatically, and only when the run actually changed something those two
  fixes depend on. On a live box that briefly interrupts WAN tracking.
- **Fix 6 is applied to every member, v4 included, on purpose.** The flush is
  router-global, so one member's false churn event costs every other member
  its sessions. Fix 6 also never *adds* flushing to a member that had none.

Every file is fingerprint-gated: matching bytes are skipped, recognised older
bytes are replaced, and **anything unrecognised is reported and left alone** —
never mangled. Members are discovered live, not hardcoded.

`DETAILS.md` has the reasoning behind each fix, the maintainer build/test
instructions, and the changelog.

## License

MIT. Contributions welcome.