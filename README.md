# 🧰 ClickHouse Ops Playbook

Field-tested ClickHouse operations guide — practical SQLs, scripts, and runbooks for keeping clusters healthy in production.

This repository collects real-world troubleshooting patterns, scripts, and observability queries for managing ClickHouse at scale — from readonly recovery to detached parts cleanup, background merge tuning, and compression verification.

---
```
## 📁 Repository Structure
clickhouse-ops-playbook/
├── README.md
├── troubleshooting/
│   ├── readonly-mode.md
│   ├── detached-parts.md
│   ├── background-merges.md
│   └── compression-checks.md
├── scripts/
│   ├── check_detached_parts.sql
│   ├── fix_readonly.sh
│   └── compression_verification.sql
└── observability/
├── newrelic_alerts.md
├── metrics.md
└── dashboards/
```
---

## 🚀 Quick Start

Clone or reference the playbook for your ClickHouse clusters:

```bash
git clone https://github.com/sjksingh/clickhouse-ops-playbook.git
cd clickhouse-ops-playbook
