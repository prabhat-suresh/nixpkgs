{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.samba;

  settingsFormat = pkgs.formats.ini { };
  configFile = settingsFormat.generate "smb.conf" cfg.settings;

in

{
  meta = {
    doc = ./samba.md;
    maintainers = [ lib.maintainers.anthonyroussel ];
  };

  imports = [
    (mkRemovedOptionModule [ "services" "samba" "defaultShare" ] "")
    (mkRemovedOptionModule [ "services" "samba" "syncPasswordsByPam" ] "This option has been removed by upstream, see https://bugzilla.samba.org/show_bug.cgi?id=10669#c10")

    (lib.mkRemovedOptionModule [ "services" "samba" "configText" ] ''
      Use services.samba.settings instead.

      This is part of the general move to use structured settings instead of raw
      text for config as introduced by RFC0042:
      https://github.com/NixOS/rfcs/blob/master/rfcs/0042-config-option.md
    '')
    (lib.mkRemovedOptionModule [ "services" "samba" "extraConfig" ] "Use services.samba.settings instead.")
    (lib.mkRenamedOptionModule [ "services" "samba" "invalidUsers" ] [ "services" "samba" "settings" "global" "invalid users" ])
    (lib.mkRenamedOptionModule [ "services" "samba" "securityType" ] [ "services" "samba" "settings" "global" "security" ])
    (lib.mkRenamedOptionModule [ "services" "samba" "shares" ] [ "services" "samba" "settings" ])

    (lib.mkRenamedOptionModule [ "services" "samba" "enableWinbindd" ] [ "services" "samba" "winbindd" "enable" ])
    (lib.mkRenamedOptionModule [ "services" "samba" "enableNmbd" ] [ "services" "samba" "nmbd" "enable" ])
  ];

  ###### interface

  options = {
    services.samba = {
      enable = lib.mkEnableOption "Samba, the SMB/CIFS protocol";

      package = lib.mkPackageOption pkgs "samba" {
        example = "samba4Full";
      };

      openFirewall = lib.mkEnableOption "opening the default ports in the firewall for Samba";

      smbd = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to enable Samba's smbd daemon.";
        };

        extraArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Extra arguments to pass to the smbd service.";
        };
      };

      nmbd = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Whether to enable Samba's nmbd, which replies to NetBIOS over IP name
            service requests. It also participates in the browsing protocols
            which make up the Windows "Network Neighborhood" view.
          '';
        };

        extraArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Extra arguments to pass to the nmbd service.";
        };
      };

      winbindd = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Whether to enable Samba's winbindd, which provides a number of services
            to the Name Service Switch capability found in most modern C libraries,
            to arbitrary applications via PAM and ntlm_auth and to Samba itself.
          '';
        };

        extraArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Extra arguments to pass to the winbindd service.";
        };
      };

      nsswins = lib.mkEnableOption ''
        WINS NSS (Name Service Switch) plug-in.

        Enabling it allows applications to resolve WINS/NetBIOS names (a.k.a.
        Windows machine names) by transparently querying the winbindd daemon
      '';

      settings = lib.mkOption {
        type = lib.types.submodule { freeformType = settingsFormat.type; };
        default = {};
        example = {
          "global" = {
            "security" = "user";
            "passwd program" = "/run/wrappers/bin/passwd %u";
            "invalid users" = "root";
          };
          "public" = {
            "path" = "/srv/public";
            "read only" = "yes";
            "browseable" = "yes";
            "guest ok" = "yes";
            "comment" = "Public samba share.";
          };
        };
        description = ''
          Configuration file for the Samba suite in ini format.
          This file is located in /etc/samba/smb.conf

          Refer to <https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html>
          for all available options.
        '';
      };
    };
  };

  ###### implementation

  config = mkMerge
    [ { assertions =
          [ { assertion = cfg.nsswins -> cfg.winbindd.enable;
              message   = "If services.samba.nsswins is enabled, then services.samba.winbindd.enable must also be enabled";
            }
          ];
      }

      (lib.mkIf cfg.enable {
        environment.etc."samba/smb.conf".source = configFile;

        system.nssModules = optional cfg.nsswins cfg.package;
        system.nssDatabases.hosts = optional cfg.nsswins "wins";

        systemd = {
          slices.system-samba = {
            description = "Samba slice";
          };
          targets.samba = {
            description = "Samba Server";
            after = [ "network.target" ];
            wants = [ "network-online.target" ];
            wantedBy = [ "multi-user.target" ];
          };
          tmpfiles.rules = [
            "d /var/lock/samba - - - - -"
            "d /var/log/samba - - - - -"
            "d /var/cache/samba - - - - -"
            "d /var/lib/samba/private - - - - -"
          ];
        };

        security.pam.services.samba = {};
        environment.systemPackages = [ cfg.package ];
        # Like other mount* related commands that need the setuid bit, this is
        # required too.
        security.wrappers."mount.cifs" = {
          program = "mount.cifs";
          source = "${lib.getBin pkgs.cifs-utils}/bin/mount.cifs";
          owner = "root";
          group = "root";
          setuid = true;
        };

        networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ 139 445 ];
        networking.firewall.allowedUDPPorts = mkIf cfg.openFirewall [ 137 138 ];
      })

      (lib.mkIf (cfg.enable && cfg.nmbd.enable) {
        systemd.services.samba-nmbd = {
          description = "Samba NMB Daemon";
          documentation = [ "man:nmbd(8)" "man:samba(7)" "man:smb.conf(5)" ];

          after = [
            "network.target"
            "network-online.target"
          ];

          partOf = [ "samba.target" ];
          wantedBy = [ "samba.target" ];
          wants = [ "network-online.target" ];

          environment.LD_LIBRARY_PATH = config.system.nssModules.path;

          serviceConfig = {
            ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
            ExecStart = "${cfg.package}/sbin/nmbd --foreground --no-process-group ${lib.escapeShellArgs cfg.nmbd.extraArgs}";
            LimitCORE = "infinity";
            PIDFile = "/run/samba/nmbd.pid";
            Slice = "system-samba.slice";
            Type = "notify";
          };

          unitConfig.RequiresMountsFor = "/var/lib/samba";

          restartTriggers = [ configFile ];
        };
      })

      (lib.mkIf (cfg.enable && cfg.smbd.enable) {
        systemd.services.samba-smbd = {
          description = "Samba SMB Daemon";
          documentation = [ "man:smbd(8)" "man:samba(7)" "man:smb.conf(5)" ];

          after = [
            "network.target"
            "network-online.target"
          ] ++ lib.optionals (cfg.nmbd.enable) [
            "samba-nmbd.service"
          ] ++ lib.optionals (cfg.winbindd.enable) [
            "samba-winbindd.service"
          ];

          partOf = [ "samba.target" ];
          wantedBy = [ "samba.target" ];
          wants = [ "network-online.target" ];

          environment.LD_LIBRARY_PATH = config.system.nssModules.path;

          serviceConfig = {
            ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
            ExecStart = "${cfg.package}/sbin/smbd --foreground --no-process-group ${lib.escapeShellArgs cfg.smbd.extraArgs}";
            LimitCORE = "infinity";
            LimitNOFILE = 16384;
            PIDFile = "/run/samba/smbd.pid";
            Slice = "system-samba.slice";
            Type = "notify";
          };

          unitConfig.RequiresMountsFor = "/var/lib/samba";

          restartTriggers = [ configFile ];
        };
      })

      (lib.mkIf (cfg.enable && cfg.winbindd.enable) {
        systemd.services.samba-winbindd = {
          description = "Samba Winbind Daemon";
          documentation = [ "man:winbindd(8)" "man:samba(7)" "man:smb.conf(5)" ];

          after = [
            "network.target"
          ] ++ lib.optionals (cfg.nmbd.enable) [
            "samba-nmbd.service"
          ];

          partOf = [ "samba.target" ];
          wantedBy = [ "samba.target" ];

          environment.LD_LIBRARY_PATH = config.system.nssModules.path;

          serviceConfig = {
            ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
            ExecStart = "${cfg.package}/sbin/winbindd --foreground --no-process-group ${lib.escapeShellArgs cfg.winbindd.extraArgs}";
            LimitCORE = "infinity";
            PIDFile = "/run/samba/winbindd.pid";
            Slice = "system-samba.slice";
            Type = "notify";
          };

          unitConfig.RequiresMountsFor = "/var/lib/samba";

          restartTriggers = [ configFile ];
        };
      })
    ];
}
