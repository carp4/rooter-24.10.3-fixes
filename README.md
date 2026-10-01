# roo_fix — live fixes for ROOter 24.10 boxes

One-shot installer that applies six validated fixes to an existing
ROOter 24.10 box **without a reflash**. Targeted at routers built from the
same build ecosystem (OpenWrt 24.10 / firewall4 / nftables base).

## One-liner

Pipe it into `sh` — **do not** use `sh -c "$(curl …)"`. The installer is
~150 KB and the kernel caps any single argument at 128 KiB, so the
`sh -c` form dies with `Argument list too long` on the router. Piping via
stdin has no such limit.

```sh
wget -qO- https://raw.githubusercontent.com/carp4/rooter-24.10.3-fixes/main/install.sh | sh -s
```

Or with `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/carp4/rooter-24.10.3-fixes/main/install.sh | sh -s
```

Prefer to inspect first — the installer ships a read-only audit mode:

```sh
wget -qO- https://raw.githubusercontent.com/carp4/rooter-24.10.3-fixes/main/install.sh | sh -s -- --check
```

Pin a release by swapping `main` for the tag (e.g. `v1.0.1`).

## What it fixes

| # | fix | file(s) | fingerprint-gated |
|---|-----|---------|-------------------|
| 1 | **IPv6 end-to-end** — firewall `wan<N>_6` zone members + `masq6`, LAN `ip6assign/ip6hint/ip6class/multipath`, `wan6` DHCPv6-PD options (`reqprefix 60`, Norelease, metric), odhcpd RA (`ra_default`, `ra_preference`, `piofolder`), mwan3 numeric track targets (no DNS-hostname tracking) | uci config | no (config apply, idempotent) |
| 2 | **TTL/HL nft fix** — `handlettl.sh` emitted invalid nft syntax on fw4 builds so TTL/HL silently did nothing; replaces with the validated six-rule block | `handlettl.sh` | yes |
| 3 | **Already-connected ECM preserve** — when a modem already owns the session, ROOter's connect flow now skips the AT-command takeover + hard reset instead of dropping the link; per-modem `preserve` toggle ("Skip Connection Script for Hostless Modem if Already Connected", default **Yes**) | `create_hostless.sh`, `get_profile.sh`, `profiles.lua` | yes |
| 4 | **mwan3 IPv6 diagnostics** — LuCI → mwan3 → Diagnostics reported a phantom "Missing fwmark and iif IP rule" and "Routing table not found" for every `wan<N>_6` member, because the upstream `luci-mwan3` helper always used the IPv4-only `ip rule` / `ip route list table N`. Now selects the `ip -6` forms for mwan3 interfaces with `family=ipv6` | `luci-mwan3` | yes |
| 5 | **mwan3track stale IPv6 source pin** — the tracker pinned one IPv6 source address for the life of the process while the carrier rotated the delegated /64, so every track target then failed with `failed to bind to ip address: Address not available` and the member showed 100% loss on a perfectly healthy link. The patched tracker re-derives its source in place, no restart needed | `mwan3track` | yes |
| 6 | **mwan3 IPv6 conntrack churn** — stock sets `flush_conntrack` to `connected disconnected ifup ifdown` on every member, and `connected`/`disconnected` fire on tracker churn during a prefix rotation, flushing conntrack and killing every live LAN session. IPv6 members drop to `ifup ifdown` (a real link transition still fires those); IPv4 members are left alone | uci config | no (config apply, idempotent) |

Fix 4 is a **diagnostic** fix, not a connectivity fix: it corrects what the
LuCI page reports. It does not change routing or firewall behaviour. Upstream
bug is in `luci-app-mwan3`'s `/usr/libexec/luci-mwan3`; the original
copyright notice is preserved.

### Fixes 5 and 6 need activation

The other six payloads take effect the next time they are invoked — they are
per-call AT/LuCI handlers or CBI models that are re-read on each use. The
`mwan3track` script is a **spawned process holding the code it started with**,
so replacing its bytes on disk changes nothing until it respawns. Likewise a
committed `flush_conntrack` change is not applied until mwan3 re-reads it.

`roo_fix` therefore restarts mwan3 (`svc mwan3 reload`) when, and only when,
the run actually changed mwan3 config or replaced the tracker. Gating it
unconditionally would bounce WAN tracking on every member on every run; not
gating it at all would leave both fixes dormant. `--check` reports the pending
restart without performing it.

### What fix 6 does *not* do

Fix 6 removes the `connected`/`disconnected` flush events. It does **not**
write `ifup ifdown` onto every IPv6 member: a member that had no
`flush_conntrack` list at all keeps having none, and a member trimmed down to
the churn events alone ends up with no list. Only the churn events are the
defect, so only they are removed — the link-transition events a member already
had are preserved. Forcing a list onto a member would add conntrack flushing
nobody asked for, which is a behaviour change disguised as a repair.

### A third IPv6 failure mode is *not* covered here

There are three distinct ways an IPv6 member goes "down" against a link that
is fine, and this tool only addresses two of them:

| mode | mechanism | covered by |
|---|---|---|
| stale source pin, a live address available | tracker pinned a source the carrier rotated away | fix 5 |
| rotation churn flushing conntrack | `connected`/`disconnected` on tracker churn | fix 6 |
| **last prefix withdrawn, netifd unaware** | kernel has no global, netifd still reports the interface up | **nothing here** |

The third mode needs an interface cycle so `odhcp6c` re-solicits DHCPv6; a
config or payload change cannot do it, and restarting the tracker cannot help
because there is no address left to bind to. That mechanism ships in the
firmware as `/etc/hotplug.d/iface/50-z8102-wan6-mwan3`, which is part of the
build tree and not part of the ofmodemsandmen vendor baseline — so it is
deliberately **not** a `roo_fix` payload. A box only gets it by flashing
newer firmware.

### Member discovery, not a fixed list

Neither fix names a member. `wan<N>_6` sections come and go with the "Multiple
Modems" setting (`maxmodem.maxmodem.maxmodem`), which the operator can change at
runtime, so a 4-modem box and an 8-modem box have different member sets. The
members are enumerated live: named sections of type `interface` whose `family`
matches. Two conditions are both required — filtering on `family` alone also
matches policy rules such as `rule_v6`, which is a `rule`, not an `interface`.

Each file is **fingerprint-gated** into one of three behaviors:

- on-box md5 == **canonical** → skip (idempotent; re-running is a no-op)
- on-box md5 in the **known-old** set → replace with the canonical payload (backup first)
- anything else → **report-only** (backed up and left alone — never mangled)

## Behavior

- Single self-contained POSIX-sh script — payloads embedded at build time,
  no network fetch at runtime beyond the one-liner itself. Busybox-safe.
- **Auto-backup**: before any change, the touched packages are exported
  (`uci export`) and replaced files are copied into
  `/root/rooter-upgrade-bk-<timestamp>/`, including a **`rollback.sh`** that
  restores files + config.
- `--check` = read-only audit; prints exactly what it would change.
- Requires **root** on the router and OpenWrt **24.10** (fw4/nftables).
  Legacy iptables builds exit with a clear unsupported message.

## Build (maintainers)

```sh
./build.sh          # validates payloads against metadata/fingerprints.conf,
                    # embeds them, writes ./install.sh (+ .md5)
```

## Test

See `tests/run-offline.sh` — runs the installer against fake roots (stock
state synthesized from source `HEAD`, canonical state from the reference
rootfs) to validate the replace path, idempotency, and audit mode. Never
touches `/` or a live box.

Twelve tests. The load-bearing ones are not "does it run" but "would this
notice if the fix stopped working":

- **8** extracts the shipped tracker's own `refresh_src_ip` and runs it
  against stubbed `ip`/`ping`, then asserts the **stock** file fails the same
  harness. If stock ever passed, the test would prove nothing.
- **9** requires member enumeration by name and excludes `rule_v6`, which is
  `family=ipv6` but is a policy rule, not an interface.
- **12** requires the flush fix to remove churn *without inventing flushing* —
  a member with no `flush_conntrack` must not be modified at all.

Stock-vs-canonical bytes come from **checked-in fixtures** under
`tests/fixtures/stock/`, not from `git HEAD`. The tree files are frequently
uncommitted working state, so `HEAD` would hand the test the already-fixed
version and every assertion would be vacuous.

## Changelog

### v1.1.3

- Fix 6 narrowed: remove only the `connected`/`disconnected` flush events.
  Previously any IPv6 member missing `ifup`/`ifdown` was rewritten to
  `ifup ifdown`, which *added* conntrack flushing to a member that had opted
  out of flushing entirely. Covered by the new test 12.
- `mwan3track` payload refreshed from the build tree; `cands` is now declared
  `local` in `refresh_src_ip`. `89888f33…` added to the known-old set so a box
  already carrying v2.2 is upgraded rather than reported unknown.
- `build.sh` had two sources of truth for the version and a `sed` that only
  matched the literal `1.1.0`. Bumping the version by editing the header — the
  natural way — silently no-op'd the stamp while the build went on *reporting*
  `1.1.0` for a later artifact. The header is now the single source of truth,
  and the build fails if the artifact's version differs from the one reported.

### v1.1.0

- Fix 4: IPv6-aware mwan3 diagnostics.

## Scope / caveats

- Targets ROOter 24.10 boxes built from this ecosystem. It is **not**
  validated on arbitrary other ROOter builds or OpenWrt releases; those exit
  unsupported.
- Firewall/network services are restarted when config changes are applied
  (brief session interruption on a live box — same as any ROOter connect
  cycle).
- For a full revert, flash a stock image — the backup/rollback path is for
  config-and-script reversion only.

## License

MIT. Contributions welcome.