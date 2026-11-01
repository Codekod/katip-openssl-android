#!/usr/bin/env bash
# Builds OpenSSL's libcrypto (static) for Android as a prefab AAR, prefab package "openssl",
# module "crypto" (CMake: find_package(openssl CONFIG), target openssl::crypto).
#
#   ./build.sh <out-dir>           full build (needs ANDROID_NDK_ROOT, Linux x86_64)
#   ./build.sh --verify <out-dir>  download and verify the OpenSSL source only
#
# The source is used only after both checks pass: its SHA-256 as pinned in openssl.env, and a
# valid OpenPGP signature made under the pinned primary key. Builds run in a fixed directory so
# the paths compiled into the library are the same on every machine; the same inputs give the
# same bytes (the workflow builds twice and compares).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=openssl.env
source "$HERE/openssl.env"
export SOURCE_DATE_EPOCH

VERIFY_ONLY=0
if [[ "${1:-}" == "--verify" ]]; then
  VERIFY_ONLY=1
  shift
fi
OUT="${1:?usage: build.sh [--verify] <out-dir>}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

WORK=/tmp/openssl-android-build
rm -rf "$WORK"
mkdir -m 700 "$WORK"
# Ours and private: nobody else can swap the verified source before it is extracted.
[[ -O "$WORK" && "$(stat -c %a "$WORK" 2>/dev/null || stat -f %Lp "$WORK")" == 700 ]] || {
  echo "$WORK is not a private directory" >&2
  exit 1
}
mkdir -m 700 "$WORK/gnupg"

TARBALL="openssl-$OPENSSL_VERSION.tar.gz"
BASE="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION"

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

check_sha256() {
  local actual
  actual="$(sha256 "$WORK/$TARBALL")"
  if [[ "$actual" != "$OPENSSL_SHA256" ]]; then
    echo "SHA-256 mismatch: $actual (expected $OPENSSL_SHA256)" >&2
    exit 1
  fi
}

echo "== source $OPENSSL_VERSION"
curl -fsSL -o "$WORK/$TARBALL" "$BASE/$TARBALL"
curl -fsSL -o "$WORK/$TARBALL.asc" "$BASE/$TARBALL.asc"
curl -fsSL -o "$WORK/pubkeys.asc" "https://openssl-library.org/source/pubkeys.asc"

check_sha256
echo "sha256 ok"

gpg --batch --quiet --homedir "$WORK/gnupg" --import "$WORK/pubkeys.asc" 2>/dev/null
status="$(LC_ALL=C gpg --batch --homedir "$WORK/gnupg" --status-fd 1 \
  --verify "$WORK/$TARBALL.asc" "$WORK/$TARBALL" 2>/dev/null || true)"
# VALIDSIG <signing key> <date> ... <primary key fingerprint>: the last field.
primary="$(printf '%s\n' "$status" | awk '$2 == "VALIDSIG" { print $NF }')"
if ! printf '%s\n' "$status" | grep -q '^\[GNUPG:\] GOODSIG ' || [[ "$primary" != "$OPENSSL_PGP_FINGERPRINT" ]]; then
  echo "OpenPGP signature not valid under $OPENSSL_PGP_FINGERPRINT (got: ${primary:-none})" >&2
  exit 1
fi
echo "signature ok ($primary)"

if [[ $VERIFY_ONLY == 1 ]]; then
  exit 0
fi

: "${ANDROID_NDK_ROOT:?set ANDROID_NDK_ROOT to NDK $NDK_VERSION}"
ndk_revision="$(sed -n 's/^Pkg.Revision *= *//p' "$ANDROID_NDK_ROOT/source.properties")"
if [[ "$ndk_revision" != "$NDK_VERSION" ]]; then
  echo "NDK $ndk_revision, expected $NDK_VERSION" >&2
  exit 1
fi
export PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH"

AAR="$WORK/aar"
MODULE="$AAR/prefab/modules/crypto"
mkdir -p "$MODULE/libs"

for abi in $ABIS; do
  case "$abi" in
    arm64-v8a) target=android-arm64 ;;
    x86_64) target=android-x86_64 ;;
    armeabi-v7a) target=android-arm ;;
    x86) target=android-x86 ;;
    *) echo "unknown ABI $abi" >&2; exit 1 ;;
  esac
  echo "== $abi"
  src="$WORK/src-$abi"
  mkdir -p "$src"
  check_sha256
  tar -xzf "$WORK/$TARBALL" -C "$src" --strip-components=1
  (
    cd "$src"
    ./Configure "$target" \
      no-shared no-module no-dso no-engine no-legacy no-tests no-apps no-docs no-ui-console \
      -D__ANDROID_API__="$ANDROID_API" -fPIC \
      -ffile-prefix-map="$src=openssl-$OPENSSL_VERSION" >/dev/null
    make -j"$(getconf _NPROCESSORS_ONLN)" build_libs >/dev/null
  )
  mkdir -p "$MODULE/libs/android.$abi"
  cp "$src/libcrypto.a" "$MODULE/libs/android.$abi/libcrypto.a"
  llvm-strip --strip-debug "$MODULE/libs/android.$abi/libcrypto.a"
  printf '{"abi":"%s","api":%s,"ndk":%s,"stl":"none","static":true}\n' \
    "$abi" "$ANDROID_API" "${NDK_VERSION%%.*}" >"$MODULE/libs/android.$abi/abi.json"
  # One include directory serves every ABI: the generated headers must agree.
  if [[ -d "$MODULE/include" ]]; then
    diff -r "$MODULE/include/openssl" "$src/include/openssl" >/dev/null || {
      echo "headers differ between ABIs ($abi)" >&2
      exit 1
    }
  else
    mkdir -p "$MODULE/include"
    cp -R "$src/include/openssl" "$MODULE/include/openssl"
  fi
  # OpenSSL's license travels inside the AAR.
  if [[ ! -f "$AAR/LICENSE.txt" ]]; then cp "$src/LICENSE.txt" "$AAR/LICENSE.txt"; fi
done

printf '{"schema_version":2,"name":"openssl","version":"%s","dependencies":[]}\n' \
  "$OPENSSL_VERSION" >"$AAR/prefab/prefab.json"
printf '{"export_libraries":[],"library_name":"libcrypto"}\n' >"$MODULE/module.json"
printf '%s\n' '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="tr.com.moxera.katip.openssl" />' \
  >"$AAR/AndroidManifest.xml"

# Same bytes from the same inputs: fixed file times, sorted entries, no extra attributes.
NAME="openssl-$OPENSSL_VERSION"
(
  cd "$AAR"
  find . -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
  find . -type f | LC_ALL=C sort | sed 's|^\./||' | TZ=UTC zip -X -D -q "$OUT/$NAME.aar" -@
)
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<project xmlns="http://maven.apache.org/POM/4.0.0">' \
  '  <modelVersion>4.0.0</modelVersion>' \
  '  <groupId>tr.com.moxera.katip</groupId>' \
  '  <artifactId>openssl</artifactId>' \
  "  <version>$OPENSSL_VERSION</version>" \
  '  <packaging>aar</packaging>' \
  '</project>' >"$OUT/$NAME.pom"
for f in "$OUT/$NAME.aar" "$OUT/$NAME.pom"; do
  echo "$(sha256 "$f")  $(basename "$f")"
done | tee "$OUT/SHA256SUMS"
