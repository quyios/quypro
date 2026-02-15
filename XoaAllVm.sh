#!/bin/bash
set -euo pipefail

echo "🔍 Đang lấy danh sách tất cả project..."

PROJECTS=$(gcloud projects list --format="value(projectId)")

if [ -z "$PROJECTS" ]; then
  echo "❌ Không tìm thấy project nào."
  exit 0
fi

for PROJECT in $PROJECTS; do
  echo ""
  echo "=============================="
  echo "📦 Project: $PROJECT"
  echo "=============================="

  # Lấy danh sách VM trong project
  INSTANCES=$(gcloud compute instances list --project="$PROJECT" --format="value(name,zone)" 2>/dev/null || true)

  if [ -z "$INSTANCES" ]; then
    echo "✅ Không có VM nào trong project này."
    continue
  fi

  # Xóa từng VM với cờ --async để không phải chờ
  while read -r NAME ZONE; do
    if [ -n "$NAME" ] && [ -n "$ZONE" ]; then
      echo "🗑️ Gửi lệnh xóa VM: $NAME | Zone: $ZONE"
      gcloud compute instances delete "$NAME" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --quiet \
        --async || true
    fi
  done <<< "$INSTANCES"

done

echo ""
echo "🔥 HOÀN TẤT: Đã gửi lệnh xóa toàn bộ VM (chạy ngầm)."
