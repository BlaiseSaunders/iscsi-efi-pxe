#!/bin/bash

if [ $# -ne 6 ]
then
	echo "Usage: $0 working_dir disk_name"
	exit 1
fi
if [ -z "$1" ]
then
	echo "ERROR: No working dir specified"
	exit 1
fi
if [ -z "$2" ]
then
	echo "ERROR: No disk name specified"
	exit 1
fi
if [ -z "$3" ]
then
	echo "ERROR: No client name specified"
	exit 1
fi
if [ -z "$4" ]
then
	echo "ERROR: No target name specified"
	exit 1
fi
if [ -z "$5" ]
then
	echo "ERROR: No target IP specified"
	exit 1
fi
if [ -z "$6" ]
then
	echo "ERROR: No client IP specified"
	exit 1
fi


print_title () {
	printf %"$COLUMNS"s |tr " " "-"
	echo ""
	echo $1
	printf %"$COLUMNS"s |tr " " "-"
	echo ""
}


print_title "Creating disk image"
dd if=/dev/zero of=$1/$2.dat bs=$(( 1024 * 1024 )) count=10000 status=progress


print_title "Mounting Disk Image"
losetup -P /dev/loop3 $1/$2.dat
partprobe

print_title "Partitioning Disk"
cat << EOF > $1/autopart.sfdisk
label: dos
unit: sectors
sector-size: 512

start=        2048, size=     1048576, type=ef, bootable
start=     1050624, size=    19429376, type=83
EOF
sfdisk /dev/loop3 < $1/autopart.sfdisk
rm $1/autopart.sfdisk


print_title "Creating FS"
mkfs.ext4 /dev/loop3p2
mkfs.fat /dev/loop3p1
mkdir $1/chroot || true


print_title "Mounting FS"
mount /dev/loop3p2 $1/chroot
mkdir $1/chroot/boot || true
mkdir $1/chroot/boot/efi || true
mount /dev/loop3p1 $1/chroot/boot/efi
echo "Mounted! :)"

print_title "Bootstrapping Debian"
debootstrap bullseye $1/chroot > $1/image_bootstrap_log.txt
mount --bind /dev $1/chroot/dev
mount -t sysfs none $1/chroot/sys
mount -t proc none $1/chroot/proc
chroot $1/chroot /bin/bash -c "echo HELLO FROM DEBIAN CHROOT" 

print_title "Configuring environment within chroot"
cat <<EOF > $1/chroot/chroot_configure.sh

#!/bin/bash
cp /proc/mounts /etc/mtab
echo "UUID=$(blkid /dev/loop3p2 | awk -F 'UUID="' '{ print $2 }' | cut -f1 -d'"') / ext4 errors=remount-ro 0 1" > /etc/fstab
apt-get install openssh-server locales -y
apt-get install linux-image-amd64 grub-efi initramfs-tools -y
mkdir /root/.ssh || true
echo 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDjyI98rBAUbxVjYVVuXGgJ/hn6cTZI2WpJZI5slUzqpYHoago/LetIVkHKN9DK+s41qN0L/76or0GRgC7YNAzqV+nevsiQf/qDDppWaA7hbE8gCCR1jkhKC5QGSPpOqjsf1AFFGEYlDOPOHm7duPWeDPKRxD/3ZbWrm5aszKFrAHraY/uONuu9CpeolHzi98/taa8OaRhR7qv2kr2b3hI6vZn5Y9w6OmhMSxGQ5TaX/ZiaJvrjcDfhyVQP6me/RWzeJcWc68PCKFnpgZ9Idp3kvHapqy79KH+U55+o+7lDRekt32rcWUzaMoXv4Ut0MItNefo7YcsvyFbJf+XWnKn/ root@prox' > /root/.ssh/authorized_keys

mkdir /etc/iscsi || true
touch /etc/iscsi/iscsi.initramfs
echo "InitiatorName=iqn.$3:client" > /etc/iscsi/initiatorname.iscsi
sed -i "s/GRUB_CMDLINE_LINUX=\"\"/GRUB_CMDLINE_LINUX=\"ISCSI_INITIATOR=iqn.$3:client ISCSI_TARGET_NAME=iqn.$4:cluster ISCSI_TARGET_IP=$5 root=UUID=$(blkid /dev/loop3p2 | awk -F 'UUID="' '{ print $2 }' | cut -f1 -d'"')\"/" /etc/default/grub
update-grub
update-initramfs -u
grub-install

echo -e "auto lo\n\niface lo inet loopback\nauto enp3s0\nallow-hotplug enp3s0\niface enp3s0 inet static\n\taddress 192.168.88.$6\n\tnetmask 255.255.255.0\n\t192.168.88.1" > /etc/network/interfaces
echo $3 > /etc/hostname
echo "192.168.88.$6 $3.dandy.local" >> /etc/hosts

EOF
echo "Running script, logging to file..."
chroot $1/chroot /bin/bash -c 'bash /chroot_configure.sh' 2>&1 > $1/image_config_log.txt


print_title "Cleaning Up"
umount $1/chroot/boot/efi
umount $1/chroot/{dev,proc,sys,}
rm -rf $1/chroot
losetup -d /dev/loop3
#rm $1/$2.dat
