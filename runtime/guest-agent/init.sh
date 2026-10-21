#!/bin/busybox sh
# PROTOTYPE: immutable system lower layer, disposable RAM upper layer, no user disk.
# The 9P share is only reachable read-only; leased commands get a private rw view.
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
mkdir -p /rootfs/workspace /rootfs/run/ws/rw
chmod 0700 /rootfs/run/ws
mount -t 9p -o trans=virtio,version=9p2000.L,cache=none,msize=262144,nosuid,nodev workspace /rootfs/run/ws/rw
mount --bind /rootfs/run/ws/rw /rootfs/workspace
mount -o remount,bind,ro,nosuid,nodev /rootfs/workspace
mount -t proc proc /rootfs/proc
mount -t sysfs sysfs /rootfs/sys
mount -t cgroup2 cgroup2 /rootfs/sys/fs/cgroup
mount --bind /dev /rootfs/dev
# Interactive terminals (#17) need their own pseudoterminals.
mkdir -p /rootfs/dev/pts
mount -t devpts -o gid=5,mode=0620,ptmxmode=0666 devpts /rootfs/dev/pts
# system.raw /tmp is root-only; the unprivileged command uid needs HOME/tmp.
mount -t tmpfs -o mode=1777 tmpfs /rootfs/tmp
echo 0 > /proc/sys/user/max_user_namespaces
cp /probe-agent.cjs /rootfs/run/probe-agent.cjs
cp /probe-token /rootfs/run/probe-token
chmod 0600 /rootfs/run/probe-token
ip link set lo up
ip link set eth0 up
ip addr add 10.0.2.15/24 dev eth0
ip route add default via 10.0.2.2
# QEMU user networking's resolver, for a push to an authorised test remote (#39 gate 5).
rm -f /rootfs/etc/resolv.conf; echo 'nameserver 10.0.2.3' > /rootfs/etc/resolv.conf
chroot /rootfs /opt/node/bin/node /run/probe-agent.cjs &
exec /bin/sh
