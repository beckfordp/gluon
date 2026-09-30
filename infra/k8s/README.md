# infra/k8s/

Helm chart(s)/manifests for running Gluon's services on Kubernetes,
parameterized per environment (see `../../environments/`) rather than
duplicated per environment.

Not yet populated — first candidate content once a service is generated and
ready to deploy: a shared/umbrella chart, or one chart per service reused
across local (OrbStack)/dev/staging/prod with environment-specific
`values.yaml` living in `../../environments/<env>/`.
