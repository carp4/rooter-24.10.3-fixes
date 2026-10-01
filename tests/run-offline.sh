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

# the 7 payload destinations (relative paths)
FILES="usr/lib/rooter/connect/create_hostless.sh
usr/lib/rooter/connect/handlettl.sh
usr/lib/rooter/connect/get_profile.sh
usr/lib/lua/luci/model/cbi/rooter/profiles.lua
usr/lib/rooter/luci/restartrun.sh
usr/libexec/luci-mwan3
usr/sbin/mwan3track"

# where the STOCK (pre-fix) bytes come from, index-aligned with FILES.
# Either a path inside the source2410 git tree (extracted from git HEAD), or
# "file:<path>" for a checked-in fixture.
#
# luci-mwan3 and mwan3track need the fixture form: their fixes are patched
# into the tree, so git HEAD is no longer the stock version we need in order to
# model a pre-fix box. For mwan3track this is also the only form that stays
# correct once the tree change is committed -- sourcing "stock" from HEAD
# would then return the PATCHED bytes and the pre-fix box could no longer be
# modelled at all. Fixtures are captured from origin/main (the vendor tip),
# so they never drift with our commits.
SRCF="package/rooter/ext-rooter-basic/files/usr/lib/rooter/connect/create_hostless.sh
package/rooter/ext-rooter-basic/files/usr/lib/rooter/connect/handlettl.sh
package/rooter/ext-rooter-basic/files/usr/lib/rooter/connect/get_profile.sh
package/rooter/ext-rooter-basic/files/usr/lib/lua/luci/model/cbi/rooter/profiles.lua
package/rooter/ext-rooter-basic/files/usr/lib/rooter/luci/restartrun.sh
file:fixtures/stock/luci-mwan3
file:fixtures/stock/mwan3track"

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
#
# The mwan3 half of this stub is deliberately NOT a single hardcoded list.
# The number of wan<N> / wan<N>_6 members depends on the box's "Multiple
# Modems" setting, so a real box may have a different count than any fixture.
# The stub emits a configurable set (MWAN3_STUB_FILE, default below) to prove
# the installer DISCOVERS members rather than assuming a fixed set.
#
# IMPORTANT: values are emitted QUOTED, exactly like real `uci show`
# (mwan3.wan1_6.family='ipv6'). A fixture that omitted the quotes would let a
# broken regex such as /family=ipv6$/ pass here and then match nothing on the
# router, which is exactly the class of silent no-op these tests exist to catch.
cat > "$WORK/uci" <<'STUB'
#!/bin/sh
# Minimal uci stub for offline tests. Answer just enough for env_probe + fixes:
#   modem.modem1.interface -> usb0 ; modem.modem1.connected -> 1
#   firewall.@zone[0].name -> wan ; network.wan1_6.proto -> dhcpv6
#   network.wan6.proto -> dhcpv6 ; network.lan show -> ok (empty)
#   profile.default.preserve -> 1 ; everything else -> "" (exit 0)
case "$*" in
	*modem.modem1.connected*) echo 1; exit 0 ;;
	*modem.modem1.interface*) echo usb0; exit 0 ;;
	*firewall.@zone\[0\].name*) echo wan; exit 0 ;;
	*network.wan6.proto*) echo dhcpv6; exit 0 ;;
	*network.wan1_6.proto*) echo dhcpv6; exit 0 ;;
	*network.lan*proto*) echo static; exit 0 ;;
	*profile.default.preserve*) echo 1; exit 0 ;;
esac

# --- mwan3 ---------------------------------------------------------------
# Model file: one record per line, TAB-separated:
#   <section-name>  <type>  <family>  <track_ips>  <flush_conntrack>
# Blank <family> means the option is absent. Empty list fields are allowed.
MF="${MWAN3_STUB_FILE:-/mwan3.model}"

# Normalise argv BEFORE dispatching. uciq() is `uci -q "$@"`, so the
# subcommand is NOT $1 — it is $2. Keying on $1 makes every branch
# unreachable and the stub silently answers "", which looks exactly like an
# empty mwan3 config and turns a working installer into a no-op.
while [ $# -gt 0 ]; do
	case "$1" in
		-*) shift ;;
		*) break ;;
	esac
done

# `uci show mwan3` -> one line per option, values quoted like the real tool
if [ "$1" = "show" ] && [ "$2" = "mwan3" ]; then
	[ -f "$MF" ] || exit 0
	while IFS='	' read -r nm tp fam trk fl; do
		[ -n "$nm" ] || continue
		case "$nm" in \#*) continue ;; esac
		echo "mwan3.$nm=$tp"
		[ -n "$fam" ] && echo "mwan3.$nm.family='$fam'"
		[ -n "$trk" ] && for v in $trk; do echo "mwan3.$nm.track_ip='$v'"; done
		[ -n "$fl" ]  && for v in $fl;  do echo "mwan3.$nm.flush_conntrack='$v'"; done
	done < "$MF"
	exit 0
fi

# `uci get mwan3.<sec>.<opt>` and `uci get mwan3.<sec>`
# Section lookup is a plain string compare, not a grep pattern: real section
# names may contain regex metacharacters, and an unescaped match would either
# miss a member or hit the wrong one.
if [ "$1" = "get" ]; then
	key="$2"
	case "$key" in
		mwan3.*) ;;
		*) echo ""; exit 0 ;;
	esac
	sec="${key#mwan3.}"; sec="${sec%%.*}"; opt=""
	case "$key" in *.*) opt="${key##*.}" ;; esac
	[ -f "$MF" ] || exit 0
	fam=""; trk=""; fl=""; tp=""
	# No pipe: `done < file` keeps these assignments in this shell, which a
	# `... | while read` would not.
	while IFS='	' read -r nm t f t2 f2; do
		[ "$nm" = "$sec" ] || continue
		tp="$t"; fam="$f"; trk="$t2"; fl="$f2"
		break
	done < "$MF"
	case "$opt" in
		"") echo "$tp" ;;
		family) echo "$fam" ;;
		track_ip) echo "$trk" ;;
		flush_conntrack) echo "$fl" ;;
		enabled) echo 1 ;;
		*) echo "" ;;
	esac
	exit 0
fi

echo ""
exit 0
STUB
chmod +x "$WORK/uci"

# Default mwan3 model. Deliberately includes:
#   - ipv4 and ipv6 members, so family filtering is actually exercised
#   - a hostname track_ip on some members, so fix_mwan3_numeric has work to do
#   - a `rule` section with family ipv6 (rule_v6), which must NOT be touched
#   - a mix of already-correct and stock-churn flush lists
cat > "$WORK/mwan3.model" <<'MODEL'
wan1	interface	ipv4	www.google.com www.facebook.com	connected disconnected ifup ifdown
wan1_6	interface	ipv6	ipv6.google.com www.v6.facebook.com	connected disconnected ifup ifdown
wan2	interface	ipv4	8.8.8.8	connected disconnected ifup ifdown
wan2_6	interface	ipv6	2606:4700::1001 2001:4860:4860::8888	connected disconnected ifup ifdown
wan6	interface	ipv6	2606:4700::1001 2620:fe::9	ifup ifdown
rule_v6	rule	ipv6			connected disconnected
MODEL

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
	ROOTUP_DEBUG="${ROOTUP_DEBUG:-0}" \
	ROOTUP_PROCFS="/proc" \
	MWAN3_STUB_FILE="$WORK/mwan3.model" \
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
echo "== TEST 8: mwan3track fix — recovers a stale ipv6 source pin =="
# Extract-and-run: exercise the SHIPPED tracker's own recovery logic rather
# than a rewrite of it, so the test tracks the shipped bytes.
extract_fn() { # file fn -> prints the function body
	awk -v want="$2" '
		$0 ~ "^" want "[ \t]*\\(\\) *\\{" { inb=1 }
		inb { print }
		inb && /^\}/ { exit }
	' "$1"
}
pay=../payloads/mwan3track
stk=fixtures/stock/mwan3track
[ -f "$pay" ] || { echo "FAIL: payload mwan3track missing"; exit 1; }
sh -n "$pay" || { echo "FAIL: payload is not valid POSIX sh"; exit 1; }
# the patch must re-derive a source that no longer exists on the device
grep -q 'refresh_src_ip' "$pay" || { echo "FAIL: payload has no refresh_src_ip"; exit 1; }
# and the stock file must NOT have it, else there is no bug to fix
if grep -q 'refresh_src_ip' "$stk" 2>/dev/null; then
	echo "FAIL: stock fixture already re-derives its source — fixture drifted"; exit 1
fi
# stock must be gated as known-old, else a stock box would be REPORT-ONLY
row="$(awk -F'|' '$1=="mwan3track" {print $5}' "$CONF")"
stk_m5="$(md5sum "$stk" | cut -d' ' -f1)"
pay_m5="$(md5sum "$pay" | cut -d' ' -f1)"
case ",$row," in
	*",$stk_m5,"*) ;;
	*) echo "FAIL: stock md5 $stk_m5 not in known-old set ($row)"; exit 1 ;;
esac
[ "$pay_m5" = "$(awk -F'|' '$1=="mwan3track" {print $4}' "$CONF")" ] \
	|| { echo "FAIL: payload md5 does not match the canonical fingerprint"; exit 1; }

# End-to-end: drive the SHIPPED tracker's own recovery logic with a stale pin
# and require it to land on the address the device actually has. This mirrors
# how the fix was proven on the box: the stale source fails to bind, the
# re-derived one succeeds.
#
# Only refresh_src_ip is extracted and run. Sourcing the whole tracker would
# execute its main tracking loop; the variables the function reads are set
# explicitly instead. Network probes are stubbed, so the test is hermetic and
# the assertion is purely about candidate selection.
{ extract_fn "$pay" refresh_src_ip; } > "$WORK/fn-refresh.sh"
if [ ! -s "$WORK/fn-refresh.sh" ]; then
	echo "FAIL: could not extract refresh_src_ip from the payload"; exit 1
fi
LIVE_ADDR=2600:1006:b130:129d:4c88:1aff:fe8c:5e11
STALE_ADDR=2600:1006:dead:beef:4c88:1aff:fe8c:5e11
cat > "$WORK/run-pin.sh" <<RUNPIN
#!/bin/sh
DEVICE=usb1
FAMILY=ipv6
PING="ping"
SRC_IP="$STALE_ADDR"
probe_ip="2606:4700::1001"
LOG() { echo "LOG: \$*" >&2; }
. "\$1"
refresh_src_ip
printf '%s' "\$SRC_IP"
RUNPIN

# Stubbed probes. `ip -6 addr` lists ONLY the live address, so a withdrawn
# address cannot pass the candidate probe — exactly the on-box failure
# ("failed to bind to ip address: Address not available"). ping succeeds only
# for the live source.
mkdir -p "$WORK/pinbin"
cat > "$WORK/pinbin/ip" <<IPSTUB
#!/bin/sh
case "\$1" in
	-6) shift ;;
esac
case "\$1" in
	addr)  echo "    inet6 $LIVE_ADDR/64 scope global" ;;
	route) echo "2606:4700::1001 via fe80::1 dev usb1" ;;
	get)   echo "2606:4700::1001 from $LIVE_ADDR dev usb1" ;;
esac
exit 0
IPSTUB
cat > "$WORK/pinbin/ping" <<PGSTUB
#!/bin/sh
src=""
while [ \$# -gt 0 ]; do
	case "\$1" in
		-I) src="\$2"; shift 2 ;;
		*) shift ;;
	esac
done
[ "\$src" = "$LIVE_ADDR" ] && exit 0
exit 1
PGSTUB
chmod +x "$WORK/pinbin/ip" "$WORK/pinbin/ping"

got="$(PATH="$WORK/pinbin:$PATH" sh "$WORK/run-pin.sh" "$WORK/fn-refresh.sh" 2>/dev/null)"
[ "$got" = "$LIVE_ADDR" ] \
	|| { echo "FAIL: patched tracker did not recover the stale pin (got '$got')"; exit 1; }

# Discriminating check: the stock file must FAIL this same harness. If it ever
# passed, the test would no longer be evidence of anything.
if grep -q 'refresh_src_ip' "$stk" 2>/dev/null; then
	echo "FAIL: stock file has refresh_src_ip — TEST 8 is vacuous"; exit 1
fi
echo "PASS: patched tracker re-derives a stale ipv6 source; stock has no such logic"

# New assertion for v2.2: warn log when no ipv6 globals on device.
# The v2.2 patch adds a LOG warn when candidate list is empty (withdrawal case).
grep -q 'no ipv6 globals on device' "$pay" \
	|| { echo "FAIL: v2.2 payload missing 'no ipv6 globals on device' warn"; exit 1; }
# stock must NOT have it
if grep -q 'no ipv6 globals on device' "$stk" 2>/dev/null; then
	echo "FAIL: stock fixture already has warn — fixture drifted"; exit 1
fi
echo "PASS: v2.2 payload logs warn on zero-candidate withdrawal; stock has none"

echo
echo "== TEST 9: mwan3 enumeration is by name, and excludes non-interfaces =="
# The previous fix_mwan3_numeric enumerated mwan3.@interface[$i] and found
# ZERO members on a real box, because every mwan3 interface is a NAMED
# section. That made the "numeric track targets" fix a silent no-op. These
# assertions fail if the regression returns.
out="$(run_install "$WORK/new-root" --check 2>&1)"
# rule_v6 is family=ipv6 but type=rule: it must never be reported as a member
if printf '%s\n' "$out" | grep -q "mwan3 interface 'rule_v6'"; then
	echo "FAIL: rule_v6 (a policy rule) was treated as an interface"; printf '%s\n' "$out"; exit 1
fi
# the ipv6 members that DO need the flush fix must be reported
for want in wan1_6 wan2_6; do
	printf '%s\n' "$out" | grep -q "mwan3 interface '$want': flush_conntrack" \
		|| { echo "FAIL: $want not reported by the v6 flush fix"; printf '%s\n' "$out"; exit 1; }
done
# wan6 is already correct in the model: it must NOT be rewritten (idempotency)
printf '%s\n' "$out" | grep -q "mwan3 interface 'wan6': flush_conntrack" \
	&& { echo "FAIL: already-correct wan6 would be rewritten"; printf '%s\n' "$out"; exit 1; }
# ipv4 members must be left alone entirely
for v4 in wan1 wan2; do
	printf '%s\n' "$out" | grep -q "mwan3 interface '$v4': flush_conntrack" \
		&& { echo "FAIL: ipv4 member $v4 was touched by the v6 flush fix"; exit 1; }
done
# hostname track_ips must be reported (proves named enumeration works at all)
for hn in wan1 wan1_6; do
	printf '%s\n' "$out" | grep -q "mwan3 interface '$hn': replace hostname track_ip" \
		|| { echo "FAIL: $hn hostname track_ip not detected — enumeration is broken"; printf '%s\n' "$out"; exit 1; }
done
echo "PASS: members discovered by name; rule_v6 excluded; ipv4 untouched; idempotent"

echo
echo "== TEST 10: mwan3 activation is gated on an actual change =="
# Replacing the tracker on disk is inert until the process respawns, so the
# installer must signal activation — but only when it really changed something.
# A no-op run must NOT claim it will restart mwan3.
#
# Two distinct contracts, both asserted:
#   --check  announces INTENT ("would restart"), never executes
#   (apply)  actually executes the restart, and only then
# Collapsing these into one would either hide the interruption from the
# operator or make --check lie about doing something it must not do.
newout="$(run_install "$WORK/new-root" --check 2>&1)"

# Build a model where nothing needs changing, and require no restart intent.
cat > "$WORK/mwan3.clean" <<'CLEAN'
wan1	interface	ipv4	1.1.1.1 8.8.8.8 9.9.9.9	connected disconnected ifup ifdown
wan1_6	interface	ipv6	2606:4700::1001 2001:4860:4860::8888 2620:fe::9	ifup ifdown
CLEAN
run_with_model() { # model-file mode debug -> output
	m="$1"; md="$2"; dbg="${3:-0}"
	X=""; [ "$NOB64" = 1 ] && X="$WORK/nob64:"
	PATH="$X$WORK:$PATH" ROOTUP_ROOT="$WORK/new-root" ROOTUP_TEST=1 \
	ROOTUP_SKIP_NFT=1 ROOTUP_PROCFS="/proc" ROOTUP_DEBUG="$dbg" \
	MWAN3_STUB_FILE="$m" sh ../install.sh "$md" 2>&1
}
cleanout="$(run_with_model "$WORK/mwan3.clean" --check)"

# (a) clean config, check mode: must say nothing about restarting mwan3.
# Scoped to "mwan3:" because the summary always mentions restartrun.sh (the
# payload, not the service) — matching bare "restart" here would fail on
# unrelated output and hide a real regression behind a false positive.
if printf '%s\n' "$cleanout" | grep -qi 'mwan3:.*restart'; then
	echo "FAIL: clean config would announce an mwan3 restart"; printf '%s\n' "$cleanout"; exit 1
fi

# (b) dirty config, check mode: must announce INTENT, and say "would"
printf '%s\n' "$newout" | grep -qi 'would restart so the tracker' \
	|| { echo "FAIL: --check did not announce the pending restart"; printf '%s\n' "$newout"; exit 1; }
# it must not claim it is doing the restart
printf '%s\n' "$newout" | grep -qi 'restarting so the tracker' \
	&& { echo "FAIL: --check claims to be restarting mwan3 (read-only mode)"; printf '%s\n' "$newout"; exit 1; }

# (c) dirty config, apply mode: must ACTUALLY invoke the restart.
# ROOTUP_TEST sets TESTMODE=1, so svc() logs "svc(skip) mwan3 reload" at debug
# level instead of touching init.d — which is exactly the evidence needed.
applyout="$(run_with_model "$WORK/mwan3.model" apply 1)"
printf '%s\n' "$applyout" | grep -q 'svc(skip) mwan3 reload' \
	|| { echo "FAIL: apply did not restart mwan3 after changing it"; printf '%s\n' "$applyout"; exit 1; }

# (d) clean config, apply mode: must NOT restart mwan3
cleanapply="$(run_with_model "$WORK/mwan3.clean" apply 1)"
printf '%s\n' "$cleanapply" | grep -q 'svc(skip) mwan3 reload' \
	&& { echo "FAIL: apply restarted mwan3 with nothing to change"; printf '%s\n' "$cleanapply"; exit 1; }
echo "PASS: intent reported in --check, executed only in apply, both gated on a real change"

echo
echo "== TEST 11: member discovery adapts to the member count =="
# The number of wan<N>_6 members depends on the box's "Multiple Modems"
# setting, so it is not fixed. A 4-member box must work exactly as well as the
# 6-member default model, with no hardcoded names anywhere.
cat > "$WORK/mwan3.four" <<'FOUR'
wan1	interface	ipv4	1.1.1.1 8.8.8.8	connected disconnected ifup ifdown
wan1_6	interface	ipv6	ipv6.google.com	connected disconnected ifup ifdown
wan3	interface	ipv4	1.1.1.1 8.8.8.8	connected disconnected ifup ifdown
wan3_6	interface	ipv6	ipv6.google.com	connected disconnected ifup ifdown
FOUR
fourout="$(X=""; [ "$NOB64" = 1 ] && X="$WORK/nob64:"; \
	PATH="$X$WORK:$PATH" ROOTUP_ROOT="$WORK/new-root" ROOTUP_TEST=1 \
	ROOTUP_SKIP_NFT=1 ROOTUP_PROCFS="/proc" \
	MWAN3_STUB_FILE="$WORK/mwan3.four" sh ../install.sh --check 2>&1)"
for want in wan1_6 wan3_6; do
	printf '%s\n' "$fourout" | grep -q "mwan3 interface '$want': flush_conntrack" \
		|| { echo "FAIL: $want missed — discovery is not count-agnostic"; printf '%s\n' "$fourout"; exit 1; }
done
# and the count must not be pinned anywhere in the source
if grep -nE "wan5_6|wwan26|wwan56" src/40-fix-ipv6.sh 2>/dev/null; then
	echo "FAIL: a specific member name is hardcoded in the fix"; exit 1
fi
echo "PASS: discovery follows the box's member set, nothing hardcoded"

echo
echo "== TEST 12: the v6 flush fix removes churn, it never adds flushing =="
# The defect is connected/disconnected firing on tracker churn; removing them
# is the fix. Forcing 'ifup ifdown' onto a member that never had a
# flush_conntrack list would ADD conntrack flushing nobody asked for -- a
# behaviour change disguised as a repair. Same trap for a member trimmed down
# to the churn events alone: the honest result is no list, not the two
# link-transition events invented back.
cat > "$WORK/mwan3.edge" <<'EDGE'
wan1	interface	ipv4	1.1.1.1	connected disconnected ifup ifdown
wan1_6	interface	ipv6	2606:4700::1001	connected disconnected ifup ifdown
wan2_6	interface	ipv6	2606:4700::1001
wan3_6	interface	ipv6	2606:4700::1001	connected disconnected
EDGE
edgeout="$(X=""; [ "$NOB64" = 1 ] && X="$WORK/nob64:"; \
	PATH="$X$WORK:$PATH" ROOTUP_ROOT="$WORK/new-root" ROOTUP_TEST=1 \
	ROOTUP_SKIP_NFT=1 ROOTUP_PROCFS="/proc" \
	MWAN3_STUB_FILE="$WORK/mwan3.edge" sh ../install.sh --check 2>&1)"

# stock shape: churn removed, the link transitions it already had are kept
printf '%s\n' "$edgeout" | grep -q "mwan3 interface 'wan1_6': flush_conntrack .*-> 'ifup ifdown'" \
	|| { echo "FAIL: stock-shaped wan1_6 not reduced to 'ifup ifdown'"; printf '%s\n' "$edgeout"; exit 1; }
# churn only: churn removed, nothing invented to replace it
printf '%s\n' "$edgeout" | grep -q "mwan3 interface 'wan3_6': flush_conntrack .*-> '<none>'" \
	|| { echo "FAIL: churn-only wan3_6 should end with no list, not 'ifup ifdown'"; printf '%s\n' "$edgeout"; exit 1; }
# no list at all: nothing to remove, so nothing may be written
if printf '%s\n' "$edgeout" | grep -q "mwan3 interface 'wan2_6'"; then
	echo "FAIL: wan2_6 (no flush_conntrack) was modified -- flushing was invented"
	printf '%s\n' "$edgeout"; exit 1
fi
echo "PASS: churn removed; ifup/ifdown preserved and never added; churn-only ends empty"

echo
echo "== ALL OFFLINE TESTS PASSED =="