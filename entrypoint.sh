#!/bin/bash

set -euo pipefail
# set -x

export GH_TOKEN="${GH_TOKEN:-}"
export GITHUB_TOKEN="$GH_TOKEN"
EVENT_PATH="${CUSTOM_EVENT_PATH:-$GITHUB_EVENT_PATH}"

# trust the workspace since initiator and runner might be different users
git config --global --add safe.directory "$GITHUB_WORKSPACE"

echo "Verifying GH_TOKEN..."
if [ -z "$GH_TOKEN" ]; then
    echo "Error: GH_TOKEN is not set. The GitHub CLI will not be able to authenticate."
    exit 1
fi
echo "GH_TOKEN is set."

echo "Verifying GitHub CLI authentication and permissions..."
if ! gh auth status > /dev/null 2>&1; then
    echo "GitHub CLI is not authenticated properly."
    gh auth status || true
    exit 1
fi

CONFIG_FILE="${CONFIG_PATH:-/issue-config.json}"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Configuration file '$CONFIG_FILE' not found in the repo root."
    exit 1
fi

# load the json config once
CONFIG_JSON=$(cat "$CONFIG_FILE")

# extract default assignee from config
DEFAULT_ASSIGNEE=$(echo "$CONFIG_JSON" | jq -r '.defaultAssignee // empty')

# function to check and create labels if missing
ensure_label_exists() {
    local label="$1"
    local color="${2:-ededed}"
    local description="${3:-Auto-created by issue triage script}"

    if ! gh label list --limit 100 | grep -q "^$label[[:space:]]"; then
        echo "Label '$label' not found. Creating it..."
        gh label create "$label" --color "$color" --description "$description"
    fi
}

# initiate info to nothing to check if scheduled event
ISSUE_NUMBER=""
ISSUE_TITLE=""
ISSUE_BODY=""

if [[ -f "$EVENT_PATH" && "$GITHUB_EVENT_NAME" == "issues" ]]; then
  ISSUE_NUMBER=$(jq -r .issue.number "$EVENT_PATH")
  ISSUE_BODY=$(jq -r .issue.body "$EVENT_PATH")
  ISSUE_TITLE=$(jq -r .issue.title "$EVENT_PATH")
elif [[ "$GITHUB_EVENT_NAME" == "workflow_dispatch" ]]; then
  ISSUE_NUMBER="${ISSUE_INDEX:?Issue number required}"
  read -r ISSUE_NUMBER ISSUE_TITLE ISSUE_BODY < <(gh issue view "$ISSUE_NUMBER" --json number,title,body --jq '. | "\(.number)\t\(.title)\t\(.body)"')
elif [[ "$GITHUB_EVENT_NAME" == "schedule" ]]; then
  echo "Scheduled event: skipping single issue triage, proceeding to stale issue processing..."
fi

# check if issue nubmer exists
if [[ -n "$ISSUE_NUMBER" ]]; then
    ISSUE_LABELS=$(gh issue view "$ISSUE_NUMBER" --json labels --jq '.labels.[].name' || echo "")
    CURRENT_ASSIGNEES=$(gh issue view "$ISSUE_NUMBER" --json assignees --jq '.assignees.[].login' || echo "")

    echo "Processing issue #$ISSUE_NUMBER: '$ISSUE_TITLE'"

    # case-insensitive, exact match label check
    has_label() {
        local label="$1"
        echo "$ISSUE_LABELS" | awk '{print tolower($0)}' | grep -qxF "$(echo "$label" | awk '{print tolower($0)}')"
    }

    has_assignees() {
        [ -n "$CURRENT_ASSIGNEES" ]
    }

    has_keyword() {
        local keywords_csv="$1"
        local issue_text="${ISSUE_TITLE,,} ${ISSUE_BODY,,}"

        IFS=',' read -ra keywords <<< "$keywords_csv"
        for kw in "${keywords[@]}"; do
            kw="${kw,,}"
            if [[ "$issue_text" =~ $kw ]]; then
                return 0
            fi
        done
        return 1
    }

    # lowercase conversion
    issue_text="$(echo "$ISSUE_TITLE
    $ISSUE_BODY" | tr '[:upper:]' '[:lower:]')"

    if [[ ("$GITHUB_EVENT_NAME" == "issues" && ("$(jq --raw-output .action "$EVENT_PATH")" == "opened" || "$(jq --raw-output .action "$EVENT_PATH")" == "reopened")) || ("$GITHUB_EVENT_NAME" == "workflow_dispatch") ]]; then

        echo "Performing automatic categorization based on config..."

        labels_count=$(jq '.labels | length' <<< "$CONFIG_JSON")
        for ((i=0; i<labels_count; i++)); do
            label_name=$(jq -r ".labels[$i].name" <<< "$CONFIG_JSON")
            label_color=$(jq -r ".labels[$i].color" <<< "$CONFIG_JSON")
            label_desc=$(jq -r ".labels[$i].description" <<< "$CONFIG_JSON")
            keywords_array=$(jq -r ".labels[$i].keywords | join(\",\")" <<< "$CONFIG_JSON")

            if [[ "$keywords_array" == "" && "$label_name" != "needs more info" ]]; then
                continue
            fi

            IFS=',' read -ra kws <<< "$keywords_array"
            for kw in "${kws[@]}"; do
                kw="${kw,,}"
                if [[ "$issue_text" =~ $kw ]]; then
                    if ! has_label "$label_name"; then
                        ensure_label_exists "$label_name" "$label_color" "$label_desc"
                        echo "Applying label: $label_name"
                        gh issue edit "$ISSUE_NUMBER" --add-label "$label_name"
                    fi
                    break
                fi
            done
        done

        # special case: needs more info label logic
        min_body_length=100
        required_phrase="steps to reproduce"

        if (( $(echo -n "$ISSUE_BODY" | wc -m) < min_body_length )) || ! grep -iqF "$required_phrase" <<< "$ISSUE_BODY"; then
            if ! has_label "needs more info"; then
                label_info=$(jq -r '.labels[] | select(.name=="needs more info")' <<< "$CONFIG_JSON")
                label_color=$(jq -r '.color' <<< "$label_info")
                label_desc=$(jq -r '.description' <<< "$label_info")
                ensure_label_exists "needs more info" "$label_color" "$label_desc"
                echo "Applying label: needs more info"
                gh issue edit "$ISSUE_NUMBER" --add-label "needs more info"
                gh issue comment "$ISSUE_NUMBER" --body "Thank you for the issue! To help us resolve this, please provide more information, such as 'steps to reproduce' and an expected behavior."
            fi
        fi

        # dev assignment
        if ! has_assignees; then
            echo "Performing automatic assignment..."

            pick_least_busy_assignee() {
                local assignees_string="$1"
                if [ -z "$assignees_string" ]; then
                    echo ""
                    return
                fi

                IFS=',' read -r -a ASSIGNEE_LIST <<< "$assignees_string"
                local least_busy_assignee=""
                local min_issues=-1

                for assignee in "${ASSIGNEE_LIST[@]}"; do
                    local issue_count
                    issue_count=$(gh issue list --search "is:open assignee:$assignee" --json number --jq '.[].number' | wc -l)
                    >&2 echo "  -> $assignee has $issue_count open issues."

                    if [[ "$min_issues" -eq -1 || "$issue_count" -lt "$min_issues" ]]; then
                        min_issues="$issue_count"
                        least_busy_assignee="$assignee"
                    fi
                done

                echo "$least_busy_assignee"
            }

            echo "Checking assignment rules..."
            ASSIGNED_TO=""

            if [[ -n "$CONFIG_JSON" ]]; then
                while read -r rule; do
                    rule_labels=$(echo "$rule" | jq -r '.labels // [] | @csv' | tr -d '"')
                    rule_keywords=$(echo "$rule" | jq -r '.keywords // [] | @csv' | tr -d '"')
                    rule_assignees=$(echo "$rule" | jq -r '.assignees | join(",")')

                    matched=false

                    for lbl in $(echo "$rule_labels" | tr ',' '\n'); do
                        if has_label "$lbl"; then
                            matched=true
                            break
                        fi
                    done

                    if [[ "$matched" == "false" && -n "$rule_keywords" ]]; then
                        if has_keyword "$rule_keywords"; then
                            matched=true
                        fi
                    fi

                    if [[ "$matched" == "true" && -n "$rule_assignees" ]]; then
                        echo "Matched assignment rule: labels=[$rule_labels], keywords=[$rule_keywords], assignees=[$rule_assignees]"
                        ASSIGNED_TO=$(pick_least_busy_assignee "$rule_assignees")
                        break
                    fi

                done < <(echo "$CONFIG_JSON" | jq -c '.assignments[]')
            fi

            if [ -n "$ASSIGNED_TO" ]; then
                echo "Assigning to $ASSIGNED_TO based on matched rule."
                gh issue edit "$ISSUE_NUMBER" --add-assignee "$ASSIGNED_TO"
            elif [ -n "$DEFAULT_ASSIGNEE" ]; then
                echo "No match found. Assigning to default: $DEFAULT_ASSIGNEE"
                gh issue edit "$ISSUE_NUMBER" --add-assignee "$DEFAULT_ASSIGNEE"
            fi
        fi
    fi
fi

# scheduled trigger
if [[ "$GITHUB_EVENT_NAME" == "schedule" ]]; then
    STALE_DAYS="${STALE_DAYS:-0}"
    CLOSE_DAYS="${CLOSE_DAYS:-0}"
    STALE_MSG="${STALE_MESSAGE:-}"
    CLOSE_MSG="${CLOSE_MESSAGE:-}"

    echo "Running stale issue management..."

    if [[ "$STALE_DAYS" -gt 0 ]]; then
        echo "Searching for issues older than $STALE_DAYS days..."
        ensure_label_exists "stale" "cccccc" "Issue is stale and may be closed soon"

        gh issue list --search "state:open -label:stale -label:bug -label:enhancement" --limit 100 --json number --jq '.[].number' | while read -r issue_num; do
            last_updated=$(gh issue view "$issue_num" --json updatedAt --jq '.updatedAt')
            last_updated_ts=$(date -d "$(echo "$last_updated" | sed 's/T/ /;s/Z//')" +%s)
            current_ts=$(date +%s)
            days_ago=$(( (current_ts - last_updated_ts) / 86400 ))

            if [[ "$days_ago" -ge "$STALE_DAYS" ]]; then
                echo "Issue #$issue_num is stale. Adding 'stale' label."
                formatted_stale_msg=$(echo "$STALE_MSG" | sed "s/{{ stale-days }}/$STALE_DAYS/g; s/{{ close-days }}/$CLOSE_DAYS/g")
                gh issue edit "$issue_num" --add-label "stale"
                gh issue comment "$issue_num" --body "$formatted_stale_msg"
            fi
        done
    fi

    if [[ "$CLOSE_DAYS" -gt 0 ]]; then
        echo "Searching for issues that have been stale for more than $CLOSE_DAYS days..."
        gh issue list --search "state:open label:stale" --limit 100 --json number,updatedAt,labels --jq '.[]' | while read -r issue_json; do
            issue_num=$(echo "$issue_json" | jq -r '.number')

            updated_at=$(echo "$issue_json" | jq -r '.updatedAt')
            updated_ts=$(date -d "$(echo "$updated_at" | sed 's/T/ /;s/Z//')" +%s)
            current_ts=$(date +%s)
            days_since_update=$(( (current_ts - updated_ts) / 86400 ))

            if [[ "$days_since_update" -ge "$CLOSE_DAYS" ]]; then
                echo "Issue #$issue_num has been stale for too long. Closing it."
                gh issue close "$issue_num" --comment "$CLOSE_MSG"
            fi
        done
    fi
fi