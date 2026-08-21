{ config, lib, ... }:
let
  cfg = config.virtualisation.ash-guest;
in
{
  imports = [
    ./ash-guest-boot.nix
    ./ash-guest-qga.nix
    ./ash-guest-ssh.nix
    ./ash-guest-store.nix
  ];

  options.virtualisation.ash-guest = {
    enable = lib.mkEnableOption "guest support for Ash-managed Virtle VMs";

    user = lib.mkOption {
      type = lib.types.str;
      default = "agent";
      description = "User selected for Ash SSH sessions and key provisioning.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.ash-guest = {
      boot.enable = true;
      qga.enable = true;
      sshReadySignal.enable = true;
      store.enable = true;
    };

    # Ash evaluates this option to discover the default SSH user.
    services.getty.autologinUser = lib.mkDefault cfg.user;

    assertions = [
      {
        assertion = builtins.hasAttr cfg.user config.users.users;
        message = "virtualisation.ash-guest.user ${lib.escapeShellArg cfg.user} must name a declared NixOS user";
      }
      {
        assertion =
          !builtins.hasAttr cfg.user config.users.users || config.users.users.${cfg.user}.group == "users";
        message = "Ash SSH key provisioning currently requires virtualisation.ash-guest.user to have primary group users";
      }
    ];
  };
}
