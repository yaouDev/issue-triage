#!/bin/bash

set -e

ISSUE_NUMBER=$(jq --raw-output .issue.number "$GITHUB_EVENT_PATH")
ISSUE_BODY=$(jq --raw-output .issue.body "$GITHUB_EVENT_PATH")
ISSUE_TITLE=$(jq --raw-output .issue.title "$GITHUB_EVENT_PATH")
ISSUE_LABELS=$(gh issue view "$ISSUE_NUMBER" --json labels --jq '.labels.[].name')

CURRENT_ASSIGNEES=$(gh issue view "$ISSUE_NUMBER" --json assignees --jq '.assignees.[].login')

echo "Processing issue #$ISSUE_NUMBER: '$ISSUE_TITLE'"

has_label() {
    local label="$1"
    echo "$ISSUE_LABELS" | grep -q "^$label$"
}

has_assignees() {
    [ -n "$CURRENT_ASSIGNEES" ]
}

# check if new or repoened
if [[ "$GITHUB_EVENT_NAME" == "issues" && ("$(jq --raw-output .action "$GITHUB_EVENT_PATH")" == "opened" || "$(jq --raw-output .action "$GITHUB_EVENT_PATH")" == "reopened") ]]; then

    # 1. Categorization || bug, feature, documentation, question
    echo "Performing automatic categorization..."
    
    if [[ "$ISSUE_TITLE" =~ "bug" || "$ISSUE_BODY" =~ "error" || "$ISSUE_BODY" =~ "crash" ]]; then
        if ! has_label "bug"; then
            echo "Applying label: bug"
            gh issue edit "$ISSUE_NUMBER" --add-label "bug"
        fi
    fi

    if [[ "$ISSUE_TITLE" =~ "feature" || "$ISSUE_BODY" =~ "enhancement" || "$ISSUE_BODY" =~ "new functionality" ]]; then
        if ! has_label "enhancement"; then
            echo "Applying label: enhancement"
            gh issue edit "$ISSUE_NUMBER" --add-label "enhancement"
        fi
    fi
    
    if [[ "$ISSUE_TITLE" =~ "docs" || "$ISSUE_BODY" =~ "documentation" ]]; then
        if ! has_label "documentation"; then
            echo "Applying label: documentation"
            gh issue edit "$ISSUE_NUMBER" --add-label "documentation"
        fi
    fi

    if [[ "$ISSUE_TITLE" =~ "question" || "$ISSUE_BODY" =~ "how to" || "$ISSUE_BODY" =~ "what is" ]]; then
        if ! has_label "question"; then
            echo "Applying label: question"
            gh issue edit "$ISSUE_NUMBER" --add-label "question"
        fi
    fi

    # 2. Prioritization Heuristics || critical/security = high
    echo "Applying priority heuristics..."
    if [[ "$ISSUE_TITLE" =~ "critical" || "$ISSUE_BODY" =~ "critical" || "$ISSUE_BODY" =~ "security" ]]; then
        if ! has_label "priority: high"; then
            echo "Applying label: priority: high"
            gh issue edit "$ISSUE_NUMBER" --add-label "priority: high"
        fi
    fi

    # 3. Required Information Check || short or lacks explanation
    echo "Checking for required information..."
    # checks if the issue body is too short or lacks a "steps to reproduce" section
    if [[ $(echo -n "$ISSUE_BODY" | wc -m) -lt 100 ]] || ! [[ "$ISSUE_BODY" =~ "steps to reproduce" ]]; then
        if ! has_label "needs more info"; then
            echo "Applying label: needs more info"
            gh issue edit "$ISSUE_NUMBER" --add-label "needs more info"
            gh issue comment "$ISSUE_NUMBER" --body "Thank you for the issue! To help us resolve this, please provide more information, such as 'steps to reproduce' and an expected behavior. "
        fi
    fi

    # 4. Automatic Assignment || assign leasy busy matched assignee
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
                local issue_count=$(gh issue list --search "is:open assignee:$assignee" --json number --jq '.[].number' | wc -l)

                echo "  -> $assignee has $issue_count open issues."
                
                if [[ "$min_issues" -eq -1 || "$issue_count" -lt "$min_issues" ]]; then
                    min_issues="$issue_count"
                    least_busy_assignee="$assignee"
                fi
            done
            echo "$least_busy_assignee"
        }

        ASSIGNED_TO=""
        if [[ -n "$INPUT_ASSIGNMENT_RULES" ]]; then
            echo "$INPUT_ASSIGNMENT_RULES" | jq -c '.[]' | while read -r rule; do
                KEYWORDS=$(echo "$rule" | jq -r '.keywords')
                ASSIGNEES=$(echo "$rule" | jq -r '.assignees')
                if has_keyword "$KEYWORDS"; then
                    ASSIGNED_TO=$(pick_least_busy_assignee "$ASSIGNEES")
                    break
                fi
            done
        fi

        if [ -n "$ASSIGNED_TO" ]; then
            echo "Assigning to $ASSIGNED_TO based on a matched keyword."
            gh issue edit "$ISSUE_NUMBER" --add-assignee "$ASSIGNED_TO"
        elif [ -n "$INPUT_DEFAULT_ASSIGNEE" ]; then
            echo "No keywords matched. Assigning to default assignee: $INPUT_DEFAULT_ASSIGNEE."
            gh issue edit "$ISSUE_NUMBER" --add-assignee "$INPUT_DEFAULT_ASSIGNEE"
        fi
    fi
fi

# only run by a separate scheduled workflow
# currently uses gh cli calls instead of API - consider the benefits
if [[ "$GITHUB_EVENT_NAME" == "schedule" ]]; then
    STALE_DAYS="${INPUT_STALE_DAYS}"
    CLOSE_DAYS="${INPUT_CLOSE_DAYS}"
    STALE_MSG="${INPUT_STALE_MESSAGE}"
    CLOSE_MSG="${INPUT_CLOSE_MESSAGE}"
    
    echo "Running stale issue management..."

    if [[ "$STALE_DAYS" -gt 0 ]]; then
        echo "Searching for issues older than $STALE_DAYS days..."
        
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

    # close stale issues
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
