# 0002. Use OrbStack for local Kubernetes, not minikube

## Status
Accepted

## Context
Development is on macOS. Need a local Kubernetes cluster for day-to-day service
development before promoting through dev/staging/prod on EKS. minikube was the
default assumption, but the local-k8s tooling landscape has moved on. Options
considered: minikube (status quo), OrbStack (built-in k8s, macOS-only Docker
Desktop replacement), kind (Kubernetes-in-Docker, lightweight, widely used in CI).

## Decision
Use **OrbStack** for daily local development (fast start/rebuild loop, low
resource use, replaces Docker Desktop too). Use **kind** specifically for
CI-mirroring smoke tests, where matching the actual CI cluster config matters
more than dev-loop speed.

## Consequences
- Faster inner dev loop on macOS than minikube gave.
- OrbStack is macOS-only — not portable to a Linux dev machine if that ever
  changes; kind covers that gap where CI parity matters.
- Two local-cluster tools in play (OrbStack + kind) rather than one; acceptable
  since they serve different purposes (dev speed vs. CI parity).
