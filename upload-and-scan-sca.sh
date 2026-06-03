#!/usr/bin/env bash
# ============================================================
# CleanSource SCA — Token Auth, S3 Multipart Upload & Scan
#
# AUTH:
#   All API calls send:  token: <SCA_TOKEN>
#   No cookie jar or login step required.
#   Obtain your token from the SCA UI: Profile → API Token.
#
# UPLOAD + SCAN FLOW:
#   1. POST /file/multipart_upload/create  → uploadId + S3 pre-signed URLs
#   2. PUT  <pre-signed S3 URL per chunk>  → direct S3 upload (no SCA headers)
#   3. POST /file/multipart_upload/complete
#   4. POST /task/create
# ============================================================
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# CONFIGURATION — override via environment variables
# ──────────────────────────────────────────────────────────────
SCA_BASE_URL="${SCA_BASE_URL:-"http://10.0.222.103:19778"}"
SCA_TOKEN="${SCA_TOKEN:-""}"          # API token — REQUIRED
DEBUG="${DEBUG:-"0"}"                 # Set DEBUG=1 for verbose curl + raw responses

DEPARTMENT_ID="${DEPARTMENT_ID:-"1001"}"
CUSTOM_PROJECT="${CUSTOM_PROJECT:-"MyProject"}"
CUSTOM_PRODUCT="${CUSTOM_PRODUCT:-"MyProduct"}"
CUSTOM_VERSION="${CUSTOM_VERSION:-"defaultVersion"}"
LICENSE_NAME="${LICENSE_NAME:-""}"
SCAN_TYPE="${SCAN_TYPE:-"sourceCode"}"
SCAN_WAY="${SCAN_WAY:-"1"}"           # 1=full, 2=quick
BUILD_DEPEND="${BUILD_DEPEND:-"0"}"
QUEUE_PRIORITY="${QUEUE_PRIORITY:-"4"}"
STAGE="${STAGE:-"developing"}"
DISTRIBUTION="${DISTRIBUTION:-"outside"}"
NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:-""}"
KNOWLEDGE_BASE_TYPE="${KNOWLEDGE_BASE_TYPE:-"open_source"}"
CHUNK_SIZE_MB="${CHUNK_SIZE_MB:-"5"}" # S3 minimum part size is 5 MB

# ──────────────────────────────────────────────────────────────
# HELPERS
# ──────────────────────────────────────────────────────────────
info()  { echo "[INFO]  $*" >&2; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; }
die()   { error "$*"; exit 1; }
debug() { [[ "${DEBUG:-0}" == "1" ]] && echo "[DEBUG] $*" >&2 || true; }

check_deps() {
  for cmd in curl jq split wc; do
    command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
  done
}

usage() {
  cat <<EOF
Usage: $0 <path-to-zip-file>

Required environment variable:
  SCA_TOKEN        API token (from SCA UI → Profile → API Token) — REQUIRED

Optional environment variables:
  SCA_BASE_URL     Base URL                (default: http://10.0.222.103:19778)
  DEPARTMENT_ID    Department ID           (default: 1001)
  CUSTOM_PROJECT   Project name            (default: MyProject)
  CUSTOM_PRODUCT   Product name            (default: MyProduct)
  CUSTOM_VERSION   Version name            (default: defaultVersion)
  LICENSE_NAME     e.g. GPL-2.0-or-later
  SCAN_TYPE        sourceCode|gitlab|svn|git|docker|nexus2|bitbucket|merging
                   (default: sourceCode)
  SCAN_WAY         1=full scan, 2=quick scan  (default: 1)
  BUILD_DEPEND     1=run dependency detection, 0=skip  (default: 0)
  QUEUE_PRIORITY   1-10, higher = higher priority  (default: 4)
  STAGE            developing|planing|preRelease|released|deprecated|archived
  DISTRIBUTION     inside|outside|saas|open_source  (default: outside)
  NOTIFICATION_EMAIL  Scan-completion notification email
  KNOWLEDGE_BASE_TYPE open_source|private  (default: open_source)
  CHUNK_SIZE_MB    Upload chunk size in MB (min 5 for S3)  (default: 5)
EOF
  exit 1
}

# ──────────────────────────────────────────────────────────────
# Authenticated curl wrapper — injects "token: <SCA_TOKEN>" header
# Used only for SCA API calls; S3 pre-signed PUT requests bypass this.
# ──────────────────────────────────────────────────────────────
# Assert a curl response is valid JSON with success=true.
# On failure, print the first 500 chars of the raw body so the real error is visible.
assert_success() {
  local resp="$1"
  local label="$2"
  # Check it's actually JSON first
  if ! echo "$resp" | jq -e 'type == "object"' &>/dev/null; then
    die "${label} — server returned non-JSON (HTML redirect?). Raw response:\n$(echo "$resp" | head -c 500)"
  fi
  if ! echo "$resp" | jq -e '.success == true' &>/dev/null; then
    die "${label} — $(echo "$resp" | jq -r '.message // .code // "unknown error"')"
  fi
}

api_curl() {
  local curl_args=(-s -L -X POST
    -H "Accept: application/json, text/plain, */*"
    -H "Content-Type: application/json"
    -H "token: ${SCA_TOKEN}"
  )
  if [[ "${DEBUG:-0}" == "1" ]]; then
    # In debug mode: capture HTTP status + body separately; print both
    local tmp_body
    tmp_body=$(mktemp)
    local http_code
    http_code=$(curl "${curl_args[@]}"       -w "%{http_code}"       -o "$tmp_body"       "$@" 2>&1)
    local body
    body=$(cat "$tmp_body"); rm -f "$tmp_body"
    debug "HTTP ${http_code} ← $(echo "$@" | grep -oE 'https?://[^ ]+' | tail -1)"
    debug "REQUEST  headers: token=***${SCA_TOKEN: -6} Content-Type=application/json"
    debug "RESPONSE body   : $(echo "$body" | head -c 800)"
    # Fail on 4xx/5xx like -f would
    if [[ "$http_code" -ge 400 ]]; then
      error "HTTP ${http_code} error from server"
      return 22
    fi
    echo "$body"
  else
    curl -sf "${curl_args[@]}" "$@"
  fi
}

# ──────────────────────────────────────────────────────────────
# STEP 1 — POST /file/multipart_upload/create
# Returns uploadId and a list of S3 pre-signed PUT URLs (one per chunk)
# ──────────────────────────────────────────────────────────────
multipart_create() {
  local object_name="$1"
  local chunk_count="$2"
  local body
  body=$(jq -n \
    --arg  o "$object_name" \
    --arg     c "$chunk_count" \
    '{"object_name": $o, "chunk_size": ($c | tonumber)}')

  info "Creating multipart upload (${chunk_count} part(s)) ..."
  debug "POST ${SCA_BASE_URL}/cleansourcesca/api/v2/file/multipart_upload/create"
  debug "body: $body"
  local resp
  resp=$(api_curl \
    -d "$body" \
    "${SCA_BASE_URL}/cleansourcesca/api/v2/file/multipart_upload/create") \
    || die "multipart_upload/create request failed — check SCA_BASE_URL and SCA_TOKEN"

  assert_success "$resp" "multipart_upload/create"

  echo "$resp"
}

# ──────────────────────────────────────────────────────────────
# STEP 2 — PUT each chunk directly to its S3 pre-signed URL
# S3 pre-signed URLs are self-authenticating — send NO extra headers.
# The Content-Type must be application/octet-stream (or omitted entirely)
# so it matches the signature computed by the server.
# ──────────────────────────────────────────────────────────────
upload_parts() {
  local zip_file="$1"
  local chunk_size_bytes="$2"
  local upload_url_list_json="$3"

  local total_parts
  total_parts=$(echo "$upload_url_list_json" | jq 'length')
  info "Uploading ${total_parts} part(s) to S3 ..."

  local tmp_dir
  tmp_dir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp_dir}'" RETURN

  # Split the zip into fixed-size binary chunks
  split -b "${chunk_size_bytes}" "$zip_file" "${tmp_dir}/part_"

  local part_files=("${tmp_dir}"/part_*)
  local i=0
  for part_file in "${part_files[@]}"; do
    local url
    url=$(echo "$upload_url_list_json" | jq -r ".[$i]")

    info "  Uploading part $((i+1)) / ${total_parts} ..."
    # S3 pre-signed PUT: no Authorization/token headers — the signature is in the URL.
    # -H "Content-Type: application/octet-stream" matches the pre-signed signature.
    curl -sf \
      -X PUT \
      -H "Content-Type: application/octet-stream" \
      --data-binary "@${part_file}" \
      "$url" \
      || die "Part $((i+1)) upload to S3 failed"

    info "  Part $((i+1)) uploaded OK"
    i=$((i + 1))
  done
}

# ──────────────────────────────────────────────────────────────
# STEP 3 — POST /file/multipart_upload/complete
# Tells the SCA server to ask S3 to merge all parts into one object
# ──────────────────────────────────────────────────────────────
multipart_complete() {
  local object_name="$1"
  local upload_id="$2"
  local body
  body=$(jq -n \
    --arg o "$object_name" \
    --arg u "$upload_id" \
    '{"object_name": $o, "upload_id": $u}')

  info "Completing multipart upload (upload_id: ${upload_id}) ..."
  debug "POST ${SCA_BASE_URL}/cleansourcesca/api/v2/file/multipart_upload/complete"
  debug "body: $body"
  local resp
  resp=$(api_curl \
    -d "$body" \
    "${SCA_BASE_URL}/cleansourcesca/api/v2/file/multipart_upload/complete") \
    || die "multipart_upload/complete request failed"

  assert_success "$resp" "multipart_upload/complete"

  info "Multipart upload completed — S3 object assembled"
}

# ──────────────────────────────────────────────────────────────
# STEP 4 — POST /task/create
# ──────────────────────────────────────────────────────────────
create_task() {
  local file_name="$1"
  local object_name="$2"

  local body
  body=$(jq -n \
    --arg  fn  "$file_name" \
    --arg  on  "$object_name" \
    --arg  st  "$SCAN_TYPE" \
    --arg  sw  "$SCAN_WAY" \
    --arg  bd  "$BUILD_DEPEND" \
    --arg  qp  "$QUEUE_PRIORITY" \
    --arg  di  "$DEPARTMENT_ID" \
    --arg  cp  "$CUSTOM_PROJECT" \
    --arg  cpd "$CUSTOM_PRODUCT" \
    --arg  cv  "$CUSTOM_VERSION" \
    --arg  ln  "$LICENSE_NAME" \
    --arg  dv  "$DISTRIBUTION" \
    --arg  sg  "$STAGE" \
    --arg  ne  "$NOTIFICATION_EMAIL" \
    --arg  kb  "$KNOWLEDGE_BASE_TYPE" \
    '{
      "file_name":             $fn,
      "object_name":           $on,
      "scan_type":             $st,
      "scan_way":              ($sw  | tonumber),
      "build_depend":          ($bd  | tonumber),
      "caller_type":           "web",
      "queue_priority":        ($qp  | tonumber),
      "department_id":         ($di  | tonumber),
      "custom_project":        $cp,
      "custom_product":        $cpd,
      "custom_version":        $cv,
      "license_name":          $ln,
      "distribution":          $dv,
      "stage":                 $sg,
      "notification_email":    $ne,
      "knowledge_base_type":   $kb,
      "is_delete_root_folder": 1,
      "is_rescan":             0,
      "scheduler_type":        0,
      "scan_config": {
        "remarks":                    "",
        "is_increment":               0,
        "is_save_source_file":        1,
        "snippet_flag":               1,
        "is_unzip":                   1,
        "detect_reachable":           0,
        "attribution_flag":           0,
        "matched":                    50,
        "matching_auto_confirm":      0,
        "is_open_candidate_pool":     0,
        "license_flag":               1,
        "copyright_flag":             1,
        "vulnerability_flag":         1,
        "cryptography_flag":          1,
        "com_dependency_level":       0,
        "excluding_scan_path_rules":  [],
        "mixed_binary_scan_flag":     1,
        "sensitive_information_flag": 0,
        "mixed_binary_scan_file_paths": [],
        "build_scan_type":            3,
        "package_manager_types":      "",
        "scan_jira_config":           {},
        "inherit_configs":            [],
        "depth":                      0,
        "thread_num":                 30,
        "scan_way":                   1
      }
    }')

  info "Creating scan task ..."
  debug "POST ${SCA_BASE_URL}/cleansourcesca/api/v2/task/create"
  debug "body: $(echo "$body" | head -c 300)..."
  local resp
  resp=$(api_curl \
    -d "$body" \
    "${SCA_BASE_URL}/cleansourcesca/api/v2/task/create") \
    || die "task/create request failed"

  assert_success "$resp" "task/create"

  local task_id task_instance_id
  task_id=$(echo "$resp"          | jq -r '.data.task_id          // .data.taskId          // "unknown"')
  task_instance_id=$(echo "$resp" | jq -r '.data.task_instance_id // .data.taskInstanceId  // "unknown"')
  info "Task created successfully!"
  info "  task_id          = ${task_id}"
  info "  task_instance_id = ${task_instance_id}"
  echo ""
  echo "$resp" | jq '.data'
}

# ──────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────
main() {
  [[ $# -lt 1 ]] && usage
  local zip_file="$1"
  [[ -f "$zip_file" ]]       || die "File not found: $zip_file"
  [[ -z "$SCA_TOKEN" ]]      && die "SCA_TOKEN is not set. Set it via: export SCA_TOKEN=<your-token>"

  check_deps

  local file_name
  file_name=$(basename "$zip_file")
  local upload_uuid
  upload_uuid=$(cat /proc/sys/kernel/random/uuid)
  local object_name="source-code/${upload_uuid}/${file_name}"

  local file_size_bytes
  file_size_bytes=$(wc -c < "$zip_file" | tr -d ' \n')

  # S3 requires each part to be at least 5 MB (except the last).
  # Enforce the floor here so chunk count is always valid.
  local min_chunk_mb=5
  if [[ "$CHUNK_SIZE_MB" -lt "$min_chunk_mb" ]]; then
    warn "CHUNK_SIZE_MB=${CHUNK_SIZE_MB} is below S3 minimum of ${min_chunk_mb} MB — using ${min_chunk_mb} MB"
    CHUNK_SIZE_MB="$min_chunk_mb"
  fi

  local chunk_size_bytes=$(( CHUNK_SIZE_MB * 1024 * 1024 ))
  local chunk_count=$(( (file_size_bytes + chunk_size_bytes - 1) / chunk_size_bytes ))
  chunk_count=$(echo "$chunk_count" | tr -d '[:space:]')
  [[ $chunk_count -lt 1 ]] && chunk_count=1

  info "=================================================="
  info " SCA Upload & Scan"
  info "=================================================="
  info " Server     : ${SCA_BASE_URL}"
  info " File       : ${file_name}"
  info " OSS path   : ${object_name}"
  info " File size  : ${file_size_bytes} bytes"
  info " Chunk size : ${CHUNK_SIZE_MB} MB → ${chunk_count} part(s)"
  info " Auth       : token"
  [[ "${DEBUG:-0}" == "1" ]] && info " DEBUG      : ON — verbose output enabled"
  info "=================================================="
  echo ""

  # Step 1: Create multipart upload → get S3 pre-signed URLs
  local create_resp
  create_resp=$(multipart_create "$object_name" "$chunk_count")
  local upload_id
  upload_id=$(echo "$create_resp" | jq -r '.data.uploadId // .data.upload_id')
  local upload_url_list_json
  upload_url_list_json=$(echo "$create_resp" | jq '.data.uploadUrlList // .data.upload_url_list')
  info "Upload ID   : ${upload_id}"
  echo ""

  # Step 2: PUT each chunk to its S3 pre-signed URL
  upload_parts "$zip_file" "$chunk_size_bytes" "$upload_url_list_json"
  echo ""

  # Step 3: Complete multipart (merge on S3)
  multipart_complete "$object_name" "$upload_id"
  echo ""

  # Step 4: Trigger scan task
  create_task "$file_name" "$object_name"
}

main "$@"

