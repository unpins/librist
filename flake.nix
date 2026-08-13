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
    in
    ulib.mkStandaloneFlake {
      inherit self;
      dnsFallback = true; # resolves hostnames; opt into the Android DNS fallback
      name = "rist";
      smoke = [ "--unpin-program=ristsrppasswd" "unpins-smoke" "secret" ];
      smokePattern = "^unpins-smoke:";
      # librist ships under BSD-2-Clause; the MIT/ISC bits are vendored helpers.
      license = "BSD-2-Clause";
      # No smoke: the tools have no version/help flag — each starts its network
      # transport immediately on invocation (a bare `rist` prints the program
      # menu). Upstream ships no man pages for them either, so nothing to embed.

      engine = "unpin-llvm";
      multicall.windows = true;
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
          # cmocka's doCheck, cjson's -Werror block and mbedtls' darwin fixes all
          # live in nix-lib's native-overlay now, and it autoWires into this very
          # pkgsStatic — a copy here lands ON TOP of it. For mbedtls that was not
          # merely redundant: the nested postConfigure clobbered its own saved
          # $PWD and left the build phase outside build/ (no build.ninja).
          sp = pkgs.pkgsStatic;
        in
        withTools ((ulib.nativeFixes.librist sp).override { stdenv = eng; });

      # mingw cross. No per-package stdenv swap: multicall.windows = true puts
      # the whole set on the engine adapter already.
      windowsBuild = pkgs:
        withTools (ulib.nativeFixes.librist (ulib.mingwStaticCross pkgs));
    };
}
