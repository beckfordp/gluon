# infra/docker/

**Shared** local runtime infrastructure — things more than one service needs
at once (Kafka, schema registry, and anything else in that category). Not
per-service Postgres — each generated service already ships its own
`docker-compose.yml` for that (see its own repo under `../../services/`).

Not yet populated. First thing that belongs here: a `docker-compose.yml`
bringing up Kafka + schema registry (ADR 0003) for local multi-service
testing — see `PLAN.md` phase 3 onward, where services start actually
publishing/consuming events.
