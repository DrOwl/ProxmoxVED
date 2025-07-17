#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Authors: MickLesk (CanbiZ)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://frigate.video/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies (Patience)"
$STD apt-get install -y \
  git gpg ca-certificates automake build-essential xz-utils libtool ccache pkg-config \
  libgtk-3-dev libavcodec-dev libavformat-dev libswscale-dev libv4l-dev libxvidcore-dev libx264-dev \
  libjpeg-dev libpng-dev libtiff-dev openexr libatlas-base-dev libssl-dev libtbb-dev \
  libgstreamer-plugins-base1.0-dev libgstreamer1.0-dev gcc gfortran \
  libopenblas-dev liblapack-dev libusb-1.0-0-dev jq moreutils tclsh libhdf5-dev libopenexr-dev
msg_ok "Installed Dependencies"

msg_info "Setup Python3"
$STD apt-get install -y \
  python3 python3-dev python3-setuptools python3-distutils python3-pip
$STD pip install --upgrade pip
msg_ok "Setup Python3"

msg_info "Installing Node.js"
DIR_KEYS="/etc/apt/keyrings"
PATH_nodesource_KEY="${DIR_KEYS}/nodesource.gpg"
DIR_apt_sources="/etc/apt/sources.list.d"
PATH_nodesource_LIST="${DIR_apt_sources}/nodesource.list"

mkdir -p /etc/apt/keyrings

if [[ ! -f ${PATH_nodesource_KEY} ]]; then
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o ${PATH_nodesource_KEY}
fi
if [[ ! -f ${PATH_nodesource_LIST} ]]; then
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
    >${PATH_nodesource_LIST}
fi
$STD apt-get update
$STD apt-get install -y nodejs
msg_ok "Installed Node.js"

msg_info "Installing go2rtc"
GET_go2rtc_RELEASE=$(curl -s "https://api.github.com/repos/AlexxIT/go2rtc/releases/${go2rtc_version:-latest}" | jq -r '.tag_name')
BIN_go2rtc_RELEASE=go2rtc-${GET_go2rtc_RELEASE}
DIR_go2rtc="/usr/local/go2rtc/bin"
PATH_go2rtc_RELEASE="${DIR_go2rtc}/${BIN_go2rtc_RELEASE}"
LOCAL_go2rtc_LINK="/usr/local/bin/go2rtc"
mkdir -p "${DIR_go2rtc}"

if [[ -L "${LOCAL_go2rtc_LINK}" && -x "${LOCAL_go2rtc_LINK}" ]]; then
  LOCAL_go2rtc_VER=$("${LOCAL_go2rtc_LINK}" --version | cut -f3 -d" ")
elif [[ -f "${LOCAL_go2rtc_LINK}" ]]; then
  rm -f "${LOCAL_go2rtc_LINK}"
fi

if [[ "v${LOCAL_go2rtc_VER:-NONE}" != "${GET_go2rtc_RELEASE}" ]]; then
  wget -qO "${PATH_go2rtc_RELEASE}" "https://github.com/AlexxIT/go2rtc/releases/download/${GET_go2rtc_RELEASE}/go2rtc_linux_amd64"
  chmod +x "${PATH_go2rtc_RELEASE}"
  $STD ln -svf "${PATH_go2rtc_RELEASE}" "${LOCAL_go2rtc_LINK}"
fi
msg_ok "Installed go2rtc"

msg_info "Setting Up Hardware Acceleration"
$STD apt-get -y install \
  va-driver-all ocl-icd-libopencl1 intel-opencl-icd vainfo intel-gpu-tools
if [[ "$CTTYPE" == "0" ]]; then
  chgrp video /dev/dri
  chmod 755 /dev/dri
  chmod 660 /dev/dri/*
fi
msg_ok "Set Up Hardware Acceleration"

msg_info "Setup Frigate"
GET_frigate_RELEASE=${frigate_version:-latest}
RELEASE=$(curl -s "https://api.github.com/repos/blakeblackshear/frigate/releases/${GET_frigate_RELEASE}" | jq -r '.tag_name')
msg_info "using release ${RELEASE}"
mkdir -p /opt/frigate/models
curl -fsSL "https://github.com/blakeblackshear/frigate/archive/refs/tags/${RELEASE}.tar.gz" -o frigate.tar.gz
rm -rf /opt/frigate/web
rm -rf /wheels/*.whl
rm -rf /opt/frigate/docker
tar -xzf frigate.tar.gz -C /opt/frigate --strip-components 1
rm -rf frigate.tar.gz
cd /opt/frigate || exit
$STD pip install -r /opt/frigate/docker/main/requirements.txt --break-system-packages
$STD pip install -r /opt/frigate/docker/main/requirements-ov.txt --break-system-packages
$STD pip3 wheel --wheel-dir=/wheels -r /opt/frigate/docker/main/requirements-wheels.txt
pip3 install -U /wheels/*.whl
cp -a /opt/frigate/docker/main/rootfs/. /
export TARGETARCH="amd64"
echo 'libc6 libraries/restart-without-asking boolean true' | debconf-set-selections
$STD /opt/frigate/docker/main/install_deps.sh
$STD apt update
$STD ln -svf /usr/lib/btbn-ffmpeg/bin/ffmpeg /usr/local/bin/ffmpeg
$STD ln -svf /usr/lib/btbn-ffmpeg/bin/ffprobe /usr/local/bin/ffprobe
$STD pip3 install -U /wheels/*.whl
ldconfig
$STD pip3 install -r /opt/frigate/docker/main/requirements-dev.txt
$STD /opt/frigate/.devcontainer/initialize.sh
$STD make version
cd /opt/frigate/web || exit
$STD npm install
$STD npm run build
cp -r /opt/frigate/web/dist/* /opt/frigate/web/
sed -i '/^s6-svc -O \.$/s/^/#/' /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/frigate/run

msg_info "Setup Frigate Config"
if [[ ! -d "/config/" ]]; then
  cp -r /opt/frigate/config/. /config
  cat <<EOF >/config/config.yml
mqtt:
  enabled: false
cameras:
  test:
    ffmpeg:
      #hwaccel_args: preset-vaapi
      inputs:
        - path: /media/frigate/person-bicycle-car-detection.mp4
          input_args: -re -stream_loop -1 -fflags +genpts
          roles:
            - detect
            - rtmp
    detect:
      height: 1080
      width: 1920
      fps: 5
EOF
  ln -sf /config/config.yml /opt/frigate/config/config.yml
fi

if [[ "$CTTYPE" == "0" ]]; then
  sed -i -e 's/^kvm:x:104:$/render:x:104:root,frigate/' -e 's/^render:x:105:root$/kvm:x:105:/' /etc/group
else
  sed -i -e 's/^kvm:x:104:$/render:x:104:frigate/' -e 's/^render:x:105:$/kvm:x:105:/' /etc/group
fi
echo "tmpfs   /tmp/cache      tmpfs   defaults        0       0" >>/etc/fstab
msg_ok "Installed Frigate $RELEASE"

read -rp "Semantic Search requires a dedicated GPU and at least 16GB RAM. Would you like to install it? (y/n): " semantic_choice
if [[ "$semantic_choice" == "y" ]]; then
  msg_info "Configuring Semantic Search & AI Models"
  mkdir -p /opt/frigate/models/semantic_search
  curl -fsSL -o /opt/frigate/models/semantic_search/clip_model.pt https://huggingface.co/openai/clip-vit-base-patch32/resolve/main/pytorch_model.bin
  msg_ok "Semantic Search Models Installed"
else
  msg_ok "Skipped Semantic Search Setup"
fi

msg_info "Building and Installing libUSB without udev"
GET_libusb_RELEASE="${libusb_version:-1.0.26}"

curl -fsSL -o /tmp/libusb.zip "https://github.com/libusb/libusb/archive/v${GET_libusb_RELEASE}.zip"
unzip -q /tmp/libusb.zip -d /tmp/
cd "/tmp/libusb-${GET_libusb_RELEASE}" || exit 1
./bootstrap.sh
./configure --disable-udev --enable-shared
make -j "$(nproc --all)"
make install
ldconfig
rm -rf /tmp/libusb.zip /tmp/"${GET_libusb_RELEASE}"
msg_ok "Installed libUSB without udev"

msg_info "Installing Coral Object Detection Model (Patience)"
export CCACHE_DIR=/root/.ccache
export CCACHE_MAXSIZE=2G
cd /
wget -qO edgetpu_model.tflite https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess_edgetpu.tflite
wget -qO cpu_model.tflite https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess.tflite
cp /opt/frigate/labelmap.txt /labelmap.txt
wget -qO yamnet-tflite-classification-tflite-v1.tar.gz https://www.kaggle.com/api/v1/models/google/yamnet/tfLite/classification-tflite/1/download
tar xzf yamnet-tflite-classification-tflite-v1.tar.gz
rm -rf yamnet-tflite-classification-tflite-v1.tar.gz
mv 1.tflite cpu_audio_model.tflite
cp /opt/frigate/audio-labelmap.txt /audio-labelmap.txt
mkdir -p /media/frigate
wget -qO /media/frigate/person-bicycle-car-detection.mp4 https://github.com/intel-iot-devkit/sample-videos/raw/master/person-bicycle-car-detection.mp4
msg_ok "Installed Coral Object Detection Model"

msg_info "Building Nginx with Custom Modules"
$STD /opt/frigate/docker/main/build_nginx.sh
sed -e '/s6-notifyoncheck/ s/^#*/#/' -i /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/nginx/run
ln -sf /usr/local/nginx/sbin/nginx /usr/local/bin/nginx
msg_ok "Built Nginx"

msg_info "Installing Tempio"
sed -i 's|/rootfs/usr/local|/usr/local|g' /opt/frigate/docker/main/install_tempio.sh
$STD /opt/frigate/docker/main/install_tempio.sh
chmod +x /usr/local/tempio/bin/tempio
ln -sf /usr/local/tempio/bin/tempio /usr/local/bin/tempio
msg_ok "Installed Tempio"

msg_info "Creating Services"
cat <<EOF >/etc/systemd/system/create_directories.service
[Unit]
Description=Create necessary directories for logs

[Service]
Type=oneshot
ExecStart=/bin/bash -c '/bin/mkdir -p /dev/shm/logs/{frigate,go2rtc,nginx} && /bin/touch /dev/shm/logs/{frigate/current,go2rtc/current,nginx/current} && /bin/chmod -R 777 /dev/shm/logs'

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now create_directories
sleep 3

cat <<EOF >/etc/systemd/system/go2rtc.service
[Unit]
Description=go2rtc service
After=network.target
After=create_directories.service
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
User=root
ExecStartPre=+rm /dev/shm/logs/go2rtc/current
ExecStart=/bin/bash -c "bash /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/go2rtc/run 2> >(/usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S ' >&2) | /usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S '"
StandardOutput=file:/dev/shm/logs/go2rtc/current
StandardError=file:/dev/shm/logs/go2rtc/current

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now go2rtc
sleep 3

cat <<EOF >/etc/systemd/system/frigate.service
[Unit]
Description=Frigate service
After=go2rtc.service
After=create_directories.service
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
User=root
# Environment=PLUS_API_KEY=
ExecStartPre=+rm /dev/shm/logs/frigate/current
ExecStart=/bin/bash -c "bash /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/frigate/run 2> >(/usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S ' >&2) | /usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S '"
StandardOutput=file:/dev/shm/logs/frigate/current
StandardError=file:/dev/shm/logs/frigate/current

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now frigate
sleep 3

cat <<EOF >/etc/systemd/system/nginx.service
[Unit]
Description=Nginx service
After=frigate.service
After=create_directories.service
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
User=root
ExecStartPre=+rm /dev/shm/logs/nginx/current
ExecStart=/bin/bash -c "bash /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/nginx/run 2> >(/usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S ' >&2) | /usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S '"
StandardOutput=file:/dev/shm/logs/nginx/current
StandardError=file:/dev/shm/logs/nginx/current

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now nginx
msg_ok "Configured Services"

motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"
