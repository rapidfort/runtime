#!/bin/bash

# Kubeadm Installation and Management Script for Ubuntu/RHEL
# Supports single-node and multi-node clusters
# Usage: ./play.sh [command] [options]

# Source common architecture detection
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common-arch.sh" || {
    echo "Error: common-arch.sh not found"
    exit 1
}

set -e

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
MASTER_NODE=""
WORKER_NODES=()
JOIN_CMD_FILE="/tmp/kubeadm-join-command.sh"
POD_NETWORK_CIDR="10.244.0.0/16"
KUBECONFIG_PATH="$HOME/.kube/config"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to detect host IP if RF_LOCAL_REGISTRY not set
detect_host_ip() {
    local host_ip=""
    
    # First try RF_LOCAL_REGISTRY
    if [[ -n "$RF_LOCAL_REGISTRY" ]]; then
        echo "$RF_LOCAL_REGISTRY"
        return
    fi
    
    # Try to get IP from default route
    host_ip=$(ip route get 1.1.1.1 | awk '{print $7; exit}' 2>/dev/null || true)
    
    if [[ -z "$host_ip" ]]; then
        # Fallback to hostname -I
        host_ip=$(hostname -I | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
    fi
    
    if [[ -z "$host_ip" ]]; then
        # Last resort - try to get from network interfaces
        host_ip=$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d'/' -f1 | head -1)
    fi
    
    echo "$host_ip"
}

# Function to show help
show_help() {
    cat << EOF
Kubeadm Installation and Management Script

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    install         Install Kubernetes cluster
    uninstall       Remove Kubernetes cluster
    status          Show cluster status
    deploy-rapidfort Deploy RapidFort Runtime to existing cluster
    help            Show this help message

OPTIONS:
    --master        Specify master node (for multi-node setup)
    --workers       Comma-separated list of worker nodes
    --pod-cidr      Pod network CIDR (default: 10.244.0.0/16)
    --single-node   Setup single-node cluster (default if no workers specified)
    --local-registry Use local registry for RapidFort images
    --image-tag     Tag for RapidFort images (e.g., 3.1.32-dev6)

EXAMPLES:
    # Single-node cluster
    $0 install
    
    # Multi-node cluster
    $0 install --master node1 --workers node2,node3
    
    # Deploy RapidFort Runtime
    $0 deploy-rapidfort
    
    # Deploy RapidFort from local registry
    $0 deploy-rapidfort --local-registry --image-tag 3.1.32-dev6
    
    # Show status
    $0 status
    
    # Uninstall
    $0 uninstall

PREREQUISITES:
    - Supported OS: Ubuntu 20.04/22.04 or RHEL 8/9
    - Root or sudo access
    - Minimum 2 CPUs, 2GB RAM
    - Swap disabled
    - Ports: 6443, 2379-2380, 10250-10252
    - For RapidFort: ~/.rapidfort/credentials file

FEATURES:
    - Automatic OS detection (Ubuntu/RHEL)
    - Container runtime setup (containerd)
    - CNI plugin installation (Calico)
    - Single or multi-node deployment
    - SSH-based multi-node setup
    - RapidFort Runtime deployment support

EOF
}

# Function to detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        log_error "Cannot detect OS. /etc/os-release not found"
        exit 1
    fi
    
    case "$OS" in
        ubuntu)
            if [[ "$OS_VERSION" != "20.04" && "$OS_VERSION" != "22.04" ]]; then
                log_warning "Ubuntu $OS_VERSION is not tested. Proceeding anyway..."
            fi
            ;;
        rhel|centos|rocky|almalinux)
            if [[ "${OS_VERSION%%.*}" -lt 8 ]]; then
                log_error "RHEL/CentOS version 8 or higher required"
                exit 1
            fi
            OS="rhel"  # Treat all RHEL derivatives the same
            ;;
        *)
            log_error "Unsupported OS: $OS"
            exit 1
            ;;
    esac
    
    log_info "Detected OS: $OS $OS_VERSION"
}

# Function to run command on remote node
run_remote() {
    local node=$1
    shift
    ssh -o StrictHostKeyChecking=no "$node" "$@"
}

# Function to check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if running as root or with sudo
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi
    
    # Check CPU count
    local cpu_count=$(nproc)
    if [[ $cpu_count -lt 2 ]]; then
        log_error "Kubernetes requires at least 2 CPUs"
        exit 1
    fi
    
    # Check memory
    local mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    if [[ $mem_total -lt 2097152 ]]; then  # 2GB in KB
        log_error "Kubernetes requires at least 2GB of RAM"
        exit 1
    fi
    
    # Check if swap is disabled
    if [[ $(swapon -s | wc -l) -gt 0 ]]; then
        log_warning "Swap is enabled. Disabling swap..."
        swapoff -a
        sed -i '/ swap / s/^/#/' /etc/fstab
    fi
    
    log_success "Prerequisites check passed"
}

# Function to setup networking
setup_networking() {
    log_info "Configuring network settings..."
    
    # Load required kernel modules
    cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
    
    modprobe overlay
    modprobe br_netfilter
    
    # Setup required sysctl params
    cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    
    sysctl --system
    
    log_success "Network configuration completed"
}

# Function to install container runtime (containerd)
install_container_runtime() {
    log_info "Installing containerd..."
    
    if [[ "$OS" == "ubuntu" ]]; then
        apt-get update
        apt-get install -y apt-transport-https ca-certificates curl software-properties-common
        
        # Add Docker's official GPG key
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
        
        # Add Docker repository
        add-apt-repository "deb [arch=$(get_docker_repo_arch)] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        
        apt-get update
        apt-get install -y containerd.io
    else  # RHEL-based
        yum install -y yum-utils
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        yum install -y containerd.io
    fi
    
    # Configure containerd
    mkdir -p /etc/containerd
    containerd config default | tee /etc/containerd/config.toml
    
    # Update containerd config to use systemd cgroup driver
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    
    systemctl restart containerd
    systemctl enable containerd
    
    log_success "Containerd installed and configured"
}

# Function to install Kubernetes packages
install_kubernetes_packages() {
    log_info "Installing Kubernetes packages..."
    
    local k8s_version="1.29.0"  # Specify version for consistency
    
    if [[ "$OS" == "ubuntu" ]]; then
        # Add Kubernetes apt repository
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list
        
        apt-get update
        apt-get install -y kubelet="${k8s_version}-*" kubeadm="${k8s_version}-*" kubectl="${k8s_version}-*"
        apt-mark hold kubelet kubeadm kubectl
    else  # RHEL-based
        cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
        
        yum install -y kubelet-${k8s_version} kubeadm-${k8s_version} kubectl-${k8s_version} --disableexcludes=kubernetes
    fi
    
    systemctl enable --now kubelet
    
    log_success "Kubernetes packages installed"
}

# Function to initialize master node
init_master() {
    log_info "Initializing Kubernetes master node..."
    
    # Get the primary IP address
    local master_ip=$(hostname -I | awk '{print $1}')
    
    # Initialize cluster
    kubeadm init \
        --pod-network-cidr=$POD_NETWORK_CIDR \
        --apiserver-advertise-address=$master_ip \
        --apiserver-cert-extra-sans=$master_ip
    
    # Setup kubeconfig for root user
    mkdir -p $HOME/.kube
    cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config
    
    # Also setup for regular user if not root
    if [[ -n "$SUDO_USER" ]]; then
        local user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        mkdir -p "$user_home/.kube"
        cp -i /etc/kubernetes/admin.conf "$user_home/.kube/config"
        chown "$SUDO_USER:$SUDO_USER" "$user_home/.kube/config"
    fi
    
    # Save join command
    kubeadm token create --print-join-command > $JOIN_CMD_FILE
    
    log_success "Master node initialized"
}

# Function to install CNI plugin (Calico)
install_cni_plugin() {
    log_info "Installing Calico CNI plugin..."
    
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.0/manifests/tigera-operator.yaml
    
    # Wait for operator to be ready
    kubectl wait --for=condition=available --timeout=300s deployment/tigera-operator -n tigera-operator
    
    # Create Calico configuration
    cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: $POD_NETWORK_CIDR
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
    
    log_success "Calico CNI plugin installed"
}

# Function to setup single-node cluster
setup_single_node() {
    log_info "Setting up single-node cluster..."
    
    # Remove taint from control-plane node to allow pod scheduling
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
    
    log_success "Single-node cluster setup completed"
}

# Function to join worker nodes
join_workers() {
    log_info "Joining worker nodes to cluster..."
    
    if [[ ! -f "$JOIN_CMD_FILE" ]]; then
        log_error "Join command file not found. Initialize master first."
        exit 1
    fi
    
    local join_cmd=$(cat "$JOIN_CMD_FILE")
    
    for worker in "${WORKER_NODES[@]}"; do
        log_info "Setting up worker node: $worker"
        
        # Copy and run this script on worker
        run_remote "$worker" "mkdir -p /tmp/kubeadm-setup"
        scp "$0" "$worker:/tmp/kubeadm-setup/play.sh"
        
        # Install prerequisites on worker
        run_remote "$worker" "cd /tmp/kubeadm-setup && sudo ./play.sh install-prereqs"
        
        # Join cluster
        run_remote "$worker" "sudo $join_cmd"
        
        log_success "Worker $worker joined successfully"
    done
}

# Function to wait for all nodes to be ready
wait_for_nodes() {
    log_info "Waiting for all nodes to be ready..."
    
    local expected_nodes=1
    if [[ ${#WORKER_NODES[@]} -gt 0 ]]; then
        expected_nodes=$((1 + ${#WORKER_NODES[@]}))
    fi
    
    local timeout=300
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        local ready_nodes=$(kubectl get nodes --no-headers | grep " Ready" | wc -l)
        
        if [[ $ready_nodes -eq $expected_nodes ]]; then
            log_success "All $ready_nodes nodes are ready"
            kubectl get nodes
            return 0
        fi
        
        echo -n "."
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    log_error "Timeout waiting for nodes to be ready"
    kubectl get nodes
    return 1
}

# Function to deploy RapidFort Runtime
deploy_rapidfort() {
    log_info "Deploying RapidFort Runtime to kubeadm cluster"
    
    # Check if cluster is running
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Kubernetes cluster is not running. Install kubeadm first with: $0 install"
        exit 1
    fi
    
    # Check if helm is installed
    if ! command -v helm &> /dev/null; then
        log_error "Helm is not installed. Please install helm first."
        log_info "Visit: https://helm.sh/docs/intro/install/"
        exit 1
    fi
    
    # Check prerequisites
    if [[ ! -f "$HOME/.rapidfort/credentials" ]]; then
        log_error "RapidFort credentials not found at ~/.rapidfort/credentials"
        exit 1
    fi
    
    # Get registry IP
    local registry_ip=$(detect_host_ip)
    if [[ -z "$registry_ip" ]]; then
        log_error "Could not determine host IP address. Please set RF_LOCAL_REGISTRY"
        exit 1
    fi
    log_info "Using registry IP: $registry_ip"
    
    # Parse credentials
    local creds_file="$HOME/.rapidfort/credentials"
    export RF_ACCESS_ID=$(grep "access_id" "$creds_file" | cut -d'=' -f2 | xargs)
    export RF_SECRET_ACCESS_KEY=$(grep "secret_key" "$creds_file" | cut -d'=' -f2 | xargs)
    export RF_ROOT_URL=$(grep "rf_root_url" "$creds_file" | cut -d'=' -f2 | xargs)
    
    if [[ -z "$RF_ACCESS_ID" ]] || [[ -z "$RF_SECRET_ACCESS_KEY" ]] || [[ -z "$RF_ROOT_URL" ]]; then
        log_error "Invalid or incomplete RapidFort credentials"
        exit 1
    fi
    
    # Create namespace
    kubectl create namespace rapidfort --dry-run=client -o yaml | kubectl apply -f -
    
    # Create credentials secret
    kubectl create secret generic rfruntime-credentials \
        --namespace rapidfort \
        --from-literal=RF_ACCESS_ID="$RF_ACCESS_ID" \
        --from-literal=RF_SECRET_ACCESS_KEY="$RF_SECRET_ACCESS_KEY" \
        --from-literal=RF_ROOT_URL="$RF_ROOT_URL" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Check for local registry option
    local use_local_registry=false
    local runtime_chart="oci://quay.io/rapidfort/runtime"
    local image_tag=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --local-registry)
                use_local_registry=true
                shift
                ;;
            --registry-ip)
                registry_ip="$2"
                shift 2
                ;;
            --image-tag)
                image_tag="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    
    # Apply registry secret if exists
    local registry_secret_path="${HOME}/.rapidfort/rapidfort-registry-secret.yaml"
    if [[ -f "$registry_secret_path" ]]; then
        kubectl apply -f "$registry_secret_path" -n rapidfort
    else
        log_warning "Registry secret not found at: $registry_secret_path"
        if [[ "$use_local_registry" == "false" ]]; then
            log_warning "Registry secret may be required for pulling from quay.io"
        fi
    fi
    
    # Deploy RapidFort Runtime
    log_info "Installing RapidFort Runtime with Helm..."
    
    local helm_args=(
        "upgrade" "--install" "rfruntime"
        "$runtime_chart"
        "--namespace" "rapidfort"
        "--set" "ClusterName=kubeadm"
        "--set" "ClusterCaption=Kubeadm Cluster"
        "--set" "rapidfort.credentialsSecret=rfruntime-credentials"
        "--set" "variant=generic"
        "--set" "scan.enabled=true"
        "--set" "profile.enabled=false"
        "--wait" "--timeout=5m"
    )
    
    # Check if we should use local registry
    if [[ "$use_local_registry" == "true" ]] || [[ "$RF_USE_LOCAL_REGISTRY" == "true" ]]; then
        use_local_registry=true
        log_info "Using local registry for RapidFort Runtime images"
        
        # Override the registry value in values.yaml
        helm_args+=(
            "--set" "registry=$registry_ip:5000/rapidfort"
        )
        
        # If image tag is specified, use it
        if [[ -n "$image_tag" ]]; then
            helm_args+=("--set" "imageTag=$image_tag")
        fi
        
        # Set pull policy to Always for local registry
        helm_args+=("--set" "imagePullPolicy=Always")
        
        log_info "Note: Make sure all RapidFort images are available in local registry:"
        echo "  Images needed (example with tag 3.1.32-dev6):"
        echo "    - $registry_ip:5000/rapidfort/sentry:3.1.32-dev6"
        echo "    - $registry_ip:5000/rapidfort/controller:3.1.32-dev6"
        echo "    - $registry_ip:5000/rapidfort/rfwrap-init:3.1.32-dev6"
        echo "    - $registry_ip:5000/rapidfort/bpf:3.1.32-dev6"
        echo ""
        echo "  To push images (example):"
        echo "    docker pull quay.io/rapidfort/sentry:3.1.32-dev6"
        echo "    docker tag quay.io/rapidfort/sentry:3.1.32-dev6 $registry_ip:5000/rapidfort/sentry:3.1.32-dev6"
        echo "    docker push $registry_ip:5000/rapidfort/sentry:3.1.32-dev6"
        echo ""
        echo "  Helm will use registry: $registry_ip:5000/rapidfort"
        if [[ -n "$image_tag" ]]; then
            echo "  Image tag: $image_tag"
        fi
    else
        # Add imagePullSecrets for quay.io
        if [[ -f "$registry_secret_path" ]]; then
            helm_args+=("--set" "imagePullSecrets.names={rapidfort-registry-secret}")
        fi
    fi
    
    # Execute helm install
    if helm "${helm_args[@]}"; then
        log_success "RapidFort Runtime helm chart installed"
    else
        log_error "Helm installation failed"
        kubectl describe pods -n rapidfort
        exit 1
    fi
    
    # Check deployment
    log_info "Waiting for RapidFort Runtime pods to be ready..."
    if kubectl wait --for=condition=ready pod -l app=rfruntime -n rapidfort --timeout=300s; then
        log_success "RapidFort Runtime deployed successfully"
        echo ""
        kubectl get pods -n rapidfort -o wide
        echo ""
        echo "Commands:"
        echo "  # Check logs: kubectl logs -n rapidfort -l app=rfruntime -c sentry -f"
        echo "  # Check scan results: rfjobs"
        echo "  # Check runtime status: kubectl get pods -n rapidfort"
        echo "  # Check images being used: kubectl describe pods -n rapidfort | grep Image:"
    else
        log_error "RapidFort Runtime deployment failed"
        kubectl describe pods -n rapidfort
        exit 1
    fi
}

# Install only prerequisites (for worker nodes)
install_prereqs() {
    detect_os
    check_prerequisites
    setup_networking
    install_container_runtime
    install_kubernetes_packages
}

# Main installation function
install_cluster() {
    log_info "Starting Kubernetes installation..."
    
    # Run all prerequisite steps
    install_prereqs
    
    # Initialize master
    init_master
    
    # Install CNI plugin
    install_cni_plugin
    
    # Setup based on cluster type
    if [[ ${#WORKER_NODES[@]} -eq 0 ]]; then
        setup_single_node
    else
        join_workers
    fi
    
    # Wait for all nodes
    wait_for_nodes
    
    log_success "Kubernetes cluster installation completed!"
    
    # Show cluster info
    echo ""
    kubectl cluster-info
    echo ""
    kubectl get nodes -o wide
    echo ""
    log_info "To deploy RapidFort Runtime, run: $0 deploy-rapidfort"
}

# Uninstall function
uninstall_cluster() {
    log_info "Uninstalling Kubernetes cluster..."
    
    # Reset kubeadm
    kubeadm reset -f
    
    # Remove Kubernetes packages
    if [[ "$OS" == "ubuntu" ]]; then
        apt-get purge -y kubeadm kubectl kubelet kubernetes-cni
        apt-get autoremove -y
    else
        yum remove -y kubeadm kubectl kubelet kubernetes-cni
    fi
    
    # Clean up directories
    rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni /opt/cni
    rm -rf $HOME/.kube
    
    # Clean up iptables
    iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
    
    log_success "Kubernetes cluster uninstalled"
}

# Show status function
show_status() {
    log_info "Kubernetes Cluster Status"
    echo "========================="
    
    if ! command -v kubectl &> /dev/null; then
        log_warning "kubectl not found. Kubernetes may not be installed."
        return
    fi
    
    if ! kubectl cluster-info &> /dev/null 2>&1; then
        log_warning "Cannot connect to Kubernetes cluster"
        return
    fi
    
    kubectl cluster-info
    echo ""
    kubectl get nodes -o wide
    echo ""
    kubectl get pods --all-namespaces | head -20
    echo ""
    
    # Check RapidFort Runtime if deployed
    if kubectl get namespace rapidfort &>/dev/null 2>&1; then
        log_info "RapidFort Runtime Status:"
        kubectl get pods -n rapidfort
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --master)
                MASTER_NODE="$2"
                shift 2
                ;;
            --workers)
                IFS=',' read -ra WORKER_NODES <<< "$2"
                shift 2
                ;;
            --pod-cidr)
                POD_NETWORK_CIDR="$2"
                shift 2
                ;;
            --single-node)
                WORKER_NODES=()
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
}

# Main function
main() {
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        install)
            parse_args "$@"
            install_cluster
            ;;
        install-prereqs)
            install_prereqs
            ;;
        uninstall)
            uninstall_cluster
            ;;
        status)
            show_status
            ;;
        deploy-rapidfort)
            deploy_rapidfort "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
