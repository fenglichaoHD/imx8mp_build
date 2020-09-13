#!/bin/bash
set -e

### General setup
NXP_REL=rel_imx_5.4.24_2.1.0
UBOOT_NXP_REL=imx_v2020.04_5.4.24_2.1.0
#rel_imx_5.4.24_2.1.0
#imx_v2020.04_5.4.24_2.1.0
BUILDROOT_VERSION=2020.02
###

export ARCH=arm64
ROOTDIR=`pwd`

COMPONENTS="imx-atf uboot-imx linux-imx imx-mkimage"
mkdir -p build
for i in $COMPONENTS; do
	if [[ ! -d $ROOTDIR/build/$i ]]; then
		cd $ROOTDIR/build/
		git clone https://source.codeaurora.org/external/imx/$i
		cd $i
		if [ "x$i" == "xuboot-imx" ]; then
			git checkout remotes/origin/$UBOOT_NXP_REL
			git pull origin $UBOOT_NXP_REL
		elif [ "x$i" == "xlinux-imx" ]; then
			git checkout -b $NXP_REL
			git pull origin $NXP_REL
		elif [ "x$i" == "ximx-mkimage" ]; then
			git checkout -b $NXP_REL
			git pull origin $NXP_REL
		elif [ "x$i" == "ximx-atf" ]; then
			git checkout $NXP_REL
			git pull origin $NXP_REL
		else
			git checkout -b $NXP_REL
			git pull origin $NXP_REL
		fi
		if [[ -d $ROOTDIR/patches/$i/ ]]; then
			git am $ROOTDIR/patches/$i/*.patch
		fi
	fi
done


if [[ ! -d $ROOTDIR/build/firmware ]]; then
	cd $ROOTDIR/build/
	mkdir -p firmware
	cd firmware
	wget https://www.nxp.com/lgfiles/NMG/MAD/YOCTO/firmware-imx-8.7.bin
	bash firmware-imx-8.7.bin --auto-accept
	cp -v $(find . | awk '/train|hdmi_imx8|dp_imx8/' ORS=" ") ${ROOTDIR}/build/imx-mkimage/iMX8M/
fi

if [[ ! -d $ROOTDIR/build/buildroot ]]; then
	cd $ROOTDIR/build
	git clone https://github.com/buildroot/buildroot -b $BUILDROOT_VERSION
fi

# Build buildroot
cd $ROOTDIR/build/buildroot
cp $ROOTDIR/configs/buildroot_defconfig configs/imx8mp_hummingboard_pulse_defconfig
make imx8mp_hummingboard_pulse_defconfig
make

export CROSS_COMPILE=$ROOTDIR/build/buildroot/output/host/bin/aarch64-linux-

# Build ATF
cd $ROOTDIR/build/imx-atf
make -j32 PLAT=imx8mp bl31
cp build/imx8mp/release/bl31.bin $ROOTDIR/build/imx-mkimage/iMX8M/

# Build u-boot
cd $ROOTDIR/build/uboot-imx/
make imx8mp_solidrun_defconfig
make -j 32
set +e
cp -v $(find . | awk '/u-boot-spl.bin$|u-boot.bin$|u-boot-nodtb.bin$|.*\.dtb$|mkimage$/' ORS=" ") ${ROOTDIR}/build/imx-mkimage/iMX8M/
cp tools/mkimage ${ROOTDIR}/build//imx-mkimage/iMX8M/mkimage_uboot
set -e

# Build linux
cd $ROOTDIR/build/linux-imx
make defconfig
./scripts/kconfig/merge_config.sh .config $ROOTDIR/configs/kernel.extra
make -j32 Image dtbs

# Bring bootlader all together
unset ARCH CROSS_COMPILE
cd $ROOTDIR/build/imx-mkimage/iMX8M
sed "s/\(^dtbs = \).*/\1imx8mp-solidrun.dtb/;s/\(mkimage\)_uboot/\1/" soc.mak > Makefile
make clean
make flash_evk SOC=iMX8MP

# Create disk images
mkdir -p $ROOTDIR/images/tmp/
cd $ROOTDIR/images
dd if=/dev/zero of=tmp/part1.fat32 bs=1M count=148
mkdosfs tmp/part1.fat32

echo "label linux" > $ROOTDIR/images/extlinux.conf
echo "        linux ../Image" >> $ROOTDIR/images/extlinux.conf
echo "        fdt ../imx8mp-hummingboard-pulse.dtb" >> $ROOTDIR/images/extlinux.conf
echo "        append root=/dev/mmcblk1p2 rootwait" >> $ROOTDIR/images/extlinux.conf
mmd -i tmp/part1.fat32 ::/extlinux
mcopy -i tmp/part1.fat32 $ROOTDIR/images/extlinux.conf ::/extlinux/extlinux.conf
mcopy -i tmp/part1.fat32 $ROOTDIR/build/linux-imx/arch/arm64/boot/Image ::/Image
mcopy -s -i tmp/part1.fat32 $ROOTDIR/build/linux-imx/arch/arm64/boot/dts/freescale/*imx8mp*.dtb ::/
dd if=/dev/zero of=microsd.img bs=1M count=301
dd if=$ROOTDIR/build/imx-mkimage/iMX8M/flash.bin of=microsd.img bs=1K seek=32 conv=notrunc
parted --script microsd.img mklabel msdos mkpart primary 2MiB 150MiB mkpart primary 150MiB 300MiB
dd if=tmp/part1.fat32 of=microsd.img bs=1M seek=2 conv=notrunc
dd if=$ROOTDIR/build/buildroot/output/images/rootfs.ext2 of=microsd.img bs=1M seek=150 conv=notrunc
echo -e "\n\n*** Image is ready - images/microsd.img"
