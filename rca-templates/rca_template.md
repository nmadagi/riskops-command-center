# Root Cause Analysis (RCA) Template

> **Incident ID:** INC-YYYY-MMDD-NNN  
> **Date:** YYYY-MM-DD  
> **Severity:** P1 / P2 / P3  
> **Author:** [Name]  
> **Review Date:** [48 hours post-incident]

---

## Executive Summary

_[2-3 sentences: What happened, what was the impact, what was the root cause]_

---

## Timeline

| Time (ET) | Event | Source |
|-----------|-------|--------|
| HH:MM | First detection (alert name / monitoring tool) | Splunk / Dynatrace / Manual |
| HH:MM | On-call engineer acknowledged | PagerDuty |
| HH:MM | Investigation started | — |
| HH:MM | Root cause identified | — |
| HH:MM | Mitigation applied | — |
| HH:MM | Service restored | — |
| HH:MM | Monitoring confirmed stable | Splunk / Dynatrace |

**Total duration:** X hours Y minutes  
**Time to detect (TTD):** X minutes  
**Time to mitigate (TTM):** X minutes  
**Time to resolve (TTR):** X hours Y minutes  

---

## Impact Assessment

- **Services affected:** [list]
- **Duration of impact:** X hours Y minutes
- **Transactions affected:** ~N transactions
- **SLA impact:** [breach / within SLA]
- **Client notifications sent:** Yes / No
- **Revenue impact:** $X estimated (if applicable)

---

## Root Cause

### What happened
_[Detailed technical description of the failure]_

### Why it happened (5 Whys)

1. **Why?** [Proximate cause]
2. **Why?** [Contributing factor]
3. **Why?** [Deeper cause]
4. **Why?** [Process/system gap]
5. **Why?** [Root cause]

### Contributing factors
- [Factor 1]
- [Factor 2]

---

## Resolution

_[What was done to fix the issue, step by step]_

---

## Action Items

| # | Action | Owner | Priority | Due Date | Status |
|---|--------|-------|----------|----------|--------|
| 1 | [Preventive action] | [Name] | P1 | YYYY-MM-DD | Open |
| 2 | [Detective improvement] | [Name] | P2 | YYYY-MM-DD | Open |
| 3 | [Process improvement] | [Name] | P2 | YYYY-MM-DD | Open |
| 4 | [Documentation update] | [Name] | P3 | YYYY-MM-DD | Open |

---

## Lessons Learned

### What went well
- [List positives]

### What could be improved
- [List improvements]

### What was lucky
- [Things that could have made it worse but didn't]

---

## Appendix

### Relevant Splunk Queries
```
[SPL queries used during investigation]
```

### Log Excerpts
```
[Key log entries that show the root cause]
```

### Related Incidents
- [Links to similar past incidents]
