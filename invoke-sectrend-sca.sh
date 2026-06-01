#!/bin/bash
# =============================================
# Bash Script for CleanSource SCA API (Linux)
# Converted from PowerShell Invoke-SCACreateTask
# =============================================

set -o pipefail

SERVER_URL="http://10.0.222.103:19778"
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

# =============================================
# FUNCTION: Check required tools
# =============================================
check_dependencies() {
    local missing=0
    for cmd in curl jq awk stat dd; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "[!] Missing required tool: $cmd"
            echo "    Please install it (e.g. sudo apt-get install curl jq awk coreutils)"
            missing=1
        fi
    done
    if [ $missing -eq 1 ]; then
        exit 1
    fi
    echo "[*] All required tools are available."
}

# =============================================
# FUNCTION: Show usage
# =============================================
usage() {
    cat << 'EOF'
# Invoke-SecTrend-SCA.sh Usage for SCA (Linux Bash)

Quick usage:
```
# Using username and password:
./Invoke-SecTrend-SCA.sh --Username "username" --Password "password" --FileName "WebGoat-2025.3.zip"

# Using Token:
./Invoke-SecTrend-SCA.sh --Token xxxxxxxxxxxxxxxxxxxx --FileName "WebGoat-2025.3.zip"

# Full usage:
./Invoke-SecTrend-SCA.sh \
    --Token "xxxxxxxxxxxxxxxxxxxxxxxxxxxx" \
    --FileName "WebGoat-2025.3.zip" \
    --Remark "My custom scan remark" \
    --ProjectName "TestProject" \
    --ProductName "WebGoat" \
    --VersionName "2025.3"
```

## Parameters
| Parameter     | Type   | Mandatory | Parameter Set | Default Value          | Description |
|---------------|--------|-----------|---------------|------------------------|-------------|
| --Username    | string | Yes       | Credential    | -                      | Username for credential-based login. |
| --Password    | string | Yes       | Credential    | -                      | Password for credential-based login. |
| --LoginType   | int    | No        | Credential    | 1                      | Login type used during credential authentication. |
| --Forced      | bool   | No        | Credential    | true                   | Force login flag (true = allow re-login if already logged in). |
| --Token       | string | Yes       | Token         | -                      | API token for token-based authentication. |
| --FileName    | string | Yes       | Both          | -                      | Full local path to the file to upload and scan (e.g. `/path/to/WebGoat-2025.3.zip`). |
| --ObjectName  | string | No        | Both          | "" (auto-generated)    | Custom object name in storage. Leave empty to let the script generate one automatically using a UUID. |
| --Remark      | string | No        | Both          | "Uploaded via Bash"    | Custom remark / description for the scan task. |
| --ProjectName | string | No        | Both          | ""                     | Custom project name. |
| --ProductName | string | No        | Both          | ""                     | Custom product name. |
| --VersionName | string | No        | Both          | ""                     | Custom version name. |
| --SourceType  | int    | No        | Both          | 3                      | Source type for API headers (token mode). |

Notes:
- Either --Token OR both --Username and --Password are required (mutually exclusive).
- --FileName is always mandatory.
- The script uses curl and supports chunked multipart upload for large files (10MB chunks).
- SSL certificate validation is disabled (-k / --insecure) to match original behavior.
- Run with --help or no arguments to show this usage.

Examples:
  ./Invoke-SecTrend-SCA.sh --Username "testuser" --Password "secret" --FileName "/tmp/WebGoat-2025.3.zip"
  ./Invoke-SecTrend-SCA.sh --Token "your-api-token-here" --FileName "/tmp/WebGoat-2025.3.zip" --Remark "Automated scan"
EOF
}

# =============================================
# FUNCTION: Login (credential mode)
# =============================================
do_login() {
    local login_url="${SERVER_URL}/cleansourcesca/api/v2/user/open_login"
    local login_type=${LOGINTYPE:-1}
    local forced=${FORCED:-true}

    # Normalize bool
    if [ "${forced,,}" = "false" ] || [ "$forced" = "0" ]; then
        forced="false"
    else
        forced="true"
    fi

    local body
    body=$(jq -n \
        --arg user_name "$USERNAME" \
        --arg password "$PASSWORD" \
        --argjson login_type "$login_type" \
        --argjson forced "$forced" \
        '{user_name: $user_name, password: $password, login_type: $login_type, forced: $forced}')

    echo "[*] Sending login request to $login_url"
    local resp
    resp=$(curl -k -s -X POST \
        -H "Content-Type: application/json" \
        -d "$body" \
        -c /tmp/sca_cookies.txt \
        "$login_url")

    local success
    success=$(echo "$resp" | jq -r '.success // "false"')

    if [ "$success" = "true" ]; then
        echo "[+] Login Successful!"
        local user
        user=$(echo "$resp" | jq -r '.data.user_name // "unknown"')
        local uid
        uid=$(echo "$resp" | jq -r '.data.user_id // "unknown"')
        echo " Username: $user (UserID: $uid)"
        return 0
    else
        echo "[!] Login Failed"
        local msg
        msg=$(echo "$resp" | jq -r '.message // "Unknown error"')
        echo "Error: $msg"
        rm -f /tmp/sca_cookies.txt 2>/dev/null
        return 1
    fi
}

# =============================================
# FUNCTION: Generate ObjectName if not provided
# =============================================
generate_object_name() {
    if [ -z "$OBJECTNAME" ]; then
        local uuid
        uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "$(date +%s%N | md5sum | cut -c1-32)")
        local fname
        fname=$(basename "$FILENAME")
        OBJECTNAME="/source-code/${uuid}/${fname}"
    fi
    FINAL_OBJECT_NAME="$OBJECTNAME"
}

# =============================================
# FUNCTION: Upload Project Files (multipart)
# =============================================
upload_file() {
    local filepath="$FILENAME"
    local objname="$FINAL_OBJECT_NAME"

    if [ ! -f "$filepath" ]; then
        echo "[!] File not found: $filepath"
        return 1
    fi

    local filesize
    filesize=$(stat -c %s "$filepath" 2>/dev/null)
    if [ -z "$filesize" ] || [ "$filesize" -eq 0 ]; then
        echo "[!] Unable to determine file size or file is empty."
        return 1
    fi

    local filesizemb
    filesizemb=$(awk "BEGIN {printf \"%.2f\", $filesize / 1048576}")

    local chunksize=10485760  # 10MB
    local chunkcount=$(( (filesize + chunksize - 1) / chunksize ))
    if [ $chunkcount -lt 1 ]; then
        chunkcount=1
    fi

    echo "[*] Uploading: $filepath ($filesizemb MB)"
    echo "[*] ObjectName: $objname"
    echo "[*] Total Chunks: $chunkcount"

    # Step 1: Create multipart upload
    local create_url="${SERVER_URL}/cleansourcesca/api/v2/file/multipart_upload/create"
    local create_body
    create_body=$(jq -n \
        --argjson cs "$chunkcount" \
        --arg on "$objname" \
        '{chunk_size: $cs, object_name: $on}')

    echo "[*] Creating upload session..."
    local create_resp
    if [ -n "$TOKEN" ]; then
        create_resp=$(curl -k -s -X POST \
            -H "Content-Type: application/json" \
            -H "sourceType: $SOURCETYPE" \
            -H "Token: $TOKEN" \
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
        echo "[!] Create upload failed: $(echo "$create_resp" | jq -r '.message // "Unknown error"')"
        return 1
    fi

    local upload_id
    upload_id=$(echo "$create_resp" | jq -r '.data.uploadId // empty')
    if [ -z "$upload_id" ]; then
        echo "[!] Failed to get uploadId from response."
        return 1
    fi

    echo "[+] Upload session created. UploadId: $upload_id"

    # Parse upload URL list into array
    mapfile -t upload_url_list < <(echo "$create_resp" | jq -r '.data.uploadUrlList[]')

    # Step 2: Upload chunks
    local i=0
    local part=1
    while [ $i -lt $chunkcount ]; do
        local start=$(( i * chunksize ))
        local remaining=$(( filesize - start ))
        local length=$chunksize
        if [ $remaining -lt $length ]; then
            length=$remaining
        fi
        if [ $length -le 0 ]; then
            break
        fi

        local url="${upload_url_list[$i]}"
        if [ -z "$url" ]; then
            echo "[!] Missing upload URL for part $part"
            return 1
        fi

        # Upload chunk using dd + curl (no temp file)
        if ! dd if="$filepath" bs=$chunksize skip=$i count=1 status=none 2>/dev/null | \
             curl -k -s -X PUT \
                  -H "Content-Type: application/octet-stream" \
                  --data-binary @- \
                  "$url" > /dev/null; then
            echo "[!] Failed to upload part $part"
            return 1
        fi

        echo "[+] Part $part uploaded"
        i=$((i + 1))
        part=$((part + 1))
    done

    # Step 3: Complete upload
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
            -H "sourceType: $SOURCETYPE" \
            -H "Token: $TOKEN" \
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
        echo "[+] Upload completed successfully!"
        echo " ObjectName: $objname"
        FINAL_OBJECT_NAME="$objname"
        return 0
    else
        echo "[!] Merge failed: $(echo "$complete_resp" | jq -r '.message // "Unknown error"')"
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

    # Build complex JSON body using jq
    local body
    body=$(jq -n \
        --arg remark "$remark" \
        --argjson is_increment 0 \
        --argjson is_save_source_file 1 \
        --argjson snippet_flag 1 \
        --argjson is_unzip 1 \
        --argjson detect_reachable 0 \
        --argjson attribution_flag 1 \
        --argjson matched 50 \
        --argjson matching_auto_confirm 0 \
        --argjson is_open_candidate_pool 0 \
        --argjson license_flag 1 \
        --argjson copyright_flag 1 \
        --argjson vulnerability_flag 1 \
        --argjson cryptography_flag 1 \
        --argjson com_dependency_level 0 \
        --argjson mixed_binary_scan_flag 0 \
        --argjson sensitive_information_flag 0 \
        --argjson build_scan_type 3 \
        --argjson build_depend 0 \
        --arg package_manager_types "" \
        --arg scan_type "sourceCode" \
        --arg file_name "$display_fname" \
        --arg object_name "$objname" \
        --argjson scheduler_type 0 \
        --arg caller_type "web" \
        --arg knowledge_base_type "open_source" \
        --argjson scan_way 1 \
        --argjson queue_priority 4 \
        --arg custom_project "$project" \
        --arg custom_product "$product" \
        --arg custom_version "$version" \
        --arg distribution "inside" \
        --arg stage "developing" \
        '{
            scan_config: {
                remarks: $remark,
                is_increment: $is_increment,
                is_save_source_file: $is_save_source_file,
                snippet_flag: $snippet_flag,
                is_unzip: $is_unzip,
                detect_reachable: $detect_reachable,
                attribution_flag: $attribution_flag,
                matched: $matched,
                matching_auto_confirm: $matching_auto_confirm,
                is_open_candidate_pool: $is_open_candidate_pool,
                license_flag: $license_flag,
                copyright_flag: $copyright_flag,
                vulnerability_flag: $vulnerability_flag,
                cryptography_flag: $cryptography_flag,
                com_dependency_level: $com_dependency_level,
                excluding_scan_path_rules: [],
                mixed_binary_scan_flag: $mixed_binary_scan_flag,
                sensitive_information_flag: $sensitive_information_flag,
                build_scan_type: $build_scan_type,
                build_depend: $build_depend,
                package_manager_types: $package_manager_types,
                scan_jira_config: {},
                inherit_configs: []
            },
            scan_type: $scan_type,
            file_name: $file_name,
            object_name: $object_name,
            scheduler_type: $scheduler_type,
            caller_type: $caller_type,
            knowledge_base_type: $knowledge_base_type,
            scan_way: $scan_way,
            queue_priority: $queue_priority,
            custom_project: $custom_project,
            custom_product: $custom_product,
            custom_version: $custom_version,
            distribution: $distribution,
            stage: $stage
        }')

    echo "[*] Creating task for: $display_fname"
    echo " ObjectName: $objname"

    local task_resp
    if [ -n "$TOKEN" ]; then
        task_resp=$(curl -k -s -X POST \
            -H "Content-Type: application/json" \
            -H "sourceType: $SOURCETYPE" \
            -H "Token: $TOKEN" \
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
        echo "[+] Task created successfully!"
        # Optional: show limited task info
        local task_data
        task_data=$(echo "$task_resp" | jq -r '.data // empty' 2>/dev/null | head -c 300)
        if [ -n "$task_data" ]; then
            echo " Task Details (partial): $task_data..."
        fi
        return 0
    else
        echo "[!] Failed: $(echo "$task_resp" | jq -r '.message // "Unknown error"')"
        return 1
    fi
}

# =============================================
# FUNCTION: Main entry - Invoke SCA Create Task
# =============================================
invoke_sca_create_task() {
    echo "========================================"
    echo " Invoke-SecTrend-SCA.sh - One-Click SCA Task Creation"
    echo "========================================"

    # Step 1: Authentication
    echo -e "\n[1/3] Authenticating..."
    if [ -n "$TOKEN" ]; then
        echo "[+] Using Token authentication"
    else
        if ! do_login; then
            echo "[!] Login failed. Aborting."
            exit 1
        fi
    fi

    # Step 2: Upload file
    echo -e "\n[2/3] Uploading file..."
    if ! upload_file; then
        echo "[!] File upload failed. Aborting."
        exit 1
    fi

    # Step 3: Create scan task
    echo -e "\n[3/3] Creating scan task..."
    if create_scan_task; then
        echo -e "\n========================================"
        echo " [+] Task Summary: "
        echo "========================================"
        echo " Display File Name : $(basename "$FILENAME")"
        echo " ObjectName        : $FINAL_OBJECT_NAME"
        echo " Remark            : $REMARK"
        if [ -n "$PROJECTNAME" ]; then echo " ProjectName       : $PROJECTNAME"; fi
        if [ -n "$PRODUCTNAME" ]; then echo " ProductName       : $PRODUCTNAME"; fi
        if [ -n "$VERSIONNAME" ]; then echo " VersionName       : $VERSIONNAME"; fi
    else
        echo -e "\n[!] Task creation failed."
    fi

    # Cleanup
    rm -f /tmp/sca_cookies.txt 2>/dev/null
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
        --Username|-Username|--username|-u)
            USERNAME="$2"
            shift 2
            ;;
        --Password|-Password|--password|-p)
            PASSWORD="$2"
            shift 2
            ;;
        --Token|-Token|--token|-t)
            TOKEN="$2"
            shift 2
            ;;
        --FileName|-FileName|--filename|-f)
            FILENAME="$2"
            shift 2
            ;;
        --ObjectName|-ObjectName|--objectname)
            OBJECTNAME="$2"
            shift 2
            ;;
        --Remark|-Remark|--remark)
            REMARK="$2"
            shift 2
            ;;
        --ProjectName|-ProjectName|--projectname)
            PROJECTNAME="$2"
            shift 2
            ;;
        --ProductName|-ProductName|--productname)
            PRODUCTNAME="$2"
            shift 2
            ;;
        --VersionName|-VersionName|--versionname)
            VERSIONNAME="$2"
            shift 2
            ;;
        --SourceType|-SourceType|--sourcetype)
            SOURCETYPE="$2"
            shift 2
            ;;
        --LoginType|-LoginType|--logintype)
            LOGINTYPE="$2"
            shift 2
            ;;
        --Forced|-Forced|--forced)
            FORCED="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "[!] Unknown parameter: $1"
            usage
            exit 1
            ;;
    esac
done

# =============================================
# Validation
# =============================================
if [ -z "$FILENAME" ]; then
    echo "[!] --FileName is mandatory."
    usage
    exit 1
fi

if [ -n "$TOKEN" ] && { [ -n "$USERNAME" ] || [ -n "$PASSWORD" ]; }; then
    echo "[!] Cannot use both --Token and credential parameters at the same time."
    exit 1
fi

if [ -z "$TOKEN" ] && { [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; }; then
    echo "[!] Either --Token or both --Username and --Password are required."
    usage
    exit 1
fi

# =============================================
# Main Execution
# =============================================
check_dependencies
generate_object_name
invoke_sca_create_task

exit 0


