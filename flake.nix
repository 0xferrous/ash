{
  description = "ash - a simple OCaml CLI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    virtle.url = "github:shazow/virtle";
    virtle.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      virtle,
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
          version = "0.1.7";
          inherit src;
          duneVersion = "3";

          nativeBuildInputs = [ pkgs.git pkgs.makeWrapper ];

          buildInputs = [ pkgs.e2fsprogs ];

          propagatedBuildInputs = [
            ocamlPackages.base64
            ocamlPackages.cmdliner
            ocamlPackages.ctypes
            ocamlPackages.ctypes-foreign
            ocamlPackages.msgpck
            ocamlPackages.notty-community
            ocamlPackages.otoml
            ocamlPackages.uutf
            ocamlPackages.yojson
          ];

          postFixup = ''
            wrapProgram "$out/bin/ash-dbus-proxy" \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.xdg-dbus-proxy ]}
          '';

          strictDeps = true;
        };

        # The virtle manifest -> QEMU pipeline exposed as a C shared library
        # for in-process FFI from OCaml (lib/ash/virtle_ffi). The cgo shim in
        # ./ffi/shim.go is dropped into the pinned virtle flake input at build
        # time, so the module graph, go.sum, and vendorHash are virtle's own.
        libvirtle =
          let
            virtleSource = self.inputs.virtle;
            virtleRelease = import "${virtleSource}/release.nix";
            ffiSource = pkgs.runCommand "virtle-ffi-src" { } ''
              cp -r ${virtleSource} "$out"
              chmod -R u+w "$out"
              mkdir -p "$out/ffishim"
              cp ${./ffi/shim.go} "$out/ffishim/main.go"
            '';
          in
          pkgs.buildGoModule {
            pname = "ash-libvirtle";
            inherit (virtleRelease) version vendorHash;
            src = ffiSource;
            nativeBuildInputs = [ pkgs.gcc ];
            env.CGO_ENABLED = "1";
            buildPhase = ''
              runHook preBuild
              mkdir -p "$out/lib"
              go build -buildmode=c-shared -trimpath -o "$out/lib/libvirtle.so" ./ffishim
            '';
            installPhase = "true";
          };

        ash = pkgs.runCommand "${ashBuild.pname}-${ashBuild.version}"
          {
            nativeBuildInputs = [ pkgs.makeWrapper ];
          }
          ''
            install -Dm755 ${ashBuild}/bin/ash "$out/bin/ash"
            install -Dm755 ${ashBuild}/bin/ash-dbus-proxy "$out/bin/ash-dbus-proxy"
            wrapProgram "$out/bin/ash" \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.bindfs pkgs.waypipe ]} \
              --set ASH_LIBVIRTLE ${libvirtle}/lib/libvirtle.so
          '';

        agentPortalHost = pkgs.runCommand "agent-portal-host" { } ''
          install -Dm755 ${ashBuild}/bin/agent-portal-host "$out/bin/agent-portal-host"
        '';

        agentPortalCli = pkgs.runCommand "agent-portal-cli" { } ''
          install -Dm755 ${ashBuild}/bin/agent-portal-cli "$out/bin/agent-portal-cli"
        '';

        ashDbusProxy = pkgs.runCommand "ash-dbus-proxy" { } ''
          install -Dm755 ${ashBuild}/bin/ash-dbus-proxy "$out/bin/ash-dbus-proxy"
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
          version = "0.1.7";
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
            closureJson =
              name: toplevel:
              pkgs.runCommand name
                {
                  __structuredAttrs = true;
                  exportReferencesGraph.closure = [ toplevel ];
                  nativeBuildInputs = [ pkgs.jq ];
                }
                ''
                  out=''${outputs[out]}
                  jq '.closure | map({ key: .path, value: { narHash: .narHash, narSize: .narSize, references: .references } }) | from_entries' \
                    "$NIX_ATTRS_JSON_FILE" > "$out"
                '';
            firstClosureJson = closureJson "ash-first-closure.json" firstToplevel;
            secondClosureJson = closureJson "ash-second-closure.json" secondToplevel;
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
                ${firstToplevel} ${firstClosure}/registration ${firstClosure}/store-paths ${firstClosureJson} \
                ${secondToplevel} ${secondClosure}/registration ${secondClosure}/store-paths ${secondClosureJson}
              touch "$out"
            '';
      in
      {
        packages = {
          default = ash;
          ash = ash;
          all = ashBuild;
          libvirtle = libvirtle;
          "agent-portal-cli" = agentPortalCli;
          "agent-portal-host" = agentPortalHost;
          "agent-portal-wrappers" = agentPortalWrappers;
          "ash-dbus-proxy" = ashDbusProxy;
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

          "ash-dbus-proxy" = {
            type = "app";
            program = "${ashDbusProxy}/bin/ash-dbus-proxy";
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
            ocamlPackages.ctypes
            ocamlPackages.ctypes-foreign
            ocamlPackages.msgpck
            ocamlPackages.notty-community
            ocamlPackages.otoml
            ocamlPackages.utop
            ocamlPackages.uutf
            pkgs.bindfs
            pkgs.e2fsprogs
            pkgs.gcc
            pkgs.go
            pkgs.waypipe
          ];
          shellHook = ''
            export ASH_LIBVIRTLE=${libvirtle}/lib/libvirtle.so
          '';
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
