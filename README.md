# Advanced Issue Triage

[![GitHub Marketplace](https://img.shields.io/badge/GitHub%20Marketplace-Advanced%20Issue%20Triage-brightgreen?logo=github)](https://github.com/marketplace/actions/advanced-issue-triage)

A smart GitHub Action for automating issue management. This action automatically applies labels, assigns issues to the least busy team member, and manages stale issues.

## ✨ Features

* **Automatic Labeling:** 🏷️ Applies labels like `bug`, `enhancement`, `documentation`, or `question` based on keywords found in the issue's title and body.

* **Intelligent Assignment:** 🧑‍💻 Assigns issues to a team member based on keywords. It intelligently picks the least busy assignee from a predefined list.

* **Stale Issue Management:** 🕰️ Automatically marks issues as stale after a period of inactivity and closes them if no action is taken.

* **Information Check:** ❓ Checks if an issue has sufficient details and adds a `needs more info` label if it appears to be lacking key information like "steps to reproduce".

## 🚀 Usage

To start using this action, create a workflow file in your repository at `.github/workflows/triage.yml`.

### Example Workflow

```yaml
name: 'Advanced Issue Triage'

on:
  issues:
    types: [opened, reopened]
  schedule:
    - cron: '0 0 * * *' # This will run the action daily at midnight UTC

jobs:
  triage:
    runs-on: ubuntu-latest
    permissions:
      issues: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
      - name: Run Advanced Issue Triage
        uses: yaouDev@issue-triage@v1 # Replace with your action's path and version
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          stale-days: 30
          close-days: 7
          stale-message: 'This issue is stale because it has been open for {{ stale-days }} days with no activity. Please remove the stale label or comment, otherwise this issue will be closed in {{ close-days }} days.'
          close-message: 'This issue was closed because it has been inactive for a long time. Please reopen if this issue is still relevant.'
          assignment-rules: |
            [
              {
                "keywords": "ui,css,frontend",
                "assignees": "user1,user2"
              },
              {
                "keywords": "api,server,database",
                "assignees": "user3,user4"
              },
              {
                "keywords": "docs,documentation",
                "assignees": "writer1"
              }
            ]
          default-assignee: 'default-username'

```

### ⚙️ Inputs

| Name | Description | Required | Default | 
 | ----- | ----- | ----- | ----- | 
| `github-token` | A GitHub token with permissions to read/write issues. This is required for the action to function. | `true` |  | 
| `stale-days` | The number of days an issue can be inactive before being marked with the `stale` label. Set to `0` to disable this feature. | `false` | `30` | 
| `close-days` | The number of days to wait after an issue is marked as stale before it is automatically closed. Set to `0` to disable closing. | `false` | `7` | 
| `stale-message` | The comment that will be added to an issue when it is marked as stale. | `false` | `This issue is stale because...` | 
| `close-message` | The comment that will be added to an issue when it is automatically closed. | `false` | `This issue was closed because...` | 
| `assignment-rules` | A JSON array of objects, where each object defines keywords and the assignees to consider. The action will assign the least busy user from the matched list. | `true` | `[]` | 
| `default-assignee` | The GitHub username to assign if no keywords from the `assignment-rules` match the issue. | `false` | `''` | 

## 🤝 Contributing

We welcome contributions! Please feel free to open a new issue to discuss a feature or submit a pull request with your changes.
