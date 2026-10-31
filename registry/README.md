# registry/ — Kafka schema registry store

Git is the schema registry's persistent store; Apicurio is a rebuildable
cache ([ADR 0003](../docs/adr/0003-kafka-schema-registry.md), 2026-10-31
notes; TD-18).

## Layout

One file per producer service, named after its `services/<name>` repo:

```
registry/<producer-service>/registry.json
```

Only producers own artifacts. A consumer-only service (notification-service)
or one with no events (inventory-service) has no file.

## Format

```json
{
  "producer": "order-service",
  "groupId": "gluon",
  "artifacts": [
    {
      "artifactId": "order-events-OrderCancelled",
      "artifactType": "JSON",
      "rules": { "COMPATIBILITY": "BACKWARD_TRANSITIVE" },
      "versions": [
        { "version": "1", "schema": { "$schema": "http://json-schema.org/draft-07/schema#", "...": "..." } }
      ]
    }
  ]
}
```

- `artifactId` is `<topic>-<eventType>`, in the shared `gluon` group.
- `versions` are every registered version, oldest first; `schema` is the
  JSON Schema as JSON (not an escaped string), so diffs show field changes.
- No timestamps or registry ids: an unchanged registry re-exports with no diff.
- The producer comes from the `producer` label purekafka (0.5.0+) sets when a
  producer build runs `schemaRegistryCheck`.

## Loop

1. Change an event in the producer service; its `sbt schemaRegistryCheck`
   registers the new version in the local registry (and fails on an
   incompatible change). Consumers' checks dry-run their mirrors against it.
2. `bin/registry-export` — rewrites the producer's `registry.json`.
3. Commit it in gluon, alongside the service change.

`bin/registry-restore` replays this directory into an empty registry. It runs
automatically in the local registry's restore sidecar (after any OrbStack or
pod restart) and in every Kafka service's CI before `schemaRegistryCheck`,
so CI checks against the real baseline. Export refuses to drop committed
versions (e.g. after a wipe); restore first, or `--force` deliberately.
