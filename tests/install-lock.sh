#!/usr/bin/env bash
# Exercise installer/remover through their CLI with isolated XDG directories.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export XDG_STATE_HOME=$tmp/state XDG_DATA_HOME=$tmp/data XDG_CONFIG_HOME=$tmp/config
state=$XDG_STATE_HOME/omarchy-openlogi
mkdir -p -- "$state"
printf 'keep me\n' >"$tmp/valuable"
ln -s -- "$tmp/valuable" "$state/.install.lock"

if bash "$root/scripts/install.sh" >"$tmp/output" 2>&1; then
    printf 'install unexpectedly succeeded\n' >&2
    exit 1
fi
[[ $(<"$tmp/valuable") == 'keep me' ]] || { printf 'install truncated symlink target\n' >&2; exit 1; }

mkdir -- "$state/install"
if bash "$root/scripts/uninstall.sh" >"$tmp/output" 2>&1; then
    printf 'uninstall unexpectedly succeeded\n' >&2
    exit 1
fi
[[ $(<"$tmp/valuable") == 'keep me' ]] || { printf 'uninstall truncated symlink target\n' >&2; exit 1; }

exec 9<"$state"
flock -n 9
for script in install uninstall; do
    if bash "$root/scripts/$script.sh" >"$tmp/output" 2>&1; then
        printf '%s ignored concurrent operation\n' "$script" >&2
        exit 1
    fi
    [[ $(<"$tmp/output") == *'another OpenLogi installation/removal is running'* ]] || {
        printf '%s did not honor shared state lock: %s\n' "$script" "$(<"$tmp/output")" >&2
        exit 1
    }
done
printf 'install/uninstall preserve symlink targets and share state lock\n'
