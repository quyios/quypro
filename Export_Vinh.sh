#!/usr/bin/env bash
# Lấy list project
mapfile -t ALL_PROJECTS < <(gcloud projects list --format="value(projectId)")

# In hết PORT 60501
for PROJECT_ID in "${ALL_PROJECTS[@]}"; do
  gcloud --project "$PROJECT_ID" compute instances list \
    --filter="name~'^proxy-(tokyo|osaka)-'" \
    --format="value(EXTERNAL_IP)" \
  | awk 'NF {print $1":60501"}'
done

