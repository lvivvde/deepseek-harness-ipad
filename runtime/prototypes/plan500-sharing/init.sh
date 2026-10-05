#!/bin/busybox sh
# PROTOTYPE: immutable system lower layer, disposable RAM upper layer, no user disk.
set -eu
/bin/busybox --install -s /bin
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
mkdir -p /proc /sys /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
for module in virtio_blk virtio_net ext4 overlay 9pnet_virtio 9p; do modprobe "$module"; done
mkdir -p /system /upper /work /rootfs
mount -t ext4 -o ro /dev/vda /system
mount -t overlay overlay -o lowerdir=/system,upperdir=/upper,workdir=/work /rootfs
mkdir -p /rootfs/workspace
mount -t 9p -o trans=virtio,version=9p2000.L,cache=none,msize=262144 workspace /rootfs/workspace
mount -t proc proc /rootfs/proc
mount -t sysfs sysfs /rootfs/sys
mount --bind /dev /rootfs/dev
cp /probe-agent.cjs /rootfs/run/probe-agent.cjs
cp /probe-token /rootfs/run/probe-token
ip link set eth0 up
ip addr add 10.0.2.15/24 dev eth0
ip route add default via 10.0.2.2
chroot /rootfs /opt/node/bin/node /run/probe-agent.cjs &
exec /bin/sh
