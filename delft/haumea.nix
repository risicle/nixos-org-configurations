{ config, lib, pkgs, ...}:

{
  imports =
    [ ./common.nix
      ./datadog.nix
      ./fstrim.nix
    ];

  environment.systemPackages = [ pkgs.lz4 ];

  deployment.targetEnv = "hetzner";
  deployment.hetzner.mainIPv4 = "46.4.89.205";

  deployment.hetzner.partitionCommand =
    ''
      if ! [ -e /usr/local/sbin/zfs ]; then
        echo "installing zfs..."
        bash -i -c 'echo y | zfsonlinux_install'
      fi

      umount -R /mnt || true

      zpool destroy rpool || true

      for disk in /dev/nvme0n1 /dev/nvme1n1; do
        echo "partitioning $disk..."
        index="''${disk: -3:1}"
        parted -s $disk "mklabel msdos"
        parted -a optimal -s $disk "mkpart primary ext4 1m 256m"
        parted -a optimal -s $disk "mkpart primary zfs 256m 100%"
        udevadm settle
        mkfs.ext4 -L boot$index ''${disk}p1
      done

      echo "creating ZFS pool..."
      zpool create -f -o ashift=12 \
        -O mountpoint=legacy -O atime=off -O compression=lz4 -O xattr=sa -O acltype=posixacl \
        rpool mirror /dev/nvme0n1p2 /dev/nvme1n1p2

      zfs create rpool/local
      zfs create rpool/local/nix
      zfs create rpool/safe
      zfs create rpool/safe/root
      zfs create -o primarycache=all -o recordsize=16k -o logbias=throughput rpool/safe/postgres
    '';

  deployment.hetzner.mountCommand =
    ''
      mkdir -p /mnt
      mount -t zfs rpool/safe/root /mnt
      mkdir -p /mnt/nix
      mount -t zfs rpool/local/nix /mnt/nix
      mkdir -p /mnt/var/db/postgresql
      mount -t zfs rpool/safe/postgres /mnt/var/db/postgresql
      mkdir -p /mnt/boot
      mount /dev/disk/by-label/boot0 /mnt/boot
    '';

  fileSystems."/" =
    { device = "rpool/safe/root";
      fsType = "zfs";
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-label/boot0";
      fsType = "ext4";
    };

  fileSystems."/nix" =
    { device = "rpool/local/nix";
      fsType = "zfs";
    };

  fileSystems."/var/db/postgresql" =
    { device = "rpool/safe/postgres";
      fsType = "zfs";
    };

  networking.hostId = "83c81a23";

  boot.loader.grub.devices = [ "/dev/nvme0n1" "/dev/nvme1n1" ];
  boot.loader.grub.copyKernels = true;

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_12;
    dataDir = "/var/db/postgresql";
    # https://pgtune.leopard.in.ua/#/
    logLinePrefix = "user=%u,db=%d,app=%a,client=%h ";
    settings = {
      listen_addresses = lib.mkForce "10.254.1.9";

      checkpoint_completion_target = "0.9";
      default_statistics_target = 100;

      log_duration = "off";
      log_statement = "none";

      # pgbadger-compatible logging
      log_transaction_sample_rate = 0.01;
      log_min_duration_statement = 5000;
      log_checkpoints = "on";
      log_connections = "on";
      log_disconnections = "on";
      log_lock_waits = "on";
      log_temp_files = 0;
      log_autovacuum_min_duration = 0;

      max_connections = 250;
      work_mem = "20MB";
      maintenance_work_mem = "2GB";

      # 25% of memory
      shared_buffers = "16GB";

      # Checkpoint every 1GB. (default)
      # increased after seeing many warninsg about frequent checkpoints
      min_wal_size = "1GB";
      max_wal_size = "2GB";
      wal_buffers = "16MB";

      max_worker_processes = 16;
      max_parallel_workers_per_gather = 8;
      max_parallel_workers = 16;

      # NVMe related performance tuning
      effective_io_concurrency = 200;
      random_page_cost = "1.1";

      # We can risk losing some transactions.
      synchronous_commit = "off";

      effective_cache_size = "16GB";
    };

    # FIXME: don't use 'trust'.
    authentication = ''
      host hydra all 10.254.1.3/32 trust
      local all root peer map=prometheus
    '';

    identMap = ''
      prometheus root root
      prometheus postgres-exporter root
    '';
  };

  networking = {
    firewall.interfaces.wg0.allowedTCPPorts = [ 5432 ];
    firewall.allowPing = true;
    firewall.logRefusedConnections = true;
  };

  services.prometheus.exporters.postgres = {
    enable = true;
    dataSourceName = "user=root database=hydra host=/run/postgresql sslmode=disable";
    firewallFilter = "-i wg0 -p tcp -m tcp --dport 9187";
    openFirewall = true;
  };

  programs.ssh = {
    extraConfig = ''
      Host rob-backup-server
      Hostname 83.162.34.61
      User nixosfoundationbackups
      Port 6666
    '';

    knownHosts = {
      graham-backup-server = {
        hostNames = [ "lord-nibbler.gsc.io" "67.246.1.194" ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEjBFLoalf56exb7GptkI151ee+05CwvXzoyBuvzzUbK";
      };
      rob-backup-server = {
        hostNames = [ "[83.162.34.61]:6666" ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKKUSblYu3vgZOY4hsezAx8pwwsgVyDsnZLT9M0zZsgZ";
      };
    };
  };

  services.zfs.autoScrub.enable = true;

  services.znapzend = {
    enable = true;
    autoCreation = true;
    pure = true;
    zetup = {
      "rpool/local" = {
        enable = true;
        recursive = true;
        plan = "15min=>5min,1hour=>15min,1day=>1hour,4day=>1day,3week=>1week";
        timestampFormat = "%Y-%m-%dT%H:%M:%SZ";
      };

      "rpool/safe" = {
        enable = true;
        plan = "15min=>5min,1hour=>15min,1day=>1hour,4day=>1day,3week=>1week";
        recursive = true;
        timestampFormat = "%Y-%m-%dT%H:%M:%SZ";
        destinations = {
          ogden = {
            plan = "1hour=>5min,4day=>1hour,1week=>1day,1year=>1week,10year=>1month";
            host = "hydraexport@lord-nibbler.gsc.io";
            dataset = "rpool/backups/nixos.org/haumea/safe";
          };
/*
          rob = {
            plan = "1hour=>5min,4day=>1hour,1week=>1day,1year=>1week,10year=>1month";
            host = "rob-backup-server";
            dataset = "tank/nixos-org/haumea/safe";
          };
*/
        };
      };
    };
  };
}
