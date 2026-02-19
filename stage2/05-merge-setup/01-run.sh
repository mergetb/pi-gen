#!/bin/bash -e

# Restore working DNS for downloads (systemd-resolved package broke it)
# We'll set up the proper symlink at the end
rm -f "${ROOTFS_DIR}/etc/resolv.conf"
cp /etc/resolv.conf "${ROOTFS_DIR}/etc/resolv.conf"

# Configure journald
cat > "${ROOTFS_DIR}/etc/systemd/journald.conf" << 'EOF'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=100M
EOF

# Create persistent journal directory
mkdir -p "${ROOTFS_DIR}/var/log/journal"
on_chroot << EOF
systemd-tmpfiles --create --prefix /var/log/journal
systemctl daemon-reload
systemctl restart systemd-journald || true
EOF

# Configure systemd to reduce log verbosity
mkdir -p "${ROOTFS_DIR}/etc/systemd/system.conf.d"
cat > "${ROOTFS_DIR}/etc/systemd/system.conf.d/01-loglevel.conf" << 'EOF'
[Manager]
LogLevel=info
EOF

# Configure SSH
echo "UseDNS no" >> "${ROOTFS_DIR}/etc/ssh/sshd_config"

# Create machine-id-init service
cat > "${ROOTFS_DIR}/etc/systemd/system/machine-id-init.service" << 'EOF'
[Unit]
Description=Initialize machine id

[Service]
Type=oneshot
ExecStart=/bin/systemd-machine-id-setup

[Install]
WantedBy=multi-user.target
EOF

# Create foundryc service
cat > "${ROOTFS_DIR}/lib/systemd/system/foundryc.service" << 'EOF'
[Unit]
Description=Foundry client
Documentation=https://gitlab.com/mergetb/tech/foundry

[Service]
ExecStart=/usr/local/bin/foundryc
Type=simple
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Create node_exporter service
cat > "${ROOTFS_DIR}/etc/systemd/system/node_exporter.service" << 'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
Type=simple
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Set fstab with PARTUUIDs
cat > "${ROOTFS_DIR}/etc/fstab" << 'EOF'
PARTUUID=a0000000-0000-0000-0000-00000000000a /         ext4    defaults,noatime        0       1
PARTUUID=10000000-0000-0000-0000-000000000001 /boot/firmware         vfat    defaults        0       2
EOF

# Force built-in ethernet to eth0 (handles both end0 from kexec and eth0 from disk boot)
cat > "${ROOTFS_DIR}/etc/udev/rules.d/70-persistent-net.rules" << 'EOF'
# Force built-in macb interface to eth0 regardless of initial name
SUBSYSTEM=="net", ACTION=="add", ENV{ID_NET_DRIVER}=="macb", NAME="eth0"
EOF

# Configure systemd-networkd to bring up all interfaces with DHCP
cat > "${ROOTFS_DIR}/etc/systemd/network/20-wired-dhcp.network" << 'EOF'
[Match]
Name=e*
#end0 for primary
#ethX for usb

[Network]
DHCP=yes
EOF

# Configure locales
on_chroot << EOF
sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
dpkg-reconfigure --frontend=noninteractive locales
update-locale LANG=en_US.UTF-8
EOF

# Set keymap
on_chroot << EOF
localectl set-keymap us || true
EOF

# Disable NetworkManager if it exists and enable systemd-networkd/resolved
on_chroot << EOF
systemctl disable NetworkManager.service || true
systemctl disable NetworkManager-wait-online.service || true
systemctl disable NetworkManager-dispatcher.service || true
systemctl mask NetworkManager.service || true
systemctl enable machine-id-init.service
systemctl enable systemd-networkd.service
systemctl enable systemd-networkd.socket
systemctl enable systemd-resolved.service
systemctl enable foundryc.service
systemctl enable node_exporter.service
systemctl enable serial-getty@ttyAMA0.service
EOF

# Purge unattended-upgrades and NetworkManager
on_chroot << EOF
apt-get purge -y unattended-upgrades || true
apt-get purge -y network-manager || true
apt-get autoremove -y
EOF

# Remove machine-ids so they're regenerated on first boot
rm -f "${ROOTFS_DIR}/etc/machine-id"
rm -f "${ROOTFS_DIR}/var/lib/dbus/machine-id"
touch "${ROOTFS_DIR}/etc/machine-id"

# Remove network interfaces file
rm -rf "${ROOTFS_DIR}/etc/network/interfaces"

# Download foundryc binary
on_chroot << EOF
curl -L "https://gitlab.com/api/v4/projects/11436163/jobs/artifacts/v1.1.5/raw/build/foundryc-arm64?job=make" -o /usr/local/bin/foundryc
chmod 755 /usr/local/bin/foundryc
EOF

# Download and install node_exporter
on_chroot << EOF
cd /tmp
curl -L -O https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-arm64.tar.gz
tar xzf node_exporter-1.8.2.linux-arm64.tar.gz
cp node_exporter-1.8.2.linux-arm64/node_exporter /usr/local/bin/
chmod +x /usr/local/bin/node_exporter
useradd -r -s /sbin/nologin node_exporter || true
rm -rf node_exporter-1.8.2.linux-arm64*
EOF

# Final apt cleanup
on_chroot << EOF
DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y
apt-get autoremove -y
apt-get clean
apt-get autoclean
rm -rf /var/lib/apt/lists/*
EOF

# Remove piwiz and disable userconfig
rm -f "${ROOTFS_DIR}/etc/xdg/autostart/piwiz.desktop"
on_chroot << EOF
systemctl disable userconfig.service || true
systemctl mask userconfig.service || true
apt-get purge -y userconf-pi || true
apt-get purge -y raspberrypi-ui-mods || true
apt-get purge -y piwiz || true
apt-get autoremove -y
EOF

on_chroot << EOF
mkdir -p /etc/cloud
touch /etc/cloud/cloud-init.disabled
EOF

# Setup resolv.conf symlink for runtime (after all downloads complete)
rm -f "${ROOTFS_DIR}/etc/resolv.conf"
on_chroot << EOF
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
EOF
