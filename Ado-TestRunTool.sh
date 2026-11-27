#!/usr/bin/env bash
#
# SYNOPSIS
#     Interactive tool to delete an Azure DevOps test run (incl. its linked
#     test results/outcomes) or to list all test runs and save them to a file.
#     Bash port of Ado-TestRunTool.ps1 for macOS and Linux.
#
# DESCRIPTION
#     Running the script without -r/-l starts an interactive menu:
#
#       [1] Delete a test run  - asks for the Run ID, shows the run and its
#           linked results/outcomes, asks for confirmation, deletes the run
#           (which cascades to results/attachments), then verifies both the
#           run and its results are gone (404).
#       [2] List test runs     - fetches all test runs (paged) and saves them
#           as a timestamped CSV in the current directory (or to -O).
#       [Q] Quit.
#
#     Authentication uses a Personal Access Token (PAT) read from the
#     environment variable AZURE_DEVOPS_PAT (or AZDO_PAT as fallback).
#     The PAT needs the "Test (read & write)" scope.
#
# EXAMPLES
#     export AZURE_DEVOPS_PAT="<your PAT>"
#     ./Ado-TestRunTool.sh -o myorg -p myproject
#
#     # Pre-filled launcher (edit Example-Run.sh once, then just run it)
#     ./Example-Run.sh
#
#     # Non-interactive: delete a run directly
#     ./Ado-TestRunTool.sh -o myorg -p myproject -r 1234
#
#     # Non-interactive: export run list
#     ./Ado-TestRunTool.sh -o myorg -p myproject -l
#
# NOTES
#     Requires bash, curl and jq. Based on:
#       - Test Runs - Delete:       DELETE https://dev.azure.com/{org}/{project}/_apis/test/runs/{runId}?api-version=7.1
#       - Test Runs - List:         GET    https://dev.azure.com/{org}/{project}/_apis/test/runs?api-version=7.1
#       - Test Runs - List results: GET    https://dev.azure.com/{org}/{project}/_apis/test/runs/{runId}/results?api-version=7.1
#     Run deletion removes the results server-side; there is no modern
#     per-result delete API, hence the delete-run-then-verify approach.

set -u

API_VERSION='7.1'

ORGANIZATION=''
PROJECT=''
RUN_ID=''
LIST_RUNS=0
OUTPUT_PATH=''
FORCE=0
WHATIF=0

usage() {
    cat <<'EOF'
Usage: Ado-TestRunTool.sh -o <organization> -p <project> [options]

Options:
  -o, -Organization, --organization <org>   Azure DevOps organization (required)
  -p, -Project,      --project <project>    Project name (required)
  -r, -RunId,        --run-id <id>          Delete this test run directly (non-interactive)
  -l, -ListRuns,     --list-runs            Export all test runs to CSV (non-interactive)
  -O, -OutputPath,   --output-path <file>   CSV output file (default: ./testruns-<timestamp>.csv)
  -f, -Force,        --force                Skip the confirmation prompt before deleting
  -w, -WhatIf,       --whatif               Show what would be deleted, without deleting
  -c, -Confirm,      --confirm              Ask for confirmation before deleting (default)
  -h, -Help,         --help                 Show this help

Authentication: PAT is read from the environment variable AZURE_DEVOPS_PAT
(fallback AZDO_PAT), scope "Test (read & write)". Never stored or written.
EOF
}

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[0;33m' RESET=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' RESET=''
fi

cecho() {
    local color="$1"; shift
    printf '%s%s%s\n' "$color" "$*" "$RESET"
}

die() {
    cecho "$RED" "Error: $*" >&2
    exit 1
}

need_value() {
    if [[ $# -lt 2 || -z "$2" ]]; then
        echo "Error: missing value for $1" >&2
        usage >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|-Organization|-organization|--organization)
            need_value "$1" "${2:-}"; ORGANIZATION="$2"; shift 2 ;;
        --organization=*)
            ORGANIZATION="${1#*=}"; shift ;;
        -p|-Project|-project|--project)
            need_value "$1" "${2:-}"; PROJECT="$2"; shift 2 ;;
        --project=*)
            PROJECT="${1#*=}"; shift ;;
        -r|-RunId|-runid|--run-id)
            need_value "$1" "${2:-}"; RUN_ID="$2"; shift 2 ;;
        --run-id=*)
            RUN_ID="${1#*=}"; shift ;;
        -l|-ListRuns|-listruns|--list-runs)
            LIST_RUNS=1; shift ;;
        -O|-OutputPath|-outputpath|--output-path)
            need_value "$1" "${2:-}"; OUTPUT_PATH="$2"; shift 2 ;;
        --output-path=*)
            OUTPUT_PATH="${1#*=}"; shift ;;
        -f|-Force|-force|--force)
            FORCE=1; shift ;;
        -w|-WhatIf|-whatif|--whatif)
            WHATIF=1; shift ;;
        -c|-Confirm|-confirm|--confirm)
            shift ;;
        -h|-Help|-help|--help)
            usage; exit 0 ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            usage >&2
            exit 2 ;;
    esac
done

if [[ -z "$ORGANIZATION" || -z "$PROJECT" ]]; then
    echo "Error: -o/--organization and -p/--project are required." >&2
    usage >&2
    exit 2
fi

if [[ -n "$RUN_ID" && ! "$RUN_ID" =~ ^[0-9]+$ ]]; then
    die "'$RUN_ID' is not a valid run ID."
fi

for dep in curl jq; do
    command -v "$dep" >/dev/null 2>&1 || die "'$dep' is required but not installed."
done

PAT="${AZURE_DEVOPS_PAT:-${AZDO_PAT:-}}"
if [[ -z "$PAT" ]]; then
    die "No PAT found. Set the environment variable AZURE_DEVOPS_PAT (scope: Test read & write), e.g. export AZURE_DEVOPS_PAT='<token>'."
fi

AUTH_HEADER=$(printf ':%s' "$PAT" | base64 | tr -d '\n')
BASE_URI="https://dev.azure.com/${ORGANIZATION}/${PROJECT}/_apis/test"

BODY_FILE=$(mktemp)
ERR_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE" "$ERR_FILE"' EXIT

HTTP_CODE=000
CURL_ERROR=''

# http_request <METHOD> <URI>  -> sets HTTP_CODE (000 on transport failure) and BODY_FILE
http_request() {
    local method="$1" uri="$2" rc=0
    HTTP_CODE=$(curl -sS --max-time 120 -o "$BODY_FILE" -w '%{http_code}' \
        -X "$method" \
        -H "Authorization: Basic ${AUTH_HEADER}" \
        -H 'Accept: application/json' \
        "$uri" 2>"$ERR_FILE") || rc=1
    if [[ $rc -ne 0 ]]; then
        HTTP_CODE=000
        CURL_ERROR=$(tr '\n' ' ' < "$ERR_FILE")
    else
        CURL_ERROR=''
    fi
    return 0
}

is_2xx() {
    [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]
}

api_error_message() {
    local context="$1"
    case "$HTTP_CODE" in
        404) echo "${context} not found (404) in ${ORGANIZATION}/${PROJECT}." ;;
        401) echo "Unauthorized (401). Check the PAT and its Test (read & write) scope." ;;
        403) echo "Forbidden (403). The PAT lacks access: check the Test (read & write) scope and your permissions on ${ORGANIZATION}/${PROJECT}." ;;
        000) echo "No HTTP response from Azure DevOps (connectivity/DNS/TLS). ${CURL_ERROR}" ;;
        *)   echo "Azure DevOps returned HTTP ${HTTP_CODE}. $(tr '\n' ' ' < "$BODY_FILE")" ;;
    esac
}

# confirm <target> -> 0 if the user answers yes
confirm() {
    local ans
    read -rp "Are you sure you want to perform this action? Deleting $1. [y/N] " ans || return 1
    case "$ans" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ============================================================================
# Action: delete a test run (cascades to its linked results/outcomes)
# ============================================================================
delete_run() {
    local run_id="$1"
    local run_uri="${BASE_URI}/runs/${run_id}"

    # --- 1. Fetch the run ----------------------------------------------------
    http_request GET "${run_uri}?api-version=${API_VERSION}"
    if ! is_2xx; then
        die "$(api_error_message "Run #${run_id}")"
    fi

    local name state url
    name=$(jq -r '.name // ""' "$BODY_FILE")
    state=$(jq -r '.state // ""' "$BODY_FILE")
    url=$(jq -r '.webAccessUrl // ""' "$BODY_FILE")
    echo ""
    echo "Run:   #${run_id} '${name}' (state: ${state})"
    if [[ -n "$url" ]]; then
        echo "URL:   ${url}"
    fi

    # --- 2. Fetch linked results (paged) -------------------------------------
    local skip=0 top=1000 count
    local outcomes_file
    outcomes_file=$(mktemp)
    while true; do
        http_request GET "${run_uri}/results?api-version=${API_VERSION}&\$top=${top}&\$skip=${skip}"
        is_2xx || die "Azure DevOps returned HTTP ${HTTP_CODE} while listing results of run #${run_id}. $(tr '\n' ' ' < "$BODY_FILE")"
        count=$(jq -r '.value | length' "$BODY_FILE")
        if [[ "$count" -gt 0 ]]; then
            jq -r '.value[].outcome // "Unknown"' "$BODY_FILE" >> "$outcomes_file"
        fi
        [[ "$count" -lt "$top" ]] && break
        skip=$((skip + top))
    done

    local total
    total=$(wc -l < "$outcomes_file" | tr -d ' ')
    echo "Linked test results/outcomes: ${total}"
    if [[ "$total" -gt 0 ]]; then
        sort "$outcomes_file" | uniq -c | sort -rn | \
            awk '{ c = $1; $1 = ""; sub(/^ /, ""); printf "  %-20s %s\n", $0, c }'
    fi

    # --- 3. Confirm and delete the run ---------------------------------------
    local target="test run #${run_id} with ${total} linked result(s)"
    if [[ "$WHATIF" -eq 1 ]]; then
        echo "What if: Performing the operation \"Delete\" on target \"${target}\"."
        cecho "$YELLOW" "WhatIf: nothing was deleted."
    elif [[ "$FORCE" -eq 1 ]] || confirm "$target"; then
        http_request DELETE "${run_uri}?api-version=${API_VERSION}"
        if is_2xx; then
            cecho "$GREEN" "Delete request sent."
        else
            rm -f "$outcomes_file"
            die "$(api_error_message "Delete of run #${run_id} failed")"
        fi

        # --- 4. Verify nothing is left dangling ------------------------------
        http_request GET "${run_uri}?api-version=${API_VERSION}"
        if [[ "$HTTP_CODE" -eq 404 ]]; then
            cecho "$GREEN" "Verified: run #${run_id} no longer exists (404)."
        else
            cecho "$YELLOW" "Run still resolvable after delete; it may be marked for deletion and disappear shortly."
        fi
        http_request GET "${run_uri}/results?api-version=${API_VERSION}"
        if [[ "$HTTP_CODE" -eq 404 ]]; then
            cecho "$GREEN" "Verified: no resolvable results remain (404)."
        else
            cecho "$YELLOW" "Results endpoint still resolvable after delete; re-check in a moment."
        fi
    else
        cecho "$YELLOW" "Cancelled. Nothing was deleted."
    fi
    rm -f "$outcomes_file"
}

# ============================================================================
# Action: list all test runs and save them to a CSV file
# ============================================================================
export_runs() {
    local skip=0 top=1000 count
    local runs_file
    runs_file=$(mktemp)
    while true; do
        http_request GET "${BASE_URI}/runs?api-version=${API_VERSION}&\$top=${top}&\$skip=${skip}"
        is_2xx || die "Azure DevOps returned HTTP ${HTTP_CODE} while listing runs. $(tr '\n' ' ' < "$BODY_FILE")"
        count=$(jq -r '.value | length' "$BODY_FILE")
        if [[ "$count" -gt 0 ]]; then
            jq -c '.value[]' "$BODY_FILE" >> "$runs_file"
        fi
        [[ "$count" -lt "$top" ]] && break
        skip=$((skip + top))
    done

    local total
    total=$(wc -l < "$runs_file" | tr -d ' ')
    echo ""
    echo "Found ${total} test run(s) in ${ORGANIZATION}/${PROJECT}."

    if [[ "$total" -eq 0 ]]; then
        rm -f "$runs_file"
        return 0
    fi

    if [[ -z "$OUTPUT_PATH" ]]; then
        OUTPUT_PATH="$(pwd)/testruns-$(date +%Y%m%d-%H%M%S).csv"
    fi

    {
        printf '"id","name","state","outcome","planId","isAutomated","startedDate","completedDate","createdDate","totalTests","passedTests","failedTests","webAccessUrl"\n'
        jq -r '
            def v(x): if x == null then "" else (x | tostring) end;
            def b(x): if x == true then "True" elif x == false then "False" else "" end;
            [ v(.id), v(.name), v(.state), v(.outcome), v(.planId), b(.isAutomated),
              v(.startedDate), v(.completedDate), v(.createdDate),
              v(.totalTests), v(.passedTests), v(.failedTests), v(.webAccessUrl) ] | @csv
        ' "$runs_file"
    } > "$OUTPUT_PATH"
    cecho "$GREEN" "Saved run list to: ${OUTPUT_PATH}"

    echo ""
    echo "Preview (latest first):"
    jq -rs 'sort_by(.id) | reverse | .[0:10][] | "  #\(.id) \(.name) [\(.state)]"' "$runs_file"
    rm -f "$runs_file"
}

# ============================================================================
# Non-interactive mode
# ============================================================================
if [[ -n "$RUN_ID" && "$RUN_ID" -gt 0 ]]; then
    delete_run "$RUN_ID"
    exit 0
fi
if [[ "$LIST_RUNS" -eq 1 ]]; then
    export_runs
    exit 0
fi

# ============================================================================
# Interactive menu
# ============================================================================
echo "=========================================="
echo " Azure DevOps Test Run Tool"
echo "   Organization: ${ORGANIZATION}"
echo "   Project:      ${PROJECT}"
echo "=========================================="
while true; do
    echo ""
    echo "  [1] Delete a test run (incl. linked outcomes)"
    echo "  [2] List all test runs and save to file"
    echo "  [Q] Quit"
    read -rp "Choose an action: " choice || { echo ""; break; }
    case "$choice" in
        1)
            read -rp "Enter the test run ID to delete: " input || { echo ""; break; }
            input=$(trim "$input")
            if ! [[ "$input" =~ ^[0-9]+$ ]]; then
                cecho "$RED" "'${input}' is not a valid run ID."
                continue
            fi
            delete_run "$input"
            ;;
        2)
            export_runs
            ;;
        [Qq])
            break
            ;;
        *)
            cecho "$RED" "Invalid choice."
            ;;
    esac
done
echo "Bye."
