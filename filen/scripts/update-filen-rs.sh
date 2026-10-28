#!/usr/bin/env bash
# Moves the filen/filen-rs submodule to a Filen release tag and records it in filen/FILEN_VERSION.
#   usage: update-filen-rs.sh [tag]      (default: newest filen-js@X.Y.Z tag)
# Prints the new tag on stdout (empty output + exit 0 = already up to date).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_URL="https://github.com/FilenCloudDienste/filen-rs"
CURRENT="$(tr -d '[:space:]' < "$ROOT/FILEN_VERSION")"

latest_tag() {
  git ls-remote --tags --refs "$REPO_URL" 'filen-js@*' \
    | sed 's#.*refs/tags/##' \
    | grep -E '^filen-js@[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V | tail -n1
}

TAG="${1:-$(latest_tag)}"
[[ -n "$TAG" ]] || { echo "no filen-js release tag found" >&2; exit 1; }
if [[ "$TAG" == "$CURRENT" ]]; then exit 0; fi

git -C "$ROOT/.." submodule update --init filen/filen-rs >&2
cd "$ROOT/filen-rs"
git fetch --quiet --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG"
git checkout --quiet --detach "$TAG"
echo "$TAG" > "$ROOT/FILEN_VERSION"
echo "$TAG"
