#!/usr/bin/env bash
# Build the four OpenLogi 0.8.10 binaries with the external overlay patch and
# stage them in a private directory. Never touches /usr, PATH, or services.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly repository=https://github.com/AprilNEA/OpenLogi
readonly revision=19036d7fe86abe11cdb628da11ff89aa5fb7a204
readonly toolchain=1.98.0
readonly patch=$root/patches/openlogi-0.8.10-external-overlay.patch
cache=${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-openlogi
bin=${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-openlogi/0.8.10/bin
readonly binaries=(openlogi openlogi-agent openlogi-desktop openlogi-overlay)

fail() { printf 'build-openlogi: %s\n' "$*" >&2; exit 1; }

# The exact form the patch was generated in, independent of user git config.
staged_patch() {
    git -C "$1" diff --cached --full-index --no-color --no-ext-diff --no-textconv \
        --diff-algorithm=myers --indent-heuristic --src-prefix=a/ --dst-prefix=b/
}

# pristine: the pinned revision, untouched. patched: exactly this patch,
# staged. other: anything else, which is never modified here.
checkout_state() {
    local dir=$1
    [[ $(git -C "$dir" rev-parse HEAD 2>/dev/null) == "$revision" ]] || { echo other; return; }
    if [[ -z $(git -C "$dir" status --porcelain) ]]; then
        echo pristine
    elif git -C "$dir" diff --quiet &&
        [[ -z $(git -C "$dir" ls-files --others --exclude-standard) ]] &&
        staged_patch "$dir" | cmp -s - "$patch"; then
        echo patched
    else
        echo other
    fi
}

command -v rustup >/dev/null || fail "rustup is required (omarchy pkg add rustup)"
rustup run "$toolchain" cargo --version >/dev/null 2>&1 ||
    fail "Rust $toolchain is required (rustup toolchain install $toolchain --profile minimal --component rustfmt,clippy)"
[[ -f $patch ]] || fail "missing $patch"

checkout=$cache/OpenLogi
if [[ -e $checkout ]] && [[ $(checkout_state "$checkout") == other ]]; then
    printf 'build-openlogi: %s has other changes; using a separate checkout\n' "$checkout" >&2
    checkout=$cache/OpenLogi-$revision
fi
if [[ ! -e $checkout ]]; then
    mkdir -p -- "$cache"
    git clone --no-checkout -- "$repository" "$checkout"
    git -C "$checkout" checkout --quiet --detach "$revision"
fi
case $(checkout_state "$checkout") in
    pristine)
        git -C "$checkout" apply --index --check "$patch" || fail "patch does not apply to $checkout"
        git -C "$checkout" apply --index "$patch"
        ;;
    patched) ;;
    *) fail "$checkout is not the pinned revision with exactly this patch; nothing was built or installed" ;;
esac

(
    cd -- "$checkout"
    cargo "+$toolchain" test --locked -p openlogi-overlay
    cargo "+$toolchain" test --locked -p openlogi-agent --bin openlogi-agent
    cargo "+$toolchain" build --locked --release \
        -p openlogi --bin openlogi \
        -p openlogi-agent --bin openlogi-agent \
        -p openlogi-desktop --bin openlogi-desktop \
        -p openlogi-overlay --bin openlogi-overlay
)

parent=$(dirname -- "$bin")
mkdir -p -- "$parent"
stage=$(mktemp -d -- "$parent/.bin.stage.XXXXXX")
previous=
cleanup() { rm -rf -- "$stage" ${previous:+"$previous"}; }
trap cleanup EXIT
for name in "${binaries[@]}"; do
    install -m 755 -- "$checkout/target/release/$name" "$stage/$name"
done
for license in LICENSE-MIT LICENSE-APACHE; do
    install -m 644 -- "$checkout/$license" "$stage/$license"
done
install -m 644 -- "$patch" "$stage/external-overlay.patch"
printf '%s\n' "$revision" >"$stage/REVISION"
"$stage/openlogi-overlay" --help >/dev/null || fail "built overlay does not run"

# Running processes keep their old inode; the next start uses the new files.
if [[ -e $bin ]]; then
    previous=$(mktemp -d -- "$parent/.bin.previous.XXXXXX")
    rmdir -- "$previous"
    mv -- "$bin" "$previous"
fi
mv -- "$stage" "$bin"
printf 'Installed compatible binaries in %s\n' "$bin"
