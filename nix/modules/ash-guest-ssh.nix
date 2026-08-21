{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.virtualisation.ash-guest;
  readyPort = "/dev/virtio-ports/virtle.ready";
in
{
  options.virtualisation.ash-guest.sshReadySignal = {
    enable = lib.mkEnableOption "Virtle SSH readiness signalling";

    afterUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional units that must finish before SSH readiness is signalled.";
    };

    requiredUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional units required by the SSH readiness service.";
    };
  };

  config = lib.mkIf cfg.sshReadySignal.enable {
    services.openssh.enable = true;

    # A path unit avoids delaying background boots where Virtle does not expose
    # the readiness port. Foreground `ash spawn --attach` creates the port and
    # causes the oneshot service to send the token after sshd is running.
    systemd.paths.virtle-ssh-signal = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathExists = readyPort;
        Unit = "virtle-ssh-signal.service";
      };
    };

    systemd.services.virtle-ssh-signal = {
      requires = [ "sshd.service" ] ++ cfg.sshReadySignal.requiredUnits;
      after = [ "sshd.service" ] ++ cfg.sshReadySignal.afterUnits;
      unitConfig.ConditionPathExists = "!/run/virtle-ssh-signalled";
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "130s";
      };
      script = ''
        deadline=$(( $(${pkgs.coreutils}/bin/date +%s) + 120 ))
        attempts=0
        while [ "$(${pkgs.coreutils}/bin/date +%s)" -lt "$deadline" ]; do
          if [ -e ${readyPort} ]; then
            # The write blocks when the host has not started reading the port.
            # Bound each attempt, but retain the retry loop used by the proven
            # agent configuration so foreground launches tolerate that race.
            if ${pkgs.coreutils}/bin/timeout 2s ${pkgs.bash}/bin/bash -c \
              '${pkgs.coreutils}/bin/echo SSH-READY > ${readyPort}'; then
              ${pkgs.coreutils}/bin/touch /run/virtle-ssh-signalled
              exit 0
            fi
            attempts=$((attempts + 1))
            echo "virtle ready port write timed out (attempt $attempts); retrying" >&2
          fi
          ${pkgs.coreutils}/bin/sleep 1
        done
        echo "virtle ready port write did not succeed within 2 minutes" >&2
        exit 0
      '';
    };
  };
}
