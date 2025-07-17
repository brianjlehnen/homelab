#!/bin/bash
# Homelab Disaster Recovery Cleanup Check
# Run after major infrastructure changes

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_section() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_section "1. Checking Failed/Orphaned Pods"
failed_pods=$(kubectl get pods --all-namespaces --field-selector status.phase=Failed --no-headers | wc -l)
completed_pods=$(kubectl get pods --all-namespaces --field-selector status.phase=Succeeded --no-headers | wc -l)
terminating_pods=$(kubectl get pods --all-namespaces --no-headers | grep Terminating | wc -l)

echo "Failed pods: $failed_pods"
echo "Completed pods: $completed_pods"
echo "Terminating pods: $terminating_pods"

if [ $failed_pods -gt 0 ] || [ $completed_pods -gt 0 ] || [ $terminating_pods -gt 0 ]; then
    print_warning "Found orphaned pods to clean up"
    echo "Run: kubectl delete pods --all-namespaces --field-selector status.phase=Failed"
    echo "Run: kubectl delete pods --all-namespaces --field-selector status.phase=Succeeded"
fi

print_section "2. Checking Storage Resources"
unbound_pvcs=$(kubectl get pvc --all-namespaces --no-headers | grep -v Bound | wc -l)
available_pvs=$(kubectl get pv --no-headers | grep Available | wc -l)

echo "Unbound PVCs: $unbound_pvcs"
echo "Available PVs: $available_pvs"

if [ $unbound_pvcs -gt 0 ]; then
    print_warning "Found unbound PVCs:"
    kubectl get pvc --all-namespaces | grep -v Bound
fi

print_section "3. Checking ArgoCD Applications"
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

out_of_sync=$(kubectl get applications -n argocd -o json | jq -r '.items[] | select(.status.sync.status != "Synced") | .metadata.name' | wc -l)
if [ $out_of_sync -gt 0 ]; then
    print_warning "Found out-of-sync applications:"
    kubectl get applications -n argocd -o json | jq -r '.items[] | select(.status.sync.status != "Synced") | .metadata.name'
fi

print_section "4. Checking SOPS Encryption"
sops_secret_exists=$(kubectl get secret sops-age -n argocd --no-headers 2>/dev/null | wc -l)
if [ $sops_secret_exists -eq 0 ]; then
    print_error "SOPS age secret missing in argocd namespace!"
else
    print_success "SOPS age secret exists"
fi

print_section "5. Checking Certificates"
failed_certs=$(kubectl get certificates -A --no-headers | grep -v Ready | wc -l)
echo "Failed certificates: $failed_certs"

if [ $failed_certs -gt 0 ]; then
    print_warning "Found failed certificates:"
    kubectl get certificates -A | grep -v Ready
fi

print_section "6. Checking Network Services"
# AdGuard Home DNS
adguard_ready=$(kubectl get pods -n network -l app=adguard-home --no-headers | grep Running | wc -l)
if [ $adguard_ready -eq 0 ]; then
    print_error "AdGuard Home not running"
else
    print_success "AdGuard Home running"
fi

# Test DNS resolution
if dig @192.168.4.201 argocd.lab1830.com +short > /dev/null 2>&1; then
    print_success "DNS resolution working"
else
    print_error "DNS resolution failed"
fi

print_section "7. Checking Vault Status"
vault_pods=$(kubectl get pods -n vault --no-headers | grep Running | wc -l)
echo "Running Vault pods: $vault_pods"

if [ $vault_pods -gt 0 ]; then
    # Check if vault is sealed
    if kubectl exec -n vault vault-0 -- sh -c 'VAULT_SKIP_VERIFY=true vault status' 2>/dev/null | grep -q "Sealed.*false"; then
        print_success "Vault is unsealed"
    else
        print_warning "Vault may be sealed - check status manually"
    fi
fi

print_section "8. Checking Centralized Logging"
# Test Loki connectivity
if curl -s -f http://192.168.4.250:3100/ready > /dev/null 2>&1; then
    print_success "Loki service responding"
else
    print_error "Loki service not responding"
fi

# Check Loki storage
loki_storage=$(ssh brian@192.168.4.250 "du -sh /data/logs/loki/ 2>/dev/null" | awk '{print $1}' || echo "unknown")
echo "Loki storage usage: $loki_storage"

print_section "9. Checking Resource Distribution"
echo "Node resource usage:"
kubectl top nodes 2>/dev/null || echo "Metrics server not responding"

echo -e "\nPod distribution per node:"
kubectl get pods -o wide --all-namespaces | awk 'NR>1 {print $8}' | grep -E 'k8s-(control|node[12])' | sort | uniq -c

print_section "10. Docker Host Check (titan)"
echo "Checking Docker host connectivity..."
if ssh blehnen@192.168.4.156 "echo 'SSH OK'" > /dev/null 2>&1; then
    print_success "Docker host SSH working"
    
    # Check container status
    container_count=$(ssh blehnen@192.168.4.156 "docker ps --format '{{.Names}}' | wc -l")
    echo "Running containers on titan: $container_count"
    
    # Check Promtail connectivity
    if ssh blehnen@192.168.4.156 "curl -s -f http://192.168.4.250:3100/ready" > /dev/null 2>&1; then
        print_success "Promtail → Loki connectivity working"
    else
        print_warning "Promtail → Loki connectivity issue"
    fi
else
    print_error "Cannot SSH to Docker host"
fi

print_section "Summary & Recommendations"
echo "✅ Key services to verify manually:"
echo "   - ArgoCD: https://argocd.lab1830.com"
echo "   - Grafana: https://grafana.lab1830.com"
echo "   - Vault: https://vault.lab1830.com (check if unsealing needed)"
echo "   - AdGuard: https://adguard.lab1830.com"
echo ""
echo "🔧 Common post-disaster tasks:"
echo "   - kubectl delete pods --all-namespaces --field-selector status.phase=Failed"
echo "   - Unseal Vault if needed (see Vault operations in command library)"
echo "   - Force ArgoCD sync: kubectl patch application <app> -n argocd --type='json' -p='[{\"op\": \"replace\", \"path\": \"/spec/source/targetRevision\", \"value\": \"HEAD\"}]'"
echo "   - Check backup mount: df -h /mnt/nas-backup/"
echo ""
echo "📊 Monitor for 24h:"
echo "   - Pod restart counts: kubectl get pods -A | grep -v Running"
echo "   - Certificate renewal: kubectl get certificates -A"
echo "   - Log ingestion: curl -s http://192.168.4.250:3100/loki/api/v1/label/job/values"