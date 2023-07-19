#!/usr/bin/env bash

# This script picks up after a live image has been booted, networking has been configured, and SSH access enabled
# Assumptions: Using gentoo media, installing on NVME disk, static swap size, gentoo stage3 may be out of date

install_disk=/dev/nvme0n1

sgdisk -Z $install_disk
sgdisk -o $install_disk
# Type codes > 8300 - Linux filesystem, 8200 - Linux swap, ef00 - ESP
sgdisk -n 1::+1G -t 1:ef00 -c 1:esp ${install_disk}
sgdisk -n 2::+16G -t 2:8200 -c 2:swap ${install_disk}
sgdisk -n 3:: -t 3:ef00 -c 3:main ${install_disk}

mkfs.vfat -F 32 ${install_disk}p1
mkswap ${install_disk}p2
mkfs.btrfs -L btrfsMain ${install_disk}p3

mount ${install_disk}p3 /mnt/gentoo

cd /mnt/gentoo || { echo "Failure to cd, unable to create subvolumes"; exit 1; }
btrfs subvol create @root
btrfs subvol create @home
btrfs subvol create @varCache
btrfs subvol create @varTmp
btrfs subvol create @varLog

cd && umount -l /mnt/gentoo

mount -o defaults,noatime,compress=lzo,autodefrag,subvol=@root ${install_disk}p3 /mnt/gentoo
cd /mnt/gentoo || { echo "Failure to create required directories "; exit 1; }
mkdir -p home boot var/{cache,tmp,log}

swapon ${install_disk}p2
mount -o defaults,noatime,compress=lzo,autodefrag,subvol=@home ${install_disk}p3 /mnt/gentoo/home
mount -o defaults,noatime,compress=lzo,autodefrag,subvol=@varCache ${install_disk}p3 /mnt/gentoo/var/cache
mount -o defaults,noatime,compress=lzo,autodefrag,subvol=@varTmp ${install_disk}p3 /mnt/gentoo/var/tmp
mount -o defaults,noatime,compress=lzo,autodefrag,subvol=@varLog ${install_disk}p3 /mnt/gentoo/var/log
mount -o defaults,noatime ${install_disk}p1 /mnt/gentoo/boot

wget "https://bouncer.gentoo.org/fetch/root/all/releases/amd64/autobuilds/20230611T170207Z/stage3-amd64-desktop-systemd-20230611T170207Z.tar.xz"
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/


chronyd -q
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run 

 # TODO: this won't work
chroot /mnt/gentoo /bin/bash

source /etc/profile
export PS1="(chroot) ${PS1}"

cat << EOF >> /etc/locale.gen
en_US ISO-8859-1
en_US.UTF-8 UTF-8 
EOF
locale-gen
eselect locale set en_US.utf8
source /etc/profile
export PS1="(chroot) ${PS1}"

cat << EOF > /etc/fstab # TODO: get worky variables
# <fs>           <mountpoint>    <type>  <opts>                                                  <dump/pass>
shm              /dev/shm        tmpfs   nodev,nosuid,noexec                                     0 0

/dev/nvme0n1p1   /boot           btrfs   rw,noatime                                              1 2
/dev/nvme0n1p2   none            swap    sw                                                      0 0

/dev/nvme0n1p3   /               btrfs   rw,noatime,compress=zstd:3,autodefrag,subvol=@root      0 0
/dev/nvme0n1p3   /home           btrfs   rw,noatime,compress=zstd:3,autodefrag,subvol=@home      0 0
/dev/nvme0n1p3   /var/cache      btrfs   rw,noatime,compress=zstd:3,autodefrag,subvol=@varCache  0 0
/dev/nvme0n1p3   /var/tmp        btrfs   rw,noatime,compress=zstd:3,autodefrag,subvol=@varTmp    0 0
/dev/nvme0n1p3   /var/log        btrfs   rw,noatime,compress=zstd:3,autodefrag,subvol=@varLog    0 0
EOF

cat << EOF > /etc/portage/make.conf
COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"

LC_MESSAGES=C.utf8

GRUB_PLATFORMS="efi-64"
VIDEO_CARDS="nvidia"
ACCEPT_KEYWORDS="~amd64"
ACCEPT_LICENSE="*"
MAKEOPTS="-j16 -l30"

# Portage Opts
FEATURES="parallel-fetch parallel-install ebuild-locks"
EMERGE_DEFAULT_OPTS="--with-bdeps=y --jobs 6"
AUTOCLEAN="yes"
EOF

emerge --sync --quiet
emerge --oneshot portage
emerge app-portage/cpuid2cpuflags
echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

eselect profile set default/linux/amd64/17.1/desktop/systemd

emerge --verbose --update --deep --newuse @world

ln -sf ../usr/share/zoneinfo/America/New_York /etc/localtime

emerge -v sys-kernel/linux-firmware sys-kernel/installkernel-systemd-boot sys-kernel/gentoo-kernel
emerge -v sys-fs/btrfs-progs net-fs/nfs-utils net-fs/autofs sys-fs/dosfstools sys-apps/mlocate sys-block/io-scheduler-udev-rules \
app-portage/gentoolkit app-editors/neovim dev-vcs/git app-admin/sudo

cat << EOF > /etc/hosts
# localhost definitions
127.0.0.1   localhost sethdesk sethdesk.serek
::1         localhost sethdesk sethdesk.serek

# remote host configuration
10.0.5.1    garbagefire garbagefire.serek
10.0.10.10  storepod storepod.serek
EOF

systemd-firstboot --prompt --setup-machine-id #TODO: make scriptable
systemctl preset-all --preset-mode=enable-only #TODO: check if this is the best way forward
systemctl enable sshd

ln -snf /run/systemd/resolve/resolv.conf /etc/resolv.conf # Breaks name resolutione
systemctl enable systemd-networkd.service
systemctl enable systemd-resolved.service