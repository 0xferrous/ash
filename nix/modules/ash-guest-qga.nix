{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.virtualisation.ash-guest.qga;
in
{
  options.virtualisation.ash-guest.qga.enable =
    lib.mkEnableOption "QEMU Guest Agent support required by Ash";

  config = lib.mkIf cfg.enable {
    services.qemuGuest.enable = true;

    # Virtle guest-exec actions and Ash's provisioning scripts invoke sh.
    systemd.services.qemu-guest-agent.path = [ pkgs.bash ];
  };
}
