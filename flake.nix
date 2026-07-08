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

          propagatedBuildInputs = [
            ocamlPackages.cmdliner
            ocamlPackages.otoml
          ];

          strictDeps = true;
        };
      in
      {
        packages = {
          default = ash;
          ash = ash;
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
          ];
        };
      });
}
