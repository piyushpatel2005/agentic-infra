# Hermes Agent on Oracle Cloud Always Free

Terraform-driven deployment of [Hermes Agent](https://hermes-agent.nousresearch.com/docs/)
on an Oracle Cloud Infrastructure (OCI) **Always Free** Ampere A1 VM, reachable only over
Tailscale, with encrypted backups to OCI Object Storage and an off-cloud GitHub mirror.

See [PLAN.md](PLAN.md) for the full design, decisions, and phased build-out, and
[docs/RUNBOOK.md](docs/RUNBOOK.md) (added in Phase 9) for day-2 operations.

## Status

Being built phase by phase on branches named `phase/NN-<name>`, one merged at a time
(see PLAN.md §5). Do not deploy from a phase branch — only `main` is expected to be
consistent and deployable.

## Repository layout

| Path | Purpose |
|---|---|
| `terraform/` | All infrastructure-as-code (network, compute, storage, IAM, monitoring) |
| `terraform/bootstrap/` | One-time stack that creates the Terraform state backend |
| `scripts/` | Operational scripts run on the VM (backup, restore, provider rotation, MCP OAuth helper, Kanban WIP guard) |
| `systemd/` | Unit files installed on the VM |
| `cron/` | System crontab fragments (e.g. the 4-hourly provider rotation) |
| `docs/` | Runbook and operational documentation |

## Prerequisites

- An OCI tenancy with Always Free resources available in its home region.
- Terraform >= 1.7, the OCI CLI, and `age` installed locally for backup/restore drills.
- A Tailscale account (the dashboard is reachable only via your tailnet).

## Quick start

Not yet available — infrastructure lands in Phases 1–4. This section will be filled in
during Phase 9 once the full stack is deployable end to end.
