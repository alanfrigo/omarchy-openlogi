#!/usr/bin/env bash
# Build first; switch only after success, retaining the previous installation on failure.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
data=${XDG_DATA_HOME:-$HOME/.local/share}
config=${XDG_CONFIG_HOME:-$HOME/.config}
state=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-openlogi
receipt=$state/install
plugin=$config/omarchy/plugins/alanfrigo.openlogi
bin=$data/omarchy-openlogi/bin
fail() { printf 'update-openlogi: %s\n' "$*" >&2; exit 1; }
[[ $# -le 1 ]] || fail 'usage: update.sh [vMAJOR.MINOR.PATCH]'
export OMARCHY_SHELL_IPC_TIMEOUT=${OMARCHY_SHELL_IPC_TIMEOUT:-15s}
for path in "$data" "$config" "$state"; do [[ $path == /* ]] || fail "XDG path must be absolute: $path"; done
[[ -d $state && ! -L $state && -O $state ]] || fail 'no safe installation state; run scripts/install.sh first'
exec 9<"$state"
flock -n 9 || fail 'another OpenLogi installation/removal is running'
# Child installers inherit the lock during the switch.
OPENLOGI_ROLLBACK=1 OPENLOGI_PREFLIGHT=1 bash "$root/scripts/uninstall.sh"
[[ -f $receipt/committed ]] || fail 'previous installation incomplete; resolve receipt before updating'
if [[ $(<"$receipt/in-place") == 1 ]]; then
    [[ $root == "$(cd -- "$plugin" && pwd -P)" ]] || fail 'in-place installation: run update.sh from the installed plugin source'
fi
old_bin=$data/omarchy-openlogi/0.8.10/bin
if [[ -f $receipt/bin-path ]]; then old_bin=$(<"$receipt/bin-path"); fi
[[ ! -e $bin || $old_bin == "$bin" ]] || fail "foreign binary destination: $bin"
mkdir -p -- "$data/omarchy-openlogi"
work=$(mktemp -d -- "$data/omarchy-openlogi/.update.XXXXXX")
keep_backup=0
trap 'if (( ! keep_backup )); then rm -rf -- "$work"; else printf "update-openlogi: recovery files retained at %s\n" "$work" >&2; fi' EXIT
# Keep source available even when updating from the copied plugin itself.
cp -a -- "$root" "$work/source"
XDG_DATA_HOME=$work/data bash "$work/source/scripts/build-openlogi.sh" "$@"
# Snapshot only managed state, not device configuration. Reflinks avoid copying big binaries.
cp -a --reflink=auto -- "$receipt" "$work/receipt"
cp -a --reflink=auto -- "$old_bin" "$work/old-bin"
if [[ -d $plugin ]]; then cp -a -- "$plugin" "$work/plugin"; fi
for key in dropin desktop unit; do
    case $key in
        dropin) path=$config/systemd/user/openlogi-agent.service.d/omarchy-openlogi.conf;;
        desktop) path=$data/applications/openlogi.desktop;;
        unit) path=$data/systemd/user/openlogi-agent.service;;
    esac
    if [[ -f $path ]]; then cp -p -- "$path" "$work/$key"; fi
done
was_enabled=$(omarchy plugin list --json | jq -r '([.[] | select(.id == "alanfrigo.openlogi") | .enabled] | first) // false')
was_active=$(systemctl --user show openlogi-agent.service -p ActiveState --value)
[[ $was_active == active || $was_active == inactive ]] || fail "cannot restore agent state: $was_active"
# uninstall.sh validates the same managed files again immediately before mutation.
recover() {
    trap - ERR
    printf 'update-openlogi: switch failed; restoring previous installation\n' >&2
    omarchy plugin disable alanfrigo.openlogi || :
    rm -rf -- "$bin" "$old_bin"
    mkdir -p -- "$(dirname -- "$old_bin")"
    cp -a --reflink=auto -- "$work/old-bin" "$old_bin"
    rm -rf -- "$receipt"
    cp -a -- "$work/receipt" "$receipt"
    if [[ -d $work/plugin ]]; then
        rm -rf -- "$plugin"
        cp -a -- "$work/plugin" "$plugin"
    fi
    for key in dropin desktop unit; do
        case $key in
            dropin) path=$config/systemd/user/openlogi-agent.service.d/omarchy-openlogi.conf;;
            desktop) path=$data/applications/openlogi.desktop;;
            unit) path=$data/systemd/user/openlogi-agent.service;;
        esac
        if [[ -f $work/$key ]]; then mkdir -p -- "$(dirname -- "$path")"; cp -p -- "$work/$key" "$path"; else rm -f -- "$path"; fi
    done
    systemctl --user daemon-reload
    if [[ $was_active == active ]]; then systemctl --user restart openlogi-agent.service; else systemctl --user stop openlogi-agent.service; fi
    recovered=0
    for ((second=0; second<30; second++)); do
        if omarchy-shell shell ping >/dev/null 2>&1; then recovered=1; break; fi
        sleep 1
    done
    (( recovered )) || fail 'shell did not recover; previous backend restored, recovery files retained'
    omarchy-shell shell rescanPlugins
    if [[ $was_enabled == true ]]; then
        recovered=0
        for ((second=0; second<15; second++)); do
            if omarchy plugin list --json | jq -e 'any(.[]; .id == "alanfrigo.openlogi")' >/dev/null; then recovered=1; break; fi
            sleep 1
        done
        (( recovered )) || fail 'restored plugin not discovered; recovery files retained'
        omarchy plugin enable alanfrigo.openlogi
        recovered=0
        for ((second=0; second<30; second++)); do
            if omarchy-shell alanfrigo.openlogi status | jq -e '.protocolReady == true and .agentState == "connected"' >/dev/null; then recovered=1; break; fi
            sleep 1
        done
        (( recovered )) || fail 'restored bridge not connected; recovery files retained'
    fi
    keep_backup=0
    exit 1
}
# Parent keeps lock; child installers explicitly inherit it.
keep_backup=1
trap recover ERR
OPENLOGI_ROLLBACK=1 bash "$work/source/scripts/uninstall.sh"
if [[ $old_bin == "$bin" ]]; then mv -- "$bin" "$work/live-bin"; fi
mv -- "$work/data/omarchy-openlogi/bin" "$bin"
install_root=$work/source
if [[ $(<"$work/receipt/in-place") == 1 && -d $plugin ]]; then install_root=$plugin; fi
OPENLOGI_UPDATE_LOCKED=1 bash "$install_root/scripts/install.sh"
trap - ERR
keep_backup=0
printf 'OpenLogi updated to %s\n' "$(<"$bin/RELEASE")"
