# Upstream librist builds four separate tool binaries — ristsender,
# ristreceiver, rist2rist and ristsrppasswd. To honour the unpins
# one-pkg-one-bin rule we post-link them into a single multicall binary at
# $out/bin/rist; `lib.withAliases` then embeds the tool names as an UNPIN_META
# block so unpin's installer can recreate the argv[0] shims.
#
# librist is meson/ninja/C (srt was CMake/C++), so the link mechanics differ
# from srt/multicall.nix in two ways:
#
#   * No OBJECT library. meson compiles the shared tool helpers (oob_shared,
#     srp_shared, contrib/time-shim, contrib/pthread-shim) ONCE PER TOOL into
#     tools/<tool>.p/. Renaming a shared symbol the srt way would break it: the
#     def lives in oob_shared.c.o but the refs live in <tool>.c.o — different
#     objects. Instead we keep ONE full object set (the template tool, which
#     carries the shared superset) and splice in only each other tool's own
#     <tool>.c.o. Shared symbols then resolve once from the template; the only
#     clashes left are `main` (every tool) plus any global a tool defines in
#     its own .c — both def and refs in the same object, so a per-tool
#     `objcopy --redefine-sym` stays self-consistent.
#
#   * The resolved link line comes from `ninja -t commands tools/<tool>`
#     (last line), not CMake's link.txt.
#
# ristsender is the template: it pulls oob_shared + srp_shared + both shims, a
# superset of what the other tools' .c.o reference. We reuse its link line
# verbatim (exact compiler, flags, librist.a + the lib group — mbedcrypto,
# cjson, -lm, winpthreads on mingw — in the right order), splice in the other
# tools' .c.o + dispatcher.o, and rename the output to `rist`.
{ lib }:
{ pkgs, librist, name ? "rist", extraLinkFlags ? "" }:
let
  multicall = librist.overrideAttrs (old: {
    pname = "librist-multi";

    # Re-enable the tools the library overlay turns off, and collapse to a
    # single output (we ship only the multicall binary, no lib/headers/.pc).
    mesonFlags =
      (builtins.filter (f: f != "-Dbuilt_tools=false") (old.mesonFlags or [ ]))
      ++ [ "-Dbuilt_tools=true" ];
    outputs = [ "out" ];
    # The library overlay's propagated cjson/mbedtls and any .pc sed are moot
    # here (no .pc shipped). withAliases re-appends its own postInstall on top.
    postInstall = "";

    # mingw only: the tools force POSIX pthreads (HAVE_PTHREADS=1, set by the
    # mingw overlay so librist's pthread-shim short-circuits to the real
    # winpthreads headers) and mbedcrypto pulls BCryptGenRandom — but meson's
    # `threads` dep adds no -l on mingw and nothing linked an executable in the
    # lib-only (ffmpeg) build, so neither lib reached the link line. Append both
    # after the archive group (NIX_LDFLAGS lands at the end of the link) so
    # meson's own tool link AND the multicall relink below resolve.
    preBuild = (old.preBuild or "") + lib.optionalString pkgs.stdenv.hostPlatform.isWindows ''
      export NIX_LDFLAGS="''${NIX_LDFLAGS:-} -lwinpthread -lbcrypt"
    '';

    postBuild = (old.postBuild or "") + ''
      mkdir -p multicall

      # meson's per-tool object dir + suffix differ by toolchain: unix gcc emits
      # tools/<tool>.p/<tool>.c.o; mingw emits tools/<tool>.exe.p/<tool>.c.obj
      # (the .exe rides in the dir name too). Probe ristsender (always built).
      exe=""; objext=o
      if [ -f "tools/ristsender.exe.p/ristsender.c.obj" ]; then
        exe=.exe; objext=obj
      fi
      # Per-tool main object and ninja target, given the toolchain layout.
      mobj() { echo "tools/$1$exe.p/$1.c.$objext"; }

      # Present tools (existence gates any platform that drops one). ristsender
      # first: it carries the shared-helper superset, so it is the template.
      apps=()
      for a in ristsender ristreceiver rist2rist ristsrppasswd; do
        [ -f "$(mobj "$a")" ] && apps+=("$a")
      done
      [ ''${#apps[@]} -ge 1 ] || { echo "multicall: no librist tools built" >&2; exit 1; }
      printf '%s\n' "''${apps[@]}" > multicall/apps.list

      # Platform symbol prefix (Mach-O leads C symbols with '_'), read once from
      # the template's main.
      obj0="$(mobj "''${apps[0]}")"
      if $NM --defined-only "$obj0" | awk '$3=="_main"{f=1} END{exit !f}'; then
        up=_
      else
        up=""
      fi

      # Rename each tool's main → <tool>_main so the dispatcher can reach them
      # as distinct entry points. main is the one clash known a priori; any
      # others are discovered from the linker in the iterative link below.
      for a in "''${apps[@]}"; do
        san=$(echo "$a" | tr '-' '_')
        $OBJCOPY --redefine-sym "''${up}main=''${up}''${san}_main" "$(mobj "$a")"
      done

      # Dispatcher (shared canonical generator — see nix-lib
      # lib.multicallDispatcherC). It derives each app's C symbol from the applet
      # name in multicall/apps.list via `tr -c 'A-Za-z0-9_' '_'`, matching the
      # `tr '-' '_'` rename above (rist-* → rist_*).
${lib.multicallDispatcherC { inherit name; }}
      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      # Iterative link. Reuse the template tool's resolved ninja link line
      # verbatim (exact compiler, flags, its full object set incl. the shared
      # helpers, librist.a and the lib group in the right order); splice in the
      # other tools' own .c.o + dispatcher.o before the lib group and rename the
      # output (the link line's output token carries .exe on mingw, so split it
      # off — we always emit multicall/${name}).
      #
      # Each failed attempt names the *strong* duplicate symbols ("multiple
      # definition" / "duplicate symbol"); weak/COMDAT defs merge silently. We
      # trust the linker rather than predict from nm. Rename each reported
      # symbol in every tool that defines it, then relink. -Wl,--no-demangle
      # makes GNU ld print mangled names objcopy can consume (ld64 already
      # prints raw symbols). Pure C here, so beyond main this typically
      # converges in one pass.
      template="''${apps[0]}"
      line=$(ninja -t commands "tools/$template$exe" | tail -1)
      pre="''${line%% -o *}"
      post="''${line#* -o }"
      oldname="''${post%% *}"
      libs="''${post#"$oldname"}"
      extra=""
      for a in "''${apps[@]:1}"; do
        extra="$extra $(mobj "$a")"
      done
      nodemangle=-Wl,--no-demangle
      case "$($CC -dumpmachine)" in *darwin*) nodemangle="" ;; esac

      # Demangler to map the linker's reported clash back to the raw nm symbol
      # objcopy needs (ld64 always demangles and has no flag to stop it). The
      # toolchain ships it next to nm.
      nmdir=$(dirname "$(command -v ''${NM%% *})")
      demangle=cat
      for c in c++filt llvm-cxxfilt; do
        if [ -x "$nmdir/$c" ]; then demangle="$nmdir/$c"; break; fi
        command -v "$c" >/dev/null 2>&1 && { demangle=$c; break; }
      done

      converged=0
      for _ in $(seq 1 30); do
        if eval "$pre $extra multicall/dispatcher.o -o multicall/${name} $libs $nodemangle ${extraLinkFlags}" 2>multicall/link.err; then
          converged=1; break
        fi
        cat multicall/link.err >&2
        sed -nE "s/.*multiple definition of [\`']([^']+)'.*/\1/p; s/.*duplicate symbol '([^']+)'.*/\1/p" \
          multicall/link.err | sort -u > multicall/clash.syms
        [ -s multicall/clash.syms ] || { echo "multicall: link failed without a duplicate-symbol diagnostic" >&2; exit 1; }
        while IFS= read -r sym; do
          hit=0
          for a in "''${apps[@]}"; do
            obj="$(mobj "$a")"
            $NM --defined-only "$obj" | awk '{print $3}' > multicall/raw.syms
            sed 's/^_//' multicall/raw.syms | $demangle > multicall/dem.syms
            raw=$(paste multicall/raw.syms multicall/dem.syms \
                  | awk -F'\t' -v s="$sym" '$1==s || $2==s {print $1; exit}')
            [ -n "$raw" ] || continue
            san=$(echo "$a" | tr '-' '_')
            $OBJCOPY --redefine-sym "$raw=''${up}''${san}__''${raw#"$up"}" "$obj"
            hit=1
          done
          [ "$hit" = 1 ] || { echo "multicall: clashing symbol '$sym' not defined by any tool object" >&2; exit 1; }
        done < multicall/clash.syms
      done
      [ "$converged" = 1 ] || { echo "multicall: link did not converge in 30 passes" >&2; exit 1; }

      # mingw gcc auto-appends .exe; normalize to the suffixless name
      # installPhase and withAliases expect (Windows postFixup re-adds .exe
      # after the UNPIN_META embed).
      [ -f multicall/${name} ] || mv multicall/${name}.exe multicall/${name}
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      install -m755 multicall/${name} "$out/bin/${name}"
      while IFS= read -r a; do
        [ -n "$a" ] && ln -s ${name} "$out/bin/$a"
      done < multicall/apps.list
      runHook postInstall
    '';
  });
  # withAliases harvests the tool symlinks, embeds them as UNPIN_META and
  # objcopies into `$out/bin/${name}` (its `primary`). On mingw the shipped
  # file must be `${name}.exe`; rename after the embed (symlinks are already
  # gone by then, so nothing dangles).
  aliased = lib.withAliases pkgs
    {
      primary = name;
      aliasesFromSymlinksIn = "bin";
    }
    multicall;
in
if pkgs.stdenv.hostPlatform.isWindows
then aliased.overrideAttrs (o: {
  postFixup = (o.postFixup or "") + ''
    [ -f "$out/bin/${name}" ] && mv "$out/bin/${name}" "$out/bin/${name}.exe"
  '';
})
else aliased
