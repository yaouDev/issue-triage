#!/bin/bash

set -e
# set -x
set -euo pipefail

export GH_TOKEN="${GH_TOKEN:-}"
export GITHUB_TOKEN="$GH_TOKEN"
EVENT_PATH="${CUSTOM_EVENT_PATH:-$GITHUB_EVENT_PATH}"

# needed to trust the workspace since initiator and runner are different users
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

# check if label exists
ensure_label_exists() {
    local label="$1"
    local color="${2:-ededed}"
    local description="${3:-Auto-created by issue triage script}"

    if ! gh label list --limit 100 | grep -q "^$label[[:space:]]"; then
        echo "Label '$label' not found. Creating it..."
        gh label create "$label" --color "$color" --description "$description"
    fi
}

if [[ -f "$EVENT_PATH" && "$GITHUB_EVENT_NAME" == "issues" ]]; then
  ISSUE_NUMBER=$(jq -r .issue.number "$EVENT_PATH")
  ISSUE_BODY=$(jq -r .issue.body "$EVENT_PATH")
  ISSUE_TITLE=$(jq -r .issue.title "$EVENT_PATH")
else
  ISSUE_NUMBER="${ISSUE_INDEX:?Issue number required}"
  read -r ISSUE_NUMBER ISSUE_TITLE ISSUE_BODY < <(gh issue view "$ISSUE_NUMBER" --json number,title,body --jq '. | "\(.number)\t\(.title)\t\(.body)"')
fi
ISSUE_LABELS=$(gh issue view "$ISSUE_NUMBER" --json labels --jq '.labels.[].name' || echo "")
CURRENT_ASSIGNEES=$(gh issue view "$ISSUE_NUMBER" --json assignees --jq '.assignees.[].login' || echo "")

echo "Processing issue #$ISSUE_NUMBER: '$ISSUE_TITLE'"

has_label() {
    local label="$1"
    echo "$ISSUE_LABELS" | grep -q "^$label$"
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

if [[ ("$GITHUB_EVENT_NAME" == "issues" && ("$(jq --raw-output .action "$EVENT_PATH")" == "opened" || "$(jq --raw-output .action "$EVENT_PATH")" == "reopened")) || ("$GITHUB_EVENT_NAME" == "workflow_dispatch") ]]; then

    echo "Performing automatic categorization..."

    if [[ "$ISSUE_TITLE" =~ "bug" || "$ISSUE_BODY" =~ "error" || "$ISSUE_BODY" =~ "crash" ]]; then
        if ! has_label "bug"; then
            ensure_label_exists "bug" "d73a4a" "Something isn't working"
            echo "Applying label: bug"
            gh issue edit "$ISSUE_NUMBER" --add-label "bug"
        fi
    fi

    if [[ "$ISSUE_TITLE" =~ "feature" || "$ISSUE_BODY" =~ "enhancement" || "$ISSUE_BODY" =~ "new functionality" ]]; then
        if ! has_label "enhancement"; then
            ensure_label_exists "enhancement" "a2eeef" "New feature or request"
            echo "Applying label: enhancement"
            gh issue edit "$ISSUE_NUMBER" --add-label "enhancement"
        fi
    fi

    if [[ "$ISSUE_TITLE" =~ "docs" || "$ISSUE_BODY" =~ "documentation" ]]; then
        if ! has_label "documentation"; then
            ensure_label_exists "documentation" "0075ca" "Improvements or additions to documentation"
            echo "Applying label: documentation"
            gh issue edit "$ISSUE_NUMBER" --add-label "documentation"
        fi
    fi

    if [[ "$ISSUE_TITLE" =~ "question" || "$ISSUE_BODY" =~ "how to" || "$ISSUE_BODY" =~ "what is" ]]; then
        if ! has_label "question"; then
            ensure_label_exists "question" "d876e3" "Further information is requested"
            echo "Applying label: question"
            gh issue edit "$ISSUE_NUMBER" --add-label "question"
        fi
    fi

    echo "Applying priority heuristics..."
    if [[ "$ISSUE_TITLE" =~ "critical" || "$ISSUE_BODY" =~ "critical" || "$ISSUE_BODY" =~ "security" ]]; then
        if ! has_label "priority: high"; then
            ensure_label_exists "priority: high" "b60205" "High priority issue"
            echo "Applying label: priority: high"
            gh issue edit "$ISSUE_NUMBER" --add-label "priority: high"
        fi
    fi

    echo "Checking for required information..."
    if [[ $(echo -n "$ISSUE_BODY" | wc -m) -lt 100 ]] || ! [[ "$ISSUE_BODY" =~ "steps to reproduce" ]]; then
        if ! has_label "needs more info"; then
            ensure_label_exists "needs more info" "fef2c0" "Needs more input from the author"
            echo "Applying label: needs more info"
            gh issue edit "$ISSUE_NUMBER" --add-label "needs more info"
            gh issue comment "$ISSUE_NUMBER" --body "Thank you for the issue! To help us resolve this, please provide more information, such as 'steps to reproduce' and an expected behavior."
        fi
    fi

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

        ASSIGNED_TO=""

        if [[ -n "$ASSIGNMENT_RULES" ]]; then
            while read -r rule; do
                KEYWORDS=$(echo "$rule" | jq -r '.keywords')
                ASSIGNEES=$(echo "$rule" | jq -r '.assignees')
                if has_keyword "$KEYWORDS"; then
                    ASSIGNED_TO=$(pick_least_busy_assignee "$ASSIGNEES")
                    break
                fi
            done < <(echo "$ASSIGNMENT_RULES" | jq -c '.[]')
        fi

        if [ -n "$ASSIGNED_TO" ]; then
            echo "Assigning to $ASSIGNED_TO based on a matched keyword."
            gh issue edit "$ISSUE_NUMBER" --add-assignee "$ASSIGNED_TO"
        elif [ -n "$DEFAULT_ASSIGNEE" ]; then
            echo "No keywords matched. Assigning to default assignee: $DEFAULT_ASSIGNEE."
            gh issue edit "$ISSUE_NUMBER" --add-assignee "$DEFAULT_ASSIGNEE"
        fi
    fi
fi

# will only run as a scheduled flow
if [[ "$GITHUB_EVENT_NAME" == "schedule" ]]; then
    STALE_DAYS="${STALE_DAYS}"
    CLOSE_DAYS="${CLOSE_DAYS}"
    STALE_MSG="${STALE_MESSAGE}"
    CLOSE_MSG="${CLOSE_MESSAGE}"

    echo "Running stale issue management..."

    if [[ "$STALE_DAYS" -gt 0 ]]; then
        echo "Searching for issues older than $STALE_DAYS days..."
        ensure_label_exists "stale" "cccccc" "Issue is stale and may be closed soon"

        gh issue list --search "state:open -label:stale -label:bug -label:enhancement" --limit 100 --json number --jq '.[].number' | while read -r issue_num; do
            last_updated=$(gh issue view "$issue_num" --json updatedAt --jq '.updatedAt')
            last_updated_ts=$(date -d "$last_updated" +%s)
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
            stale_label_updated=$(echo "$issue_json" | jq -r '.labels[] | select(.name=="stale") | .updatedAt')

            if [[ -n "$stale_label_updated" ]]; then
                stale_ts=$(date -d "$stale_label_updated" +%s)
                current_ts=$(date +%s)
                days_since_stale=$(( (current_ts - stale_ts) / 86400 ))

                if [[ "$days_since_stale" -ge "$CLOSE_DAYS" ]]; then
                    echo "Issue #$issue_num has been stale for too long. Closing it."
                    gh issue close "$issue_num" --comment "$CLOSE_MSG"
                fi
            fi
        done
    fi
fi
