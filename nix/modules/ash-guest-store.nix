{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.virtualisation.ash-guest;
  persist = cfg.boot.persistMount;
  lowerStoreUri = "local?real=/nix/.ro-store&state=/run/ash/shares/ro/guest-store-state&read-only=true";
  upperStoreState = "/run/ash/shares/rw/guest-store-state";
  overlayStoreUri = "local-overlay://?state=${lib.escapeURL upperStoreState}&lower-store=${lib.escapeURL lowerStoreUri}&upper-layer=${lib.escapeURL "/run/ash/shares/rw/guest-store-upper"}&check-mount=false";
  sharedCondition = [ "ash.nix-store=shared" ];
  initrdMount =
    mount:
    {
      unitConfig = {
        DefaultDependencies = false;
        ConditionKernelCommandLine = sharedCondition;
      };
      before = [ "initrd-fs.target" ];
    }
    // mount;
  sharedMountPaths = [
    "/sysroot/nix/.ro-store"
    "/sysroot/run/ash/shares/ro"
    "/sysroot/run/ash/shares/rw"
  ];
  sharedMountUnits = map (path: "${utils.escapeSystemdPath path}.mount") sharedMountPaths;
in
{
  options.virtualisation.ash-guest.store.enable =
    lib.mkEnableOption "Ash shared and image-backed Nix store boot support";

  config = lib.mkIf cfg.store.enable {
    # The store mounts and generator below run in the systemd-based initrd.
    boot.initrd.systemd.enable = true;

    # Ash checks this marker before attempting to import registration data.
    # The shared local-overlay store already gets that database from its
    # readonly lower store, so importing it again is unnecessary and can fail.
    environment.etc."ash/local-overlay-store".text = "";

    # Select the Nix daemon store from the strategy Ash places on the kernel
    # command line. Image mode uses the normal local store; shared mode uses
    # the host-backed lower store plus Ash's writable upper layer.
    environment.etc."ash/nix-daemon".source = pkgs.writeShellScript "ash-nix-daemon" ''
      store_strategy=shared
      for parameter in $(${pkgs.coreutils}/bin/cat /proc/cmdline); do
        case "$parameter" in
          ash.nix-store=shared) store_strategy=shared ;;
          ash.nix-store=image) store_strategy=image ;;
        esac
      done

      if [ "$store_strategy" = image ]; then
        exec ${pkgs.nix}/bin/nix-daemon --daemon
      fi

      exec ${pkgs.nix}/bin/nix-daemon --daemon \
        --option store ${lib.escapeShellArg overlayStoreUri}
    '';

    systemd.services.nix-daemon.serviceConfig.ExecStart = lib.mkForce [
      ""
      "/etc/ash/nix-daemon"
    ];

    # Generate only the root Nix mount appropriate for the selected strategy.
    # In shared mode /nix/store is the overlay below. In image mode Virtle
    # supplies an ext4 image labelled nix-store and it is mounted at /nix.
    boot.initrd.systemd.contents."/etc/systemd/system-generators/ash-nix-store-generator".source =
      pkgs.writeShellScript "ash-nix-store-generator" ''
        store_strategy=shared
        for parameter in $(${pkgs.coreutils}/bin/cat /proc/cmdline); do
          case "$parameter" in
            ash.nix-store=shared) store_strategy=shared ;;
            ash.nix-store=image) store_strategy=image ;;
          esac
        done

        case "$store_strategy" in
          shared)
            mount_unit=sysroot-nix-store.mount
            mount_unit_path="/etc/systemd/system/$mount_unit"
            ;;
          image)
            mount_unit=sysroot-nix.mount
            mount_unit_path="$1/$mount_unit"
            cat > "$mount_unit_path" <<'EOF'
        [Unit]
        DefaultDependencies=false
        Before=initrd-fs.target

        [Mount]
        What=/dev/disk/by-label/nix-store
        Where=/sysroot/nix
        Type=ext4
        EOF
            ;;
        esac

        wants_dir="$1/initrd-fs.target.requires"
        ${pkgs.coreutils}/bin/mkdir -p "$wants_dir"
        ${pkgs.coreutils}/bin/ln -s "$mount_unit_path" "$wants_dir/$mount_unit"
      '';

    boot.initrd.systemd.mounts = [
      (initrdMount {
        what = "/sysroot/run/ash/shares/ro/system/nix-store";
        where = "/sysroot/nix/.ro-store";
        type = "none";
        options = "bind,ro";
        requires = [ "sysroot-run-ash-shares-ro.mount" ];
        after = [ "sysroot-run-ash-shares-ro.mount" ];
      })
      (initrdMount {
        what = "shares-ro";
        where = "/sysroot/run/ash/shares/ro";
        type = "virtiofs";
        options = "ro";
      })
      (initrdMount {
        what = "shares-rw";
        where = "/sysroot/run/ash/shares/rw";
        type = "virtiofs";
      })
      (initrdMount {
        what = "overlay";
        where = "/sysroot/nix/store";
        type = "overlay";
        options = lib.concatStringsSep "," [
          "lowerdir=/sysroot/nix/.ro-store"
          "upperdir=/sysroot/run/ash/shares/rw/guest-store-upper"
          "workdir=/sysroot/run/ash/shares/rw/guest-store-work"
          "userxattr"
        ];
        requires = sharedMountUnits;
        after = sharedMountUnits;
      })
    ];

    # Shared mode keeps Nix's mutable database on the persist image. Image mode
    # must use the database Ash prepared inside the Nix store image.
    systemd.services.ash-prepare-shared-nix-state = {
      requiredBy = [ "nix-var-nix.mount" ];
      requires = [ "persist.mount" ];
      after = [ "persist.mount" ];
      before = [ "nix-var-nix.mount" ];
      unitConfig = {
        ConditionKernelCommandLine = sharedCondition;
        DefaultDependencies = false;
      };
      serviceConfig.Type = "oneshot";
      script = ''
        # Create the persistent source and empty mountpoint only; no Nix state
        # is copied. nix-var-nix.mount below bind-mounts the first over the
        # second for shared-store boots.
        ${pkgs.coreutils}/bin/install -d -m 0755 ${persist}/nix/var/nix
        ${pkgs.coreutils}/bin/install -d -m 0755 /nix/var/nix
      '';
    };

    systemd.mounts = [
      {
        wantedBy = [ "local-fs.target" ];
        requires = [ "ash-prepare-shared-nix-state.service" ];
        after = [ "ash-prepare-shared-nix-state.service" ];
        before = [ "local-fs.target" ];
        where = "/nix/var/nix";
        what = "${persist}/nix/var/nix";
        type = "none";
        options = "bind";
        unitConfig = {
          ConditionKernelCommandLine = sharedCondition;
          DefaultDependencies = false;
        };
      }
    ];
  };
}
