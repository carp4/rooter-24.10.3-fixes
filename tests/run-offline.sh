#!/bin/sh
# ============================================================================
# run-offline.sh — offline test harness for roo_fix (build artifact test).
#
# Validates the installer against FAKE ROOTS (never touches /, never touches a
# live box):
#   1. builds two fake roots:
#        old-root  = fully-STOCK ROOter 24.10 state synthesized from the
#                    source2410 git HEAD (the 5 scripts at their stock md5s)
#        new-root  = canonical b19 state (flash-staging/b19/rootfs)
#   2. runs ./install.sh --check  -> must be read-only on the fake root
#   3. runs ./install.sh          -> must replace old scripts with canonical
#   4. re-runs ./install.sh       -> idempotent (all already-current)
#   5. runs ./install.sh on new-root -> no-op (all canonical)
#   6. RUNS the generated rollback.sh -> must restore the pre-replace stock
#      state, including filenames containing '_' (a reverse-mapping bug once
#      shipped where rollback restored create_hostless.sh to
#      .../connect/create/hostless.sh)
#
# Env:
#   ROOTUP_WORK=<dir>   scratch dir for fake roots (default tests/.work)
#   ROOTUP_SRC=<source2410 tree>, ROOTUP_FIX19=<b19 rootfs>  override paths
#   ROOTUP_NOBASE64=1   shadow system `base64` with an exit-127 shim across
#                       the whole suite — proves the installer never calls it
#                       (ROOter 24.10 images ship NO base64 binary)
#
# Requires: ./build.sh already run (produces install.sh).
# ============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

WORK="${ROOTUP_WORK:-$HERE/.work}"
SRC="${ROOTUP_SRC:-../../source2410}"
FIX19="${ROOTUP_FIX19:-../../flash-staging/b19/rootfs}"

[ -f ../install.sh ] || { echo "run build.sh first (../install.sh missing)" >&2; exit 1; }
[ -d "$SRC/.git" ] || { echo "source2410 git tree missing: $SRC" >&2; exit 1; }
[ -d "$FIX19" ] || { echo "b19 rootfs fixture missing: $FIX19" >&2; exit 1; }

# the 6 payload destinations (relative paths)
FILES="usr/lib/rooter/connect/create_hostless.sh
usr/lib/rooter/connect/handlettl.sh
usr/lib/rooter/connect/get_profile.sh
usr/lib/lua/luci/model/cbi/rooter/profiles.lua
usr/lib/rooter/luci/restartrun.sh
usr/libexec/luci-mwan3"

# where the STOCK (pre-fix) bytes come from, index-aligned with FILES.
# Either a path inside the source2410 git tree (extracted from git HEAD), or
# "file:<path>" for a checked-in fixture. luci-mwan3 needs the fixture form:
# its fix is patched into the luci feed at HEAD, so git HEAD is no longer the
# stock version we need in order to model a pre-fix box.
SRCF="package/rooter/ext-rooter-basic/files/usr/lib/rooter/connect/create_hostless.sh
package/rooter/ext-rooter-basic/files/usr/lib/rooter/connect/handlettl.sh
package/rooter/ext-rooter-basic/files/usr/lib/rooter/connect/get_profile.sh
package/rooter/ext-rooter-basic/files/usr/lib/lua/luci/model/cbi/rooter/profiles.lua
package/rooter/ext-rooter-basic/files/usr/lib/rooter/luci/restartrun.sh
file:fixtures/stock/luci-mwan3"

CONF="$HERE/../metadata/fingerprints.conf"

# canonical md5 for a payload name, per the fingerprint table
canon_for() { awk -F'|' -v n="$1" '$1==n {print $4}' "$CONF"; }

# materialize the stock (pre-fix) bytes for entry N of FILES into $2
stock_bytes() {
	_idx="$1"; _dest="$2"
	_src="$(printf '%s\n' "$SRCF" | sed -n "${_idx}p")"
	mkdir -p "$(dirname "$_dest")"
	case "$_src" in
		file:*) cp -p "$HERE/${_src#file:}" "$_dest" || return 1 ;;
		*)      git -C "$SRC" show "HEAD:$_src" > "$_dest" 2>/dev/null || return 1 ;;
	esac
}

rm -rf "$WORK"
mkdir -p "$WORK/old-root" "$WORK/new-root"

# ---- old-root: fully stock (pre-fix) --------------------------------
# Record each file's stock md5 HERE, before any test mutates old-root: once
# TEST 2 has installed, old-root holds canonical bytes and can no longer
# tell us what the pre-fix state was.
i=0
: > "$WORK/stock-md5s"
for f in $FILES; do
	i=$((i+1))
	stock_bytes "$i" "$WORK/old-root/$f" || {
		echo "FAIL: cannot obtain stock bytes for $f" >&2; exit 1; }
	md5sum "$WORK/old-root/$f" | cut -d' ' -f1 > "$WORK/stock-md5s.$i"
done

# ---- new-root: canonical --------------------------------------------
# Prefer the b19 fixture — it is canonical for the 5 ROOter payloads. For a
# payload whose fix postdates b19, b19 still carries the pre-fix file, so seed
# from the shipped payload instead; that models a box flashed from a build
# which includes the fix.
for f in $FILES; do
	n="$(basename "$f")"
	canon="$(canon_for "$n")"
	mkdir -p "$WORK/new-root/$(dirname "$f")"
	if [ -f "$FIX19/$f" ] && [ "$(md5sum "$FIX19/$f" | cut -d' ' -f1)" = "$canon" ]; then
		cp -p "$FIX19/$f" "$WORK/new-root/$f"
	elif [ -f "../payloads/$n" ]; then
		cp -p "../payloads/$n" "$WORK/new-root/$f"
		echo "  new-root: $n seeded from payload (canonical in no shipped image yet)"
	else
		echo "FAIL: no canonical source available for $f" >&2; exit 1
	fi
done

# minimal /etc so run_checks is satisfiable in test mode
for r in old-root new-root; do
	mkdir -p "$WORK/$r/etc"
	printf 'DISTRIB_RELEASE="24.10.3"\n' > "$WORK/$r/etc/openwrt_release"
done

# uci stub (test mode): answer the handful of reads the script makes.
# MUST be named `uci` (uciq() runs plain `uci -q ...`); it is prepended to
# PATH by run_install so it shadows any real uci. Consequence: the installer
# uses `uci -q commit` etc., which the stub no-ops (exit 0), so uci-driven
# config is exercised but never persisted — file fingerprints are asserted.
cat > "$WORK/uci" <<'STUB'
#!/bin/sh
# Minimal uci stub for offline tests. Answer just enough for env_probe + fixes:
#   modem.modem1.interface -> usb0 ; modem.modem1.connected -> 1
#   firewall.@zone[0].name -> wan ; network.wan1_6.proto -> dhcpv6
#   network.wan6.proto -> dhcpv6 ; network.lan show -> ok (empty)
#   profile.default.preserve -> 1 ; everything else -> "" (exit 0)
case "$*" in
	*modem.modem1.connected*) echo 1 ;;
	*modem.modem1.interface*) echo usb0 ;;
	*firewall.@zone\[0\].name*) echo wan ;;
	*network.wan6.proto*) echo dhcpv6 ;;
	*network.wan1_6.proto*) echo dhcpv6 ;;
	*network.lan*proto*) echo static ;;
	*profile.default.preserve*) echo 1 ;;
	*) echo "" ;;
esac
exit 0
STUB
chmod +x "$WORK/uci"

# optional no-base64 regime (ROOTUP_NOBASE64=1): shadow system base64 with an
# exit-127 shim across the whole suite — the installer must never call it.
NOB64="${ROOTUP_NOBASE64:-0}"
if [ "$NOB64" = 1 ]; then
	mkdir -p "$WORK/nob64"
	printf '#!/bin/sh\necho "base64: not found" >&2\nexit 127\n' > "$WORK/nob64/base64"
	chmod +x "$WORK/nob64/base64"
	echo "== base64 shadowed (ROOTUP_NOBASE64=1): any base64 use will fail =="
fi

run_install() { # root-dir mode
	r="$1"; mode="$2"
	X=""; [ "$NOB64" = 1 ] && X="$WORK/nob64:"
	PATH="$X$WORK:$PATH" \
	ROOTUP_ROOT="$r" \
	ROOTUP_TEST=1 \
	ROOTUP_SKIP_NFT=1 \
	ROOTUP_PROCFS="/proc" \
	sh ../install.sh "$mode"
}

echo "== fixture fingerprints =="
for f in $FILES; do
	printf '  old  %s  %s\n' "$(md5sum "$WORK/old-root/$f" | cut -d' ' -f1)" "$f"
	printf '  new  %s  %s\n' "$(md5sum "$WORK/new-root/$f" | cut -d' ' -f1)" "$f"
done

echo
echo "== TEST 0: fixtures must be genuinely different =="
same=1
for f in $FILES; do
	o="$(md5sum "$WORK/old-root/$f" | cut -d' ' -f1)"
	n="$(md5sum "$WORK/new-root/$f" | cut -d' ' -f1)"
	# restartrun.sh is canonical in HEAD too -> allowed to match
	[ "$f" = "usr/lib/rooter/luci/restartrun.sh" ] && continue
	[ "$o" = "$n" ] || same=0
done
[ "$same" = 0 ] || { echo "FIXME: old/new fixtures not different (except restartrun)"; exit 1; }
echo "PASS: fixtures are meaningfully different"

echo
echo "== TEST 1: --check must be read-only on old root =="
before1="$(md5sum "$WORK/old-root/usr/lib/rooter/connect/handlettl.sh" | cut -d' ' -f1)"
run_install "$WORK/old-root" --check
after1="$(md5sum "$WORK/old-root/usr/lib/rooter/connect/handlettl.sh" | cut -d' ' -f1)"
[ "$before1" = "$after1" ] || { echo "FAIL: --check modified the fake root"; exit 1; }
[ -d "$WORK/old-root/root" ] && { echo "FAIL: --check created backup dir"; exit 1; }
echo "PASS: --check is read-only"

echo
echo "== TEST 2: install on old root replaces old scripts with canonical =="
run_install "$WORK/old-root" apply > "$WORK/run2.log" 2>&1 || { echo "FAIL: install exited nonzero"; cat "$WORK/run2.log"; exit 1; }
bad=0
for f in $FILES; do
	[ -f "$WORK/old-root/$f" ] || continue
	# canonical comes from the fingerprint table, not the b19 fixture: some
	# payloads are canonical only in builds newer than the newest staged image
	exp="$(canon_for "$(basename "$f")")"
	got="$(md5sum "$WORK/old-root/$f" | cut -d' ' -f1)"
	if [ "$exp" != "$got" ]; then
		echo "  mismatch: $f canonical=$exp got=$got"
		bad=1
	fi
done
[ "$bad" = 1 ] && { echo "FAIL: files not canonical after install"; exit 1; }
ls -d "$WORK/old-root/root"/rooter-upgrade-bk-* >/dev/null 2>&1 || { echo "FAIL: no backup dir created"; exit 1; }
find "$WORK/old-root/root"/rooter-upgrade-bk-* -name rollback.sh | grep -q . || { echo "FAIL: no rollback.sh in backup"; exit 1; }
echo "PASS: old root now canonical + backup/rollback present"

echo
echo "== TEST 3: re-run on old root is idempotent (already current) =="
out="$(run_install "$WORK/old-root" apply)"
printf '%s\n' "$out" | grep -q "already current" || { echo "FAIL: expected 'already current' entries"; printf '%s\n' "$out"; exit 1; }
echo "PASS: idempotent"

echo
echo "== TEST 4: install on new (canonical) root is a no-op =="
out="$(run_install "$WORK/new-root" apply)"
printf '%s\n' "$out" | grep -q "already current" || { echo "FAIL: canonical root should be all-skip"; printf '%s\n' "$out"; exit 1; }
echo "PASS: canonical root no-op"

echo
echo "== TEST 5: generated rollback.sh restores the pre-replace stock state =="
bk="$(ls -d "$WORK/old-root/root"/rooter-upgrade-bk-* 2>/dev/null | head -1)"
[ -n "$bk" ] || { echo "FAIL: no backup dir to roll back"; exit 1; }
[ -s "$bk/manifest" ] || { echo "FAIL: backup dir has no manifest"; exit 1; }
# expected post-rollback md5s, as recorded at fixture-build time
i=0
stock_m5=""
for f in $FILES; do
	i=$((i+1))
	sm="$(cat "$WORK/stock-md5s.$i" 2>/dev/null)"
	[ -n "$sm" ] || { echo "FAIL: no recorded stock md5 for $f"; exit 1; }
	stock_m5="$stock_m5 $f=$sm"
done
# run the real generated rollback.sh against the fake root
PATH="$WORK:$PATH" ROOT_PREFIX="$WORK/old-root" sh "$bk/rollback.sh" > "$WORK/rollback.log" 2>&1 || {
	echo "FAIL: rollback.sh exited nonzero"; cat "$WORK/rollback.log"; exit 1; }
bad=0
for pair in $stock_m5; do
	f="${pair%%=*}"; want="${pair#*=}"
	[ -f "$WORK/old-root/$f" ] || { echo "  missing after rollback: $f"; bad=1; continue; }
	got="$(md5sum "$WORK/old-root/$f" | cut -d' ' -f1)"
	[ "$got" = "$want" ] || { echo "  not restored: $f got=$got want=$want"; bad=1; }
done
[ "$bad" = 1 ] && { echo "FAIL: rollback did not restore stock state"; cat "$WORK/rollback.log"; exit 1; }
echo "PASS: rollback.sh restored all stock files (underscore names intact)"

echo
echo "== TEST 6: mwan3 diag fix — IPv6-aware, and stock is IPv4-only =="
pay=../payloads/luci-mwan3
stk=fixtures/stock/luci-mwan3
[ -f "$pay" ] || { echo "FAIL: payload luci-mwan3 missing"; exit 1; }
# the payload must select the IPv6 forms when an mwan3 interface is family=ipv6
grep -q 'ip -6 rule' "$pay" || { echo "FAIL: payload lacks 'ip -6 rule'"; exit 1; }
grep -q 'ip -6 route list table' "$pay" || { echo "FAIL: payload lacks 'ip -6 route list table'"; exit 1; }
grep -q 'config_get family' "$pay" || { echo "FAIL: payload never reads the mwan3 family option"; exit 1; }
# and the pre-fix stock file must NOT contain them, else there is no bug to fix
if grep -q 'ip -6 rule' "$stk" 2>/dev/null; then
	echo "FAIL: stock fixture already IPv6-aware — fixture/capture drifted"; exit 1
fi
# the upstream GPL attribution must survive the port
grep -q 'Copyright (C) 2021 TDT AG' "$pay" || { echo "FAIL: upstream copyright notice stripped"; exit 1; }
sh -n "$pay" || { echo "FAIL: payload is not valid POSIX sh"; exit 1; }
# stock must be gated as known-old, else a stock box would be REPORT-ONLY
row="$(awk -F'|' '$1=="luci-mwan3" {print $5}' "$CONF")"
stock_m5="$(md5sum "$stk" | cut -d' ' -f1)"
case ",$row," in
	*",$stock_m5,"*) ;;
	*) echo "FAIL: stock md5 $stock_m5 not in known-old set ($row)"; exit 1 ;;
esac
echo "PASS: diag fix is IPv6-aware, gated, attributed, and stock is IPv4-only"

echo
echo "== TEST 7: the mwan3 diag fix actually fixes the reported bug =="
# Drive the real payload with the REAL mwan3 interface list captured from a
# live ROOter 24.10 box, proving an IPv6 member is checked with `ip -6` and
# therefore no longer reports a phantom "missing" verdict. Stubs stand in for
# OpenWrt's config_load/config_get so the shipped logic runs unmodified.
MROOT="$WORK/mwan3diag"
mkdir -p "$MROOT/bin" "$MROOT/lib/functions" "$MROOT/usr/share/libubox" "$MROOT/usr/libexec"
# the payload sources OpenWrt libs at the top; provide empty stand-ins so we
# can execute the SHIPPED logic verbatim instead of a trimmed copy
: > "$MROOT/lib/functions.sh"
: > "$MROOT/lib/functions/network.sh"
: > "$MROOT/usr/share/libubox/jshn.sh"
cat > "$MROOT/bin/ip" <<'STUBIP'
#!/bin/sh
# Minimal ip(8) stub mirroring the REAL state observed on a live ROOter 24.10.
# mwan3 interface order is wan1 (#1, ipv4) then wan1_6 (#2, ipv6), so the
# payload should ask for iif/fwmark 1001/2001 over v4 and 1002/2002 over v6.
# Critically the v4 table has NO 1002/2002 entries and the v6 table has NO
# 1001/2001 ones: that asymmetry is exactly why the pre-fix tool (always v4)
# reported a phantom "Missing" for the IPv6 member.
case "$1" in
	-6)
		shift
		case "$1" in
			rule)  echo "1002:	from all iif usb0 lookup 2"
			       echo "2002:	from all fwmark 0x200/0x3f00 lookup 2" ;;
			route) echo "default via fe80::1 dev usb0 metric 10" ;;
			*) exit 1 ;;
		esac ;;
	rule)
		echo "1001:	from all iif usb0 lookup 1"
		echo "2001:	from all fwmark 0x100/0x3f00 lookup 1" ;;
	route)
		# RFC 5737 / RFC 3849 style placeholder: the payload only greps for
		# the table id, so the exact address is irrelevant to the test.
		echo "default via 198.51.100.1 dev usb0 metric 10" ;;
	*) exit 1 ;;
esac
STUBIP
chmod +x "$MROOT/bin/ip"
# NOTE: no `let` shim. The payload uses `let number++` to derive the mwan3
# interface ordinal, which requires a shell with `let` as a BUILTIN (busybox
# ash has one on the router). An external-script shim runs in its own process
# and cannot mutate the caller's variable, which silently pins number at 0 and
# makes the pre-fix file appear to pass — a false green. TEST 7 therefore runs
# under bash, whose `let` behaves like busybox ash's.
# run the SHIPPED payload's rules+paths with only the OpenWrt shims injected
PATH="$MROOT/bin:$PATH"
# shellcheck disable=SC1090
# The payload hardcodes absolute /lib/... and /usr/share/... sources, and we
# are unprivileged here so chroot is unavailable. Instead build a runnable copy
# in which ONLY those three source lines are redirected at the fakes. The
# diagnostic logic under test (diag_rules / diag_routes) is left byte-for-byte
# identical to the shipped payload, which TEST 6 re-checks with sh -n.
mkdir -p "$MROOT/etc"
sed -e "s#^\. /lib/functions\.sh\$#. $MROOT/lib/functions.sh#" \
    -e "s#^\. /lib/functions/network\.sh\$#. $MROOT/lib/functions/network.sh#" \
    -e "s#^\. /usr/share/libubox/jshn\.sh\$#. $MROOT/usr/share/libubox/jshn.sh#" \
    "$pay" > "$MROOT/luci-mwan3"
chmod +x "$MROOT/luci-mwan3"
# fail loudly if the rewrite did not take (e.g. upstream re-indents the sources)
if grep -q '^\. /lib/functions\.sh$' "$MROOT/luci-mwan3"; then
	echo "FAIL: could not redirect the payload's absolute source lines"; exit 1
fi
cat > "$MROOT/lib/functions.sh" <<'SH'
# Model the REAL mwan3 config on the live ROOter 24.10 box, in on-box order.
# The list below is the verbatim `config_foreach probe interface` output taken
# from that box, so the interface ordinals the payload derives are the true
# ones (wan1_6 is #2, which is why it must look for iif 1002 / fwmark 2002).
#
# Ground truth captured live: the real config_foreach invokes the callback with
# ONLY the section name in $1. So config_foreach must actually call the
# payload's own callback and let its global counter (iface_number / let
# number++) run — a stub that precomputed the index would hide the very bug
# under test.
MWAN3_SECTIONS="wan1 wan1_6 CLAT1 wan2 wan2_6 CLAT2 wan3 wan3_6 CLAT3 wan4
wan4_6 CLAT4 wan5 wan5_6 CLAT5 wan wan6 wwan2 wwan26 wwan5 wwan56 wg0"
config_load() { :; }
config_get() {
	case "$2:$3" in
		*_6:family) eval "$1=ipv6" ;;
		*:family)   eval "$1=ipv4" ;;
		*)          eval "$1=" ;;
	esac
}
config_foreach() { # <callback> <type> [extra-arg-passed-through-by-payload]
	_cb="$1"
	for _s in $MWAN3_SECTIONS; do
		"$_cb" "$_s" "$3"
	done
	return 0
}
SH
out6="$(PATH="$MROOT/bin:$PATH" bash "$MROOT/luci-mwan3" diag rules wan1_6 2>&1)"
out4="$(PATH="$MROOT/bin:$PATH" bash "$MROOT/luci-mwan3" diag rules wan1  2>&1)"
case "$out6" in
	*"All required IP rules"*) ;;
	*) echo "FAIL: IPv6 member still misreported -> $out6"; exit 1 ;;
esac
case "$out6" in
	*"Missing"*) echo "FAIL: IPv6 member still reports 'Missing'"; exit 1 ;;
esac
# IPv4 path must be unchanged by the port
case "$out4" in
	*"All required IP rules"*) ;;
	*) echo "FAIL: IPv4 regression — $out4"; exit 1 ;;
esac
echo "PASS: IPv6 member reports correctly; IPv4 path unregressed"

# Guard against a vacuous test: drive the STOCK file through the identical
# harness and require it to FAIL. If the stock file ever started passing here,
# this test would no longer be evidence of anything.
stockrun() { # $1 = file to exercise, $2 = mwan3 interface to diagnose
	sed -e "s#^\. /lib/functions\.sh\$#. $MROOT/lib/functions.sh#" \
	    -e "s#^\. /lib/functions/network\.sh\$#. $MROOT/lib/functions/network.sh#" \
	    -e "s#^\. /usr/share/libubox/jshn\.sh\$#. $MROOT/usr/share/libubox/jshn.sh#" \
	    "$1" > "$MROOT/probe"
	chmod +x "$MROOT/probe"
	PATH="$MROOT/bin:$PATH" bash "$MROOT/probe" diag rules "$2" 2>&1
}
s6="$(stockrun "$stk" wan1_6)"
case "$s6" in
	*"All required IP rules"*)
		echo "FAIL: stock file passes the check — TEST 7 is vacuous, not a real guard"; exit 1 ;;
	*"Missing"*) : ;;   # expected: this is the bug
	*) echo "FAIL: unexpected stock output: $s6"; exit 1 ;;
esac
# and the stock file must still pass for IPv4 (it was only ever broken for v6)
s4="$(stockrun "$stk" wan1)"
case "$s4" in
	*"All required IP rules"*) ;;
	*) echo "FAIL: stock IPv4 path unexpectedly broken: $s4"; exit 1 ;;
esac
echo "PASS: TEST 7 is discriminating (stock fails IPv6, passes IPv4)"

echo
echo "== ALL OFFLINE TESTS PASSED =="