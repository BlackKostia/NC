{
  description = "Duop — Dual-pane TUI file manager in pure GNU Assembler (zero libc)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      packages.${system}.default = pkgs.stdenvNoCC.mkDerivation {
        pname = "duop";
        version = builtins.replaceStrings ["\n" " "] ["" ""] (builtins.readFile ./VERSION);
        src = ./.;
        nativeBuildInputs = [ pkgs.binutils pkgs.gnumake ];
        buildPhase = "make release";
        installPhase = ''
          mkdir -p $out/bin $out/share/duop
          cp duop $out/bin/duop
          cp scripts/duop-cd.sh $out/share/duop/duop-cd.sh
          mkdir -p $out/share/duop/layouts
          cp layouts/*.layout $out/share/duop/layouts/
          mkdir -p $out/share/duop/lang
          cp lang/*.lang $out/share/duop/lang/
        '';
      };
    };
}
