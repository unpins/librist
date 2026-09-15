{
  description = "librist tools (Reliable Internet Stream Transport) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # librist ships four CLI tools (ristsender / ristreceiver / rist2rist /
  # ristsrppasswd) folded into one argv[0]-dispatching `rist` binary. The
  # shared `nativeFixes.librist` swaps OpenSSL → mbedtls and turns the tools
  # off (ffmpeg only wants librist.a); here we turn them back on.
  #
  # Every target builds under the unpin-llvm engine (all objects LLVM bitcode)
  # and lets mkStandaloneFlake's bitcode self-fold pack the four tools into one
  # binary — no hand `ld -r`/objcopy surgery.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      # Pure C (no libc++), lto + link capture so the self-fold can relink the
      # four tools from the captured link inputs.
      engStdenv = pkgs:
        let sp = pkgs.pkgsStatic; in
        ulib.unpinAdapterStdenv {
          inherit pkgs;
          target = sp.stdenv.hostPlatform.config;
          native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
          cxx = false;
          lto = true;
          captureLinks = true;
        };

      # nativeFixes.librist with the tools re-enabled (drop -Dbuilt_tools=false)
      # and a single output (we ship only the folded binary, no lib/headers/.pc).
      withTools = drv: drv.overrideAttrs (o: {
        mesonFlags =
          (builtins.filter (f: f != "-Dbuilt_tools=false") (o.mesonFlags or [ ]))
          ++ [ "-Dbuilt_tools=true" ];
        outputs = [ "out" ];
        postInstall = "";
      });

      # A smoke that prints a password entry passes a binary that cannot carry a
      # stream, so the native build sends one for real on loopback: UDP
      # datagrams go into ristsender, over RIST (in the clear and AES-128
      # encrypted) to ristreceiver, and back out as UDP; every datagram must
      # arrive unchanged. Runs wherever the build machine can execute the result.
      withRoundTrip = pkgs: drv: drv.overrideAttrs (old: {
        doInstallCheck = pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform;
        nativeInstallCheckInputs = (old.nativeInstallCheckInputs or [ ])
          ++ [ pkgs.buildPackages.python3 ];
        installCheckPhase = ''
          runHook preInstallCheck
          b=$out/bin
          fail() { echo "installCheck: $*"; exit 1; }
          for enc in "" "?secret=0123456789abcdef&aes-type=128"; do
            inp=$((20000 + RANDOM % 5000)); rist=$((26000 + RANDOM % 2000)); outp=$((30000 + RANDOM % 5000))
            python3 - "$outp" > received.txt <<'PY' &
        import hashlib, socket, sys
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", int(sys.argv[1]))); s.settimeout(10)
        h = hashlib.sha256(); n = 0
        try:
            while True:
                d, _ = s.recvfrom(65536); h.update(d); n += 1
        except socket.timeout:
            pass
        print(n, h.hexdigest())
        PY
            sink=$!
            "$b/ristreceiver" -i "rist://@127.0.0.1:$rist$enc" -o "udp://127.0.0.1:$outp" > rx.log 2>&1 &
            rx=$!
            sleep 1
            "$b/ristsender" -i "udp://@127.0.0.1:$inp" -o "rist://127.0.0.1:$rist$enc" > tx.log 2>&1 &
            tx=$!
            sleep 2
            python3 - "$inp" > sent.txt <<'PY'
        import hashlib, socket, sys, time
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); h = hashlib.sha256()
        for i in range(200):
            d = bytes((i * 7 + j) % 256 for j in range(1316))
            s.sendto(d, ("127.0.0.1", int(sys.argv[1]))); h.update(d); time.sleep(0.005)
        print(200, h.hexdigest())
        PY
            wait "$sink" || true
            kill "$rx" "$tx" 2>/dev/null || true
            wait "$rx" "$tx" 2>/dev/null || true
            cmp -s sent.txt received.txt \
              || { cat tx.log rx.log; fail "RIST''${enc:+ (encrypted)} delivered $(cat received.txt), sent $(cat sent.txt)"; }
          done
          echo "installCheck: RIST carried every datagram intact, in the clear and encrypted"
          runHook postInstallCheck
        '';
      });
    in
    ulib.mkStandaloneFlake {
      inherit self;
      dnsFallback = true; # resolves hostnames; opt into the Android DNS fallback
      name = "rist";
      smoke = [ "--unpin-program=ristsrppasswd" "unpins-smoke" "secret" ];
      smokePattern = "^unpins-smoke:";
      # librist ships under BSD-2-Clause; the MIT/ISC bits are vendored helpers.
      license = "BSD-2-Clause";
      # ristsrppasswd prints a password entry and exits, which makes it the one
      # program a smoke can run without opening a network transport.

      engine = "unpin-llvm";
      multicall.windows = true;
      multicall.programs = [
        # librist installs no man pages at all.
        { name = "ristsender"; noMan = true; }
        { name = "ristreceiver"; noMan = true; }
        { name = "rist2rist"; noMan = true; }
        { name = "ristsrppasswd"; noMan = true; }
      ];

      # Engine + bitcode self-fold (native Linux + darwin): the four tools are
      # C, so pkgsStatic already links musl statically and there is no libc++
      # dance (cf. srt). Return the engine-built librist directly; the self-fold
      # packs the tools.
      build = pkgs:
        let
          eng = engStdenv pkgs;
          # cmocka's doCheck, cjson's -Werror block and mbedtls' darwin fixes all
          # live in nix-lib's native-overlay now, and it autoWires into this very
          # pkgsStatic — a copy here lands ON TOP of it. For mbedtls that was not
          # merely redundant: the nested postConfigure clobbered its own saved
          # $PWD and left the build phase outside build/ (no build.ninja).
          sp = pkgs.pkgsStatic;
        in
        withRoundTrip pkgs (withTools ((ulib.nativeFixes.librist sp).override { stdenv = eng; }));

      # mingw cross. No per-package stdenv swap: multicall.windows = true puts
      # the whole set on the engine adapter already.
      windowsBuild = pkgs:
        withTools (ulib.nativeFixes.librist (ulib.mingwStaticCross pkgs));
    };
}
