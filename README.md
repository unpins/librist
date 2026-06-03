# librist

Standalone build of the [librist](https://code.videolan.org/rist/librist) (Reliable Internet Stream Transport) command-line tools.

[![Build](https://github.com/unpins/librist/actions/workflows/librist.yml/badge.svg)](https://github.com/unpins/librist/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

Low-latency, reliable transport of streams over lossy networks (RIST TR-06-1/2), a libre alternative to SRT. Ships the upstream programs:

- `ristsender` — send a stream (UDP/file in) over RIST.
- `ristreceiver` — receive a RIST stream and output it (UDP/file/stdout).
- `rist2rist` — relay/repackage one RIST stream into another.
- `ristsrppasswd` — manage SRP authentication password files.

## Usage

Run a program with [unpin](https://github.com/unpins/unpin):

```bash
unpin librist ristsender -i udp://:1234 -o rist://example:1968
unpin librist ristreceiver -i rist://@:1968 -o udp://example:1234
```

To install the programs onto your PATH:

```bash
unpin install librist
```

`unpin install librist` creates the `ristsender`, `ristreceiver`, `rist2rist`, and `ristsrppasswd` commands.

## Build locally

```bash
nix build github:unpins/librist
./result/bin/rist
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/librist/releases) page has standalone binaries for manual download.

## Build notes

- **Single multicall binary** — the four tools are post-linked into one `rist`; tool names are recreated as `argv[0]` shims on install.
- **mbedtls, not OpenSSL** — smaller crypto closure; SRP-authenticated and AES-encrypted streams work unchanged.
- **No man pages** — librist ships none upstream; each tool prints its options with `--help`.
- **Windows:** `mingw` cross, single `.exe`, no companion DLLs. Ships all four tools.

Platform fixes live in [`nix-lib/native-overlay/librist.nix`](https://github.com/unpins/nix-lib/blob/main/native-overlay/librist.nix) + [`nix-lib/mingw-overlay/librist.nix`](https://github.com/unpins/nix-lib/blob/main/mingw-overlay/librist.nix); the multicall link recipe is in [`multicall.nix`](./multicall.nix).
