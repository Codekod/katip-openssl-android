# OpenSSL libcrypto for Android (prefab AAR)

OpenSSL's `libcrypto`, built as a **static** library for Android and packaged as a prefab AAR:
prefab package `openssl`, module `crypto` (CMake: `find_package(openssl CONFIG)`, target
`openssl::crypto`). Maven coordinates: `tr.com.moxera.katip:openssl:<version>`.

- **Version:** OpenSSL 3.5 LTS only (supported until 2030-04-08). See `openssl.env`.
- **Built for:** `arm64-v8a`, `x86_64`; Android API 24; NDK 27.1.12297006; no `libssl`.
- **Built by:** the `build` workflow in this repository, on GitHub-hosted runners. It builds
  twice and fails unless both results are byte for byte the same. Releases are published by
  hand from `main`, carry a build provenance attestation and are immutable.

## How the source is checked

`build.sh` uses the OpenSSL source only after both checks pass:

1. the SHA-256 of `openssl-<version>.tar.gz` equals `OPENSSL_SHA256` in `openssl.env`;
2. its OpenPGP signature is valid and made under the primary key
   `B146 647E 45A7 B339 47AB 226B 2A2C 87D1 6169 2D40`, the trust anchor published on
   <https://openssl-library.org/source/>.

## How to verify a release

```sh
gh release download openssl-3.5.9 --repo Codekod/katip-openssl-android
sha256sum -c SHA256SUMS
gh attestation verify openssl-3.5.9.aar --repo Codekod/katip-openssl-android \
  --signer-workflow Codekod/katip-openssl-android/.github/workflows/build.yml
gh attestation verify openssl-3.5.9.pom --repo Codekod/katip-openssl-android \
  --signer-workflow Codekod/katip-openssl-android/.github/workflows/build.yml
```

To rebuild it yourself on Linux x86_64 with the NDK above: `ANDROID_NDK_ROOT=<ndk> ./build.sh out`
and compare `out/SHA256SUMS` with the release.

## License

OpenSSL is licensed under the Apache License 2.0. Its license text (`LICENSE.txt` from the
OpenSSL source) is inside every AAR. The scripts and workflow in this repository are also
under the Apache License 2.0.
