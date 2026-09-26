# Changelog

## [Unreleased]

## [0.2.11-2] - 2026-09-26

### Added

- On Linux, hostnames now resolve on a machine whose DNS resolver is missing or
  unreachable — Android, or a container with no `/etc/resolv.conf` — once you
  point unpins at a name server. Before, every lookup failed there and the
  stream never left the machine.

### Changed

- A program inside the binary is selected with `--unpin-program=<name>`:
  `rist --unpin-program=ristreceiver -i rist://@:1968 -o udp://127.0.0.1:1234`.
  The positional form (`rist ristreceiver …`) is gone. The installed
  `ristsender`, `ristreceiver`, `rist2rist` and `ristsrppasswd` commands are
  unaffected.

- The build carries a real stream before the binary ships: UDP datagrams go
  into `ristsender`, cross RIST in the clear and AES-128 encrypted to
  `ristreceiver`, and come back out as UDP, and every datagram must arrive
  unchanged. It runs on every target the build host can execute. The check
  before this only printed an SRP password entry.

- Built by the same compiler as the rest of the catalog. The Linux x86_64
  binary shrank from 808 KB to 664 KB; behaviour is unchanged.
