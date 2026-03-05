#!/bin/bash
set -euo pipefail

REG_NAME="Vinh..HaiPhong"
REG_APP="GGCL-PROXY"

# Generate Random User and Password
PROXY_USER="$(openssl rand -hex 4 2>/dev/null || echo "user$RANDOM")"
PROXY_PASS="$(openssl rand -hex 6 2>/dev/null || echo "pass$RANDOM$RANDOM")"

DESIRED_TOKYO=4
DESIRED_OSAKA=4

TOKYO_ZONES=("asia-northeast1-a" "asia-northeast1-b" "asia-northeast1-c" "asia-northeast1-a")
OSAKA_ZONES=("asia-northeast2-a" "asia-northeast2-b" "asia-northeast2-c" "asia-northeast2-a")

MACHINE_TYPE="e2-micro"
IMAGE_FAMILY="ubuntu-2204-lts"
IMAGE_PROJECT="ubuntu-os-cloud"

BOOT_DISK_SIZE="10GB"
BOOT_DISK_TYPE="pd-balanced"

TAGS="http-server,https-server"
FW_NAME="allow-web-ssh"

SLEEP_BETWEEN_CREATES=30

WHOAMI="$(timeout 10 gcloud config get-value account 2>/dev/null || echo unknown)"
HOST="$(hostname 2>/dev/null || echo cloud)"
RUN_ID="$(date +%Y%m%d_%H%M%S)_$RANDOM"

ensure_firewall() {
  if gcloud compute firewall-rules list --filter="name=${FW_NAME}" --format="value(name)" | grep -q .; then
    gcloud compute firewall-rules update "${FW_NAME}" \
      --allow tcp:65531,tcp:22 \
      --target-tags=http-server,https-server >/dev/null 2>&1 || true
  else
    gcloud compute firewall-rules create "${FW_NAME}" \
      --allow tcp:65531,tcp:22 \
      --target-tags=http-server,https-server \
      --description="Allow HTTP, HTTPS, SSH, 65531" \
      --direction=INGRESS --priority=1000 --network=default >/dev/null 2>&1 || true
  fi
}

count_and_next_index() {
  local prefix="$1"
  local names count max

  names="$(timeout 30 gcloud compute instances list \
    --filter="name~'^${prefix}-[0-9]+'" \
    --format='value(name)' 2>/dev/null || true)"

  count=0
  [ -n "$names" ] && count="$(echo "$names" | wc -l | tr -d '[:space:]')"

  max=0
  if [ -n "$names" ]; then
    max="$(echo "$names" | sed -E 's/.*-([0-9]+)$/\1/' | sort -n | tail -n1)"
    max="${max:-0}"
  fi

  echo "${count} $((max + 1))"
}

make_startup() {
  local f
  f="$(mktemp /tmp/startup.XXXX.sh)"

  cat > "$f" <<EOF
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

apt update -y

sudo mkdir -p /opt/hev-socks5
cd /opt/hev-socks5
sudo wget -q -O hev-socks5-server https://github.com/heiher/hev-socks5-server/releases/download/2.11.2/hev-socks5-server-linux-x86_64
sudo chmod +x hev-socks5-server
sudo mkdir -p /etc/hev-socks5

cat > /etc/hev-socks5/config.yml <<CONF
main:
  workers: 4
  port: 65531
  listen-address: '0.0.0.0'
  listen-ipv6-only: false
  bind-address: ''
  bind-address-v4: '0.0.0.0'
  bind-address-v6: ''
  bind-interface: ''
  domain-address-type: unspec
  mark: 0
auth:
  username: ${PROXY_USER}
  password: ${PROXY_PASS}
CONF

sudo useradd -r -s /usr/sbin/nologin hev || true
sudo chown -R hev:hev /opt/hev-socks5
sudo chown -R hev:hev /etc/hev-socks5

cat > /etc/systemd/system/hev-socks5.service <<'SERVICE'
[Unit]
Description=hev-socks5-server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hev
Group=hev
ExecStart=/opt/hev-socks5/hev-socks5-server /etc/hev-socks5/config.yml
Restart=on-failure
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now hev-socks5
systemctl status hev-socks5 --no-pager || true
EOF

  echo "$f"
}

run_for_project() {
  local PROJECT="$1"
  local STARTUP_FILE="$2"

  timeout 15 gcloud config set project "$PROJECT" >/dev/null 2>&1 || true
  ensure_firewall

  # TOKYO
  local TOKYO_COUNT TOKYO_NEXT TOKYO_MISSING
  read -r TOKYO_COUNT TOKYO_NEXT <<< "$(count_and_next_index "proxy-tokyo")"
  TOKYO_MISSING=$(( DESIRED_TOKYO - TOKYO_COUNT ))

  if [ "${TOKYO_MISSING}" -gt 0 ]; then
    for i in $(seq 0 $((TOKYO_MISSING - 1))); do
      local IDX=$((TOKYO_NEXT + i))
      local NAME="proxy-tokyo-${IDX}"
      local ZONE="${TOKYO_ZONES[$(( IDX % ${#TOKYO_ZONES[@]} ))]}"

      timeout 180 gcloud compute instances create "$NAME" \
        --zone="${ZONE}" \
        --machine-type="${MACHINE_TYPE}" \
        --image-family="${IMAGE_FAMILY}" \
        --image-project="${IMAGE_PROJECT}" \
        --boot-disk-size="${BOOT_DISK_SIZE}" \
        --boot-disk-type="${BOOT_DISK_TYPE}" \
        --tags="${TAGS}" \
        --metadata-from-file=startup-script="${STARTUP_FILE}" \
        --metadata=enable-oslogin=true \
        --quiet || true

      sleep "${SLEEP_BETWEEN_CREATES}"
    done
  fi

  # OSAKA
  local OSAKA_COUNT OSAKA_NEXT OSAKA_MISSING
  read -r OSAKA_COUNT OSAKA_NEXT <<< "$(count_and_next_index "proxy-osaka")"
  OSAKA_MISSING=$(( DESIRED_OSAKA - OSAKA_COUNT ))

  if [ "${OSAKA_MISSING}" -gt 0 ]; then
    for i in $(seq 0 $((OSAKA_MISSING - 1))); do
      local IDX=$((OSAKA_NEXT + i))
      local NAME="proxy-osaka-${IDX}"
      local ZONE="${OSAKA_ZONES[$(( IDX % ${#OSAKA_ZONES[@]} ))]}"

      timeout 180 gcloud compute instances create "$NAME" \
        --zone="${ZONE}" \
        --machine-type="${MACHINE_TYPE}" \
        --image-family="${IMAGE_FAMILY}" \
        --image-project="${IMAGE_PROJECT}" \
        --boot-disk-size="${BOOT_DISK_SIZE}" \
        --boot-disk-type="${BOOT_DISK_TYPE}" \
        --tags="${TAGS}" \
        --metadata-from-file=startup-script="${STARTUP_FILE}" \
        --metadata=enable-oslogin=true \
        --quiet || true

      sleep "${SLEEP_BETWEEN_CREATES}"
    done
  fi
}

if [ "$WHOAMI" = "unknown" ] || [ -z "$WHOAMI" ]; then
  echo "❌ gcloud chưa login hoặc account chưa active."
  echo "👉 gcloud auth login"
  exit 1
fi

echo "🚀 START SCRIPT | REG_NAME=${REG_NAME} | ACC=${WHOAMI}"

cleanup() { true; }
trap cleanup EXIT

STARTUP_FILE="$(make_startup)"
trap 'rm -f "$STARTUP_FILE"; cleanup' EXIT

echo "🔎 Đang lấy danh sách project..."
mapfile -t ALL_PROJECTS < <(timeout 60 gcloud projects list --format="value(projectId)" || true)

if [ "${#ALL_PROJECTS[@]}" -eq 0 ]; then
  echo "❌ Không có project nào hoặc account không có quyền list."
  exit 1
fi

for p in "${ALL_PROJECTS[@]}"; do
  run_for_project "$p" "$STARTUP_FILE"
done

PROXY_LIST_65531="$(
  for PROJECT_ID in "${ALL_PROJECTS[@]}"; do
    timeout 30 gcloud --project "$PROJECT_ID" compute instances list \
      --filter="name~'^proxy-(tokyo|osaka)-'" \
      --format="value(EXTERNAL_IP)" 2>/dev/null | \
      awk -v u="${PROXY_USER}" -v pw="${PROXY_PASS}" 'NF {print $1":65531:"u":"pw}'
  done
)"

PROXY_FILE="$HOME/${WHOAMI}.txt"
{
  echo "APP=${REG_APP}"
  echo "NAME=${REG_NAME}"
  echo "ACCOUNT=${WHOAMI}"
  echo "HOST=${HOST}"
  echo "RUN=${RUN_ID}"
  echo "TIME=$(date)"
  echo ""
  echo "---- PORT 65531 ----"
  echo "$PROXY_LIST_65531"
} > "$PROXY_FILE"

echo ""
echo "========== PROXY PORT 65531 =========="
echo "$PROXY_LIST_65531"
echo ""

echo "🎉 HOÀN TẤT."


