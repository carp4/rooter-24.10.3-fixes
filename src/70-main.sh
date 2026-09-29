# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	printf 'roo_fix %s — ROOter 24.10 live fixes (mode: %s)\n' "$VERSION" "$MODE"
	[ "$MODE" = "check" ] && printf 'AUDIT MODE — read-only, nothing will be written.\n'

	run_checks
	make_backup

	install_payloads        # 1) canonical file drop-ins (TTL/HL + preserve scripts + UI)

	# 2) IPv6
	fix_ipv6

	# 3) TTL rules re-apply + verify (runs after payload install)
	fix_ttl

	# 4) preserve profile default + report-only checks
	fix_preserve

	write_rollback

	printf '\n== Summary ==\n'
	if [ "$MODE" = "apply" ]; then
		printf '  files replaced: %s\n' "$CHANGED"
		printf '  backup: %s  (rollback: sh %s/rollback.sh)\n' "$BK" "$BK"
	else
		printf '  audit only — no changes made. Re-run without --check to apply.\n'
	fi
	printf '  Done.\n'
}

main
exit 0