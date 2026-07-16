# Triage Labels Mapping

This document defines the canonical labels used by the `triage` skill for classifying issues within the GitHub issue tracker.

## Canonical Roles and Labels
The following five states are managed by the triage workflow:

| Role Name | Label String | Description |
| :--- | :--- | :--- |
| needs-triage | `needs-triage` | Maintainer needs to evaluate this issue. |
| needs-info | `needs-info` | Waiting on information from the reporter. |
| ready-for-agent | `ready-for-agent` | Issue is fully specified and ready for an AFK agent pick-up. |
| ready-for-human | `ready-for-human` | Issue needs human implementation/coding. |
| wontfix | `wontfix` | The issue is deliberately marked as not actionable. |

## Custom Label Mapping
You can map custom labels to these canonical roles for better alignment with your specific repository naming conventions.
For example, if you use a label `bug:needs-triage`, the skill will treat it identically to the canonical `needs-triage`.

**Configuration Example:**
```yaml
# Configuration for mapping custom labels to canonical labels
label_mapping:
  "bug:needs-triage": "needs-triage"
  "needs_info": "needs-info"
```
If no custom mappings are provided, the skill uses the default string names listed above.