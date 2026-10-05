#!/usr/bin/env bash
# Remove only files installed by install.sh; never erase post-install edits.
set -euo pipefail

id=alanfrigo.openlogi
data=${XDG_DATA_HOME:-$HOME/.local/share}
config=${XDG_CONFIG_HOME:-$HOME/.config}
state=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-openlogi
bin=$data/omarchy-openlogi/bin
unit=$data/systemd/user/openlogi-agent.service
dropin=$config/systemd/user/openlogi-agent.service.d/omarchy-openlogi.conf
desktop=$data/applications/openlogi.desktop
plugin=$config/omarchy/plugins/$id
receipt=$state/install
conflict=0
rollback=${OPENLOGI_ROLLBACK:-0}

fail() { printf 'uninstall-openlogi: %s\n' "$*" >&2; exit 1; }
[[ -d $state && ! -L $state && -O $state ]] || fail "unsafe state directory: $state"
[[ -d $receipt && ! -L $receipt ]] || fail "no installation receipt at $receipt"
exec 9<"$state"
if [[ $rollback != 1 ]]; then flock -n 9 || fail 'another OpenLogi installation/removal is running'; fi
for name in unit-state active-state plugin-enabled in-place; do [[ -f $receipt/$name ]] || fail "incomplete receipt: $name"; done
# Legacy receipts predate the unversioned build directory.
if [[ -f $receipt/bin-path && ! -L $receipt/bin-path ]]; then
    bin=$(<"$receipt/bin-path")
    [[ $bin == "$data/omarchy-openlogi/bin" ]] || fail 'invalid recorded binary path'
else
    bin=$data/omarchy-openlogi/0.8.10/bin
fi
original_enabled=$(<"$receipt/unit-state")
original_active=$(<"$receipt/active-state")
original_plugin=$(<"$receipt/plugin-enabled")
in_place=$(<"$receipt/in-place")
[[ $original_enabled == enabled || $original_enabled == disabled || $original_enabled == static ]] || fail 'invalid recorded unit enablement'
[[ $original_active == active || $original_active == inactive ]] || fail 'invalid recorded unit activity'
[[ $original_plugin == true || $original_plugin == false ]] || fail 'invalid recorded plugin enablement'
[[ $in_place == 0 || $in_place == 1 ]] || fail 'invalid recorded plugin ownership'

# Do not disable an unrelated replacement plugin in an interrupted install.
owned_plugin=1
if [[ $in_place == 0 && -d $plugin && ! -L $plugin ]]; then
    [[ -d $receipt/plugin.new ]] || fail 'incomplete receipt: plugin snapshot missing'
    while IFS= read -r -d '' name; do
        name=${name#"$receipt/plugin.new/"}
        if [[ -e $plugin/$name || -L $plugin/$name ]]; then
            if [[ ! -f $plugin/$name || -L $plugin/$name ]] || ! cmp -s -- "$receipt/plugin.new/$name" "$plugin/$name"; then owned_plugin=0; fi
        elif [[ $rollback != 1 ]]; then owned_plugin=0; fi
    done < <(find "$receipt/plugin.new" -type f -print0)
    while IFS= read -r -d '' name; do
        name=${name#"$plugin/"}
        [[ -f $receipt/plugin.new/$name ]] || owned_plugin=0
    done < <(find "$plugin" \( -type f -o -type l \) -print0)
    while IFS= read -r -d '' path; do
        case ${path#"$plugin/"} in scripts|patches) ;; *) owned_plugin=0;; esac
    done < <(find "$plugin" -mindepth 1 -type d -print0)
fi
if [[ $in_place == 0 && ( -L $plugin || ( -e $plugin && ! -d $plugin ) ) ]]; then owned_plugin=0; fi


# If any managed service/launcher file changed since installation, leave backend
# and binaries intact rather than restarting a service against mixed versions.
file_unchanged() {
    local key=$1 path=$2
    if [[ -f $receipt/$key.original && -f $path && ! -L $path ]] && cmp -s -- "$receipt/$key.original" "$path"; then
        return 0
    fi
    if [[ -f $receipt/$key.absent && ! -e $path && ! -L $path ]]; then
        return 0
    fi
    [[ -f $receipt/$key.new && -f $path && ! -L $path ]] && cmp -s -- "$receipt/$key.new" "$path"
}
for key in dropin desktop unit; do
    case $key in dropin) path=$dropin;; desktop) path=$desktop;; unit) path=$unit;; esac
    if ! file_unchanged "$key" "$path"; then
        printf 'uninstall-openlogi: changed %s; keeping backend and private binaries\n' "$path" >&2
        conflict=1
    fi
done
if [[ $owned_plugin != 1 ]]; then
    printf 'uninstall-openlogi: plugin changed since installation; retaining plugin and backend\n' >&2
    conflict=1
fi
(( conflict == 0 )) || fail 'resolve conflicts manually; installation receipt retained'
[[ ${OPENLOGI_PREFLIGHT:-0} != 1 ]] || exit 0

# Plugin is stopped before backend restoration; source tree stays untouched.
if omarchy plugin list --json | jq -e --arg id "$id" 'any(.[]; .id == $id and .enabled == true)' >/dev/null; then
    omarchy plugin disable "$id" || fail 'could not disable plugin; backend unchanged'
fi

restore_file() {
    local key=$1 path=$2 temp
    if [[ -f $receipt/$key.original ]]; then
        mkdir -p -- "$(dirname -- "$path")"
        temp=$(mktemp -- "$(dirname -- "$path")/.openlogi.restore.XXXXXX")
        cp -p -- "$receipt/$key.original" "$temp"
        mv -f -- "$temp" "$path"
    elif [[ -f $receipt/$key.absent ]]; then
        rm -f -- "$path"
    else
        fail "incomplete receipt: $key snapshot missing"
    fi
}
restore_file dropin "$dropin"
restore_file desktop "$desktop"
restore_file unit "$unit"
systemctl --user daemon-reload
case $original_enabled in
    enabled) systemctl --user enable openlogi-agent.service >/dev/null;;
    disabled) systemctl --user disable openlogi-agent.service >/dev/null;;
    static) :;;
esac
case $original_active in
    active) systemctl --user restart openlogi-agent.service;;
    inactive) systemctl --user stop openlogi-agent.service;;
esac
# Restore the exact previous launcher/tree state. The source tree is never
# unlinked; copied trees are removed only after full byte-for-byte comparison.
if [[ $owned_plugin == 1 && $in_place == 0 && -d $plugin ]]; then
    while IFS= read -r -d '' name; do
        name=${name#"$receipt/plugin.new/"}
        [[ ! -e $plugin/$name ]] || rm -- "$plugin/$name"
    done < <(find "$receipt/plugin.new" -type f -print0)
    for path in "$plugin/scripts" "$plugin/patches" "$plugin"; do
        if [[ -d $path ]]; then rmdir -- "$path"; fi
    done
fi
omarchy-shell shell rescanPlugins
if [[ $original_plugin == true ]]; then
    discovered=0
    for ((second=0; second<15; second++)); do
        if omarchy plugin list --json | jq -e --arg id "$id" 'any(.[]; .id == $id)' >/dev/null; then discovered=1; break; fi
        sleep 1
    done
    (( discovered )) || fail 'original plugin not discovered after rescan'
    omarchy plugin enable "$id"
fi
# Remove private files only when exact initial build remains; changed binaries
# are user work and remain. Never remove a directory with unknown files.
if [[ $rollback != 1 && -f $receipt/bin.sha256 && -d $bin ]]; then
    bin_owned=1
    while IFS=$'\t' read -r name digest; do
        [[ -f $bin/$name && ! -L $bin/$name && $(sha256sum -- "$bin/$name" | cut -d ' ' -f 1) == "$digest" ]] || bin_owned=0
    done <"$receipt/bin.sha256"
    while IFS= read -r -d '' path; do
        name=${path##*/}
        while IFS=$'\t' read -r recorded _; do [[ $recorded == "$name" ]] && continue 2; done <"$receipt/bin.sha256"
        bin_owned=0
    done < <(find "$bin" -mindepth 1 -maxdepth 1 -print0)
    if (( bin_owned )); then
        while IFS=$'\t' read -r name _; do rm -- "$bin/$name"; done <"$receipt/bin.sha256"
        rmdir -- "$bin" "$(dirname -- "$bin")" || :
    else
        printf 'uninstall-openlogi: private build changed; retaining %s\n' "$bin" >&2
    fi
fi
rm -r -- "$receipt"
printf 'OpenLogi backend and plugin restored.\n'
