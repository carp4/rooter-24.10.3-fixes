# Offline tests — roo_fix

`run-offline.sh` validates the BUILT artifact (`../install.sh`) against FAKE
roots. It never touches `/`, never touches a live box, and never executes the
installer's live paths (test mode env stubs keep every fix in
dry-run/report shape).

## What it does

1. Synthesizes two fake router roots under `tests/.work/`:
   - `old-root/` — fully **stock** ROOter 24.10 state pulled from the
     `source2410` git `HEAD` (all 5 scripts at their stock md5s)
   - `new-root/` — **canonical** b19 state copied from
     `flash-staging/b19/rootfs`
2. Runs the installer against each with these env overrides:
   - `ROOTUP_ROOT=<fake-root>` — all filesystem reads/writes land in the fake root
   - `ROOTUP_TEST=1` — skips live env checks (release file, uid, real uci)
   - `ROOTUP_SKIP_NFT=1` — no live nft verification
   - `ROOTUP_PROCFS=/proc` — lets the IPv6 kernel check pass on the host
   - `PATH` includes `tests/.work/` with a **`uci` stub** that answers the
     handful of config reads the script makes (modem presence, firewall zone,
     wan6 proto, preserve toggle). `uciq()` runs plain `uci -q`, so the stub
     must be named `uci` to shadow any real one.

## Test matrix

| # | scenario | asserts |
|---|----------|---------|
| 0 | fixtures differ | old-root ≠ new-root (except `restartrun.sh`, canonical in HEAD too) |
| 1 | `--check` on old root | read-only: no file change, no backup dir created |
| 2 | apply on old root | all 5 files end up canonical md5; backup dir + `rollback.sh` created |
| 3 | re-apply on old root | idempotent — "already current" |
| 4 | apply on new root | no-op — all canonical, "already current" |
| 5 | rollback | generated `rollback.sh` restores the pre-replace stock state |
| 6 | mwan3 diag fix | IPv6-aware, gated, attributed; stock file is IPv4-only |
| 7 | mwan3 diag fix | the reported bug is actually fixed — and stock FAILS the same harness |
| 8 | `mwan3track` fix | recovers a stale ipv6 source pin; stock has no such logic |
| 9 | member discovery | members found by name, `rule_v6` excluded, ipv4 untouched |
| 10 | activation gate | intent reported in `--check`, executed only in apply |
| 11 | discovery vs hardcoding | member set follows the box, nothing baked in |
| 12 | v6 flush fix | churn removed; `ifup`/`ifdown` never invented; churn-only ends empty |
| 13 | hotplug absent | **created**, canonical bytes, mode 755 — the stock-flash case |
| 14 | hotplug canonical | skipped; re-run is a no-op |
| 15 | hotplug known-old | both real prior revisions (r10, r9) replaced |
| 16 | hotplug unknown | report-only — an unrecognised fingerprint is never overwritten |
| 17 | flavour safety | the 7 payloads without `install-if-missing=1` still skip when absent |
| 18 | real stock config | 8/8 ipv6 → `ifup ifdown`, 14/14 ipv4 untouched, hostnames → numerics |
| 19 | unpopulated slots | members with no modem present are trimmed too, deliberately |
| 20 | stock-image coverage | **no** payload is report-only against the real stock image |

Tests 13 and 17 are guards against opposite mistakes: 13 fails if
`install-if-missing` is dropped, 17 fails if it is widened to a global
"missing means install" policy (which would put mwan3 binaries into non-MWAN3
firmware). Both were negative-controlled before being trusted.

Test 20 exists because of a bug found on hardware, not in the abstract. The
fingerprint table was built from "b16 stock / b18-era" bytes, but the
`MWAN3 GO2026-04-25` image ships different stock bytes for `create_hostless.sh`
and `restartrun.sh`. Both fell through to report-only, so `--apply` would have
shipped **5 of 7** payloads, left fix 3 half-installed, and still exited 0
printing "Done." A partial fix that reports success is worse than no fix. Test
20 seeds a root from the image's own bytes and fails on any report-only
outcome; removing either md5 makes it fail and name the payload.

Test 18 and 19 use `fixtures/stock/config-mwan3`, the **real shipped**
`/etc/config/mwan3` (18,540 bytes, md5 `65b6b267311285a08df917d192731f0a`)
lifted verbatim out of `ZBT-Z8102AX-V2-MWAN3-GO2026-04-25-upgrade.bin`. It
holds all 22 members because that file is static — modem count sizes
`/etc/config/network`, not this.

## Run

From the `rooter-live-fixes/` directory (paths are relative to `tests/`):

```sh
sh tests/run-offline.sh
```

Optional overrides (useful on other machines):

```sh
ROOTUP_WORK=/tmp/opencode/roofix-test \
ROOTUP_SRC=/abs/path/source2410 \
ROOTUP_FIX19=/abs/path/flash-staging/b19/rootfs \
sh tests/run-offline.sh
```

`tests/.work/` is scratch — created fresh on every run, never committed.

## Why these env hooks exist

They are the SAFETY rails that let the artifact be exercised offline:

- `ROOTUP_ROOT` — redirects `rp()` (root-path helper) so `fmd5`, `cp`,
  `mkdir`, and backup paths all stay inside the fake root.
- `ROOTUP_TEST` — `run_checks()` short-circuits (no uid/release checks),
  `svc()` becomes a no-op, and the TTL re-apply prints "would re-apply"
  instead of running scripts.
- `ROOTUP_SKIP_NFT` — suppresses live `nft list` verification on the host.
- `ROOTUP_PROCFS` — points the kernel-IPv6 probe at a real procfs when the
  host isn't a router.

None of these degrade the artifact on a real box: they default to live
behavior (`ROOT`=`/`, test off, skip-nft off, procfs `/proc`) and only take
effect when explicitly exported before invoking `install.sh`.

## What offline tests do NOT prove (live go-ahead needed)

- Real `uci` commit/apply behavior and firewall/network/odhcpd service
  reloads (`svc()` is stubbed to no-op).
- Actual nft rule installation from the fixed `handlettl.sh`.
- That the withdrawal hotplug actually fires on a real `ifupdate` event and
  recovers the member. Test 13 only proves the bytes land in the right place
  with the right mode; the mechanism was validated separately against a real
  carrier withdrawal on 2026-10-02.
- Boxes carrying an UNKNOWN md5 variant other than the synthetic one in
  test 16 (report-only path) — needs a real box in the fleet.

## Fixtures

| path | provenance |
|------|-----------|
| `fixtures/stock/{create_hostless,handlettl,get_profile}.sh` | byte-identical to the file in `ZBT-Z8102AX-V2-MWAN3-GO2026-04-25-upgrade.bin` |
| `fixtures/stock/profiles.lua` | byte-identical to the file in the same image |
| `fixtures/stock/restartrun.sh` | byte-identical to the file in the same image |
| `fixtures/stock/luci-mwan3` | byte-identical to the file in the same image |
| `fixtures/stock/mwan3track` | byte-identical to the file in the same image |
| `fixtures/stock/config-mwan3` | byte-identical to `/etc/config/mwan3` in the same image |
| `fixtures/oldhp/r10` | the real r10 hook, extracted from `source2410` git `7340af0f` |
| `fixtures/oldhp/r9` | the real r9 hook, extracted from `source2410` git `f5cda0be` |

Every fixture is genuine bytes. Synthetic stand-ins cannot carry a chosen md5,
so a fabricated "old" file would either miss the fingerprint or accidentally
hit it — either way it would prove nothing.

There is deliberately **no** stock fixture for the withdrawal hotplug: stock
ships no such file, which is what `install-if-missing=1` exists to handle.