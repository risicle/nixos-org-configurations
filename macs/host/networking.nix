{ lib, pkgs, config, ... }:
let
  inherit (lib) mkIf;

  subnetIP = "${config.macosGuest.network.interiorNetworkPrefix}.0";
  routerIP = "${config.macosGuest.network.interiorNetworkPrefix}.1";
  guestIP = "${config.macosGuest.network.interiorNetworkPrefix}.2";
  broadcastIP = "${config.macosGuest.network.interiorNetworkPrefix}.255";
in {
  config = mkIf config.macosGuest.enable {
    boot.kernel.sysctl."net.ipv4.conf.all.forwarding" = true;
    boot.kernel.sysctl."net.ipv4.conf.default.forwarding" = true;

    networking.firewall.extraCommands = ''
      ip46tables -A nixos-fw -i tap0 -p udp --dport 53 -j nixos-fw-accept # knot dns / kresd
    '';

    networking.firewall.allowedTCPPorts = [
      2200 # forwarded to :22 on the guest for external SSH
      9101 # forwarded to :9100 on the guest
      config.services.prometheus.exporters.node.port
    ];
    networking.firewall.allowedUDPPorts = [
      1514 # guest sends logs here
    ];

    networking.nat = {
      enable = true;
      externalInterface = config.macosGuest.network.externalInterface;
      internalInterfaces = [
        "tap0"
      ];
      internalIPs = [
        "${subnetIP}/24"
      ];
    };

    networking.interfaces."tap0" = {
      virtual = true;
      ipv4.addresses = [
        {
          address = routerIP;
          prefixLength = 24;
        }
      ];
    };

    services.openssh.enable = true;

    services.kea.dhcp4 = {
      enable = true;
      settings = {
        interfaces-config = {
          interfaces = [
            "tap0"
          ];
          service-sockets-max-retries = 100;
          service-sockets-retry-wait-time = 200;
        };
        authoritative = true;
        subnet4 = [
          {
            subnet = "${subnetIP}/24";
            option-data = [
              {
                name = "routers";
                data = routerIP;
              }
              {
                name = "broadcast-address";
                data = broadcastIP;
              }
              {
                name = "domain-name-servers";
                data = lib.concatStringsSep "," config.networking.nameservers;
              }
            ];
            reservations = [
              {
                hw-address = config.macosGuest.guest.MACAddress;
                ip-address = guestIP;
                hostname = "builder";
              }
            ];
          }
        ];
      };
    };

    services.prometheus.exporters.node = {
      enable = true;
    };

    systemd.services.netcatsyslog = {
      wantedBy = [ "multi-user.target" ];
      script = let
          ncl = pkgs.writeScript "ncl" ''
            #!/bin/sh
            set -euxo pipefail
            ${pkgs.netcat}/bin/nc -dklun 1514 | ${pkgs.coreutils}/bin/tr '<' $'\n'
          '';
        in ''
          set -euxo pipefail
          ${pkgs.expect}/bin/unbuffer ${ncl}
        '';
    };

    systemd.services.forward-wg0-ssh-to-guest = rec {
      requires = [ "network-online.target" ];
      after = requires;
      wantedBy = [ "multi-user.target" ];
      script = ''
          set -euxo pipefail
          exec ${pkgs.socat}/bin/socat TCP-LISTEN:2200,fork,so-bindtodevice=${config.macosGuest.network.sshInterface} TCP:${guestIP}:22
        '';
    };

    systemd.services.forward-wg0-prometheus-to-guest = rec {
      requires = [ "network-online.target" ];
      after = requires;
      wantedBy = [ "multi-user.target" ];
      script = ''
          set -euxo pipefail
          exec ${pkgs.socat}/bin/socat TCP-LISTEN:9101,fork,so-bindtodevice=${config.macosGuest.network.sshInterface} TCP:${guestIP}:9100
        '';
    };

  };
}
