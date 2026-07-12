{
  description = "ash - a simple OCaml CLI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        ocamlPackages = pkgs.ocamlPackages;
        inherit (pkgs.lib) cleanSourceWith hasPrefix;

        src = cleanSourceWith {
          src = ./.;
          filter = path: type:
            let base = baseNameOf path;
            in !(base == "_build"
              || base == "result"
              || hasPrefix "result-" base
              || base == ".direnv");
        };

        ash = ocamlPackages.buildDunePackage {
          pname = "ash";
          version = "0.1.0";
          inherit src;
          duneVersion = "3";

          nativeBuildInputs = [ pkgs.git ];

          propagatedBuildInputs = [
            ocamlPackages.cmdliner
            ocamlPackages.otoml
            ocamlPackages.yojson
          ];

          strictDeps = true;
        };

        ash-command-pages = pkgs.stdenvNoCC.mkDerivation {
          pname = "ash-command-pages";
          version = "0.1.0";
          dontUnpack = true;
          installPhase = ''
            runHook preInstall
            mkdir -p "$out/share/doc/ash/html"
            ${ash}/bin/ash-docs-html "$out/share/doc/ash/html"
            runHook postInstall
          '';
        };
      in
      {
        packages = {
          default = ash;
          ash = ash;
          command-pages = ash-command-pages;
          ash-command-pages = ash-command-pages;
        };

        apps.default = flake-utils.lib.mkApp { drv = ash; };

        devShells.default = pkgs.mkShell {
          inputsFrom = [ ash ];
          packages = [
            ocamlPackages.ocaml
            ocamlPackages.dune_3
            ocamlPackages.ocamlformat
            ocamlPackages.otoml
            ocamlPackages.utop
            pkgs.nodejs
          ];
        };
      });
}
