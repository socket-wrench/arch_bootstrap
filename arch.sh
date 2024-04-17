#!/usr/bin/bash
# Build script for base OS setup for wrenchbox
#
# Set variable
DRIVE=/dev/nvme0n1
BOOT_MB=2048
SWAP_MB=32768
ROOT_MB=1048576
TIMEZONE="US/Pacific"
LANG="en_US.UTF-8"
KEYMAP="us"
HOSTNAME="wrenchbox.socketwrench.net"
TESTURL="archlinux.org"
packages=("base" "linux" "linux-lts" "linux-firmware" "lvm2" "grub" "efibootmgr" "nvidia" "nvidia-utils" "networkmanager" "vi" "vim" "ansible" "git" "openssh" "sshpass")
hooks=("base" "systemd" "udev" "autodetect" "microcode" "modconf" "kms" "keyboard" "keymap" "consolefont" "block" "lvm2" "filesystems" "fsck")
modules=("nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm")
grubcmdlinedefault=("loglevel=3" "nvidia_drm.modeset=1" "nvidia_drm.fbdev=1")

# Setup environment
loadkeys ${KEYMAP}

# Check for internet connectivity
if ! ping -c4 ${TESTURL}
then
  echo "No internet connection.  Troubleshoot and try again."
  exit 1
fi

# Prompt for root password
read -s -p "Root Password: " ROOTPASS

# Remove existing partition table
for part in $(parted -s ${DRIVE} print | grep "^ [0-9]" | awk '{print $1}')
do
  parted -s ${DRIVE} rm $part
done

# Create new partition schema
parted -s ${DRIVE} mklabel gpt
parted -s ${DRIVE} unit mib mkpart primary fat32 2 $(( 2 + BOOT_MB ))
parted -s ${DRIVE} set 1 esp on
parted -s ${DRIVE} unit mib mkpart primary $(( 3 + BOOT_MB )) 100%
parted -s ${DRIVE} set 2 lvm on

# Create Filesystems and LVs
partprobe
mkfs.fat -F 32 ${DRIVE}1
pvcreate ${DRIVE}2
vgcreate rootvg ${DRIVE}2
lvcreate -n swaplv -L ${SWAP_MB}M rootvg
lvcreate -n rootlv -L ${ROOT_MB}M rootvg
mkfs.ext4 /dev/rootvg/rootlv
mkswap /dev/rootvg/swaplv

# Mount the drives
mount /dev/rootvg/rootlv /mnt
mount --mkdir ${DRIVE}1 /mnt/boot
swapon /dev/rootvg/swaplv

# Pacstrap to do initial build
pacstrap -K /mnt ${packages[@]}

# Create fstab
genfstab -U /mnt >> /mnt/etc/fstab

cat << EOF > /mnt/root/next.sh
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc
sed -i -e 's/#${LANG}/${LANG}/' /etc/locale.gen
locale-gen
printf "LANG=${LANG}\n" > /etc/locale.conf
printf "KEYMAP=${KEYMAP}\n" > /etc/vconsole.conf
printf "${HOSTNAME}\n" > /etc/hostname
printf "127.0.0.1 localhost\n" > /etc/hosts
printf "127.0.0.1 ${HOSTNAME} $(cut -d. -f1 <<< ${HOSTNAME})" >> /etc/hosts
sed -i -e 's/^HOOKS=.*$/HOOKS=\(${hooks[@]}\)/' -e 's/^MODULES=.*$/MODULES=\(${modules[@]}\)/' /etc/mkinitcpio.conf
mkinitcpio -P
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
sed -i -e 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*$/GRUB_CMDLINE_LINUX_DEFAULT=\"${grubcmdlinedefault[@]}\"/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg
printf "%s\n%s" "${ROOTPASS}" "${ROOTPASS}" | passwd root
EOF
arch-chroot /mnt sh /root/next.sh

exit 0
