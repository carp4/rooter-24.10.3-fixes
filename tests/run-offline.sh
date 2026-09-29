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
#
# Env:
#   ROOTUP_WORK=<dir>   scratch dir for fake roots (default tests/.work)
#   ROOTUP_SRC=<source2410 tree>, ROOTUP_FIX19=<b19 rootfs>  override paths
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

# the 5 payload destinations (relative paths)
FILES="usr/lib/rooter/connect/create_hostless.sh
usr/lib/rooter/connect/handlettl.sh
usr/lib/rooter/connect/get_profile.sh
usr/lib/lua/luci/model/cbi/rooter/profiles.lua
usr/lib/rooter/luci/restartrun.sh"

# source tree paths for each (for git show HEAD)
SRCF="package/rooter/ext-rooter-basic/files/usr/lib/rooter/connect/create_hostless.sh
package/rooter/ext-rooter-basic/files/usr/lib/rooter/connect/handlettl.sh
package/rooter/ext-rooter-basic/files/usr/lib/rooter/connect/get_profile.sh
package/rooter/ext-rooter-basic/files/usr/lib/lua/luci/model/cbi/rooter/profiles.lua
package/rooter/ext-rooter-basic/files/usr/lib/rooter/luci/restartrun.sh"

rm -rf "$WORK"
mkdir -p "$WORK/old-root" "$WORK/new-root"

# ---- old-root: fully stock, synthesized from git HEAD -------------
i=0
for f in $FILES; do
	i=$((i+1))
	src="$(printf '%s\n' "$SRCF" | sed -n "${i}p")"
	mkdir -p "$WORK/old-root/$(dirname "$f")"
	git -C "$SRC" show "HEAD:$src" > "$WORK/old-root/$f" 2>/dev/null || {
		echo "FAIL: cannot extract stock $f from $SRC HEAD" >&2; exit 1; }
done

# ---- new-root: canonical (b19) -------------------------------------
for f in $FILES; do
	mkdir -p "$WORK/new-root/$(dirname "$f")"
	cp -p "$FIX19/$f" "$WORK/new-root/$f"
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

run_install() { # root-dir mode
	r="$1"; mode="$2"
	PATH="$WORK:$PATH" \
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
	[ -z "$(md5sum "$WORK/old-root/$f" | cut -d' ' -f1)" ] && continue
	exp="$(md5sum "$FIX19/$f" | cut -d' ' -f1)"
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
echo "== ALL OFFLINE TESTS PASSED =="