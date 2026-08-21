{ config, lib, ... }:
let
  cfg = config.virtualisation.ash-guest.boot;
in
{
  options.virtualisation.ash-guest.boot = {
    enable = lib.mkEnableOption "Ash guest boot filesystem and virtio support";

    rootSize = lib.mkOption {
      type = lib.types.str;
      default = "5G";
      description = "Size of the ephemeral tmpfs root filesystem.";
    };

    persistMount = lib.mkOption {
      type = lib.types.str;
      default = "/persist";
      description = "Mount point for Ash's persist image.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.loader.grub.enable = false;

    boot.initrd.availableKernelModules = [
      "virtio_pci"
      "virtio_blk"
      "virtiofs"
      "overlay"
      "virtio_console"
      "vsock"
      "vmw_vsock_virtio_transport"
      "ext4"
    ];

    boot.kernelModules = [
      "virtio_console"
      "vsock"
      "vmw_vsock_virtio_transport"
    ];

    fileSystems."/" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [
        "mode=0755"
        "size=${cfg.rootSize}"
      ];
    };

    fileSystems.${cfg.persistMount} = {
      device = "/dev/disk/by-label/persist";
      fsType = "ext4";
      neededForBoot = true;
    };
  };
}
