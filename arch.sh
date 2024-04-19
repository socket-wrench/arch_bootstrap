#!/usr/bin/bash
# Build script for base OS setup for wrenchbox

# Clear ROOTPASS var (just in case)
unset ROOTPASS

# Get command arguments
while getopts :f:hp: opt
do
  case ${opt} in
    f)
      CONFIGFILE=${OPTARG}
      ;;
    p)
      ROOTPASS="${OPTARG}"
      ;;
    h)
      printf "%s\n" ${0}
      printf "Script to install a basic build of arch linux on GPT LVM and EUFI\n"
      printf "%s\t%s\n" "-f" "(REQUIRED) Configuration file for host"
      printf "%s\t%s\n" "-p" "Root password for host once built"
      printf "%s\t%s\n" "-h" "Show this help"
      exit 2
      ;;
    :)
      printf "%s options was passed but no argument supplied. Use -h for syntax" "${OPTARG}" >&2
      exit 1
      ;;
    \?)
      printf "Unkdown option: -%s\n" "${OPTARG}" >&2
      exit 1
      ;;
  esac
done

# Confirm config file is valid
if [ -v CONFIGFILE ] && [ -f ${CONFIGFILE} ] && [ -s ${CONFIGFILE} ]
then
  source ${CONFIGFILE}
else
 printf "Config file not set, file does not exist or is zero size. See help (-h) and confirm path to file is correctly set\n" >&2
 exit 1
fi

# Set drive partition schema
if [[ ${DRIVE} =~ /dev/nvme.n. ]]
then
  PARTPREFIX="${DRIVE}p"
else
  PARTPREFIX="${DRIVE}"
fi

# Setup environment
loadkeys ${KEYMAP}

# Check for internet connectivity
if ! ping -c4 ${TESTURL}
then echo "No internet connection.  Troubleshoot and try again."
  exit 1
fi

# Prompt for root password
if [[ ! -v ROOTPASS ]]
then
  read -s -p "Root Password: " ROOTPASS
fi

# Remove any existing LVM configuration on DRIVE
for pv in $( pvs | grep -oh "${PARTPREFIX}[0-9]")
do
  for vg in $(vgs $(pvs $pv | cut -d\  -f4) | tail -n +2 | cut -d\  -f3)
  do
    for lv in $(lvs $vg | tail -n +2 | cut -d\  -f3)
    do
      lvremove --force --yes /dev/$vg/$lv
    done
    vgremove --force --yes $vg
  done
  pvremove --force --force --yes $pv
done

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
mkfs.fat -F 32 ${PARTPREFIX}1
pvcreate --force ${PARTPREFIX}2
vgcreate --force rootvg ${PARTPREFIX}2
lvcreate --yes --name swaplv --size ${SWAP_MB}M rootvg
lvcreate --yes --name rootlv --size ${ROOT_MB}M rootvg
mkfs.ext4 /dev/rootvg/rootlv
mkswap /dev/rootvg/swaplv

# Mount the drives
mount /dev/rootvg/rootlv /mnt
mount --mkdir ${PARTPREFIX}1 /mnt/boot
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
printf "KEYMAP=${KEYMAP}\nFONT=${FONT}\n" > /etc/vconsole.conf
printf "${HOSTNAME}\n" > /etc/hostname
printf "127.0.0.1 localhost\n127.0.0.1 ${HOSTNAME} $(cut -d. -f1 <<< ${HOSTNAME})" > /etc/hosts
sed -i -e 's/^HOOKS=.*$/HOOKS=\(${hooks[@]}\)/' -e 's/^MODULES=.*$/MODULES=\(${modules[@]}\)/' /etc/mkinitcpio.conf
mkinitcpio -P
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
sed -i -e 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*$/GRUB_CMDLINE_LINUX_DEFAULT=\"${grubcmdlinedefault[@]}\"/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg
printf "%s\n%s" "${ROOTPASS}" "${ROOTPASS}" | passwd root
systemctl enable NetworkManager
sed -i -e 's/^#*PermitRootLogin .*$/PermitRootLogin Yes/' /etc/ssh/sshd_config
systemctl enable sshd
EOF
arch-chroot /mnt sh /root/next.sh

exit 0
