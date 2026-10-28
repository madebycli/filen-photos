#!/usr/bin/env bash
# Builds Filen's official SDK (filen-rs submodule, unmodified) for Android and generates the
# Kotlin (uniffi) bindings from the very same binary. Android only.
#
#   FILEN_ABIS            ABIs to build (default: arm64-v8a)
#   FILEN_FEATURES        filen-sdk-rs cargo features (default: uniffi,http-provider)
#   FILEN_NATIVE_OUT      output dir (default: build/native)
#   FILEN_CARGO_TARGET_DIR  cargo target dir (default: build/cargo-target)
#   FILEN_PREBUILT_DIR    use an already built output dir (jniLibs/ + kotlin/) instead of building
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="$ROOT/filen-rs"
OUT="${FILEN_NATIVE_OUT:-$ROOT/build/native}"
ABIS="${FILEN_ABIS:-arm64-v8a}"
FEATURES="${FILEN_FEATURES:-uniffi,http-provider}"
export CARGO_TARGET_DIR="${FILEN_CARGO_TARGET_DIR:-$ROOT/build/cargo-target}"

if [[ -n "${FILEN_PREBUILT_DIR:-}" ]]; then
  rm -rf "$OUT"; mkdir -p "$OUT"
  cp -r "$FILEN_PREBUILT_DIR/jniLibs" "$FILEN_PREBUILT_DIR/kotlin" "$OUT/"
  echo "filen-native: using prebuilt output from $FILEN_PREBUILT_DIR"
  exit 0
fi

if [[ ! -f "$SDK/filen-sdk-rs/Cargo.toml" ]]; then
  echo "filen-rs submodule missing: run 'git submodule update --init filen/filen-rs'" >&2
  exit 1
fi
: "${ANDROID_NDK_HOME:=${ANDROID_NDK_ROOT:-}}"
if [[ -z "$ANDROID_NDK_HOME" && -n "${ANDROID_HOME:-}" ]]; then
  ANDROID_NDK_HOME="$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
fi
[[ -d "${ANDROID_NDK_HOME:-}" ]] || { echo "ANDROID_NDK_HOME not set / NDK not found" >&2; exit 1; }
export ANDROID_NDK_HOME

# Fingerprint: skip the (long) build when SDK commit, features and ABIs are unchanged.
STAMP_ID="$(git -C "$SDK" rev-parse HEAD)|$FEATURES|$ABIS"
if [[ -f "$OUT/.stamp" && "$(cat "$OUT/.stamp")" == "$STAMP_ID" ]]; then
  echo "filen-native: up to date ($STAMP_ID)"
  exit 0
fi

rm -rf "$OUT"; mkdir -p "$OUT/jniLibs"
cd "$SDK"   # rust-toolchain.toml (pinned nightly) + .cargo/config.toml of filen-rs apply here

NDK_TARGETS=()
for abi in $ABIS; do NDK_TARGETS+=(-t "$abi"); done
cargo ndk "${NDK_TARGETS[@]}" -o "$OUT/jniLibs" build --release -p filen-sdk-rs --features "$FEATURES" --lib

# Bindings are generated from the built library (uniffi library mode), so they always match it.
# The host-side bindgen links with plain clang: filen-rs' config asks for the `wild` linker, which
# is only a convenience for their dev machines.
FIRST_ABI="${ABIS%% *}"
RUSTFLAGS="-Zhigher-ranked-assumptions" cargo run --release -q -p uniffi-bindgen -- \
  generate --library "$OUT/jniLibs/$FIRST_ABI/libfilen_sdk_rs.so" \
  --language kotlin --no-format --out-dir "$OUT/kotlin"
python3 "$ROOT/scripts/fix-uniffi-kotlin.py" "$OUT/kotlin"

echo "$STAMP_ID" > "$OUT/.stamp"
echo "filen-native: built $STAMP_ID"
