# ADR-0003: Shared RDS Instance for All Domain Services

**Status:** Accepted
**Date:** 2026-06-06
**Relates to:** PETPLAT-22, PETPLAT-24

## Context

Three of the eight microservices (customers, visits, vets) require a MySQL database. The Spring Petclinic Microservices application was designed with a cross-service foreign key: `visits.pet_id` references `pets.id`, which is owned by the customers-service schema. This FK constraint makes true database-per-service isolation architecturally complex without a data-duplication strategy.

Two options were considered:

1. **One RDS instance per service** — three separate db.t4g.micro instances, each with its own `petclinic` database, fully isolated schemas.
2. **One shared RDS instance** — single `petclinic` database, all three service schemas co-located in the same instance.

## Decision

Use a **single shared RDS instance** (`petclinic-dev-mysql`, `petclinic-prod-mysql`) with a single `petclinic` database. Each service owns its own tables within that database. Schema initialization is handled by Spring Boot on first startup with `spring.sql.init.mode=always` and the `mysql` profile.

## Rationale

- **Application design:** The cross-service FK (`visits.pet_id` → `pets.id`) reflects how the upstream application was built. A single DB is the path of least resistance — no API-based data replication or eventual consistency is required.
- **Cost:** Three separate db.t4g.micro instances would consume the RDS free tier 3× faster (750 hrs/month divided by three instances). A single instance maximizes free tier benefit.
- **Operational simplicity:** One endpoint, one secret, one parameter group. Single connection string in K8s ConfigMaps.
- **Schema ownership:** Each service creates its own tables on startup. No shared tables, no shared ORM models — the co-location is only at the storage layer.

## Consequences

**Positive:**
- Matches application architecture (FK constraints work without duplication)
- Single RDS free tier instance covers all three services
- One set of credentials in Secrets Manager (`petclinic/{env}/rds-credentials`)
- Simple initialization: deploy customers-service first (creates `pets`), then visits-service (references `pets`)

**Negative:**
- Not true microservice data isolation — all three service schemas share the same MySQL instance
- A runaway query in one service (e.g., full table scan on `visits`) can starve other services of DB connections
- Schema migrations must be coordinated across service deployments to avoid FK conflicts
- In production at scale, this would be the first architectural constraint to revisit

**Mitigation:** For a learning project, operational simplicity outweighs isolation concerns. Students should understand that production microservices commonly use separate databases with eventual consistency. See [ADR-0006](0006-single-az-rds.md) for the related Single-AZ decision.
