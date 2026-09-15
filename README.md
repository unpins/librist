# librist

The [librist](https://code.videolan.org/rist/librist) (Reliable Internet Stream Transport) command-line programs, as a single self-contained binary built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/librist/actions/workflows/librist.yml/badge.svg)](https://github.com/unpins/librist/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install librist`.

Low-latency, reliable transport of streams over lossy networks (RIST TR-06-1/2), a libre alternative to SRT.

## Usage

Run a program with [unpin](https://github.com/unpins/unpin):

```bash
unpin librist --unpin-program=ristsender -i udp://@:1234 -o rist://example.com:1968
unpin librist --unpin-program=ristreceiver -i rist://@:1968 -o udp://127.0.0.1:1234
```

Or install them and call each by name, which is usually what you want:

```bash
unpin install librist
ristreceiver -i rist://@:1968 -o udp://127.0.0.1:1234
```

`unpin install librist` creates the `ristsender` (send), `ristreceiver` (receive), `rist2rist` (relay) and `ristsrppasswd` (make SRP password entries) commands.

## Build locally

```bash
nix build github:unpins/librist
./result/bin/rist --unpin-program=ristsender --help
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/librist/releases) page has standalone binaries for manual download.

## Build notes

- **One binary, `rist`,** holds the four programs; `unpin install` creates a command for each.
- **Encryption uses mbedtls** instead of OpenSSL; AES-encrypted (`secret=`) and SRP-authenticated streams work unchanged.
- **Windows:** a single `.exe`, no companion DLLs, with all four programs.
- **No man pages** — librist ships none; each program prints its options with `--help`.
