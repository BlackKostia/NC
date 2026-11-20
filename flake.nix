{
  description = "Duop — ultra-fast zero-libc dual-pane TUI file manager (static ELF, C23 + assembly PAL)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
      archOf = system: if system == "aarch64-linux" then "aarch64" else "x86_64";
    in {
      packages = forAll (system: pkgs: {
        default = pkgs.stdenv.mkDerivation {
          pname = "duop";
          version = builtins.replaceStrings [ "\n" " " ] [ "" "" ] (builtins.readFile ./VERSION);
          src = ./.;
          # gcc >= 13 on x86_64 (stdenv), clang on aarch64 (the Makefile selects CC per ARCH)
          nativeBuildInputs = [ pkgs.binutils pkgs.gnumake pkgs.python3 ]
            ++ pkgs.lib.optional (system == "aarch64-linux") pkgs.clang;
          hardeningDisable = [ "all" ];
          dontStrip = true;
          buildPhase = "make release ARCH=${archOf system} AS=as LD=ld";
          installPhase = ''
            install -Dm755 duop $out/bin/duop
            install -Dm755 scripts/duop-cd.sh $out/share/duop/duop-cd.sh
            install -Dm644 -t $out/share/duop/layouts layouts/*.layout
            install -Dm644 -t $out/share/duop/lang lang/*.lang
          '';
          meta = {
            description = "Ultra-fast zero-libc dual-pane TUI file manager";
            homepage = "https://github.com/BlackKostia/duop";
            license = pkgs.lib.licenses.mit;
            platforms = systems;
            mainProgram = "duop";
          };
        };
      });
    };
}
