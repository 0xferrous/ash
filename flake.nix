{
  description = "ash - a simple OCaml CLI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        ocamlPackages = pkgs.ocamlPackages;
        inherit (pkgs.lib) cleanSourceWith hasPrefix;

        src = cleanSourceWith {
          src = ./.;
          filter =
            path: type:
            let
              base = baseNameOf path;
            in
            !(base == "_build" || base == "result" || hasPrefix "result-" base || base == ".direnv");
        };

        ashBuild = ocamlPackages.buildDunePackage {
          pname = "ash";
          version = "0.1.3";
          inherit src;
          duneVersion = "3";

          nativeBuildInputs = [ pkgs.git ];

          propagatedBuildInputs = [
            ocamlPackages.base64
            ocamlPackages.cmdliner
            ocamlPackages.msgpck
            ocamlPackages.otoml
            ocamlPackages.yojson
          ];

          strictDeps = true;
        };

        ash = pkgs.runCommand "${ashBuild.pname}-${ashBuild.version}" { } ''
          install -Dm755 ${ashBuild}/bin/ash "$out/bin/ash"
        '';

        ash-command-pages = pkgs.stdenvNoCC.mkDerivation {
          pname = "ash-command-pages";
          version = "0.1.3";
          dontUnpack = true;
          installPhase = ''
            runHook preInstall
            mkdir -p "$out/share/doc/ash/html"
            ${ashBuild}/bin/ash-docs-html "$out/share/doc/ash/html"
            runHook postInstall
          '';
        };
      in
      {
        packages = {
          default = ash;
          ash = ash;
          all = ashBuild;
          command-pages = ash-command-pages;
          ash-command-pages = ash-command-pages;
        };

        apps.default = {
          type = "app";
          program = "${ash}/bin/ash";
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [ ashBuild ];
          packages = [
            ocamlPackages.ocaml
            ocamlPackages.dune_3
            ocamlPackages.ocamlformat
            ocamlPackages.msgpck
            ocamlPackages.otoml
            ocamlPackages.utop
          ];
        };
      }
    );
}
