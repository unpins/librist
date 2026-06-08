{
  description = "Standalone build of librist tools (Reliable Internet Stream Transport)";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # librist ships four CLI tools (ristsender / ristreceiver / rist2rist /
  # ristsrppasswd). The shared `nativeFixes.librist` swaps OpenSSL → mbedtls
  # and turns the tools off (ffmpeg only wants librist.a); here we turn them
  # back on and post-link the four into a single multicall `rist` binary —
  # see ./multicall.nix for the link mechanics.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;
      mk = pkgs: extra: import ./multicall.nix { lib = pkgs.lib // ulib; } extra;
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "rist";
      # librist ships under BSD-2-Clause; the MIT/ISC bits are vendored helpers.
      license = "BSD-2-Clause";

      # Pure C, so no libc++ static-link dance (cf. srt). Linux/darwin
      # pkgsStatic links the musl/system libc statically already.
      build = pkgs:
        let sp = pkgs.pkgsStatic; in
        mk pkgs { pkgs = sp; librist = ulib.nativeFixes.librist sp; };

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
