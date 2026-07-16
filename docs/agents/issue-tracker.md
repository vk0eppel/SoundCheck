# Issue Tracker: GitHub

This repository tracks issues in GitHub Issues. Commands like `/to-tickets` will interact with the GitHub API using the `gh` CLI.

## Workflow Notes
Since PRs are not treated as a triage surface, focus is on issues created via `gh issue create`. Local Markdown files under `.scratch/` are also supported for informal tracking outside of the main issue tracker flow.

## Usage Examples
- To create a new GitHub issue: `/to-tickets issue create --title "New Feature"`
- To interact with existing issues: `/to-tickets issue <issue_number>`