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
    let
      testSystem = "x86_64-linux";
      mkImageReconcileConfiguration =
        version:
        nixpkgs.lib.nixosSystem {
          system = testSystem;
          modules = [
            (nixpkgs + "/nixos/modules/profiles/minimal.nix")
            (nixpkgs + "/nixos/modules/profiles/bashless.nix")
            (
              { lib, pkgs, ... }:
              let
                marker = pkgs.writeText "ash-image-reconcile-${version}" version;
              in
              {
                networking.hostName = "ash-image-${version}";
                system.stateVersion = "26.05";
                boot.kernel.enable = false;
                boot.initrd.enable = false;
                boot.loader.grub.enable = false;
                system.disableInstallerTools = true;
                system.forbiddenDependenciesRegexes = lib.mkForce [ ];
                fileSystems."/" = {
                  device = "none";
                  fsType = "tmpfs";
                };
                documentation.enable = false;
                environment.defaultPackages = [ ];
                environment.etc."ash-image-reconcile-version".source = marker;
              }
            )
          ];
        };
      imageReconcileFirst = mkImageReconcileConfiguration "first";
      imageReconcileSecond = mkImageReconcileConfiguration "second";
    in
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
          version = "0.1.5";
          inherit src;
          duneVersion = "3";

          nativeBuildInputs = [ pkgs.git ];

          buildInputs = [ pkgs.e2fsprogs ];

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

        agentPortalHost = pkgs.runCommand "agent-portal-host" { } ''
          install -Dm755 ${ashBuild}/bin/agent-portal-host "$out/bin/agent-portal-host"
        '';

        agentPortalCli = pkgs.runCommand "agent-portal-cli" { } ''
          install -Dm755 ${ashBuild}/bin/agent-portal-cli "$out/bin/agent-portal-cli"
        '';

        nixExt4Image = pkgs.runCommand "nix-ext4-image" { } ''
          install -Dm755 ${ashBuild}/bin/nix-ext4-image "$out/bin/nix-ext4-image"
        '';

        agentPortalWrappers = pkgs.runCommand "agent-portal-wrappers" { } ''
          install -Dm755 ${ashBuild}/bin/gh "$out/bin/gh"
          install -Dm755 ${ashBuild}/bin/wl-paste "$out/bin/wl-paste"
        '';

        ash-command-pages = pkgs.stdenvNoCC.mkDerivation {
          pname = "ash-command-pages";
          version = "0.1.5";
          dontUnpack = true;
          installPhase = ''
            runHook preInstall
            mkdir -p "$out/share/doc/ash/html"
            ${ashBuild}/bin/ash-docs-html "$out/share/doc/ash/html"
            runHook postInstall
          '';
        };

        imageReconcileCheck =
          let
            firstToplevel = imageReconcileFirst.config.system.build.toplevel;
            secondToplevel = imageReconcileSecond.config.system.build.toplevel;
            firstClosure = pkgs.closureInfo { rootPaths = [ firstToplevel ]; };
            secondClosure = pkgs.closureInfo { rootPaths = [ secondToplevel ]; };
          in
          pkgs.runCommand "ash-image-store-reconcile-test"
            {
              nativeBuildInputs = [ pkgs.e2fsprogs ];
            }
            ''
              total_bytes=$(($(cat ${firstClosure}/total-nar-size) + $(cat ${secondClosure}/total-nar-size)))
              size_mib=$(((total_bytes * 2 + 1048575) / 1048576 + 256))
              ${ashBuild}/bin/ash-image-reconcile-test \
                "$TMPDIR/nix-store.img" "$size_mib" \
                ${firstToplevel} ${firstClosure}/registration ${firstClosure}/store-paths \
                ${secondToplevel} ${secondClosure}/registration ${secondClosure}/store-paths
              touch "$out"
            '';
      in
      {
        packages = {
          default = ash;
          ash = ash;
          all = ashBuild;
          "agent-portal-cli" = agentPortalCli;
          "agent-portal-host" = agentPortalHost;
          "agent-portal-wrappers" = agentPortalWrappers;
          "nix-ext4-image" = nixExt4Image;
          command-pages = ash-command-pages;
          ash-command-pages = ash-command-pages;
        };

        checks = pkgs.lib.optionalAttrs (system == testSystem) {
          image-store-reconcile = imageReconcileCheck;
        };

        apps = {
          default = {
            type = "app";
            program = "${ash}/bin/ash";
          };

          "nix-ext4-image" = {
            type = "app";
            program = "${nixExt4Image}/bin/nix-ext4-image";
          };
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
            pkgs.e2fsprogs
          ];
        };
      }
    )
    // {
      nixosConfigurations = {
        image-reconcile-first = imageReconcileFirst;
        image-reconcile-second = imageReconcileSecond;
      };
    };
}
