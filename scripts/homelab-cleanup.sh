#!/bin/bash
# Lab1830 Homelab Cleanup & Health Check Script
# Usage: ./homelab-cleanup.sh [--dry-run] [--full]

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Flags
DRY_RUN=false
FULL_CLEANUP=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) DRY_RUN=true; shift ;;
        --full) FULL_CLEANUP=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Lab1830 Homelab Cleanup & Health Check${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
}

print_section() {
    echo -e "${YELLOW}🔍 $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

execute_command() {
    local cmd="$1"
    local description="$2"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "DRY RUN: $description"
        echo "Command: $cmd"
    else
        echo "Executing: $description"
        eval "$cmd"
    fi
}

# Health checks
check_cluster_health() {
    print_section "Cluster Health Check"
    
    # Check node status
    echo "Node Status:"
    kubectl get nodes -o wide
    
    # Check critical namespaces
    echo -e "\nCritical Namespace Pods:"
    kubectl get pods -n argocd,vault,monitoring,network --no-headers | grep -v Running | head -5 || print_success "All critical pods running"
    
    # Check resource usage
    echo -e "\nTop Resource Consumers:"
    kubectl top pods --all-namespaces --sort-by=memory | head -10
}

# Cleanup functions
cleanup_completed_jobs() {
    print_section "Completed Jobs Cleanup"
    
    # Find completed jobs
    local completed_jobs=$(kubectl get jobs --all-namespaces -o json | jq -r '.items[] | select(.status.conditions[]?.type == "Complete") | "\(.metadata.namespace) \(.metadata.name)"')
    
    if [[ -z "$completed_jobs" ]]; then
        print_success "No completed jobs to clean up"
        return
    fi
    
    echo "Found completed jobs:"
    echo "$completed_jobs"
    
    if [[ "$DRY_RUN" == "false" ]]; then
        echo "$completed_jobs" | while read namespace job; do
            if [[ -n "$namespace" && -n "$job" ]]; then
                kubectl delete job "$job" -n "$namespace"
                print_success "Deleted job $job in $namespace"
            fi
        done
    fi
}

cleanup_failed_pods() {
    print_section "Failed Pods Cleanup"
    
    # Check for failed pods
    local failed_pods=$(kubectl get pods --all-namespaces --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l)
    
    if [[ "$failed_pods" -eq 0 ]]; then
        print_success "No failed pods to clean up"
    else
        echo "Failed pods found:"
        kubectl get pods --all-namespaces --field-selector=status.phase=Failed
        execute_command "kubectl delete pods --all-namespaces --field-selector=status.phase=Failed" "Delete failed pods"
    fi
}

check_loki_memory() {
    print_section "Loki Memory Check"
    
    # Check Loki chunks-cache memory usage (known issue with memory bloat)
    local loki_memory=$(kubectl top pod -n monitoring 2>/dev/null | grep "loki-chunks-cache" | awk '{print $3}' | sed 's/Mi//' || echo "0")
    
    # If not in monitoring namespace, check logging namespace
    if [[ "$loki_memory" == "0" ]]; then
        loki_memory=$(kubectl top pod -n logging 2>/dev/null | grep "loki-chunks-cache" | awk '{print $3}' | sed 's/Mi//' || echo "0")
    fi
    
    if [[ -n "$loki_memory" && "$loki_memory" -gt 500 ]]; then
        print_warning "Loki chunks-cache memory usage high: ${loki_memory}Mi (threshold: 500Mi)"
        if [[ "$FULL_CLEANUP" == "true" ]]; then
            # Try both namespaces for the chunks-cache pod
            if kubectl get pod -n monitoring loki-chunks-cache-0 >/dev/null 2>&1; then
                execute_command "kubectl delete pod -n monitoring loki-chunks-cache-0" "Restart Loki chunks-cache to reset memory"
            elif kubectl get pod -n logging loki-chunks-cache-0 >/dev/null 2>&1; then
                execute_command "kubectl delete pod -n logging loki-chunks-cache-0" "Restart Loki chunks-cache to reset memory"
            else
                print_warning "Could not find loki-chunks-cache pod"
            fi
        else
            echo "Use --full flag to automatically restart Loki chunks-cache"
        fi
    else
        print_success "Loki chunks-cache memory usage normal: ${loki_memory}Mi"
    fi
}

check_vault_status() {
    print_section "Vault Cluster Health"
    
    # Check Vault pod status
    local vault_pods=$(kubectl get pods -n vault --no-headers | grep vault- | wc -l)
    local vault_ready=$(kubectl get pods -n vault --no-headers | grep vault- | grep "1/1" | wc -l)
    
    echo "Vault pods: $vault_ready/$vault_pods ready"
    
    if [[ "$vault_ready" -eq "$vault_pods" && "$vault_pods" -gt 0 ]]; then
        print_success "Vault cluster healthy"
    else
        print_error "Vault pods not ready"
    fi
}

check_dns_health() {
    print_section "DNS Health Check"
    
    # Test AdGuard Home
    if dig @192.168.4.201 google.com +short >/dev/null 2>&1; then
        print_success "AdGuard Home DNS responding"
        
        # Test internal DNS
        if dig @192.168.4.201 argocd.lab1830.com +short | grep -q "192.168.4.200"; then
            print_success "Internal DNS records working"
        else
            print_warning "Internal DNS records may have issues"
        fi
    else
        print_error "AdGuard Home not responding"
    fi
}

generate_summary() {
    print_section "Cleanup Summary"
    
    echo "Cluster overview:"
    kubectl get nodes --no-headers | wc -l | xargs echo "Nodes:"
    kubectl get pods --all-namespaces --no-headers | wc -l | xargs echo "Total pods:"
    kubectl get pvc --all-namespaces --no-headers | wc -l | xargs echo "Total PVCs:"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_warning "DRY RUN mode - no changes were made"
    fi
}

# Main execution
main() {
    print_header
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_warning "Running in DRY RUN mode - no changes will be made"
        echo
    fi
    
    if [[ "$FULL_CLEANUP" == "true" ]]; then
        print_warning "Running FULL cleanup - will perform aggressive cleanup actions"
        echo
    fi
    
    check_cluster_health
    echo
    
    cleanup_completed_jobs
    echo
    
    cleanup_failed_pods
    echo
    
    check_loki_memory
    echo
    
    check_vault_status
    echo
    
    check_dns_health
    echo
    
    generate_summary
    
    print_success "Homelab maintenance complete!"
}

# Run the script
main "$@"
