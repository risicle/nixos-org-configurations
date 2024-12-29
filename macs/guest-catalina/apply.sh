#!/usr/bin/env bash

[ -e /Volumes/CONFIG/LOGHOST ] && LOGHOST=$(cat /Volumes/CONFIG/LOGHOST)
if [ "$LOGHOST" ] ; then
    echo "apply started at $(date)" | nc -w0 -u $LOGHOST 1514

    printf "\n*.*\t@$LOGHOST:1514\n" | tee -a /etc/syslog.conf
    pkill syslog
    pkill asl

    exec 3>&1
    exec 2> >(nc -u $LOGHOST 1514)
    exec 1>&2
fi

PS4='${BASH_SOURCE}::${FUNCNAME[0]}::$LINENO '
set -o pipefail
set -ex
date

function finish {
    set +e
    cd /
    sleep 1
    umount -f /Volumes/CONFIG
}
trap finish EXIT

if [ -e /nix ] ; then
    exit
fi

# copied from activationScripts
printf "disabling spotlight indexing... "
mdutil -i off -a &> /dev/null
mdutil -E -a &> /dev/null
echo "ok"

printf "disabling screensaver... "
defaults write com.apple.screensaver loginWindowIdleTime 0
echo "ok"

printf "disabling automatic updates... "
defaults write com.apple.SoftwareUpdate AutomaticDownload -boolean FALSE
echo "ok"

cat <<EOF | tee -a /etc/ssh/sshd_config
PermitRootLogin prohibit-password
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
EOF

launchctl stop com.openssh.sshd
launchctl start com.openssh.sshd


cd /Volumes/CONFIG

cp -r ./etc/ssh/ssh_host_* /etc/ssh
chown root:wheel /etc/ssh/ssh_host_*
chmod 600 /etc/ssh/ssh_host_*
cd /

echo "%admin ALL = NOPASSWD: ALL" | tee /etc/sudoers.d/passwordless

(
    # Make this thing work as root
    export USER=root
    export HOME=~root
    export ALLOW_PREEXISTING_INSTALLATION=1
    env

    while ! host nixos.org ; do
      sleep 1
    done

    curl -vL https://nixos.org/releases/nix/nix-2.24.6/install > ~nixos/install-nix
    chmod +rwx ~nixos/install-nix
    cat /dev/null | sudo -i -H -u nixos -- sh ~nixos/install-nix --daemon --darwin-use-unencrypted-nix-store-volume
)

(
    # Make this thing work as root
    export USER=root
    export HOME=~root

    . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
    env
    ls -la /private || true
    ls -la /private/var || true
    ls -la /private/var/run || true
    ln -s /private/var/run /run || true

    # todo: clean up this channel business, which is complicated because
    # channels on darwin are a bit ill defined and have a very bad UX.
    # If me, Graham, the author of the multi-user darwin installer can't
    # even figure this out, how can I possibly expect anybody else to know.
    nix-channel --add https://github.com/LnL7/nix-darwin/archive/master.tar.gz darwin
    nix-channel --add https://nixos.org/channels/nixpkgs-24.05-darwin nixpkgs
    nix-channel --update

    sudo -i -H -u nixos -- nix-channel --add https://github.com/LnL7/nix-darwin/archive/master.tar.gz darwin
    sudo -i -H -u nixos -- nix-channel --add https://nixos.org/channels/nixpkgs-24.05-darwin nixpkgs
    sudo -i -H -u nixos -- nix-channel --update

    NIXOS_HOME=~nixos
    sudo -u nixos -- mkdir -p  $NIXOS_HOME/.nixpkgs
    sudo -u nixos -- tee $NIXOS_HOME/.nixpkgs/darwin-configuration.nix <<EOF
# an initial darwin-configuration.nix just for the first install
{ config, pkgs, ... }:
{
  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 5;
}
EOF

    set +e
    sudo -i -H -u nixos -- nix --extra-experimental-features flakes --extra-experimental-features nix-command run nix-darwin -- switch -I nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixpkgs -I darwin=https://github.com/LnL7/nix-darwin/archive/master.tar.gz -I darwin-config=${NIXOS_HOME}/.nixpkgs/darwin-configuration.nix;
    echo $?
    set -e
)

(
    export USER=root
    export HOME=~root

    rm -f /etc/nix/nix.conf
    rm -f /etc/bashrc
    ln -s /etc/static/bashrc /etc/bashrc
    . /etc/static/bashrc
    pushd /Volumes/CONFIG
    for f in *.nix ; do
        cat $f | sudo -u nixos -- tee ~nixos/.nixpkgs/$f
    done
    popd

    while ! sudo -i -H -u nixos -- nix store ping --extra-experimental-features nix-command ; do
        cat /var/log/nix-daemon.log
        sleep 1
    done

    sudo -i -H -u nixos -- darwin-rebuild switch
)

