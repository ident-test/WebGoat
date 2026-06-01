#!/bin/bash
# =============================================
# Bash Script for CleanSource SCA API (Linux)
# Converted from PowerShell Invoke-SCACreateTask
# Bugs fixed:
#   #1 - Missing closing } on all functions
#   #2 - Token header casing (Token -> token)
#   #3 - --argjson on arithmetic -> --arg + tonumber
#   #4 - dd zero-pads last chunk -> split for exact bytes
#   #5 - Leading slash in object_name removed
#   #6 - set -euo pipefail added
#   #7 - All echo logs redirected to stderr
# =============================================

set -euo pipefail

SERVER_URL="https://xxxxxxxxxxxxxxxxxxx:19778"
SOURCETYPE=3
LOGINTYPE=1
FORCED="true"
REMARK="Uploaded via Bash"
PROJECTNAME=""
PRODUCTNAME=""
VERSIONNAME=""
OBJECTNAME=""
FILENAME=""
USERNAME=""
PASSWORD=""
TOKEN=""
FINAL_OBJECT_NAME=""

# All logging to stderr so $() subshell captures stay clean  [FIX #7]
log()  { echo "[*] $*" >&2; }
ok()   { echo "[+] $*" >&2; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# =============================================
# FUNCTION: Check required tools
# =============================================
check_dependencies() {
  local missing=0
  for cmd in curl jq awk stat split; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      warn "Missing required tool: $cmd"
      warn "  Install: sudo dnf install curl jq coreutils   # RHEL/CentOS"
      warn "  Install: sudo apt-get install curl jq coreutils  # Debian/Ubuntu"
      missing=1
    fi
  done
  [ $missing -eq 1 ] && exit 1
  ok "All required tools are available."
}  # FIX #1: was missing closing }

# =============================================
# FUNCTION: Show usage
# =============================================
usage() {
cat << 'EOF'
Invoke-SecTrend-SCA.sh — CleanSource SCA one-click upload & scan

Quick usage:
  # Token auth:
  ./Invoke-SecTrend-SCA.sh --Token <token> --FileName WebGoat-2025.3.zip

  # Credential auth:
  ./Invoke-SecTrend-SCA.sh --Username admin --Password secret --FileName WebGoat-2025.3.zip

  # Full example:
  ./Invoke-SecTrend-SCA.sh \
    --Token "xxxx" \
    --FileName "WebGoat-2025.3.zip" \
    --Remark "CI scan" \
    --ProjectName "WebGoat" \
    --ProductName "WebGoat" \
    --VersionName "2025.3"

Parameters:
  --Token        string  (Token set, required)      API token
  --Username     string  (Credential set, required) Username
  --Password     string  (Credential set, required) Password
  --FileName     string  (required)                 Path to .zip file
  --ObjectName   string  (optional)                 Storage path (auto-generated if omitted)
  --Remark       string  (optional, default: "Uploaded via Bash")
  --ProjectName  string  (optional)
  --ProductName  string  (optional)
  --VersionName  string  (optional)
  --SourceType   int     (optional, default: 3)
  --LoginType    int     (optional, default: 1)
  --Forced       bool    (optional, default: true)
EOF
}  # FIX #1: was missing closing }

# =============================================
# FUNCTION: Login (credential mode)
# =============================================
do_login() {
  local login_url="${SERVER_URL}/cleansourcesca/api/v2/user/open_login"
  local login_type="${LOGINTYPE:-1}"
  local forced="${FORCED:-true}"

  if [ "${forced,,}" = "false" ] || [ "$forced" = "0" ]; then
    forced="false"
  else
    forced="true"
  fi

  # FIX #3: use --arg + tonumber/boolean conversion (not --argjson on shell vars)
  local body
  body=$(jq -n \
    --arg user_name  "$USERNAME" \
    --arg password   "$PASSWORD" \
    --arg login_type "$login_type" \
    --arg forced_str "$forced" \
    '{user_name: $user_name,
      password: $password,
      login_type: ($login_type | tonumber),
      forced: ($forced_str == "true")}')

  log "Logging in as '${USERNAME}' ..."
  local resp
  resp=$(curl -k -s -X POST \
    -H "Content-Type: application/json" \
    -d "$body" \
    -c /tmp/sca_cookies.txt \
    "$login_url")

  local success
  success=$(echo "$resp" | jq -r '.success // "false"')
  if [ "$success" = "true" ]; then
    local user uid
    user=$(echo "$resp" | jq -r '.data.user_name // "unknown"')
    uid=$(echo  "$resp" | jq -r '.data.user_id   // "unknown"')
    ok "Login successful — ${user} (uid=${uid})"
    return 0
  else
    local msg
    msg=$(echo "$resp" | jq -r '.message // "Unknown error"')
    warn "Login failed: $msg"
    rm -f /tmp/sca_cookies.txt 2>/dev/null || true
    return 1
  fi
}  # FIX #1: was missing closing }

# =============================================
# FUNCTION: Generate ObjectName if not provided
# =============================================
generate_object_name() {
  if [ -z "$OBJECTNAME" ]; then
    local uuid fname
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null \
        || uuidgen 2>/dev/null \
        || date +%s%N | md5sum | cut -c1-32)
    fname=$(basename "$FILENAME")
    # FIX #5: removed leading slash — was "/source-code/..." which breaks S3 path matching
    OBJECTNAME="source-code/${uuid}/${fname}"
  fi
  FINAL_OBJECT_NAME="$OBJECTNAME"
}  # FIX #1: was missing closing }

# =============================================
# FUNCTION: Upload file via S3-style multipart
# =============================================
upload_file() {
  local filepath="$FILENAME"
  local objname="$FINAL_OBJECT_NAME"

  [ -f "$filepath" ] || { warn "File not found: $filepath"; return 1; }

  local filesize
  filesize=$(stat -c %s "$filepath" 2>/dev/null)
  { [ -z "$filesize" ] || [ "$filesize" -eq 0 ]; } \
    && { warn "Unable to determine file size or file is empty."; return 1; }

  local filesizemb
  filesizemb=$(awk "BEGIN {printf \"%.2f\", $filesize / 1048576}")

  local chunksize=10485760  # 10 MB
  local chunkcount=$(( (filesize + chunksize - 1) / chunksize ))
  [ "$chunkcount" -lt 1 ] && chunkcount=1

  log "File      : $filepath (${filesizemb} MB, ${chunkcount} chunk(s))"
  log "ObjectName: $objname"

  # ── Step 1: Create multipart upload session ─────────────────────────────────
  local create_url="${SERVER_URL}/cleansourcesca/api/v2/file/multipart_upload/create"

  # FIX #3: --argjson on a shell arithmetic result causes jq parse errors;
  #         use --arg + tonumber to safely convert
  local create_body
  create_body=$(jq -n \
    --arg cs "$chunkcount" \
    --arg on "$objname" \
    '{chunk_size: ($cs | tonumber), object_name: $on}')

  log "Creating upload session ..."
  local create_resp
  if [ -n "$TOKEN" ]; then
    # FIX #2: lowercase "token" header (original had "Token")
    create_resp=$(curl -k -s -X POST \
      -H "Content-Type: application/json" \
      -H "token: ${TOKEN}" \
      -H "sourceType: ${SOURCETYPE}" \
      -d "$create_body" \
      "$create_url")
  else
    create_resp=$(curl -k -s -X POST \
      -H "Content-Type: application/json" \
      -b /tmp/sca_cookies.txt \
      -d "$create_body" \
      "$create_url")
  fi

  local success
  success=$(echo "$create_resp" | jq -r '.success // "false"')
  if [ "$success" != "true" ]; then
    warn "Create upload failed: $(echo "$create_resp" | jq -r '.message // "Unknown error"')"
    return 1
  fi

  local upload_id
  upload_id=$(echo "$create_resp" | jq -r '.data.uploadId // empty')
  [ -z "$upload_id" ] && { warn "Failed to get uploadId from response."; return 1; }
  ok "Session created — uploadId: $upload_id"

  mapfile -t upload_url_list < <(echo "$create_resp" | jq -r '.data.uploadUrlList[]')

  # ── Step 2: Split and upload each chunk ─────────────────────────────────────
  # FIX #4: original used `dd count=1 bs=chunksize` which always reads a full
  #         10 MB block — the last chunk gets zero-padded, corrupting the file.
  #         `split -b` cuts at exact byte boundaries with no padding.
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' RETURN

  split -b "$chunksize" "$filepath" "${tmp_dir}/part_"

  local part_files=("${tmp_dir}"/part_*)
  local total_parts=${#part_files[@]}

  if [ "$total_parts" -ne "$chunkcount" ]; then
    warn "Part count mismatch: expected $chunkcount, got $total_parts"
    return 1
  fi

  local i=0
  for part_file in "${part_files[@]}"; do
    local url="${upload_url_list[$i]:-}"
    [ -z "$url" ] && { warn "Missing S3 URL for part $((i+1))"; return 1; }

    # S3 pre-signed PUT — no auth headers, URL is self-authenticating
    if ! curl -k -s -X PUT \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${part_file}" \
        "$url" > /dev/null; then
      warn "Failed to upload part $((i+1))"
      return 1
    fi

    ok "Part $((i+1))/${total_parts} uploaded"
    i=$((i + 1))
  done

  # ── Step 3: Complete multipart upload ───────────────────────────────────────
  local complete_url="${SERVER_URL}/cleansourcesca/api/v2/file/multipart_upload/complete"
  local complete_body
  complete_body=$(jq -n \
    --arg on "$objname" \
    --arg ui "$upload_id" \
    '{object_name: $on, upload_id: $ui}')

  local complete_resp
  if [ -n "$TOKEN" ]; then
    complete_resp=$(curl -k -s -X POST \
      -H "Content-Type: application/json" \
      -H "token: ${TOKEN}" \
      -H "sourceType: ${SOURCETYPE}" \
      -d "$complete_body" \
      "$complete_url")
  else
    complete_resp=$(curl -k -s -X POST \
      -H "Content-Type: application/json" \
      -b /tmp/sca_cookies.txt \
      -d "$complete_body" \
      "$complete_url")
  fi

  success=$(echo "$complete_resp" | jq -r '.success // "false"')
  if [ "$success" = "true" ]; then
    ok "Upload completed successfully."
    FINAL_OBJECT_NAME="$objname"
    return 0
  else
    warn "Merge failed: $(echo "$complete_resp" | jq -r '.message // "Unknown error"')"
    return 1
  fi
}

# =============================================
# FUNCTION: Create Scan Task
# =============================================
create_scan_task() {
  local display_fname
  display_fname=$(basename "$FILENAME")
  local objname="$FINAL_OBJECT_NAME"
  local remark="${REMARK:-Uploaded via Bash}"
  local project="${PROJECTNAME:-}"
  local product="${PRODUCTNAME:-}"
  local version="${VERSIONNAME:-}"
  local task_url="${SERVER_URL}/cleansourcesca/api/v2/task/create"

  # FIX #3: integer literals inlined directly in jq filter (not via --argjson shell vars)
  local body
  body=$(jq -n \
    --arg remark               "$remark" \
    --arg scan_type            "sourceCode" \
    --arg file_name            "$display_fname" \
    --arg object_name          "$objname" \
    --arg caller_type          "web" \
    --arg knowledge_base_type  "open_source" \
    --arg custom_project       "$project" \
    --arg custom_product       "$product" \
    --arg custom_version       "$version" \
    --arg distribution         "inside" \
    --arg stage                "developing" \
    --arg package_manager_types "" \
    '{
      scan_config: {
        remarks:                    $remark,
        is_increment:               0,
        is_save_source_file:        1,
        snippet_flag:               1,
        is_unzip:                   1,
        detect_reachable:           0,
        attribution_flag:           1,
        matched:                    50,
        matching_auto_confirm:      0,
        is_open_candidate_pool:     0,
        license_flag:               1,
        copyright_flag:             1,
        vulnerability_flag:         1,
        cryptography_flag:          1,
        com_dependency_level:       0,
        excluding_scan_path_rules:  [],
        mixed_binary_scan_flag:     0,
        sensitive_information_flag: 0,
        build_scan_type:            3,
        build_depend:               0,
        package_manager_types:      $package_manager_types,
        scan_jira_config:           {},
        inherit_configs:            []
      },
      scan_type:             $scan_type,
      file_name:             $file_name,
      object_name:           $object_name,
      scheduler_type:        0,
      caller_type:           $caller_type,
      knowledge_base_type:   $knowledge_base_type,
      scan_way:              1,
      queue_priority:        4,
      build_depend:          0,
      is_delete_root_folder: 0,
      custom_project:        $custom_project,
      custom_product:        $custom_product,
      custom_version:        $custom_version,
      distribution:          $distribution,
      stage:                 $stage
    }')

  log "Creating scan task for: $display_fname"

  local task_resp
  if [ -n "$TOKEN" ]; then
    task_resp=$(curl -k -s -X POST \
      -H "Content-Type: application/json" \
      -H "token: ${TOKEN}" \
      -H "sourceType: ${SOURCETYPE}" \
      -d "$body" \
      "$task_url")
  else
    task_resp=$(curl -k -s -X POST \
      -H "Content-Type: application/json" \
      -b /tmp/sca_cookies.txt \
      -d "$body" \
      "$task_url")
  fi

  local success
  success=$(echo "$task_resp" | jq -r '.success // "false"')
  if [ "$success" = "true" ]; then
    local task_id task_instance_id
    task_id=$(echo          "$task_resp" | jq -r '.data.task_id          // .data.taskId          // "unknown"')
    task_instance_id=$(echo "$task_resp" | jq -r '.data.task_instance_id // .data.taskInstanceId  // "unknown"')
    ok "Task created — task_id=${task_id}  instance_id=${task_instance_id}"
    return 0
  else
    warn "Task creation failed: $(echo "$task_resp" | jq -r '.message // "Unknown error"')"
    return 1
  fi
}

# =============================================
# FUNCTION: Main entry point
# =============================================
invoke_sca_create_task() {
  echo "========================================" >&2
  echo " Invoke-SecTrend-SCA.sh" >&2
  echo "========================================" >&2

  echo -e "\n[1/3] Authenticating..." >&2
  if [ -n "$TOKEN" ]; then
    ok "Using token authentication"
  else
    do_login || die "Login failed. Aborting."
  fi

  echo -e "\n[2/3] Uploading file..." >&2
  upload_file || die "File upload failed. Aborting."

  echo -e "\n[3/3] Creating scan task..." >&2
  if create_scan_task; then
    echo "" >&2
    echo "========================================" >&2
    echo " [+] Complete" >&2
    echo "========================================" >&2
    echo "  File       : $(basename "$FILENAME")"  >&2
    echo "  ObjectName : $FINAL_OBJECT_NAME"       >&2
    echo "  Remark     : $REMARK"                  >&2
    [ -n "$PROJECTNAME" ] && echo "  Project    : $PROJECTNAME" >&2 || true
    [ -n "$PRODUCTNAME" ] && echo "  Product    : $PRODUCTNAME" >&2 || true
    [ -n "$VERSIONNAME" ] && echo "  Version    : $VERSIONNAME" >&2 || true
  else
    die "Task creation failed."
  fi

  rm -f /tmp/sca_cookies.txt 2>/dev/null || true
}

# =============================================
# Argument Parsing
# =============================================
if [ $# -eq 0 ]; then
  usage
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case $1 in
    --Username|-Username|--username|-u)        USERNAME="$2";    shift 2 ;;
    --Password|-Password|--password|-p)        PASSWORD="$2";    shift 2 ;;
    --Token|-Token|--token|-t)                 TOKEN="$2";       shift 2 ;;
    --FileName|-FileName|--filename|-f)        FILENAME="$2";    shift 2 ;;
    --ObjectName|-ObjectName|--objectname)     OBJECTNAME="$2";  shift 2 ;;
    --Remark|-Remark|--remark)                 REMARK="$2";      shift 2 ;;
    --ProjectName|-ProjectName|--projectname)  PROJECTNAME="$2"; shift 2 ;;
    --ProductName|-ProductName|--productname)  PRODUCTNAME="$2"; shift 2 ;;
    --VersionName|-VersionName|--versionname)  VERSIONNAME="$2"; shift 2 ;;
    --SourceType|-SourceType|--sourcetype)     SOURCETYPE="$2";  shift 2 ;;
    --LoginType|-LoginType|--logintype)        LOGINTYPE="$2";   shift 2 ;;
    --Forced|-Forced|--forced)                 FORCED="$2";      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) warn "Unknown parameter: $1"; usage; exit 1 ;;
  esac
done

# =============================================
# Validation
# =============================================
[ -z "$FILENAME" ] && { warn "--FileName is mandatory."; usage; exit 1; }

if [ -n "$TOKEN" ] && { [ -n "$USERNAME" ] || [ -n "$PASSWORD" ]; }; then
  die "Cannot use both --Token and credential parameters at the same time."
fi

if [ -z "$TOKEN" ] && { [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; }; then
  die "Either --Token or both --Username and --Password are required."
fi

# =============================================
# Main Execution
# =============================================
check_dependencies
generate_object_name
invoke_sca_create_task

exit 0
