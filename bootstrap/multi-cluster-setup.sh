#!/bin/bash
# Multi-Cluster CKA Lab Setup Script for Lab1830

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Configuration
PI_IP="192.168.4.254"
PI_USER="admin"
MAIN_CLUSTER_NAME="homelab"
EDGE_CLUSTER_NAME="edge"
BACKUP_DIR="${HOME}/multi-cluster-backups"

print_header() {
    echo -e "${PURPLE}============================================${NC}"
    echo -e "${PURPLE}Lab1830 Multi-Cluster CKA Setup${NC}"
    echo -e "${PURPLE}============================================${NC}"
    echo
}

print_step() {
    echo -e "${GREEN}[STEP]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
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

# Prerequisites check
check_prerequisites() {
    print_step "Checking prerequisites..."
    
    # Check Pi connectivity
    if ! ping -c 1 $PI_IP &>/dev/null; then
        print_error "Cannot reach Raspberry Pi at $PI_IP"
        exit 1
    fi
    
    # Check SSH access
    if ! ssh -o ConnectTimeout=5 $PI_USER@$PI_IP "echo 'SSH OK'" &>/dev/null; then
        print_error "Cannot SSH to Pi as $PI_USER@$PI_IP"
        echo "Make sure you can: ssh $PI_USER@$PI_IP"
        exit 1
    fi
    
    # Check kubectl access to main cluster
    if ! kubectl cluster-info &>/dev/null; then
        print_error "Cannot connect to main Kubernetes cluster"
        exit 1
    fi
    
    print_success "Prerequisites check passed"
}

# Clean up any existing k3s installation
cleanup_existing_k3s() {
    print_step "Cleaning up any existing k3s installation..."
    
    ssh $PI_USER@$PI_IP << 'CLEANUP_EOF'
# Check if k3s is installed
if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
    echo "Removing existing k3s installation..."
    sudo /usr/local/bin/k3s-uninstall.sh || true
    sleep 5
fi

# Clean up any remaining files
sudo rm -rf /var/lib/rancher/k3s || true
sudo rm -rf /etc/rancher/k3s || true
sudo rm -rf /var/lib/cni || true
sudo rm -rf /opt/cni || true
sudo rm -rf /etc/cni || true

# Clean up network interfaces
sudo ip link delete flannel.1 2>/dev/null || true
sudo ip link delete cni0 2>/dev/null || true

echo "Cleanup completed"
CLEANUP_EOF
    
    print_success "Existing k3s cleaned up"
}

# Setup edge cluster on Pi
setup_edge_cluster() {
    print_step "Setting up edge cluster on Raspberry Pi..."
    
    # Install k3s on Pi with proper configuration
    print_info "Installing k3s on Pi..."
    ssh $PI_USER@$PI_IP << 'INSTALL_EOF'
# Install k3s with specific configuration for CKA practice
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 0644 \
  --cluster-init \
  --node-name edge-control" sh -

# Wait for k3s to be ready
echo "Waiting for k3s to start..."
sleep 30

# Check if k3s is running
if sudo systemctl is-active --quiet k3s; then
    echo "k3s service is running"
else
    echo "k3s service failed to start, checking logs..."
    sudo systemctl status k3s
    sudo journalctl -u k3s --no-pager -l
    exit 1
fi

# Wait for API server to be ready
attempts=0
while ! sudo k3s kubectl get nodes &>/dev/null && [ $attempts -lt 12 ]; do
    echo "Waiting for API server... ($attempts/12)"
    sleep 10
    ((attempts++))
done

if [ $attempts -eq 12 ]; then
    echo "API server not ready after 2 minutes"
    sudo systemctl status k3s
    exit 1
fi

# Verify installation
echo "k3s installation verification:"
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A
INSTALL_EOF
    
    if [ $? -eq 0 ]; then
        print_success "k3s installed successfully on Pi"
    else
        print_error "Failed to install k3s on Pi"
        exit 1
    fi
}

# Configure kubectl contexts
setup_kubectl_contexts() {
    print_step "Configuring kubectl contexts..."
    
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    
    # Backup current kubeconfig
    if [ -f ~/.kube/config ]; then
        cp ~/.kube/config "$BACKUP_DIR/kubeconfig-backup-$(date +%Y%m%d-%H%M%S)"
        print_info "Backed up existing kubeconfig"
    fi
    
    # Get edge cluster kubeconfig
    print_info "Retrieving edge cluster kubeconfig..."
    scp $PI_USER@$PI_IP:/etc/rancher/k3s/k3s.yaml /tmp/edge-kubeconfig.yaml
    
    # Modify edge kubeconfig to use Pi IP
    perl -i -pe "s/127\.0\.0\.1:6443/$PI_IP:6443/g" /tmp/edge-kubeconfig.yaml
    perl -i -pe 's/name: default/name: edge/g' /tmp/edge-kubeconfig.yaml
    perl -i -pe 's/cluster: default/cluster: edge/g' /tmp/edge-kubeconfig.yaml
    perl -i -pe 's/current-context: default/current-context: edge/g' /tmp/edge-kubeconfig.yaml
    
    # Rename main cluster context if it's 'default'
    if kubectl config get-contexts | grep -q "default"; then
        kubectl config rename-context default $MAIN_CLUSTER_NAME 2>/dev/null || true
    fi
    
    # Merge kubeconfigs
    export KUBECONFIG=~/.kube/config:/tmp/edge-kubeconfig.yaml
    kubectl config view --flatten > /tmp/merged-config.yaml
    mv /tmp/merged-config.yaml ~/.kube/config
    
    # Set current context to main cluster
    kubectl config use-context $MAIN_CLUSTER_NAME
    
    print_success "kubectl contexts configured successfully"
}

# Verify multi-cluster setup
verify_setup() {
    print_step "Verifying multi-cluster setup..."
    
    # Test main cluster
    print_info "Testing main cluster..."
    kubectl config use-context $MAIN_CLUSTER_NAME
    if kubectl get nodes &>/dev/null; then
        local main_nodes=$(kubectl get nodes --no-headers | wc -l)
        print_success "Main cluster: $main_nodes nodes ready"
    else
        print_error "Main cluster not accessible"
        return 1
    fi
    
    # Test edge cluster
    print_info "Testing edge cluster..."
    kubectl config use-context $EDGE_CLUSTER_NAME
    if kubectl get nodes &>/dev/null; then
        local edge_nodes=$(kubectl get nodes --no-headers | wc -l)
        print_success "Edge cluster: $edge_nodes nodes ready"
    else
        print_error "Edge cluster not accessible"
        return 1
    fi
    
    print_success "Multi-cluster setup verified!"
}

# Create practice namespaces on edge cluster
setup_edge_namespaces() {
    print_step "Creating practice namespaces on edge cluster..."
    
    kubectl config use-context $EDGE_CLUSTER_NAME
    
    # Create CKA practice namespaces
    local namespaces=("cka-test" "cka-staging" "cka-prod" "cka-monitoring")
    
    for ns in "${namespaces[@]}"; do
        kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -
        print_info "Created namespace: $ns"
    done
    
    print_success "Practice namespaces created on edge cluster"
}

# Display usage instructions
display_usage() {
    echo
    print_header
    echo -e "${GREEN}Multi-cluster setup complete!${NC}"
    echo
    echo -e "${BLUE}Quick Reference:${NC}"
    echo
    echo -e "${YELLOW}Switch between clusters:${NC}"
    echo "  kubectl config use-context $MAIN_CLUSTER_NAME    # Your production homelab"
    echo "  kubectl config use-context $EDGE_CLUSTER_NAME           # Raspberry Pi cluster"
    echo
    echo -e "${YELLOW}Check current context:${NC}"
    echo "  kubectl config current-context"
    echo
    echo -e "${YELLOW}View all contexts:${NC}"
    echo "  kubectl config get-contexts"
    echo
    echo -e "${BLUE}Test Edge Cluster:${NC}"
    echo "  kubectl config use-context $EDGE_CLUSTER_NAME"
    echo "  kubectl get nodes -o wide"
    echo
    echo -e "${BLUE}Next Steps:${NC}"
    echo "  1. Test edge cluster: kubectl config use-context $EDGE_CLUSTER_NAME"
    echo "  2. Deploy DNS service on edge cluster"
    echo "  3. Start CKA practice!"
    echo
    print_success "Ready for DNS deployment and CKA practice!"
}

# Main execution function
main() {
    print_header
    
    print_info "This script will set up a multi-cluster environment"
    print_info "Main cluster: Your existing homelab"
    print_info "Edge cluster: Raspberry Pi (for CKA practice and DNS)"
    echo
    
    read -p "Continue with setup? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Setup cancelled."
        exit 0
    fi
    
    check_prerequisites
    cleanup_existing_k3s
    setup_edge_cluster
    setup_kubectl_contexts
    verify_setup
    setup_edge_namespaces
    display_usage
}

# Run main function
main "$@"
