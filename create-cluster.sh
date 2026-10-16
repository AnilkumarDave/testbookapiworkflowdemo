#!/bin/bash

# ============================================================
# Testbook API - Fully Automated EKS Rebuild
#
# Cluster : testbook-cluster
# Region  : eu-north-1
# Nodes   : 2 x t3.small
#
# WARNING:
# Automatically deletes and recreates this demo cluster.
# No confirmation prompts.
# Do not use for production infrastructure.
# ============================================================

set -Eeuo pipefail
export AWS_PAGER=""

CLUSTER="testbook-cluster"
REGION="eu-north-1"
NODEGROUP="demo-workers"
NODE_TYPE="t3.small"
NODES=2
ECR_REPO="testbook-api"

STACK_PREFIX="eksctl-${CLUSTER}-"
CLUSTER_STACK="${STACK_PREFIX}cluster"

START_TIME=$(date +%s)

finish() {
    CODE=$?
    END_TIME=$(date +%s)
    TOTAL=$((END_TIME - START_TIME))

    echo ""
    echo "=============================================="
    echo "Total time: $((TOTAL / 60))m $((TOTAL % 60))s"

    if [ "$CODE" -eq 0 ]; then
        echo "RESULT: SUCCESS"
    else
        echo "RESULT: FAILED"
        echo "Check AWS for remaining chargeable resources."
    fi

    echo "=============================================="
}

trap finish EXIT

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

# ------------------------------------------------------------
# Helper: Get active CloudFormation stacks for this cluster
# ------------------------------------------------------------

get_stacks() {
    aws cloudformation list-stacks \
        --region "$REGION" \
        --query "StackSummaries[?starts_with(StackName, '${STACK_PREFIX}') && StackStatus!='DELETE_COMPLETE'].StackName" \
        --output text
}

get_stack_status() {
    local STACK="$1"

    aws cloudformation describe-stacks \
        --stack-name "$STACK" \
        --region "$REGION" \
        --query 'Stacks[0].StackStatus' \
        --output text
}

# ------------------------------------------------------------
# Helper: Delete CloudFormation stack
# ------------------------------------------------------------

delete_stack() {
    local STACK="$1"
    local STATUS

    STATUS=$(get_stack_status "$STACK") ||
        fail "Cannot inspect stack $STACK."

    echo "Cleaning stack: $STACK"
    echo "Current status: $STATUS"

    if [ "$STATUS" = "DELETE_IN_PROGRESS" ]; then
        echo "Deletion already running."

    elif [ "$STATUS" = "DELETE_FAILED" ]; then
        echo "Using force deletion..."

        aws cloudformation delete-stack \
            --stack-name "$STACK" \
            --region "$REGION" \
            --deletion-mode FORCE_DELETE_STACK ||
            fail "Force deletion failed: $STACK"

    else
        echo "Requesting normal deletion..."

        aws cloudformation delete-stack \
            --stack-name "$STACK" \
            --region "$REGION" ||
            fail "Deletion request failed: $STACK"
    fi

    echo "Waiting for stack deletion..."

    if ! aws cloudformation wait stack-delete-complete \
        --stack-name "$STACK" \
        --region "$REGION"; then

        STATUS=$(get_stack_status "$STACK") ||
            fail "Cannot inspect failed deletion."

        if [ "$STATUS" = "DELETE_FAILED" ]; then
            echo "Normal deletion failed. Retrying force deletion..."

            aws cloudformation delete-stack \
                --stack-name "$STACK" \
                --region "$REGION" \
                --deletion-mode FORCE_DELETE_STACK ||
                fail "Force deletion request failed."

            aws cloudformation wait stack-delete-complete \
                --stack-name "$STACK" \
                --region "$REGION" ||
                fail "Force deletion did not complete."
        else
            fail "Stack deletion did not complete: $STATUS"
        fi
    fi

    echo "Stack cleanup completed: $STACK"
}

# ------------------------------------------------------------
# STEP 1: Check required tools
# ------------------------------------------------------------

echo "=============================================="
echo " Testbook API - Automated EKS Rebuild"
echo "=============================================="

echo ""
echo "STEP 1: Checking tools..."

for TOOL in aws eksctl kubectl; do
    command -v "$TOOL" >/dev/null 2>&1 ||
        fail "$TOOL is not installed."

    echo "OK: $TOOL"
done

# ------------------------------------------------------------
# STEP 2: Check AWS login
# ------------------------------------------------------------

echo ""
echo "STEP 2: Checking AWS authentication..."

aws sts get-caller-identity ||
    fail "AWS authentication failed."

# ------------------------------------------------------------
# STEP 3: Delete existing EKS cluster
# ------------------------------------------------------------

echo ""
echo "STEP 3: Checking existing EKS cluster..."

CLUSTERS=$(aws eks list-clusters \
    --region "$REGION" \
    --query 'clusters' \
    --output text) ||
    fail "Cannot list EKS clusters."

if printf '%s\n' "$CLUSTERS" |
    tr '\t' '\n' |
    grep -Fxq "$CLUSTER"; then

    echo "Existing cluster found."
    echo "Deleting existing cluster..."

    if ! eksctl delete cluster \
        --name "$CLUSTER" \
        --region "$REGION" \
        --disable-nodegroup-eviction \
        --wait; then

        echo "eksctl deletion incomplete."
        echo "Continuing to CloudFormation cleanup."
    fi

else
    echo "No existing EKS cluster."
fi

# ------------------------------------------------------------
# STEP 4: Delete leftover node group stacks
# ------------------------------------------------------------

echo ""
echo "STEP 4: Cleaning old node group stacks..."

STACKS=$(get_stacks) ||
    fail "Cannot list CloudFormation stacks."

for STACK in $STACKS; do
    if [ "$STACK" != "$CLUSTER_STACK" ]; then
        delete_stack "$STACK"
    fi
done

# ------------------------------------------------------------
# STEP 5: Delete cluster CloudFormation stack
# ------------------------------------------------------------

echo ""
echo "STEP 5: Cleaning old cluster stack..."

STACKS=$(get_stacks) ||
    fail "Cannot inspect remaining stacks."

for STACK in $STACKS; do
    if [ "$STACK" = "$CLUSTER_STACK" ]; then
        delete_stack "$STACK"
    fi
done

# ------------------------------------------------------------
# STEP 6: Verify old infrastructure records are gone
# ------------------------------------------------------------

echo ""
echo "STEP 6: Verifying cleanup..."

REMAINING=$(get_stacks) ||
    fail "Cannot verify CloudFormation cleanup."

if [ -n "$REMAINING" ] && [ "$REMAINING" != "None" ]; then
    echo "$REMAINING"
    fail "Some old stacks still exist."
fi

CLUSTERS=$(aws eks list-clusters \
    --region "$REGION" \
    --query 'clusters' \
    --output text) ||
    fail "Cannot verify EKS cleanup."

if printf '%s\n' "$CLUSTERS" |
    tr '\t' '\n' |
    grep -Fxq "$CLUSTER"; then
    fail "Old EKS cluster still exists."
fi

echo "Old EKS and CloudFormation stack records removed."
echo "Note: Force-deleted stacks may leave retained resources."

# ------------------------------------------------------------
# STEP 7: Create new EKS cluster
# ------------------------------------------------------------

echo ""
echo "STEP 7: Creating fresh EKS cluster..."
echo "This can take 15-30 minutes or longer."

eksctl create cluster \
    --name "$CLUSTER" \
    --region "$REGION" \
    --nodegroup-name "$NODEGROUP" \
    --node-type "$NODE_TYPE" \
    --nodes "$NODES" \
    --nodes-min "$NODES" \
    --nodes-max "$NODES" \
    --managed ||
    fail "EKS cluster creation failed."

# ------------------------------------------------------------
# STEP 8: Configure kubectl
# ------------------------------------------------------------

echo ""
echo "STEP 8: Configuring kubectl..."

aws eks update-kubeconfig \
    --name "$CLUSTER" \
    --region "$REGION" ||
    fail "kubectl configuration failed."

# ------------------------------------------------------------
# STEP 9: Wait for worker nodes
# ------------------------------------------------------------

echo ""
echo "STEP 9: Waiting for worker nodes..."

REGISTERED=0

for ATTEMPT in $(seq 1 60); do

    REGISTERED=$(kubectl get nodes \
        --no-headers 2>/dev/null |
        wc -l | tr -d ' ')

    echo "Registered nodes: $REGISTERED/$NODES"

    if [ "$REGISTERED" -ge "$NODES" ]; then
        break
    fi

    sleep 10
done

[ "$REGISTERED" -ge "$NODES" ] ||
    fail "Worker nodes did not register."

kubectl wait \
    --for=condition=Ready \
    nodes \
    --all \
    --timeout=15m ||
    fail "Worker nodes did not become Ready."

kubectl get nodes -o wide

READY=$(kubectl get nodes --no-headers |
    awk '$2=="Ready" {n++} END {print n+0}')

[ "$READY" -eq "$NODES" ] ||
    fail "Expected $NODES Ready nodes, found $READY."

# ------------------------------------------------------------
# STEP 10: Verify Kubernetes system components
# ------------------------------------------------------------

echo ""
echo "STEP 10: Checking Kubernetes system pods..."

kubectl rollout status \
    daemonset/aws-node \
    -n kube-system \
    --timeout=10m ||
    fail "AWS networking component not ready."

kubectl rollout status \
    daemonset/kube-proxy \
    -n kube-system \
    --timeout=10m ||
    fail "Kube-proxy not ready."

kubectl rollout status \
    deployment/coredns \
    -n kube-system \
    --timeout=10m ||
    fail "CoreDNS not ready."

kubectl get pods -n kube-system

# ------------------------------------------------------------
# STEP 11: Create ECR repository if missing
# ------------------------------------------------------------

echo ""
echo "STEP 11: Checking ECR repository..."

REPOSITORIES=$(aws ecr describe-repositories \
    --region "$REGION" \
    --query 'repositories[].repositoryName' \
    --output text) ||
    fail "Cannot list ECR repositories."

if ! printf '%s\n' "$REPOSITORIES" |
    tr '\t' '\n' |
    grep -Fxq "$ECR_REPO"; then

    aws ecr create-repository \
        --repository-name "$ECR_REPO" \
        --region "$REGION" \
        --image-scanning-configuration scanOnPush=true ||
        fail "ECR repository creation failed."
fi

ECR_URL=$(aws ecr describe-repositories \
    --repository-names "$ECR_REPO" \
    --region "$REGION" \
    --query 'repositories[0].repositoryUri' \
    --output text)

# ------------------------------------------------------------
# STEP 12: Final summary
# ------------------------------------------------------------

echo ""
echo "=============================================="
echo " EKS CLUSTER CREATED SUCCESSFULLY"
echo "=============================================="

aws eks describe-cluster \
    --name "$CLUSTER" \
    --region "$REGION" \
    --query 'cluster.{Name:name,Status:status,Version:version}' \
    --output table

echo "Ready nodes: $READY"
echo "ECR URL: $ECR_URL"
echo ""
echo "Testbook API infrastructure is ready."
echo "=============================================="
