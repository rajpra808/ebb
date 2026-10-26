#!/bin/sh
# Removes Ebb completely: https://ebb.serveka.com
#
#   curl -fsSL https://ebb.serveka.com/uninstall.sh | sh            # everything
#   curl -fsSL https://ebb.serveka.com/uninstall.sh | sh -s -- --keep-data
#
# Removes the app, its login item, the ebb and ebbctl commands, the daily agent, and (unless
# --keep-data) Ebb's settings, rules, history, preferences and permissions.
# Anything Ebb moved to the Trash stays there. The work is done by
# install.sh, so both always agree on what Ebb installed.
set -eu

case "${1:-}" in
    --keep-data) mode="" ;;
    "") mode="--purge" ;;
    *) printf '  error: unknown option %s (use --keep-data)\n' "$1" >&2; exit 1 ;;
esac

script=$(mktemp)
trap 'rm -f "$script"' EXIT
curl -fsSL "${EBB_INSTALLER_URL:-https://ebb.serveka.com/install.sh}" -o "$script"
sh "$script" --uninstall $mode
