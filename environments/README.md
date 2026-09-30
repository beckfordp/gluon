# environments/

Per-environment configuration — `local/`, `dev/`, `staging/`, `prod/` —
values/overrides for the Helm charts in `../infra/k8s/` (image tags, replica
counts, resource limits, feature flags). **No secrets committed here** —
these hold structure and references (e.g. an AWS Secrets Manager / SSM
Parameter Store key name), never the actual secret values.

Not yet populated — first content lands alongside `infra/k8s/`, once there's
a chart for it to parameterize.
