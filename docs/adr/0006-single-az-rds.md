# ADR-0006: Single-AZ RDS for Both Environments

**Status:** Accepted
**Date:** 2026-06-06
**Relates to:** PETPLAT-22, PETPLAT-25, PETPLAT-27

## Context

AWS RDS supports Multi-AZ deployments, which maintain a synchronous standby replica in a second Availability Zone. Failover to the standby is automatic and typically completes in 60–120 seconds. Multi-AZ roughly doubles the hourly cost of the RDS instance.

The project uses db.t4g.micro, which is eligible for the RDS free tier (750 hrs/month for 12 months). Multi-AZ on db.t4g.micro would consume free tier hours twice as fast (primary + standby both count), effectively ending free tier eligibility immediately.

## Decision

Use **single-AZ deployment** (`multi_az = false`) for both dev and prod environments. This is an explicit trade-off documented here so students understand the production implication.

## Rationale

- **Cost:** Multi-AZ on db.t4g.micro doubles the RDS hourly cost. At $0.028/hr for db.t4g.micro in eu-central-1, Multi-AZ would cost ~$40/month per environment — eliminating the free tier benefit.
- **Free tier alignment:** The RDS free tier covers one db.t4g.micro instance. A second standby does not qualify.
- **Learning environment:** This is a single-student learning project, not a production service. Downtime during AZ failures is acceptable.
- **Already resilient at the application layer:** EKS pods that lose DB connectivity will restart and reconnect via Spring's `spring.datasource.hikari` retry configuration. Short DB unavailability windows are tolerable.

## Consequences

**Positive:**
- Stays within RDS free tier
- Simpler state — no standby replica to manage
- Lower complexity for a learning project

**Negative:**
- **No automatic failover:** If the RDS primary has an AZ failure, the database is unavailable until AWS replaces the instance (can take minutes to hours)
- **No zero-downtime maintenance:** RDS maintenance windows cause brief downtime
- **Not production-grade:** Any real production MySQL deployment handling user data should use Multi-AZ or Aurora with automatic failover

**Migration path:** Enable Multi-AZ by setting `multi_az = true` in the module call and re-applying. Terraform will handle the in-place upgrade (brief downtime during the conversion). For true production use, also upgrade to `db.r7g.large` or larger, enable `deletion_protection = true`, set `skip_final_snapshot = false`, and configure a 30-day backup retention.

**Related:** [ADR-0001](0001-public-subnets.md) makes the same cost-vs-resilience trade-off for networking (public subnets vs private subnets with NAT Gateway). [ADR-0003](0003-shared-rds-instance.md) covers the shared database decision.
