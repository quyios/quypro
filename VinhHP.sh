#!/bin/bash
set -euo pipefail



REG_NAME="Vinh..HaiPhong"
REG_APP="GGCL-PROXY"



DESIRED_TOKYO=4
DESIRED_OSAKA=4

ZONE_TOKYO="asia-northeast1-c"
ZONE_OSAKA="asia-northeast2-c"

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
      --allow tcp:60501,tcp:22 \
      --target-tags=http-server,https-server >/dev/null 2>&1 || true
  else
    gcloud compute firewall-rules create "${FW_NAME}" \
      --allow tcp:60501,tcp:22 \
      --target-tags=http-server,https-server \
      --description="Allow HTTP Proxy 60501 and SSH" \
      --direction=INGRESS --priority=1000 --network=default >/dev/null 2>&1 || true
  fi
}

count_and_next_index() {
  local prefix="$1" zone="$2"
  local names count max

  names="$(timeout 30 gcloud compute instances list \
    --filter="name~'^${prefix}-[0-9]+' AND zone:(${zone})" \
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

  cat > "$f" <<'EOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

apt update -y
apt install -y wget curl apache2-utils squid

# Configure Squid
cat > /etc/squid/squid.conf <<CONF
http_port 60501
cache deny all
hierarchy_stoplist cgi-bin ?

access_log none
cache_store_log none
cache_log /dev/null

refresh_pattern ^ftp: 1440 20% 10080
refresh_pattern ^gopher: 1440 0% 1440
refresh_pattern -i (/cgi-bin/|\?) 0 0% 0
refresh_pattern . 0 20% 4320

acl localhost src 127.0.0.1/32 ::1
acl to_localhost dst 127.0.0.0/8 0.0.0.0/32 ::1

acl SSL_ports port 1-65535
acl Safe_ports port 1-65535
acl CONNECT method CONNECT
acl siteblacklist dstdomain "/etc/squid/blacklist.acl"
http_access allow manager localhost
http_access deny manager

http_access deny !Safe_ports

http_access deny CONNECT !SSL_ports
http_access deny siteblacklist
#auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwd
#auth_param basic children 5
#auth_param basic realm Squid proxy-caching web server
#auth_param basic credentialsttl 2 hours
#acl password proxy_auth REQUIRED
http_access allow localhost
#http_access allow password
http_access allow all

forwarded_for off
request_header_access Allow allow all
request_header_access Authorization allow all
request_header_access WWW-Authenticate allow all
request_header_access Proxy-Authorization allow all
#request_header_access Proxy-Authenticate allow all
request_header_access Cache-Control allow all
request_header_access Content-Encoding allow all
request_header_access Content-Length allow all
request_header_access Content-Type allow all
request_header_access Date allow all
request_header_access Expires allow all
request_header_access Host allow all
request_header_access If-Modified-Since allow all
request_header_access Last-Modified allow all
request_header_access Location allow all
request_header_access Pragma allow all
request_header_access Accept allow all
request_header_access Accept-Charset allow all
request_header_access Accept-Encoding allow all
request_header_access Accept-Language allow all
request_header_access Content-Language allow all
request_header_access Mime-Version allow all
request_header_access Retry-After allow all
request_header_access Title allow all
request_header_access Connection allow all
request_header_access Proxy-Connection allow all
request_header_access User-Agent allow all
request_header_access Cookie allow all
request_header_access All deny all
CONF

systemctl enable squid

IP_ALL=$(/sbin/ip -4 -o addr show scope global | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALL_ARRAY=($IP_ALL)

SQUID_CONFIG="\n"

for IP_ADDR in ${IP_ALL_ARRAY[@]}; do
    ACL_NAME="proxy_ip_${IP_ADDR//\./_}"
    SQUID_CONFIG+="acl ${ACL_NAME}  myip ${IP_ADDR}\n"
    SQUID_CONFIG+="tcp_outgoing_address ${IP_ADDR} ${ACL_NAME}\n\n"
done

echo "Updating squid config"
echo -e "$SQUID_CONFIG" >> /etc/squid/squid.conf

echo "Restarting squid..."
systemctl restart squid
echo "Done"
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
  read -r TOKYO_COUNT TOKYO_NEXT <<< "$(count_and_next_index "proxy-tokyo" "${ZONE_TOKYO}")"
  TOKYO_MISSING=$(( DESIRED_TOKYO - TOKYO_COUNT ))

  if [ "${TOKYO_MISSING}" -gt 0 ]; then
    for i in $(seq 0 $((TOKYO_MISSING - 1))); do
      local IDX=$((TOKYO_NEXT + i))
      local NAME="proxy-tokyo-${IDX}"

      timeout 180 gcloud compute instances create "$NAME" \
        --zone="${ZONE_TOKYO}" \
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
  read -r OSAKA_COUNT OSAKA_NEXT <<< "$(count_and_next_index "proxy-osaka" "${ZONE_OSAKA}")"
  OSAKA_MISSING=$(( DESIRED_OSAKA - OSAKA_COUNT ))

  if [ "${OSAKA_MISSING}" -gt 0 ]; then
    for i in $(seq 0 $((OSAKA_MISSING - 1))); do
      local IDX=$((OSAKA_NEXT + i))
      local NAME="proxy-osaka-${IDX}"

      timeout 180 gcloud compute instances create "$NAME" \
        --zone="${ZONE_OSAKA}" \
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

PROXY_LIST_60501="$(
  for PROJECT_ID in "${ALL_PROJECTS[@]}"; do
    timeout 30 gcloud --project "$PROJECT_ID" compute instances list \
      --filter="name~'^proxy-(tokyo|osaka)-'" \
      --format="value(EXTERNAL_IP)" 2>/dev/null | \
      awk 'NF {print $1":60501"}'
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
  echo "---- PORT 60501 ----"
  echo "$PROXY_LIST_60501"
} > "$PROXY_FILE"




echo ""
echo "========== PROXY PORT 60501 =========="
echo "$PROXY_LIST_60501"
echo ""

echo "🎉 HOÀN TẤT."


echo "🎉 HOÀN TẤT."
