#!/bin/bash
# =============================================
# Bash Script for SecTrend SAST API
# Converted from PowerShell Invoke-SASTCreateTask.ps1
# Supports one-click SAST task creation and scheme listing
# =============================================

SERVER_URL="https://xxxxxxxxxxxxxxxxxxx:31888"

# =============================================
# FUNCTION: check_dependencies
# =============================================
check_dependencies() {
    local missing=0
    for cmd in curl jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "[!] Error: Required tool '$cmd' is not installed. Please install it (e.g., apt install curl jq or yum install curl jq)."
            missing=1
        fi
    done
    if [ $missing -eq 1 ]; then
        exit 1
    fi
    echo "[*] All required tools (curl, jq) are installed."
}

# =============================================
# FUNCTION: show_usage
# =============================================
show_usage() {
    cat << 'EOF'
# Invoke-SecTrend-SAST.sh Usage for SAST
Quick usage:
# Using username and password:
./Invoke-SecTrend-SAST.sh \
    --Username username \
    --Password "password" \
    --LanguageIdList 3 \
    --SchemeIdList 32 \
    --FileName ./flask-sqlinjection-vulnerable-main.zip \
    --ProjectName "MyProject"

# Using Token:
./Invoke-SecTrend-SAST.sh \
    --Token xxxx-xxxx-xxxx-xxxx \
    --FileName ./flask-sqlinjection-vulnerable-main.zip \
    --LanguageIdList 3 \
    --SchemeIdList 32 \
    --ProjectName "MyProject2"

## List detection schemes (to find SchemeIdList):
./Invoke-SecTrend-SAST.sh --list-schemes --Token xxxx-xxxx-xxxx-xxxx
# or with username/password:
./Invoke-SecTrend-SAST.sh --list-schemes --Username username --Password "password"

## Parameters
| Parameter        | Mandatory | Default Value                  | Description |
|------------------|-----------|--------------------------------|-------------|
| --Username       | No        | -                              | Username for login (required only if --Token is not provided) |
| --Password       | No        | -                              | Password for login (required only if --Token is not provided) |
| --Token          | No        | -                              | Pre-obtained Bearer token (recommended authentication method) |
| --FileName       | Yes       | -                              | Full local path to the source code zip file to be uploaded |
| --ProjectName    | Yes       | -                              | Name of the project (will be created automatically if it does not exist) |
| --TaskName       | No        | Auto-generated (SAST-YYYYMMDD-HHmmss) | Custom name for the scanning task |
| --ProjectId      | No        | 0                              | Existing Project ID (use this to skip project creation) |
| --LanguageIdList | No        | 3                              | Comma or space separated language IDs (1=C,2=Java,3=Python,4=Cpp,5=C/C++,6=Go) e.g. "3,5" or "3 5" |
| --SchemeIdList   | No        | 32                             | Comma or space separated detection scheme IDs (use --list-schemes to see full list) |
| --list-schemes   | -         | -                              | List all available detection schemes (requires --Token or --Username/--Password) |
| -h, --help       | -         | -                              | Show this help message |

Server URL: http://10.40.239.12:31888 (hardcoded - edit script if needed)
Requires: curl and jq (checked automatically)
EOF
}

# =============================================
# FUNCTION: sast_login (returns token via stdout)
# =============================================
sast_login() {
    local username="$1"
    local password="$2"
    local uri="$SERVER_URL/api/guest/login"
    local body
    body=$(jq -n \
        --arg username "$username" \
        --arg password "$password" \
        --arg type "local" \
        '{username: $username, password: $password, type: $type}')
    echo "[*] Sending login request to $uri" >&2
    local response
    response=$(curl -s -k -X POST "$uri" \
        -H "Content-Type: application/json" \
        -d "$body")
    local success
    success=$(echo "$response" | jq -r '.success // false')
    if [ "$success" = "true" ]; then
        local token
        token=$(echo "$response" | jq -r '.data')
        echo "[+] Login Successful! Token received." >&2
        echo "$token"
        return 0
    else
        local msg
        msg=$(echo "$response" | jq -r '.message // "Unknown error"')
        echo "[!] Login Failed: $msg" >&2
        return 1
    fi
}

# =============================================
# FUNCTION: get_project_id_by_name (returns id via stdout)
# =============================================
get_project_id_by_name() {
    local project_name="$1"
    local token="$2"
    local uri="$SERVER_URL/api/project/list"
    local body
    body=$(jq -n \
        --arg projectName "$project_name" \
        --argjson page 0 \
        --argjson size 50 \
        --argjson sort '[]' \
        '{projectName: $projectName, page: $page, size: $size, sort: $sort}')
    local response
    response=$(curl -s -k -X POST "$uri" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -d "$body")
    local success
    success=$(echo "$response" | jq -r '.success // false')
    if [ "$success" = "true" ]; then
        local id
        id=$(echo "$response" | jq -r --arg name "$project_name" '.data.content[] | select(.projectName == $name) | .id' | head -1)
        if [ -n "$id" ]; then
            echo "[+] Found exact project: $project_name (ID: $id)" >&2
            echo "$id"
            return 0
        else
            echo "[!] No exact match for '$project_name' (API returned partial matches only)" >&2
            return 1
        fi
    else
        local msg
        msg=$(echo "$response" | jq -r '.message // "Failed to get project list"')
        echo "[!] $msg" >&2
        return 1
    fi
}

# =============================================
# FUNCTION: create_sast_project (returns projectId via stdout)
# =============================================
create_sast_project() {
    local project_name="$1"
    local token="$2"
    local uri="$SERVER_URL/api/project/create"
    local body
    body=$(jq -n \
        --arg projectName "$project_name" \
        '{projectName: $projectName}')
    echo "[*] Creating project: $project_name" >&2
    local response
    response=$(curl -s -k -X POST "$uri" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -d "$body")
    local success
    success=$(echo "$response" | jq -r '.success // false')
    if [ "$success" = "true" ]; then
        local project_id
        project_id=$(echo "$response" | jq -r '.data.projectId')
        echo "[+] Project created successfully. ProjectID: $project_id" >&2
        echo "$project_id"
        return 0
    else
        echo "[!] Creation failed (project may already exist), checking existing projects..." >&2
    fi
    local existing_id
    existing_id=$(get_project_id_by_name "$project_name" "$token")
    if [ $? -eq 0 ] && [ -n "$existing_id" ]; then
        echo "$existing_id"
        return 0
    fi
    echo "[!] Failed to create or find project '$project_name'" >&2
    return 1
}

# =============================================
# FUNCTION: upload_sast_project_files (returns objectName via stdout)
# =============================================
upload_sast_project_files() {
    local file_path="$1"
    local token="$2"
    if [ ! -f "$file_path" ]; then
        echo "[!] File not found: $file_path" >&2
        return 1
    fi
    local uri="$SERVER_URL/api/minio/upload"
    local file_name
    file_name=$(basename "$file_path")
    echo "[*] Uploading file: $file_name" >&2
    local response
    response=$(curl -s -k -X POST "$uri" \
        -H "Authorization: Bearer $token" \
        -F "file=@$file_path")
    local success
    success=$(echo "$response" | jq -r '.success // false')
    if [ "$success" = "true" ]; then
        local object_name
        object_name=$(echo "$response" | jq -r '.data')
        echo "[+] Upload completed successfully!" >&2
        echo " ObjectName: $object_name" >&2
        echo "$object_name"
        return 0
    else
        local msg
        msg=$(echo "$response" | jq -r '.message // "Unknown error"')
        echo "[!] Upload failed: $msg" >&2
        return 1
    fi
}

# =============================================
# FUNCTION: create_sast_tasks
# =============================================
create_sast_tasks() {
    local file_name="$1"
    local object_name="$2"
    local project_id="$3"
    local task_name="$4"
    local language_json="$5"
    local scheme_json="$6"
    local token="$7"
    local uri="$SERVER_URL/api/task/create"
    local body
    body=$(jq -n \
        --arg fileName "$file_name" \
        --arg objectName "$object_name" \
        --argjson languageIdList "$language_json" \
        --argjson schemeIdList "$scheme_json" \
        --argjson projectId "$project_id" \
        --arg taskName "$task_name" \
        --argjson taskType 2 \
        --argjson notificationSettings 0 \
        '{
            "fileName": $fileName,
            "objectName": $objectName,
            "languageIdList": $languageIdList,
            "notificationSettings": $notificationSettings,
            "projectId": $projectId,
            "schemeIdList": $schemeIdList,
            "taskName": $taskName,
            "taskType": $taskType
        }')
    echo "[*] Creating task: $task_name (ProjectId: $project_id)" >&2
    local response
    response=$(curl -s -k -X POST "$uri" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -d "$body")
    local success
    success=$(echo "$response" | jq -r '.success // false')
    if [ "$success" = "true" ]; then
        echo "[+] Task created successfully!" >&2
        local task_id
        task_id=$(echo "$response" | jq -r '.data.taskId // "N/A"')
        if [ "$task_id" != "N/A" ]; then
            echo " TaskID: $task_id" >&2
        fi
        return 0
    else
        local msg
        msg=$(echo "$response" | jq -r '.message // "Unknown error"')
        echo "[!] Task creation failed: $msg" >&2
        return 1
    fi
}

# =============================================
# FUNCTION: get_sast_scheme_id_list
# =============================================
get_sast_scheme_id_list() {
    local token="$1"
    local uri="$SERVER_URL/api/scheme/list"
    local body='{"languageIdList":[],"languageNameList":[],"page":0,"schemeName":"","size":200,"sort":[],"split":0}'
    echo "[*] Fetching detection scheme list from $uri"
    local response
    response=$(curl -s -k -X POST "$uri" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -d "$body")
    local success
    success=$(echo "$response" | jq -r '.success // false')
    if [ "$success" = "true" ]; then
        local total
        total=$(echo "$response" | jq '.data.content | length')
        echo "[+] Detection Scheme List (Total: $total)"
        echo "================================================================="
        echo "$response" | jq -r '.data.content[] |
            "Scheme ID : \(.id)\n" +
            "Scheme Name : \(.schemeName)\n" +
            "Default : \(if .defaultFlag == 1 then "Yes (Built-in)" else "No" end)\n" +
            (if .description then "Description : \(.description)\n" else "" end) +
            (if (.languageInfoDTOList | length) > 0 then "Languages : \(.languageInfoDTOList | map(.languageName) | join(", "))\n" else "" end) +
            "-----------------------------------------------------------------"
        '
    else
        local msg
        msg=$(echo "$response" | jq -r '.message // "Failed to retrieve scheme list"')
        echo "[!] Failed to retrieve scheme list: $msg"
    fi
}

# =============================================
# MAIN SCRIPT
# =============================================
check_dependencies

if [ $# -eq 0 ]; then
    show_usage
    exit 0
fi

# Initialize variables
USERNAME=""
PASSWORD=""
TOKEN=""
FILENAME=""
PROJECTNAME=""
TASKNAME=""
PROJECTID=0
LANGUAGEIDLIST="3"
SCHEMEIDLIST="32"
GET_SCHEMES=0

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --Username)
            USERNAME="$2"
            shift 2
            ;;
        --Password)
            PASSWORD="$2"
            shift 2
            ;;
        --Token)
            TOKEN="$2"
            shift 2
            ;;
        --FileName)
            FILENAME="$2"
            shift 2
            ;;
        --ProjectName)
            PROJECTNAME="$2"
            shift 2
            ;;
        --TaskName)
            TASKNAME="$2"
            shift 2
            ;;
        --ProjectId)
            PROJECTID="$2"
            shift 2
            ;;
        --LanguageIdList)
            LANGUAGEIDLIST="$2"
            shift 2
            ;;
        --SchemeIdList)
            SCHEMEIDLIST="$2"
            shift 2
            ;;
        --list-schemes)
            GET_SCHEMES=1
            shift 1
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            echo "[!] Unknown parameter: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Mode: List schemes
if [ $GET_SCHEMES -eq 1 ]; then
    if [ -n "$TOKEN" ]; then
        token="$TOKEN"
        echo "[+] Using provided authentication token."
    elif [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
        echo "[+] Logging in with username and password..."
        token=$(sast_login "$USERNAME" "$PASSWORD")
        if [ $? -ne 0 ] || [ -z "$token" ]; then
            echo "[!] Login failed. Aborting."
            exit 1
        fi
    else
        echo "[!] --list-schemes requires --Token or both --Username and --Password."
        exit 1
    fi
    get_sast_scheme_id_list "$token"
    exit 0
fi

# Mode: Create SAST task (default)
if [ -z "$FILENAME" ] || [ -z "$PROJECTNAME" ]; then
    echo "[!] Error: --FileName and --ProjectName are mandatory."
    show_usage
    exit 1
fi

echo "=========================================="
echo " Invoke-SecTrend-SAST - One-Click SAST Upload & Task Creation"
echo "=========================================="

# Step 1: Authentication
echo -e "\n[1/4] Preparing authentication..."
if [ -n "$TOKEN" ]; then
    echo "[+] Using provided authentication token."
    token="$TOKEN"
elif [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
    echo "[+] Logging in with username and password..."
    token=$(sast_login "$USERNAME" "$PASSWORD")
    if [ $? -ne 0 ] || [ -z "$token" ]; then
        echo "[!] Login failed. Aborting."
        exit 1
    fi
else
    echo "[!] You must provide either a --Token or both --Username and --Password."
    exit 1
fi

# Step 2: Handle project
echo -e "\n[2/4] Handling project '$PROJECTNAME'..."
if [ "$PROJECTID" -eq 0 ] 2>/dev/null; then
    project_id=$(create_sast_project "$PROJECTNAME" "$token")
    if [ $? -ne 0 ] || [ -z "$project_id" ]; then
        echo "[!] Failed to create or find project. Provide an existing --ProjectId if available."
        exit 1
    fi
    PROJECTID="$project_id"
else
    echo "[+] Using provided ProjectId: $PROJECTID"
fi

# Step 3: Upload file
echo -e "\n[3/4] Uploading file..."
object_name=$(upload_sast_project_files "$FILENAME" "$token")
if [ $? -ne 0 ] || [ -z "$object_name" ]; then
    echo "[!] File upload failed. Aborting."
    exit 1
fi

# Step 4: Create task
echo -e "\n[4/4] Creating SAST task..."
display_file_name=$(basename "$FILENAME")
if [ -z "$TASKNAME" ]; then
    TASKNAME="SAST-$(date +%Y%m%d-%H%M%S)"
fi

# Prepare JSON arrays (support comma or space separated)
lang_str=$(echo "$LANGUAGEIDLIST" | tr ',' ' ' | tr -s ' ')
scheme_str=$(echo "$SCHEMEIDLIST" | tr ',' ' ' | tr -s ' ')
LANGUAGE_JSON=$(printf '%s\n' $lang_str | jq -R 'tonumber' | jq -s '.')
SCHEME_JSON=$(printf '%s\n' $scheme_str | jq -R 'tonumber' | jq -s '.')

if create_sast_tasks "$display_file_name" "$object_name" "$PROJECTID" "$TASKNAME" "$LANGUAGE_JSON" "$SCHEME_JSON" "$token"; then
    echo -e "\n========================================"
    echo " SAST Task Created Successfully!"
    echo "========================================"
    echo " File Name : $display_file_name"
    echo " ProjectName : $PROJECTNAME"
    echo " ProjectId : $PROJECTID"
    echo " ObjectName : $object_name"
    echo " TaskName : $TASKNAME"
else
    echo -e "\n[!] Task creation completed with errors."
fi
