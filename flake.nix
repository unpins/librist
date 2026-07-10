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
  # Native (Linux/darwin): build under the unpin-llvm engine (all objects LLVM
  # bitcode) and let mkStandaloneFlake's bitcode self-fold pack the four tools
  # into one binary — no hand `ld -r`/objcopy surgery. Windows (mingw, no
  # engine → native objects) still uses ./multicall.nix's objcopy fold, since
  # objcopy cannot rewrite bitcode and must NOT run over an engine build.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;
      mk = pkgs: extra: import ./multicall.nix { lib = pkgs.lib // ulib; } extra;

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
    in
    ulib.mkStandaloneFlake {
      inherit self;
      dnsFallback = true; # resolves hostnames; opt into the Android DNS fallback
      name = "rist";
      # librist ships under BSD-2-Clause; the MIT/ISC bits are vendored helpers.
      license = "BSD-2-Clause";
      # No smoke: the tools have no version/help flag — each starts its network
      # transport immediately on invocation (a bare `rist` prints the program
      # menu). Upstream ships no man pages for them either, so nothing to embed.

      engine = "unpin-llvm";
      multicall.programs = [
        { name = "ristsender"; }
        { name = "ristreceiver"; }
        { name = "rist2rist"; }
        { name = "ristsrppasswd"; }
      ];

      # Engine + bitcode self-fold (native Linux + darwin): the four tools are
      # C, so pkgsStatic already links musl statically and there is no libc++
      # dance (cf. srt). Return the engine-built librist directly; the self-fold
      # packs the tools.
      build = pkgs:
        let
          eng = engStdenv pkgs;
          isDarwin = pkgs.pkgsStatic.stdenv.hostPlatform.isDarwin;
          # cmocka rides in librist's buildInputs (its own test suite, which we
          # keep off via -Dtest=false), and cmocka-static's `waiter_test_wrap`
          # self-test fails under musl — a wrap/timing flake in cmocka's checks,
          # nothing we link. Disable cmocka's doCheck so the dead-weight dep just
          # builds; it never enters the folded binary (closure stays 0-ref).
          sp = pkgs.pkgsStatic.extend (_: prev: {
            cmocka = prev.cmocka.overrideAttrs (_: { doCheck = false; });
          } // pkgs.lib.optionalAttrs isDarwin {
            # nixpkgs' mbedtls hardcodes -DCMAKE_C_FLAGS=-fzero-init-padding-bits=
            # unions (a GCC-15 union-padding workaround). On Linux mbedtls builds
            # under gcc (which has the flag); on darwin the engine builds the whole
            # set with the unpin clang, which rejects the GCC-only flag → CMake's
            # compiler check fails. clang has no equivalent, so strip it — darwin
            # only, so Linux/cross keep their hash.
            mbedtls = prev.mbedtls.overrideAttrs (o: {
              cmakeFlags = builtins.filter
                (f: f != "-DCMAKE_C_FLAGS=-fzero-init-padding-bits=unions")
                (o.cmakeFlags or [ ])
                # mbedtls' demo programs and test suite build with -Werror; on
                # darwin pkgsStatic's inert `-static-libgcc` trips -Wunused-command-
                # line-argument → fatal. We link only libmbed{crypto,tls,x509}.a,
                # never the demos/tests, so skip building them entirely.
                ++ [ "-DENABLE_PROGRAMS=OFF" "-DENABLE_TESTING=OFF" ];
              # nixpkgs' mbedtls postConfigure runs `perl scripts/config.pl set …`
              # to enable threading. Under the darwin engine cmake builds
              # out-of-source (CWD = build/, scripts/ is a level up) whereas Linux
              # builds in-source, so the relative path fails. Run it from wherever
              # scripts/config.pl actually is, then return.
              postConfigure = ''
                __d=$PWD
                [ -f scripts/config.pl ] || cd ..
                ${o.postConfigure or ""}
                cd "$__d"
              '';
            });
            # cjson's CMake turns on -Werror (ENABLE_CUSTOM_COMPILER_FLAGS). On
            # darwin pkgsStatic's inert `-static-libgcc` link flag (valid on
            # Linux, no-op on darwin) trips -Wunused-command-line-argument, which
            # -Werror makes fatal. Drop cjson's strict-flag block on darwin — its
            # own warnings, nothing we depend on.
            cjson = prev.cjson.overrideAttrs (o: {
              cmakeFlags = (o.cmakeFlags or [ ]) ++ [ "-DENABLE_CUSTOM_COMPILER_FLAGS=OFF" ];
            });
          });
        in
        withTools ((ulib.nativeFixes.librist sp).override { stdenv = eng; });

      # The tools are C with winpthreads; force the runtime static so the .exe
      # carries no libwinpthread-1 / libgcc_s DLLs (the ninja link line that
      # multicall.nix reuses doesn't carry mkStandaloneFlake's -all-static).
      windowsBuild = pkgs:
        let cross = ulib.mingwStaticCross pkgs; in
        mk pkgs {
          pkgs = cross;
          librist = ulib.nativeFixes.librist cross;
          extraLinkFlags = "-static -static-libgcc";
        };
    };
}
