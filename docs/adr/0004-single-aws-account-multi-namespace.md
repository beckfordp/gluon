# 0004. Single AWS account, per-environment k8s namespaces

## Status
Accepted

## Context
Need to decide the AWS account boundary for dev/staging/prod on EKS. Options
considered: one AWS account with dev/staging/prod as separate k8s namespaces
on shared (or per-env) EKS clusters, vs. a dedicated AWS account per
environment with full account-level isolation.

## Decision
Use **one AWS account**, with dev/staging/prod separated by **k8s namespace**
(and/or separate EKS clusters within the account, per environment, if node
isolation is later needed — not decided here).

## Consequences
- Simpler IAM/account setup and billing — no cross-account role assumption
  needed for CI/CD promotion between environments.
- Weaker blast-radius isolation than separate accounts — a misconfigured IAM
  policy, quota, or compromised credential in one environment can reach
  others more easily; namespace-level RBAC and network policy become the
  primary isolation boundary instead of the account boundary.
- Revisit if compliance requirements or team growth demand stronger
  environment isolation later — not a one-way door, but harder to unwind than
  to have started separate.
