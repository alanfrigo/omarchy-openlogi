#!/usr/bin/env bash
# Install only after build-openlogi.sh has staged all four private binaries.
set -euo pipefail

id=alanfrigo.openlogi
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
data=${XDG_DATA_HOME:-$HOME/.local/share}
config=${XDG_CONFIG_HOME:-$HOME/.config}
state=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-openlogi
bin=$data/omarchy-openlogi/0.8.10/bin
unit=$data/systemd/user/openlogi-agent.service
dropin=$config/systemd/user/openlogi-agent.service.d/omarchy-openlogi.conf
desktop=$data/applications/openlogi.desktop
plugin=$config/omarchy/plugins/$id
receipt=$state/install
files=(manifest.json Service.qml Overlay.qml BarWidget.qml Model.js check.mjs scripts/build-openlogi.sh scripts/install.sh scripts/uninstall.sh patches/openlogi-0.8.10-external-overlay.patch)

transaction_live=0
fail() {
    printf 'install-openlogi: %s\n' "$*" >&2
    if (( transaction_live )); then rollback 1; fi
    exit 1
}
for tool in flock jq omarchy omarchy-shell systemctl sha256sum cut find cmp; do command -v "$tool" >/dev/null || fail "$tool is required"; done
export OMARCHY_SHELL_IPC_TIMEOUT=${OMARCHY_SHELL_IPC_TIMEOUT:-15s}
mkdir -p -- "$state"
exec 9>"$state/.install.lock"
flock -n 9 || fail 'another OpenLogi installation/removal is running'
[[ ! -e $receipt ]] || fail "installation receipt exists at $receipt; uninstall first (or resolve its reported conflicts)"
for name in openlogi openlogi-agent openlogi-desktop openlogi-overlay; do
    [[ -x $bin/$name && ! -L $bin/$name ]] || fail "missing compatible private binary $bin/$name; run scripts/build-openlogi.sh"
done
[[ -f $bin/REVISION && ! -L $bin/REVISION ]] || fail "missing private build revision at $bin/REVISION"
[[ $(<"$bin/REVISION") == 19036d7fe86abe11cdb628da11ff89aa5fb7a204 ]] || fail 'private binaries are not the pinned OpenLogi 0.8.10 revision'
for name in LICENSE-MIT LICENSE-APACHE external-overlay.patch; do
    [[ -f $bin/$name && ! -L $bin/$name ]] || fail "incomplete private build: $bin/$name"
done
cmp -s -- "$bin/external-overlay.patch" "$root/patches/openlogi-0.8.10-external-overlay.patch" || fail 'private build patch does not match this plugin'
for name in "$bin"/*; do
    case ${name##*/} in
        openlogi|openlogi-agent|openlogi-desktop|openlogi-overlay|REVISION|LICENSE-MIT|LICENSE-APACHE|external-overlay.patch) ;;
        *) fail "unknown private build file: $name";;
    esac
done
for name in "${files[@]}"; do [[ -f $root/$name && ! -L $root/$name ]] || fail "missing $root/$name"; done
for path in "$data" "$config" "$state"; do [[ $path == /* ]] || fail "XDG path must be absolute: $path"; done
[[ $bin != *[$'\n'$'\r'$'\t']* && $bin != *'"'* && $bin != *'\'* && $bin != *'$'* && $bin != *'`'* ]] || fail 'binary path contains a character unsafe for desktop/systemd Exec'

# Existing installed trees are not ours without an old receipt. Running from
# that tree is in-place: publish nothing and never delete its source on removal.
in_place=0
if [[ -e $plugin || -L $plugin ]]; then
    [[ ! -L $plugin && -d $plugin ]] || fail "unsafe plugin destination: $plugin"
    [[ $root == "$(cd -- "$plugin" && pwd -P)" ]] || fail "foreign plugin destination: $plugin"
    in_place=1
fi
for path in "$dropin" "$desktop" "$unit"; do [[ ! -L $path && ( ! -e $path || -f $path ) ]] || fail "unsafe existing file: $path"; done
[[ ! -e $config/applications/openlogi.desktop && ! -L $config/applications/openlogi.desktop ]] || fail 'a higher-priority desktop override exists in XDG_CONFIG_HOME; refusing to shadow it'

unit_state=$(systemctl --user show openlogi-agent.service -p UnitFileState --value)
active_state=$(systemctl --user show openlogi-agent.service -p ActiveState --value)
[[ $unit_state == enabled || $unit_state == disabled || $unit_state == static ]] || fail "unsupported original unit enablement: $unit_state"
[[ $active_state == active || $active_state == inactive ]] || fail "cannot safely restore original unit activity: $active_state"
original_plugin=$(omarchy plugin list --json | jq -r --arg id "$id" '([.[] | select(.id == $id) | .enabled] | first) // false')
[[ $original_plugin == true || $original_plugin == false ]] || fail 'cannot read plugin enablement'

# Preflight against actual package entry; preserve every field except Exec.
packaged=/usr/share/applications/openlogi.desktop
[[ -f $packaged ]] || fail "packaged launcher missing: $packaged"
exec_value="/usr/bin/env OPENLOGI_OVERLAY_BACKEND=external \"${bin//%/%%}/openlogi-desktop\""
quoted_bin="${bin//%/%%}/openlogi-agent"
if [[ $bin == *' '* ]]; then quoted_bin="\"$quoted_bin\""; fi
new_dropin=$(printf '[Service]\nExecStart=\nExecStart=%s\nEnvironment=OPENLOGI_OVERLAY_BACKEND=external\n' "$quoted_bin")

# Finish all input checks before creating the receipt: no failed preflight can
# leave a misleading transaction journal behind.
exec_count=0
packaged=/usr/share/applications/openlogi.desktop
[[ -f $packaged ]] || fail "packaged launcher missing: $packaged"
while IFS= read -r line; do [[ $line == Exec=* ]] && ((exec_count+=1)); done <"$packaged"
[[ $exec_count == 1 ]] || fail 'packaged launcher needs exactly one Exec key'
mkdir -m 700 -- "$receipt"
trap 'if (( ! transaction_live )); then rm -r -- "$receipt"; fi' EXIT
# Snapshot before changing any live file; receipt is journal and rollback data.
printf '%s\n' "$unit_state" >"$receipt/unit-state"
printf '%s\n' "$active_state" >"$receipt/active-state"
printf '%s\n' "$original_plugin" >"$receipt/plugin-enabled"
printf '%s\n' "$in_place" >"$receipt/in-place"
for key in dropin desktop unit; do
    case $key in dropin) path=$dropin;; desktop) path=$desktop;; unit) path=$unit;; esac
    if [[ -f $path ]]; then cp -p -- "$path" "$receipt/$key.original"; else : >"$receipt/$key.absent"; fi
done

# Expected bytes exist before any live write, including interrupted installs.
printf '%s\n' "$new_dropin" >"$receipt/dropin.new"
# Desktop Exec key appears once in packaged file; preserve every other field.
while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == Exec=* ]]; then printf 'Exec=%s\n' "$exec_value"; else printf '%s\n' "$line"; fi
done <"$packaged" >"$receipt/desktop.new"
for name in "$bin"/*; do
    [[ -f $name && ! -L $name ]] || fail "unsafe private build file: $name"
    printf '%s\t%s\n' "${name##*/}" "$(sha256sum -- "$name" | cut -d ' ' -f 1)" >>"$receipt/bin.sha256"
done
if (( ! in_place )); then
    for name in "${files[@]}"; do
        mkdir -p -- "$receipt/plugin.new/$(dirname -- "$name")"
        cp -p -- "$root/$name" "$receipt/plugin.new/$name"
    done
fi

rollback() {
    rc=${1:-$?}
    trap - ERR
    if (( rc != 0 )); then
        printf 'install-openlogi: failed; restoring from receipt\n' >&2
        OPENLOGI_ROLLBACK=1 bash "$root/scripts/uninstall.sh" || printf 'install-openlogi: rollback incomplete; retain receipt and private binaries\n' >&2
    fi
    exit "$rc"
}
trap rollback ERR
transaction_live=1

atomic_copy() {
    local source=$1 target=$2 temp
    mkdir -p -- "$(dirname -- "$target")"
    temp=$(mktemp -- "$(dirname -- "$target")/.openlogi.XXXXXX")
    cp -p -- "$source" "$temp"
    mv -f -- "$temp" "$target"
}
if (( ! in_place )); then
    mkdir -- "$plugin"
    for name in "${files[@]}"; do atomic_copy "$receipt/plugin.new/$name" "$plugin/$name"; done
fi
atomic_copy "$receipt/dropin.new" "$dropin"
# Agent may create its own data-level unit at login when binary differs from
# package; its exact original remains in receipt and is never overwritten here.
systemctl --user daemon-reload
systemctl --user restart openlogi-agent.service
# Agent may generate its own data-level unit at startup; preserve exact bytes
# before any subsequent error can trigger rollback.
if [[ -f $unit ]]; then cp -p -- "$unit" "$receipt/unit.new"; fi
actual=$(systemctl --user show openlogi-agent.service -p ExecStart --value)
[[ $actual == *"$bin/openlogi-agent"* ]] || fail "effective ExecStart is not $bin/openlogi-agent: $actual"
actual=$(systemctl --user show openlogi-agent.service -p Environment --value)
[[ " $actual " == *' OPENLOGI_OVERLAY_BACKEND=external '* ]] || fail "effective agent environment lacks external backend: $actual"
# Check actual role lock, not PID or claim contents. The old GPUI process
# should release its lock after agent succession; never kill by recorded PID.
role_lock=$config/openlogi/overlay.lock
for ((second=0; second<65; second++)); do
    if [[ ! -e $role_lock ]] || flock -n "$role_lock" -c :; then break; fi
    sleep 1
done
[[ ! -e $role_lock ]] || flock -n "$role_lock" -c : || fail 'old renderer still holds overlay role after 65 seconds'
# Agent autostart reconciliation may write data-level unit asynchronously.
if [[ -f $unit ]]; then cp -p -- "$unit" "$receipt/unit.new"; fi
atomic_copy "$receipt/desktop.new" "$desktop"
# Shell may restart while its watched plugin directory is published.
shell_ready=0
for ((second=0; second<30; second++)); do
    if omarchy-shell shell ping >/dev/null 2>&1; then shell_ready=1; break; fi
    sleep 1
done
(( shell_ready )) || fail 'omarchy-shell did not recover after plugin publication'
omarchy-shell shell rescanPlugins
# Rescan schedules a Qt callback; enablePlugin can report unknown until scan ends.
discovered=0
for ((second=0; second<15; second++)); do
    if omarchy plugin list --json | jq -e --arg id "$id" 'any(.[]; .id == $id)' >/dev/null; then discovered=1; break; fi
    sleep 1
done
(( discovered )) || fail 'shell did not discover plugin after rescan'
if [[ $original_plugin != true ]]; then omarchy plugin enable "$id" --section right; fi
# Bridge ready is not equivalent to agent/device online. Demand protocol +
# connected agent; empty ready inventory remains a valid no-device state.
ready=0
for ((second=0; second<30; second++)); do
    status=$(omarchy-shell "$id" status 2>/dev/null || true)
    if jq -e '.protocolReady == true and .agentState == "connected"' <<<"$status" >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
done
(( ready )) || fail "bridge did not report connected status within 30 seconds: ${status:-unavailable}"
# Reconcile on agent startup can finish after shell discovery and bridge hello.
if [[ -f $unit ]]; then cp -p -- "$unit" "$receipt/unit.new"; fi
: >"$receipt/committed"
trap - ERR
printf 'OpenLogi installed: %s (bridge connected)\n' "$plugin"
