# Troubleshooting FAQ — AWS EKS Spring Boot Deployment

## Table of Contents
1. [GitHub Actions & OIDC](#github-actions--oidc)
2. [Docker & ECR](#docker--ecr)
3. [Helm & Kubernetes](#helm--kubernetes)
4. [Database & RDS](#database--rds)
5. [AWS Load Balancer Controller](#aws-load-balancer-controller)
6. [Terraform / OpenTofu](#terraform--opentofu)
7. [General AWS](#general-aws)

---

## GitHub Actions & OIDC

### Credentials could not be loaded
**Error:**
```
Credentials could not be loaded, please check your action inputs:
Could not load credentials from any providers
```
**Cause:** OIDC provider not registered in AWS or `AWS_DEPLOY_ROLE_ARN` secret is missing.

**Fix:**
1. Create the GitHub OIDC provider in AWS:
```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```
2. Add `AWS_DEPLOY_ROLE_ARN` as a repository secret in GitHub.
3. Verify the IAM role trust policy has the correct repo in the `sub` condition:
```json
"token.actions.githubusercontent.com:sub": "repo:<ORG>/<REPO>:*"
```

---

### Not authorized to perform sts:AssumeRoleWithWebIdentity
**Error:**
```
Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity
```
**Cause:** IAM role trust policy has a placeholder value `YOUR_GITHUB_ORG` instead of the actual org name — happens after `tofu destroy` and re-provision.

**Fix:** Update the trust policy:
```bash
aws iam update-assume-role-policy \
  --role-name url-shortener-prod-github-actions-role \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:<ORG>/<REPO>:*"
        }
      }
    }]
  }'
```
**Permanent fix:** Use a Terraform variable for `github_org` with a default value so it's never a placeholder.

---

### Node.js 20 deprecation warning
**Error:**
```
Node.js 20 actions are deprecated...Actions will be forced to run with Node.js 24
```
**Fix:** Add to workflow env:
```yaml
env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true
```

---

### kubectl error — no kubeconfig
**Error:**
```
dial tcp [::1]:8080: connect: connection refused
```
**Cause:** `aws eks update-kubeconfig` step is missing or failed silently.

**Fix:** Ensure this step exists in the workflow before any `kubectl` commands:
```yaml
- name: Update kubeconfig
  run: |
    aws eks update-kubeconfig \
      --name $EKS_CLUSTER \
      --region $AWS_REGION
```

---

### EKS credentials error in GitHub Actions
**Error:**
```
couldn't get current server API group list: the server has asked for the client to provide credentials
```
**Cause:** EKS access entry missing after cluster recreation.

**Fix:**
```bash
aws eks update-cluster-config \
  --name url-shortener-prod-cluster \
  --access-config authenticationMode=API_AND_CONFIG_MAP \
  --region us-east-1

aws eks create-access-entry \
  --cluster-name url-shortener-prod-cluster \
  --principal-arn arn:aws:iam::<ACCOUNT_ID>:role/<GITHUB_ACTIONS_ROLE> \
  --region us-east-1

aws eks associate-access-policy \
  --cluster-name url-shortener-prod-cluster \
  --principal-arn arn:aws:iam::<ACCOUNT_ID>:role/<GITHUB_ACTIONS_ROLE> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster \
  --region us-east-1
```

---

## Docker & ECR

### Spring Boot plugin requires Gradle 8.x
**Error:**
```
Spring Boot plugin requires Gradle 8.x (8.14 or later) or 9.x. The current version is Gradle 8.7
```
**Cause:** Dockerfile base image pins an old Gradle version — `FROM gradle:8.7-jdk21`.

**Fix:** Update the base image in `Dockerfile`:
```dockerfile
FROM gradle:9.4.1-jdk21 AS build
```

---

### COPY target/*.jar not found
**Error:**
```
lstat /app/target: no such file or directory
```
**Cause:** Gradle outputs to `build/libs/` not `target/` (that's Maven).

**Fix:**
```dockerfile
COPY --from=build /app/build/libs/*.jar app.jar
```

---

### ECR Repository not empty on destroy
**Error:**
```
ECR Repository not empty, consider using force_delete
```
**Fix:**
```bash
aws ecr delete-repository \
  --repository-name url-shortener \
  --region us-east-1 \
  --force
```
**Permanent fix:** Add `force_delete = true` to the ECR Terraform resource.

---

## Helm & Kubernetes

### context deadline exceeded
**Error:**
```
release prod failed, and has been uninstalled due to atomic being set: context deadline exceeded
```
**Cause:** Pods are not becoming ready within the timeout — usually a DB connection failure or missing Kubernetes secret.

**Fix:**
1. Add debug step to workflow:
```yaml
- name: Debug failed pods
  if: failure()
  run: |
    kubectl get pods -n $NAMESPACE
    kubectl describe pods -n $NAMESPACE
    kubectl logs -n $NAMESPACE -l app=$HELM_RELEASE-url-shortener --tail=50
```
2. Check pod logs:
```bash
kubectl logs -n prod deployment/prod-url-shortener --previous
```

---

### No resources found in namespace
**Cause:** Helm chart templates failing silently or secret template missing.

**Fix:** Run dry-run to see rendered templates:
```bash
helm upgrade --install prod ./helm/url-shortener \
  --namespace prod \
  --dry-run --debug
```

---

### Namespace stuck deleting
**Cause:** Ingress finalizer not cleaned up when ALB controller was deleted before the ingress.

**Fix:**
```bash
kubectl patch ingress prod-url-shortener -n prod \
  -p '{"metadata":{"finalizers":[]}}' \
  --type=merge

# If still stuck
kubectl get namespace prod -o json | \
  jq '.spec.finalizers = []' | \
  kubectl replace --raw "/api/v1/namespaces/prod/finalize" -f -
```

---

### Deprecated ingress.class annotation
**Warning:**
```
annotation "kubernetes.io/ingress.class" is deprecated
```
**Fix:** Move from annotations to `ingressClassName` in `values.yaml`:
```yaml
ingress:
  ingressClassName: alb    # add this
  annotations: {}          # remove kubernetes.io/ingress.class from here
```
And update `ingress.yaml`:
```yaml
spec:
  {{- if .Values.ingress.ingressClassName }}
  ingressClassName: {{ .Values.ingress.ingressClassName }}
  {{- end }}
```

---

### HPA metrics unavailable
**Error:**
```
unable to fetch metrics from resource metrics API: the server could not find the requested resource (get pods.metrics.k8s.io)
```
**Cause:** Metrics server not installed in the cluster.

**Fix:**
```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

---

### DB password double base64 encoded
**Cause:** Workflow was base64 encoding the password before passing to Helm, and `secret.yaml` was using `data:` which also base64 encodes.

**Fix:**
1. Remove base64 encoding in workflow:
```yaml
--set-string dbPassword=${{ secrets.DB_PASSWORD }}
```
2. Use `stringData` in `secret.yaml`:
```yaml
stringData:
  db-password: {{ .Values.dbPassword | default "" | quote }}
```

---

## Database & RDS

### Connection attempt failed (SQL State 08001)
**Error:**
```
SQL State: 08001 — The connection attempt failed
```
**Cause:** Network connectivity issue — RDS security group not allowing traffic from EKS pods, or wrong DB URL.

**Fix:**
1. Verify EKS node security group is allowed in RDS security group on port 5432.
2. Test connectivity from inside the cluster:
```bash
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id url-shortener-prod/rds/credentials \
  --region us-east-1 \
  --query SecretString --output text)

kubectl run pg-test --image=postgres:16 -n prod --rm -it --restart=Never -- \
  psql "postgresql://$(echo $SECRET | jq -r .username):$(echo $SECRET | jq -r .password)@$(echo $SECRET | jq -r .host):5432/$(echo $SECRET | jq -r .dbname)?sslmode=require" -c "\l"
```
3. After cluster recreation, update the RDS security group with the new EKS security group ID:
```bash
aws ec2 revoke-security-group-ingress \
  --group-id <RDS_SG_ID> \
  --protocol tcp --port 5432 \
  --source-group <OLD_EKS_SG_ID> \
  --region us-east-1

aws ec2 authorize-security-group-ingress \
  --group-id <RDS_SG_ID> \
  --protocol tcp --port 5432 \
  --source-group <NEW_EKS_SG_ID> \
  --region us-east-1
```

---

### Password authentication failed
**Error:**
```
FATAL: password authentication failed for user "appuser"
```
**Cause:** DB_PASSWORD GitHub secret has missing or truncated characters.

**Fix:** Fetch the correct password from Secrets Manager and update the GitHub secret:
```bash
aws secretsmanager get-secret-value \
  --secret-id url-shortener-prod/rds/credentials \
  --region us-east-1 \
  --query SecretString \
  --output text | jq -r .password
```

---

### SSL connection required
**Error:**
```
no pg_hba.conf entry for host... no encryption
```
**Fix:** Add `?sslmode=require` to the DB URL:
```
jdbc:postgresql://<endpoint>:5432/<dbname>?sslmode=require
```

---

## AWS Load Balancer Controller

### Ingress ADDRESS empty
**Cause:** AWS Load Balancer Controller not installed or missing IAM permissions.

**Fix:**
1. Install the controller:
```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=url-shortener-prod-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=us-east-1 \
  --set vpcId=<VPC_ID>
```
2. Create a dedicated IAM role with `AWSLoadBalancerControllerIAMPolicy` attached.
3. Annotate the service account with the role ARN:
```bash
kubectl annotate serviceaccount aws-load-balancer-controller \
  -n kube-system \
  eks.amazonaws.com/role-arn=arn:aws:iam::<ACCOUNT_ID>:role/url-shortener-prod-alb-controller-role \
  --overwrite
```

---

### Webhook no endpoints available
**Error:**
```
failed calling webhook "vingress.elbv2.k8s.aws": no endpoints available for service "aws-load-balancer-webhook-service"
```
**Cause:** ALB controller using wrong IAM role (app IRSA role instead of dedicated ALB controller role).

**Fix:**
1. Create dedicated IAM role for ALB controller.
2. Update service account annotation with the correct role ARN.
3. Restart the controller:
```bash
kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system
```

---

### get credentials: failed to refresh cached credentials
**Cause:** ALB controller service account is using the app IRSA role which lacks ALB permissions.

**Fix:** Create a dedicated IAM role with `AWSLoadBalancerControllerIAMPolicy` and update the service account annotation.

---

## Terraform / OpenTofu

### Inconsistent dependency lock file
**Error:**
```
provider locked version doesn't match the updated version constraints
```
**Fix:**
```bash
tofu init -upgrade
```

---

### Unsupported block type in Helm provider
**Error:**
```
Blocks of type "kubernetes" are not expected here
```
or
```
An argument named "host" is not expected here
```
**Fix:** Use the `kubernetes {}` block syntax for Helm provider v2:
```hcl
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
      command     = "aws"
    }
  }
}
```

---

### ECR not empty on tofu destroy
**Fix:**
```bash
aws ecr delete-repository \
  --repository-name url-shortener \
  --region us-east-1 \
  --force
tofu destroy
```

---

### VPC cannot be deleted — DependencyViolation
**Error:**
```
Network vpc-xxx has some mapped public address(es)
```
or
```
The vpc has dependencies and cannot be deleted
```
**Fix:** Delete leftover ALB security groups and load balancers manually:
```bash
# Delete leftover security groups
aws ec2 delete-security-group --group-id <SG_ID> --region us-east-1

# Delete load balancers
aws elbv2 delete-load-balancer --load-balancer-arn <ALB_ARN> --region us-east-1

# Then retry
tofu destroy
```

---

## General AWS

### EKS cluster authentication mode must be API or API_AND_CONFIG_MAP
**Error:**
```
The cluster's authentication mode must be set to one of [API, API_AND_CONFIG_MAP]
```
**Fix:**
```bash
aws eks update-cluster-config \
  --name url-shortener-prod-cluster \
  --access-config authenticationMode=API_AND_CONFIG_MAP \
  --region us-east-1
```

---

### AccessDeniedException on eks:DescribeCluster
**Error:**
```
User is not authorized to perform: eks:DescribeCluster
```
**Fix:** Attach EKS policies to the GitHub Actions IAM role:
- `AmazonEKSClusterPolicy`
- `AmazonEC2ContainerRegistryPowerUser`

---

### Finding resource values after re-provision
After `tofu destroy` and re-provision, update these GitHub secrets with new values:

```bash
# ECR Registry
aws sts get-caller-identity --query Account --output text
# → <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com

# RDS endpoint
aws rds describe-db-instances \
  --region us-east-1 \
  --query 'DBInstances[*].Endpoint.Address' \
  --output text

# DB credentials
aws secretsmanager get-secret-value \
  --secret-id url-shortener-prod/rds/credentials \
  --region us-east-1 \
  --query SecretString \
  --output text | jq '{username,password,dbname}'

# IRSA role ARN
aws iam get-role \
  --role-name url-shortener-prod-app-irsa-role \
  --query 'Role.Arn' \
  --output text
```

---

## Terraform Backend

### S3 bucket does not exist
**Error:**
```
Failed to get existing workspaces: S3 bucket does not exist
```
**Cause:** S3 state bucket and/or DynamoDB lock table were deleted.

**Fix:**
```bash
# Recreate S3 bucket
aws s3 mb s3://awsdad-url-shortener-tfstate \
  --region us-east-1

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket awsdad-url-shortener-tfstate \
  --versioning-configuration Status=Enabled

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket awsdad-url-shortener-tfstate \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# Recreate DynamoDB lock table
aws dynamodb create-table \
  --table-name awsdad-url-shortener-tflock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1

# Then run init
tofu init
```
**Recommendation:** Never destroy the S3 bucket and DynamoDB table — they cost almost nothing and save this hassle on every re-provision.
