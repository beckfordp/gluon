# registry/ — Kafka event contracts, source of truth

Every Kafka event contract in gluon lives here. Each
`registry/<producer-service>/registry.json` holds every event its producer
publishes, with every version and compatibility rule. **If anything else
disagrees with these files, the files win.** That covers
[`system-design.md`](../docs/system-design.md#payload-contracts), a service's
AsyncAPI docs, and a consumer's mirror case class.

Apicurio Registry is a rebuildable cache of these files, not the store
([ADR 0003](../docs/adr/0003-kafka-schema-registry.md), 2026-10-31 notes;
TD-18). `system-design.md` keeps a readable copy of each payload plus the
reasons behind it; keep that copy in step with these files (step 5 below).

The loop:

```
producer case class ──sbt schemaRegistryCheck──▶ Apicurio ──bin/registry-export──▶ registry/ (git)
                                                                                      │
consumer mirror ◀──────────────bin/registry-scala (paste, trim fields)─────────────────┘
       └──sbt schemaRegistryCheck (dry-run against the producer's artifact)
```

## Layout

```
registry/<producer-service>/registry.json
```

- One file per producer, named after its `services/<name>` repo. Only
  producers own artifacts. notification-service (consumer only) and
  inventory-service (no events) have no file.
- Each artifact is `<topic>-<eventType>`, in the shared Apicurio group `gluon`.

## Format

```json
{
  "producer": "payment-service",
  "groupId": "gluon",
  "artifacts": [
    {
      "artifactId": "payment-events-PaymentCaptured",
      "artifactType": "JSON",
      "rules": { "COMPATIBILITY": "BACKWARD_TRANSITIVE" },
      "versions": [
        { "version": "1", "schema": { "$schema": "http://json-schema.org/draft-07/schema#", "...": "..." } }
      ]
    }
  ]
}
```

- `versions` lists every registered version, oldest first. The last one is
  the current contract.
- `schema` is the JSON Schema as JSON, not an escaped string, so a diff shows
  field changes.
- Schemas are draft-07 and closed (`additionalProperties: false`), generated
  by purekafka from the producer's tapir `Schema[T]`. Never edit them by hand.
- Artifacts are sorted, and there are no timestamps or registry ids. An
  unchanged registry re-exports with no diff.
- The envelope (`eventId`, `eventType`, `timestamp`, `source`,
  `correlationId`, `payload`) isn't registered. These schemas describe
  `payload` only; the envelope is specified in `system-design.md`.

## Workflow: changing an event contract

Run these from a local cluster that's up (`bin/k8s-local-up`); the registry
refills itself from these files within about 30s of any restart.

1. **Producer service:** change the payload case class (and its tapir
   `Schema`), then run `sbt schemaRegistryCheck`.
   - A compatible change, such as a new optional field, registers as the
     next version.
   - An incompatible change fails here with a `RuleViolationException`. See
     "Breaking changes" below.
2. **gluon:** run `bin/registry-export`. It rewrites the producer's
   `registry.json` from the local registry.
3. **Check the diff:** `git diff registry/` should show only the new
   version you intended.
4. **Each consumer service:** if it needs the change, regenerate its mirror
   with `bin/registry-scala` (see "Writing a mirror"), then run
   `sbt schemaRegistryCheck`. Consumers never write: they dry-run their
   mirror against the producer's artifact. The check fails if the mirror
   requires a field the producer doesn't send, or a type or enum doesn't
   match. Producer fields a mirror omits are fine.
5. **Update `system-design.md`'s payload contract** for that event to match,
   with the reason for the change.
6. **Commit** the export and the `system-design.md` change together in
   gluon, and push them **before** the service repos. Each service's CI
   restores gluon's `main` before its `schemaRegistryCheck`; if the service
   lands first, CI checks it against the old baseline.

### Adding a new event

The same steps. The producer's first `schemaRegistryCheck` creates the
artifact with its `producer` label and the `BACKWARD_TRANSITIVE` rule.
Consumers that run their check before the producer has registered get a
warning and are skipped, not failed. Add a new payload contract to
`system-design.md` in step 5.

### Breaking changes

`BACKWARD_TRANSITIVE` means each new version must be able to read data
written with every earlier version. Adding a required field, removing a
field, or changing a type fails the check. To make such a change, retire
the event and publish a new event type. That creates a new artifact and a
new history, as TD-15 did when it replaced `OrderStatusChanged` with
`OrderConfirmed`, `OrderPaymentFailed` and `OrderCancelled`.

1. Add the new event type, following the steps above.
2. Once nothing produces or consumes the old one, delete its artifact from
   the local registry (`DELETE .../groups/gluon/artifacts/<id>`).
3. Run `bin/registry-export --force`. `--force` is needed because the old
   artifact's versions are being dropped.
4. In `system-design.md`, mark the old contract **RETIRED** and give the date.

Don't use `--force` for anything else. Export refuses to drop versions
already committed. Without `--force` it only fails if history went missing,
for example after a wipe; run `bin/registry-restore` and export again.

## What runs where

| Where | What | Effect |
|---|---|---|
| Producer build | `sbt schemaRegistryCheck` | Registers the closed schema labelled `producer=<service>`; fails if incompatible |
| Consumer build | `sbt schemaRegistryCheck` | Checks the mirror against the producer's artifact without writing |
| Local cluster | `registry-restore` sidecar on the Apicurio pod | Re-runs `bin/registry-restore` every 30s from a ConfigMap of these files |
| Service CI | Checks out gluon's `registry/`, runs `bin/registry-restore`, then `schemaRegistryCheck` | Checks against the committed baseline |
| gluon | `bin/registry-export` | Writes registry → these files |
| Consumer dev | `bin/registry-scala` | Prints mirror case classes from these files |

The sidecar's ConfigMap is rebuilt by `bin/k8s-local-up`. To load a newly
committed export without a full `k8s-local-up`, run `bin/registry-reload`
(add `--wipe` if the export rewrote an existing version).

## Writing a mirror

`bin/registry-scala` prints Scala case classes for the events you name,
with the producer's `@description`/`@encodedExample` annotations and a
circe/tapir companion, so a consumer's AsyncAPI docs match the producer's.

```
bin/registry-scala PaymentCaptured DispatchConfirmed   # event types or artifact ids
bin/registry-scala --producer payment-service          # all of a producer's events
```

Name only the events the service consumes, paste the output, delete fields
it doesn't need, and run `scalafmt`. Untitled nested objects are named
`<Event><Field>`; rename freely. Unedited output derives back to the exact
registry schema. Nothing checks a pasted mirror stays current, so re-run it
whenever the producer's contract changes (step 4 above).

## Scripts

- `bin/registry-export [--url URL] [--group gluon] [--force] [DIR]`
- `bin/registry-restore [--url URL] [--quiet] [DIR]`. Only creates
  artifacts the registry doesn't have, so it's safe to re-run.
- `bin/registry-scala [--version N] EVENT... | --producer SERVICE`. Prints
  Scala case classes for events; see "Writing a mirror" above.
- `bin/registry-reload [--wipe | --configmap-only]`. Loads these files
  into the local cluster: rebuilds the sidecar's ConfigMap and waits for
  it to sync. `--wipe` then deletes the group's artifacts so the sidecar
  restores them from these files.

`registry-export`, `registry-restore` and `registry-scala` are Python 3
stdlib only. The scripts that talk to a registry default to the
gluon-local in-cluster one, or `$SCHEMA_REGISTRY_URL` if set.

## Browsing in the UI

Local cluster UI: http://apicurio-registry-ui.gluon-local.svc.cluster.local:8080/

To view a schema's JSON:

1. **Explore** → click the artifact (e.g. `order-events-OrderConfirmed`).
2. **Versions** tab → click a version (or "latest").
3. **Content** tab shows the JSON Schema (JSON/YAML toggle).
   **Documentation** tab shows it as a field list.
