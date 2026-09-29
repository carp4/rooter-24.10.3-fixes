# roo_fix — live fixes for ROOter 24.10 boxes

One-shot installer that applies four validated fixes to an existing
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

Fix 4 is a **diagnostic** fix, not a connectivity fix: it corrects what the
LuCI page reports. It does not change routing or firewall behaviour. Upstream
bug is in `luci-app-mwan3`'s `/usr/libexec/luci-mwan3`; the original
copyright notice is preserved.

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