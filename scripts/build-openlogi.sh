#!/usr/bin/env bash
# Build a user-selected upstream release with the external overlay bridge.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly repository=https://github.com/AprilNEA/OpenLogi
readonly patch=$root/patches/external-overlay.patch
cache=${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-openlogi
bin=${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-openlogi/bin
readonly binaries=(openlogi openlogi-agent openlogi-desktop openlogi-overlay)
fail() { printf 'build-openlogi: %s\n' "$*" >&2; exit 1; }
[[ $# -le 1 ]] || fail 'usage: build-openlogi.sh [vMAJOR.MINOR.PATCH]'
for tool in git rustup jq curl flock; do command -v "$tool" >/dev/null || fail "$tool is required"; done
release=${1:-$(curl --fail --silent --show-error https://api.github.com/repos/AprilNEA/OpenLogi/releases/latest | jq -er '.tag_name')}
[[ $release =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "not a stable release tag: $release"
[[ $bin == /* && $cache == /* ]] || fail 'XDG paths must be absolute'
receipt=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-openlogi/install
if [[ -f $receipt/bin-path && $(<"$receipt/bin-path") == "$bin" ]]; then
    fail 'installed binaries must be updated with scripts/update.sh'
fi
[[ ! -L $bin && ( ! -e $bin || -d $bin ) ]] || fail "unsafe binary destination: $bin"
[[ -f $patch ]] || fail "missing $patch"
mkdir -p -- "$cache"
exec 8<"$cache"
flock -n 8 || fail 'another OpenLogi build is running'
checkout=$cache/OpenLogi-$release
if [[ ! -e $checkout ]]; then
    git clone --depth 1 --branch "$release" -- "$repository" "$checkout"
fi
origin=$(git -C "$checkout" remote get-url origin)
[[ ${origin%.git} == "$repository" ]] || fail "unexpected repository in $checkout"
git -C "$checkout" fetch --depth 1 origin "refs/tags/$release"
revision=$(git -C "$checkout" rev-parse 'FETCH_HEAD^{commit}')
[[ $(git -C "$checkout" rev-parse HEAD) == "$revision" ]] || fail "different revision in $checkout; leave user checkout untouched"
# Accept only pristine source or exactly our staged patch, never user edits.
if [[ -z $(git -C "$checkout" status --porcelain) ]]; then
    git -C "$checkout" apply --index --check "$patch" || fail "external overlay patch is incompatible with $release; current installation unchanged"
    git -C "$checkout" apply --index "$patch"
else
    # Compare against applying this patch to the same upstream commit.
    index=$(mktemp -- "$cache/.index.XXXXXX")
    rm -- "$index"
    trap 'rm -f -- "$index"' EXIT
    GIT_INDEX_FILE=$index git -C "$checkout" read-tree "$revision"
    GIT_INDEX_FILE=$index git -C "$checkout" apply --cached "$patch" || fail "patch is incompatible with $release"
    [[ -z $(git -C "$checkout" ls-files --others --exclude-standard) ]] &&
        git -C "$checkout" diff --quiet &&
        [[ $(git -C "$checkout" write-tree) == $(GIT_INDEX_FILE=$index git -C "$checkout" write-tree) ]] ||
        fail "user changes in $checkout; nothing built or installed"
    rm -- "$index"
    trap - EXIT
fi
# Use the selected release's own Rust requirement, not a plugin-pinned toolchain.
(cd -- "$checkout" && cargo test --locked -p openlogi-overlay &&
    cargo test --locked -p openlogi-agent --bin openlogi-agent &&
    cargo build --locked --release -p openlogi --bin openlogi \
        -p openlogi-agent --bin openlogi-agent \
        -p openlogi-desktop --bin openlogi-desktop \
        -p openlogi-overlay --bin openlogi-overlay)

parent=$(dirname -- "$bin")
mkdir -p -- "$parent"
stage=$(mktemp -d -- "$parent/.bin.stage.XXXXXX")
previous=
cleanup() {
    local rc=$?
    if [[ -n $previous && ! -e $bin ]]; then mv -- "$previous" "$bin"; previous=; fi
    rm -rf -- "$stage" ${previous:+"$previous"}
    return "$rc"
}
trap cleanup EXIT
for name in "${binaries[@]}"; do install -m 755 -- "$checkout/target/release/$name" "$stage/$name"; done
for license in LICENSE-MIT LICENSE-APACHE; do install -m 644 -- "$checkout/$license" "$stage/$license"; done
install -m 644 -- "$patch" "$stage/external-overlay.patch"
printf '%s\n' "$revision" >"$stage/REVISION"
printf '%s\n' "$release" >"$stage/RELEASE"
"$stage/openlogi-overlay" --help >/dev/null || fail 'built overlay does not run'
if [[ -e $bin ]]; then
    previous=$(mktemp -d -- "$parent/.bin.previous.XXXXXX")
    rmdir -- "$previous"
    mv -- "$bin" "$previous"
fi
mv -- "$stage" "$bin"
printf 'Built %s (%s) in %s\n' "$release" "$revision" "$bin"
