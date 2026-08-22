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

    emptyPassword = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Allow the Ash guest user to log in with an empty password.";
    };

    passwordlessSudo = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Grant the Ash guest user passwordless sudo through the wheel group.";
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

    users.users.${cfg.user} = lib.mkMerge [
      (lib.mkIf cfg.emptyPassword {
        # An empty shadow hash permits the SSH "none" authentication method;
        # hashing an empty plaintext password does not have the same effect.
        hashedPassword = lib.mkDefault "";
      })
      (lib.mkIf cfg.passwordlessSudo {
        extraGroups = lib.mkAfter [ "wheel" ];
      })
    ];

    services.openssh.settings = lib.mkIf cfg.emptyPassword {
      PasswordAuthentication = lib.mkDefault true;
      PermitEmptyPasswords = lib.mkDefault true;
    };
    security.pam.services.sshd.allowNullPassword = lib.mkIf cfg.emptyPassword (lib.mkDefault true);
    security.sudo.wheelNeedsPassword = lib.mkIf cfg.passwordlessSudo (lib.mkDefault false);

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
