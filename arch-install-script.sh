#!/bin/bash
##
# Prepare the disk
# 

# select the disk block device onto which the system should be installed
DEFAULT_DISK_DEVICE=/dev/nvme0n1
echo "Choose the disk block device to which the system will be installed:"
read -p "[${DEFAULT_DISK_DEVICE}] " DISK_DEVICE
if ("${DISK_DEVICE}" -z); then
   DISK_DEVICE="${DEFAULT_DISK_DEVICE}"
fi
PARTITION_TABLE=`sgdisk --print ${DISK_DEVICE}`
if ($? -ne 0); then
    echo "ERROR: Could not the read partition table on the selected disk ${DISK_DEVICE}!" >&2
    exit 1
fi
echo "The selected disk ${DISK_DEVICE} currently contains these partitions:"
echo "${PARTITION_TABLE}"
echo 
echo "ALL DATA ON EACH PARTITION OF THE SELECTED DISK WILL BE DESTROYED!!!"
read -p "Type "do it" and press enter if you wish to continue, anythig else to abort: " CONFIRMATION
if ("${CONFIRMATION}" != "do it"); then
    echo "Aborting installation."
    exit 0
fi

# TODO: add option to securely wipe disk with random data before continuing

# clear the partition table on the selected device
sgdisk --zap-all ${DISK_DEVICE}
if ($? -ne 0); then
  echo "ERROR: Could not clear the partition table on disk ${DISK_DEVICE}!" >&2
  exit 1
fi

# create EFI system partition
echo "Creating EFI system partition..."
sgdisk --new=1:2048:+512M --typecode=1:EF00 --change-name=1:"EFI system partition" ${DISK_DEVICE}
if ($? -ne 0); then
  echo "ERROR: Could not create the EFI system partition on disk ${DISK_DEVICE}!" >&2
  exit 1
fi
EFI_PARTITION=/dev/disk/by-partuuid/`sgdisk -i=1 ${DISK_DEVICE} | grep "Partition unique GUID" | sed -e 's/Partition unique GUID: //' -e 's/\(.*\)/\L\1/'`
echo "DONE: Created partition ${EFI_PARTITION}"

# format the EFI system partition with FAT32 file system
echo "Formatting the EFI system partition..."
mkfs.vfat -F32 ${EFI_PARTITION}
if ($? -ne 0); then
  echo "ERROR: Could not create the FAT32 filesystem on the partition ${EFI_PARTITION}!" >&2
  exit 1
fi
echo "DONE: FAT32 file system created on ${EFI_PARTITION}"

# create one single partition on the remainder of the disk
echo "Creating main data partition on the remainder of the disk..."
ENCRYPTED_NAME=cryptroot
sgdisk --largest-new=2 --typecode=2:8300 --change-name=2:${ENCRYPTED_NAME} ${DISK_DEVICE}
if ($? -ne 0); then
  echo "ERROR: Could not create the main partition on ${DISK_DEVICE}!" >&2
  exit 1
fi
MAIN_PARTITION=/dev/disk/by-partuuid/`sgdisk --info=2 ${DISK_DEVICE} | grep "Partition unique GUID" | sed -e 's/Partition unique GUID: //' -e 's/\(.*\)/\L\1/'`
echo "DONE: Created partition ${MAIN_PARTITION}"

# print partition table after the changes
echo "The partition table on the disk ${DISK_DEVICE} now looks like this:"
sgdisk --print ${DISK_DEVICE}

# TODO find out how to prepare disk to use 4K sector size for cryptsetup

# setup a dm-crypt LUKS2 container on the main data partition
echo "Setting up encryption on the main data partition..."
cryptsetup --type luks2 --cipher aes-xts-plain64 --hash sha256 --iter-time 2000 --key-size 256 --pbkdf argon2i --sector-size 512 --use-random --verify-passphrase luksFormat ${MAIN_PARTITION}
if ($? -ne 0); then
  echo "ERROR: Could not setup encryption on the partition ${MAIN_PARTITION}!" >&2
  exit 1
fi
echo "DONE: Encryption container has been set up on ${MAIN_PARTITION} with these parameters:"
cryptsetup luksDump ${MAIN_PARTITION}

# TODO make TRIM optional

# make the encrypted partition available for writing
echo "Making the encrypted partition available to the system..."
cryptsetup --allow-discards --persistent open ${MAIN_PARTITION} ${ENCRYPTED_NAME}
if ($? -ne 0); then
  echo "ERROR: Could not open the encrypted partition ${MAIN_PARTITION}!" >&2
  exit 1
fi
ENCRYPTED_PARTITION=/dev/mapper/${ENCRYPTED_NAME}
echo "DONE: Encrypted partition is now available as ${ENCRYPTED_PARTITION}"

# format the encrypted partition with the BTRFS file system
echo "Formatting the encrypted partition..."
mkfs.btrfs -L archlinux ${ENCRYPTED_PARTITION}
if ($? -ne 0); then
  echo "ERROR: Could not create BTRFS file system on the partition ${ENCRYPTED_PARTITION}!" >&2
  exit 1
fi
echo "DONE: Created BTRFS file system on ${ENCRYPTED_PARTITION}"

# mount the root file system
ROOT_MOUNT_POINT=/mnt
BTRFS_OPTS=noatime,nodirtime,ssd,discard,compress=lzo
echo "Mounting the root file system..."
mount -t btrfs -o ${BTRFS_OPTS} ${ENCRYPTED_PARTITION} ${ROOT_MOUNT_POINT}
if ($? -ne 0); then
  echo "ERROR: Could not create BTRFS file system on the partition ${ENCRYPTED_PARTITION}!" >&2
  exit 1
fi
echo "DONE: The encrypted root file sytem has been mounted on ${ROOT_MOUNT_POINT}"
lsblk ${DISK_DEVICE}

# create primary subvolumes on the root file sytem
btrfs subvolume create ${ROOT_MOUNT_POINT}/@ && btrfs subvolume create ${ROOT_MOUNT_POINT}/@home && btrfs subvolume create ${ROOT_MOUNT_POINT}/@snapshots
if ($? -ne 0); then
  echo "ERROR: Could not create some of the subvolumes on the root file system!" >&2
  exit 1
fi
echo "DONE: Created ${ROOT_MOUNT_POINT}/@, ${ROOT_MOUNT_POINT}/@home and ${ROOT_MOUNT_POINT}/@snapshots BTRFS subvolumes"

# unmount the root file system and remount with the subvolumes
echo "Re-mounting the root file system and creating folders for primary subvolumes..."
BTRFS_OPTS=${BTRFS_OPTS},x-mount.mkdir
umount ${ROOT_MOUNT_POINT} && mount -t btrfs -o ${BTRFS_OPTS},subvol=@ ${ENCRYPTED_PARTITION} ${ROOT_MOUNT_POINT} && mount -o ${BTRFS_OPTS} ${EFI_PARTITION} ${ROOT_MOUNT_POINT}/boot && mount -t btrfs -o ${BTRFS_OPTS},subvol=@home ${ENCRYPTED_PARTITION} ${ROOT_MOUNT_POINT}/home && mount -t btrfs -o ${BTRFS_OPTS},subvol=@snapshots ${ENCRYPTED_PARTITION} ${ROOT_MOUNT_POINT}/.snapshots
if ($? -ne 0); then
  echo "ERROR: Could not mount some of the subvolumes on the primary file system!" >&2
  exit 1
fi
echo "DONE: Mounted all primary subvolumes of the root file system"
mount

# create nested (not backed up) subvolumes on the root file system
echo "Creating nested subvolume inside the root file sytem..."
mkdir -p ${ROOT_MOUNT_POINT}/var/cache/pacman && btrfs subvolume create ${ROOT_MOUNT_POINT}/var/cache/pacman/pkg && btrfs subvolume create ${ROOT_MOUNT_POINT}/var/abs && btrfs subvolume create ${ROOT_MOUNT_POINT}/var/tmp && btrfs subvolume create ${ROOT_MOUNT_POINT}/srv
if ($? -ne 0); then
  echo "ERROR: Could not create some of the nested subvolumes in the root file system!" >&2
  exit 1
fi
echo "DONE: Created nested volumes for /var/cache/pacman/pkg, /var/tmp, /var/abs and /srv"

WLAN_DEVICE=wlan0
WIFI_ESSID=NoMansLand
iwctl station ${WLAN_DEVICE} connect ${WIFI_ESSID}

timedatectl set-ntp true

PLATFORM=amd
KERNEL_PACKAGE=linux
pacstrap ${ROOT_MOUNT_POINT} base ${KERNEL_PACKAGE} linux-firmware ${PLATFORM}-ucode btrfs-progs efibootmgr efitools sbsigntools base-devel dhcpcd wpa_supplicant iwd networkmanager networkmanager-openvpn vim bash-completion

genfstab -U -p ${ROOT_MOUNT_POINT} >> ${ROOT_MOUNT_POINT}/etc/fstab

touch ${ROOT_MOUNT_POINT}/etc/vconsole.conf

arch-chroot ${ROOT_MOUNT_POINT} ln -s /usr/share/zoneinfo/Europe/Berlin /etc/localtime
arch-chroot ${ROOT_MOUNT_POINT} hwclock --systohc --utc

echo "

en_GB.UTF-8 UTF-8
sk_SK.UTF-8 UTF-8
cs_CZ.UTF-8 UTF-8
pl_PL.UTF-8 UTF-8
de_DE.UTF-8 UTF-8
" >> ${ROOT_MOUNT_POINT}/etc/locale.gen 

arch-chroot ${ROOT_MOUNT_POINT} locale-gen

arch-chroot ${ROOT_MOUNT_POINT} passwd

arch-chroot ${ROOT_MOUNT_POINT} useradd -m -G wheel peto
arch-chroot ${ROOT_MOUNT_POINT} passwd peto
SUDOERS_FILE=${ROOT_MOUNT_POINT}/etc/sudoers
chown u+w ${SUDOERS_FILE} && echo "
%wheel ALL=(ALL) ALL
" >> ${SUDOERS_FILE} && chown u-w ${SUDOERS_FILE}

MKINITCPIO_CONF_FILE=${ROOT_MOUNT_POINT}/etc/mkinitcpio.conf
sed -e 's/^BINARIES=.*$/BINARIES=(\/usr\/sbin\/btrfs)/' -e 's/^HOOKS=.*$/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt filesystems fsck)/' ${MKINITCPIO_CONF_FILE} > ${MKINITCPIO_CONF_FILE}
arch-chroot ${ROOT_MOUNT_POINT} mkinitcpio -p ${KERNEL_PACKAGE}

# https://wiki.archlinux.org/index.php/Systemd-boot#Preparing_a_unified_kernel_image

arch-chroot ${ROOT_MOUNT_POINT} bootctl --esp-path=/boot install
mkdir -p ${ROOT_MOUNT_POINT}/boot/BOOT

CRYPTROOT_UUID=`cryptsetup luksUUID ${MAIN_PARTITION}`

BOOT_OPTIONS="rd.luks.name=${CRYPTROOT_UUID}=${ENCRYPTED_NAME} rd.luks.options=${CRYPTROOT_UUID}=discard root=${ENCRYPTED_PARTITION} rootflags=discard,subvol=@ rw quite vga=current"
echo ${BOOT_OPTIONS} > ${ROOT_MOUNT_POINT}/boot/cmdline.txt

echo "title Arch via systemd boot loader
linux /vmlinuz-${KERNEL_PACKAGE}
initrd /${PLATFORM}-ucode.img
initrd /initramfs-${KERNEL_PACKAGE}.img
options ${BOOT_OPTIONS}" > ${ROOT_MOUNT_POINT}/boot/loader/entries/arch-bootloader.conf

echo "title Arch via EFISTUB
efi /linux.efi" > /boot/loader/entries/arch-efistub.conf
cat ${ROOT_MOUNT_POINT}/boot/${PLATFORM}-ucode.img ${ROOT_MOUNT_POINT}/boot/initramfs-${KERNEL_PACKAGE}.img > ${ROOT_MOUNT_POINT}/boot/intitramfs-unified.img
objcopy --add-section .osrel=${ROOT_MOUNT_POINT}/etc/os-release --change-section-vma .osrel=0x20000 --add-section .cmdline=${ROOT_MOUNT_POINT}/boot/cmdline.txt --change-section-vma .cmdline=0x30000 --add-section .linux=${ROOT_MOUNT_POINT}/boot/vmlinuz-${KERNEL_PACKAGE} --change-section-vma .linux=0x40000 --add-section .initrd=${ROOT_MOUNT_POINT}/boot/initramfs-unified.img --change-section-vma .initrd=0x3000000 ${ROOT_MOUNT_POINT}/usr/lib/systemd/boot/efi/linuxx64.efi.stub ${ROOT_MOUNT_POINT}/boot/linux.efi

echo "title KeyTool
efi /BOOT/KeyTool.efi" > /boot/loader/entries/keytool.conf
cp ${ROOT_MOUNT_POINT}/usr/share/efitools/efi/KeyTool.efi ${ROOT_MOUNT_POINT}/boot/BOOT/KeyTool.efi

echo "default arch.conf
timeout 3
console-mode keep
editor no" > ${ROOT_MOUNT_POINT}/boot/loader/arch-bootloader.conf

# TODO blacklist amd64_edac_mod https://askubuntu.com/questions/1264469/ecc-disabled-in-the-bios-or-no-ecc-capability-module-will-not-load

# TODO check fstrim

# TODO secure boot

HOSTNAME=krieger
UEFI_KEY_PATH=/etc/efi-keys
mkdir -p ${ROOT_MOUNT_POINT}${UEFI_KEY_PATH} && openssl req -new -x509 -newkey rsa:2048 -subj "/CN=${HOSTNAME} PK/" -keyout ${ROOT_MOUNT_POINT}${UEFI_KEY_PATH}/PK.key -out ${ROOT_MOUNT_POINT}${UEFI_KEY_PATH}/PK.crt -days 3650 -nodes -sha256 && openssl req -new -x509 -newkey rsa:2048 -subj "/CN=${HOSTNAME} KEK/" -keyout ${ROOT_MOUNT_POINT}${UEFI_KEY_PATH}/KEK.key -out ${ROOT_MOUNT_POINT}${UEFI_KEY_PATH}/KEK.crt -days 3650 -nodes -sha256 && openssl req -new -x509 -newkey rsa:2048 -subj "/CN=${HOSTNAME} DB/" -keyout ${ROOT_MOUNT_POINT}${UEFI_KEY_PATH}/DB.key -out ${ROOT_MOUNT_POINT}${UEFI_KEY_PATH}/DB.crt -days 3650 -nodes -sha256 && openssl x509 -in ${ROOT_MOUNT_POINT}${UEFI_KEY_PATH}/PK.crt -out ${ROOT_MOUNT_POINT}${UEFI_KEY_PATH}/PK.cer -outform DER && openssl x509 -in ${ROOT_MOUNT_POINT}${UEFI_KEY_PATH}/KEK.crt -out ${ROOT_MOUNT_POINT}${UEFI_KEY_PATH}/KEK.cer -outform DER && openssl x509 -in ${ROOT_MOUNT_POINT}${UEFI_KEY_PATH}/DB.crt -out ${ROOT_MOUNT_POINT}${UEFI_KEY_PATH}/DB.cer -outform DER && touch ${ROOT_MOUNT_POINT}${UEFI_KEY_PATH}/noPK.esl

UEFI_KEY_GUID=`uuidgen --time`
echo ${UEFI_KEY_GUID} > ${ROOT_MOUNT_POINT}${UEFI_KEY_PATH}/GUID.txt

arch-chroot ${ROOT_MOUNT_POINT} cert-to-efi-sig-list -g ${UEFI_KEY_GUID} ${UEFI_KEY_PATH}/PK.crt ${UEFI_KEY_PATH}/PK.esl && arch-chroot ${ROOT_MOUNT_POINT} cert-to-efi-sig-list -g ${UEFI_KEY_GUID} ${UEFI_KEY_PATH}/KEK.crt ${UEFI_KEY_PATH}/KEK.esl && arch-chroot ${ROOT_MOUNT_POINT} cert-to-efi-sig-list -g ${UEFI_KEY_GUID} ${UEFI_KEY_PATH}/DB.crt ${UEFI_KEY_PATH}/DB.esl

arch-chroot ${ROOT_MOUNT_POINT} sign-efi-sig-list -t "$(date --date='1 second' +'%Y-%m-%d %H:%M:%S')" -k ${UEFI_KEY_PATH}/PK.key -c ${UEFI_KEY_PATH}/PK.crt PK ${UEFI_KEY_PATH}/PK.esl ${UEFI_KEY_PATH}/PK.auth && arch-chroot ${ROOT_MOUNT_POINT} sign-efi-sig-list -t "$(date --date='1 second' +'%Y-%m-%d %H:%M:%S')" -k ${UEFI_KEY_PATH}/PK.key -c ${UEFI_KEY_PATH}/PK.crt PK ${UEFI_KEY_PATH}/noPK.esl ${UEFI_KEY_PATH}/noPK.auth && arch-chroot ${ROOT_MOUNT_POINT} sign-efi-sig-list -t "$(date --date='1 second' +'%Y-%m-%d %H:%M:%S')" -k ${UEFI_KEY_PATH}/PK.key -c ${UEFI_KEY_PATH}/PK.crt KEK ${UEFI_KEY_PATH}/KEK.esl ${UEFI_KEY_PATH}/KEK.auth && arch-chroot ${ROOT_MOUNT_POINT} sign-efi-sig-list -t "$(date --date='1 second' +'%Y-%m-%d %H:%M:%S')" -k ${UEFI_KEY_PATH}/KEK.key -c ${UEFI_KEY_PATH}/KEK.crt db ${UEFI_KEY_PATH}/DB.esl ${UEFI_KEY_PATH}/DB.auth

chmod 0400 ${ROOT_MOUNT_POINT}${UEFI_KEY_PATH}

cp ${ROOT_MOUNT_POINT}${UEFI_KEY_PATH}/*.esl ${ROOT_MOUNT_POINT}/boot/BOOT/
cp ${ROOT_MOUNT_POINT}${UEFI_KEY_PATH}/*.auth ${ROOT_MOUNT_POINT}/boot/BOOT/

arch-chroot ${ROOT_MOUNT_POINT} sbsign --key /etc/efi-keys/DB.key --cert /etc/efi-keys/DB.crt --output /boot/BOOT/linux-signed.efi /boot/linux.efi

efibootmgr -c -d ${DISK_DEVICE} -p 1 --label ArchLinux -l "BOOT\linux-signed.efi" --verbose

# TODO xorg

# TODO snapper

# TODO parametrize script

