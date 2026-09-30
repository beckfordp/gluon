# infra/terraform/

Provisioning for what sits above Kubernetes — the EKS cluster itself, VPC,
IAM, and the AWS ECR repositories (one per service, named `krypton/<service>`
— see ADR 0004, single AWS account).

Empty until there's an ADR covering cluster/account provisioning — not
assumed or guessed here.
