#!/bin/bash

# Kubernetes with Docker Runtime (cri-dockerd) Installation Script
# Usage: ./play.sh [install|uninstall|status|help]

# Source common architecture detection
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common-arch.sh" 2>/dev/null || {
    # Fallback if common-arch.sh doesn't exist
    detect_arch() {
        case $(uname -m) in
            x86_64) echo "amd64" ;;
            aarch64|arm64) echo "arm64" ;;
            armv7l) echo "arm" ;;
            *) echo "unknown" ;;
        esac
    }
    ARCH=$(detect_arch)
}

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration
KUBECONFIG_PATH="$HOME/.kube/config"
CLUSTER_NAME="${CLUSTER_NAME:-dockershim}"
REGISTRY_PORT="5000"
K8S_VERSION="${K8S_VERSION:-1.28.2}"
CRI_DOCKERD_VERSION="${CRI_DOCKERD_VERSION:-0.3.8}"
POD_NETWORK_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"

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

# Function to detect host IP
detect_host_ip() {
    local host_ip=""
    
    if [[ -n "$RF_LOCAL_REGISTRY" ]]; then
        echo "$RF_LOCAL_REGISTRY"
        return
    fi
    
    host_ip=$(ip route get 1.1.1.1 | awk '{print $7; exit}' 2>/dev/null || true)
    
    if [[ -z "$host_ip" ]]; then
        host_ip=$(hostname -I | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
    fi
    
    echo "$host_ip"
}

# Function to show help
show_help() {
    cat << EOF
Kubernetes with Docker Runtime (cri-dockerd) Installation Script

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    install         Install Kubernetes with Docker runtime
    uninstall       Remove everything completely
    status          Show cluster and Docker status
    deploy-rapidfort Deploy RapidFort Runtime to existing cluster
    reset           Reset cluster (clean reinstall)
    help            Show this help message

OPTIONS:
    --registry-ip   IP address for registry (optional, defaults to RF_LOCAL_REGISTRY)
    --k8s-version   Kubernetes version (default: $K8S_VERSION)
    --single-node   Configure as single-node cluster (default)
    --local-registry Use local registry for RapidFort images
    --image-tag     Tag for RapidFort images (e.g., 3.1.32-dev6)
    -h, --help      Show this help

EXAMPLES:
    $0 install --registry-ip 192.168.1.100
    $0 install  # Uses RF_LOCAL_REGISTRY
    $0 status
    $0 deploy-rapidfort --local-registry --image-tag 3.1.32-dev6
    $0 uninstall

WHAT IT DOES:
    - Installs Docker and cri-dockerd (dockershim replacement)
    - Sets up Kubernetes using kubeadm with Docker runtime
    - Configures Flannel CNI
    - Creates local Docker registry
    - Optionally deploys RapidFort Runtime

PREREQUISITES:
    - Ubuntu 20.04/22.04 or similar Linux distribution
    - Root/sudo access
    - At least 2 CPU cores and 2GB RAM
    - RF_LOCAL_REGISTRY environment variable (or --registry-ip)

EOF
}

# Function to check system requirements
check_requirements() {
    log_info "Checking system requirements..."

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi

    # Check OS
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS. This script requires a Linux distribution"
        exit 1
    fi

    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]] && [[ "$ID" != "debian" ]]; then
        log_warning "This script is tested on Ubuntu/Debian. Your OS: $ID"
    fi

    # Clean up any broken Docker repository configurations
    if [[ -f /etc/apt/sources.list.d/docker.list ]]; then
        log_info "Cleaning up existing Docker repository configuration..."
        rm -f /etc/apt/sources.list.d/docker.list
        apt-get update 2>/dev/null || true
    fi

    # Check CPU and memory
    local cpu_count=$(nproc)
    local mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local mem_gb=$((mem_kb / 1024 / 1024))

    if [[ $cpu_count -lt 2 ]]; then
        log_warning "System has only $cpu_count CPU(s). Recommended: 2+"
    fi

    if [[ $mem_gb -lt 2 ]]; then
        log_warning "System has only ${mem_gb}GB RAM. Recommended: 2GB+"
    fi

    # Check network
    if ! ip route get 1.1.1.1 &>/dev/null; then
        log_error "No network connectivity detected"
        exit 1
    fi

    log_success "System requirements check passed"
}

# Function to install Docker
install_docker() {
    log_info "Installing Docker..."

    # Check if Docker is already installed and running
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        log_info "Docker is already installed and running"
        docker --version
        
        # Just update the daemon configuration
        log_info "Updating Docker daemon configuration..."
        cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2",
  "insecure-registries": ["$(detect_host_ip):5000"]
}
EOF
        systemctl restart docker
        log_success "Docker configured for cri-dockerd"
        return 0
    fi

    # Remove old versions
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Install prerequisites
    apt-get update
    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    # Detect the actual distribution
    source /etc/os-release
    local distro_id="${ID}"
    local distro_codename="${VERSION_CODENAME}"
    
    # For Debian testing/sid, use bookworm packages
    if [[ "$distro_id" == "debian" ]]; then
        if [[ "$distro_codename" == "trixie" ]] || [[ "$distro_codename" == "sid" ]]; then
            log_warning "Debian $distro_codename detected, using bookworm packages"
            distro_codename="bookworm"
        fi
    fi

    # Add Docker's official GPG key
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${distro_id}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    # Set up repository
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${distro_id} \
        ${distro_codename} stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker
    apt-get update
    
    # Try to install Docker CE
    if ! apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        log_warning "Failed to install docker-ce, trying docker.io package..."
        # Fall back to distribution's Docker package
        apt-get install -y docker.io docker-compose || {
            log_error "Failed to install Docker from any source"
            log_info "You may need to install Docker manually"
            return 1
        }
    fi

    # Start and enable Docker
    systemctl enable docker
    systemctl start docker

    # Configure Docker daemon for cri-dockerd
    cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2",
  "insecure-registries": ["$(detect_host_ip):5000"]
}
EOF

    systemctl restart docker
    
    # Verify Docker is working
    if docker info &>/dev/null; then
        log_success "Docker installed and configured"
        docker --version
    else
        log_error "Docker installation completed but Docker daemon is not running"
        return 1
    fi
}

# Function to install cri-dockerd
install_cri_dockerd() {
    log_info "Installing cri-dockerd (dockershim replacement)..."

    # Download cri-dockerd
    local cri_dockerd_url="https://github.com/Mirantis/cri-dockerd/releases/download/v${CRI_DOCKERD_VERSION}/cri-dockerd-${CRI_DOCKERD_VERSION}.amd64.tgz"
    
    cd /tmp
    wget -q "$cri_dockerd_url" || {
        log_error "Failed to download cri-dockerd"
        exit 1
    }
    
    tar xzf "cri-dockerd-${CRI_DOCKERD_VERSION}.amd64.tgz"
    install -o root -g root -m 0755 cri-dockerd/cri-dockerd /usr/local/bin/cri-dockerd
    
    # Create systemd service files
    cat > /etc/systemd/system/cri-docker.service <<EOF
[Unit]
Description=CRI Docker Interface
After=network.target docker.service
Requires=cri-docker.socket docker.service

[Service]
Type=notify
ExecStart=/usr/local/bin/cri-dockerd --network-plugin=cni --pod-infra-container-image=registry.k8s.io/pause:3.9
ExecReload=/bin/kill -s HUP \$MAINPID
TimeoutSec=0
RestartSec=2
Restart=always
StartLimitBurst=3
StartLimitInterval=60s
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/cri-docker.socket <<EOF
[Unit]
Description=CRI Docker Socket
PartOf=cri-docker.service

[Socket]
ListenStream=/run/cri-dockerd.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF

    # Enable and start cri-dockerd
    systemctl daemon-reload
    systemctl enable cri-docker.service
    systemctl enable cri-docker.socket
    systemctl start cri-docker.socket
    systemctl start cri-docker.service

    # Verify installation
    if systemctl is-active --quiet cri-docker.service; then
        log_success "cri-dockerd installed and running"
    else
        log_error "cri-dockerd installation failed"
        systemctl status cri-docker.service
        exit 1
    fi
}

# Function to install Kubernetes components
install_kubernetes() {
    log_info "Installing Kubernetes components..."

    # Install prerequisites
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl

    # Detect distribution details
    source /etc/os-release
    local distro_id="${ID}"
    local distro_codename="${VERSION_CODENAME}"

    # Add Kubernetes GPG key (new key location for 1.28+)
    if [[ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]]; then
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    fi

    # Add Kubernetes repository
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

    # Update package list
    apt-get update

    # Install specific versions to ensure compatibility
    local kube_version="${K8S_VERSION}-*"
    
    # Try to install the specified version
    if ! apt-get install -y kubelet="${kube_version}" kubeadm="${kube_version}" kubectl="${kube_version}"; then
        log_warning "Failed to install Kubernetes ${K8S_VERSION}, trying latest 1.28.x"
        # Fall back to latest 1.28.x version
        apt-get install -y kubelet kubeadm kubectl || {
            log_error "Failed to install Kubernetes components"
            return 1
        }
    fi

    # Hold packages to prevent accidental upgrades
    apt-mark hold kubelet kubeadm kubectl

    # Configure kubelet to use cri-dockerd
    cat > /etc/default/kubelet <<EOF
KUBELET_EXTRA_ARGS="--container-runtime-endpoint=unix:///run/cri-dockerd.sock --cgroup-driver=systemd"
EOF

    # Enable kubelet
    systemctl enable kubelet

    log_success "Kubernetes components installed"
    kubectl version --client --short 2>/dev/null || kubectl version --client
}

# Function to initialize Kubernetes cluster
init_kubernetes_cluster() {
    log_info "Initializing Kubernetes cluster..."

    local host_ip=$(detect_host_ip)

    # Disable swap
    swapoff -a
    sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

    # Load required kernel modules
    modprobe overlay
    modprobe br_netfilter

    # Set kernel parameters
    cat > /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
    sysctl --system

    # Initialize cluster with kubeadm
    kubeadm init \
        --apiserver-advertise-address="$host_ip" \
        --cri-socket="unix:///run/cri-dockerd.sock" \
        --pod-network-cidr="$POD_NETWORK_CIDR" \
        --service-cidr="$SERVICE_CIDR" \
        --kubernetes-version="v${K8S_VERSION}"

    # Setup kubeconfig for root
    mkdir -p $HOME/.kube
    cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config

    # Setup kubeconfig for regular user if sudo was used
    if [[ -n "$SUDO_USER" ]]; then
        local user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        mkdir -p "$user_home/.kube"
        cp -f /etc/kubernetes/admin.conf "$user_home/.kube/config"
        chown "$SUDO_USER:$SUDO_USER" "$user_home/.kube/config"
    fi

    export KUBECONFIG=/etc/kubernetes/admin.conf

    # For single-node cluster, remove taint
    log_info "Configuring single-node cluster (removing master taint)..."
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
    kubectl taint nodes --all node-role.kubernetes.io/master- 2>/dev/null || true

    log_success "Kubernetes cluster initialized"
}

# Function to install CNI plugin
install_cni() {
    log_info "Installing Flannel CNI plugin..."

    # Apply Flannel
    kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

    # Wait for Flannel to be ready
    log_info "Waiting for CNI to be ready..."
    sleep 10
    kubectl wait --for=condition=ready pod -l app=flannel -n kube-flannel --timeout=300s || {
        log_warning "Flannel is taking longer to start, continuing..."
    }

    log_success "CNI plugin installed"
}

# Function to setup local registry
setup_registry() {
    log_info "Setting up local Docker registry..."

    local registry_ip=$(detect_host_ip)

    # Create registry if not exists
    if ! docker ps | grep -q "local-registry"; then
        docker run -d \
            --restart=always \
            --name local-registry \
            -p 5000:5000 \
            registry:2

        log_success "Local registry created at $registry_ip:5000"
    else
        log_info "Local registry already running"
    fi

    # Create registry config for Kubernetes
    cat > /tmp/registry-config.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "${registry_ip}:5000"
    help: "https://docs.docker.com/registry/"
EOF

    kubectl apply -f /tmp/registry-config.yaml
    rm -f /tmp/registry-config.yaml

    log_success "Registry configuration applied to Kubernetes"
}

# Function to check if cluster is installed
is_cluster_installed() {
    if [[ -f /etc/kubernetes/admin.conf ]] && systemctl is-active --quiet kubelet; then
        return 0
    fi
    return 1
}

# Function to check cluster status
check_cluster_status() {
    if ! is_cluster_installed; then
        return 1
    fi

    export KUBECONFIG=/etc/kubernetes/admin.conf
    
    if kubectl cluster-info &>/dev/null; then
        return 0
    fi
    return 1
}

# Function to show status
show_status() {
    log_info "Dockershim Kubernetes Cluster Status"
    echo "====================================="

    # Check Docker
    if systemctl is-active --quiet docker; then
        log_success "Docker: Running"
        docker version --format "  Version: {{.Server.Version}}"
    else
        log_warning "Docker: Not running"
    fi

    # Check cri-dockerd
    if systemctl is-active --quiet cri-docker; then
        log_success "cri-dockerd: Running"
    else
        log_warning "cri-dockerd: Not running"
    fi

    # Check Kubernetes
    if is_cluster_installed; then
        if check_cluster_status; then
            log_success "Kubernetes: Running"
            
            export KUBECONFIG=/etc/kubernetes/admin.conf
            echo ""
            log_info "Cluster nodes:"
            kubectl get nodes
            
            echo ""
            log_info "System pods:"
            kubectl get pods -n kube-system --no-headers | awk '{print "  " $1 " " $3}'
            
            # Check RapidFort Runtime
            if kubectl get namespace rapidfort &>/dev/null 2>&1; then
                echo ""
                log_info "RapidFort Runtime:"
                local rf_status=$(kubectl get pods -n rapidfort -l app=rfruntime --no-headers 2>/dev/null | grep -c Running || echo 0)
                if [[ "$rf_status" -gt 0 ]]; then
                    log_success "RapidFort: Running ($rf_status pods)"
                    kubectl get pods -n rapidfort --no-headers | awk '{print "  " $1 " " $3}'
                else
                    log_warning "RapidFort: Not running"
                fi
            fi
        else
            log_warning "Kubernetes cluster installed but not accessible"
        fi
    else
        log_warning "Kubernetes: Not installed"
    fi

    # Check registry
    if docker ps | grep -q "local-registry"; then
        log_success "Local Registry: Running at $(detect_host_ip):5000"
    else
        log_warning "Local Registry: Not running"
    fi
}

# Function to deploy RapidFort Runtime
deploy_rapidfort() {
    log_info "Deploying RapidFort Runtime to Dockershim cluster"
    
    # Check if cluster is running
    if ! check_cluster_status; then
        log_error "Kubernetes cluster is not running. Install it first with: $0 install"
        exit 1
    fi
    
    export KUBECONFIG=/etc/kubernetes/admin.conf
    
    # Check if helm is installed
    if ! command -v helm &> /dev/null; then
        log_error "Helm is not installed. Installing..."
        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
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
    fi
    
    # Deploy RapidFort Runtime
    log_info "Installing RapidFort Runtime with Helm..."
    
    local helm_args=(
        "upgrade" "--install" "rfruntime"
        "$runtime_chart"
        "--namespace" "rapidfort"
        "--set" "ClusterName=dockershim"
        "--set" "ClusterCaption=Dockershim Kubernetes Cluster"
        "--set" "rapidfort.credentialsSecret=rfruntime-credentials"
        "--set" "variant=generic"
        "--set" "scan.enabled=true"
        "--set" "profile.enabled=true"
        "--wait" "--timeout=5m"
    )
    
    # Check if we should use local registry
    if [[ "$use_local_registry" == "true" ]] || [[ "$RF_USE_LOCAL_REGISTRY" == "true" ]]; then
        helm_args+=("--set" "registry=$registry_ip:5000/rapidfort")
        if [[ -n "$image_tag" ]]; then
            helm_args+=("--set" "imageTag=$image_tag")
        fi
        helm_args+=("--set" "imagePullPolicy=Always")
    else
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
        kubectl get pods -n rapidfort -o wide
    else
        log_error "RapidFort Runtime deployment failed"
        kubectl describe pods -n rapidfort
        exit 1
    fi
}

# Function to install everything
install_all() {
    local registry_ip="$1"
    
    if [[ -z "$registry_ip" ]]; then
        registry_ip=$(detect_host_ip)
        if [[ -z "$registry_ip" ]]; then
            log_error "Could not determine registry IP. Please set RF_LOCAL_REGISTRY or use --registry-ip"
            exit 1
        fi
    fi
    
    log_info "Installing Dockershim Kubernetes cluster"
    log_info "Registry IP: $registry_ip"
    
    check_requirements
    
    # Check if already installed
    if is_cluster_installed; then
        log_warning "Kubernetes cluster already installed"
        log_info "Run 'uninstall' first or 'reset' to reinstall"
        show_status
        return 1
    fi
    
    # Install components
    install_docker
    install_cri_dockerd
    install_kubernetes
    init_kubernetes_cluster
    install_cni
    setup_registry
    
    # Wait for cluster to be ready
    log_info "Waiting for cluster to be fully ready..."
    sleep 30
    
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
    
    log_success "Installation completed!"
    
    echo ""
    log_info "Cluster Access:"
    echo "  • kubeconfig: /etc/kubernetes/admin.conf"
    echo "  • Registry: $registry_ip:5000"
    echo ""
    log_info "Usage:"
    echo "  # Check status:"
    echo "  $0 status"
    echo ""
    echo "  # Use kubectl:"
    echo "  export KUBECONFIG=/etc/kubernetes/admin.conf"
    echo "  kubectl get nodes"
    echo ""
    echo "  # Push images to registry:"
    echo "  docker tag myimage:latest $registry_ip:5000/myimage:latest"
    echo "  docker push $registry_ip:5000/myimage:latest"
    
    # Deploy RapidFort Runtime if credentials exist
    if [[ -f "$HOME/.rapidfort/credentials" ]] && command -v helm &> /dev/null; then
        log_info "Found RapidFort credentials, deploying RapidFort Runtime..."
        deploy_rapidfort
    else
        if [[ ! -f "$HOME/.rapidfort/credentials" ]]; then
            log_info "RapidFort credentials not found at ~/.rapidfort/credentials"
        fi
        if ! command -v helm &> /dev/null; then
            log_info "Helm not found. Install helm to deploy RapidFort Runtime"
        fi
        log_info "To deploy RapidFort Runtime later, run: $0 deploy-rapidfort"
    fi
}

# Function to uninstall everything
uninstall_all() {
    log_info "Uninstalling Dockershim Kubernetes cluster..."
    
    # Uninstall RapidFort Runtime if present
    if command -v helm &> /dev/null; then
        export KUBECONFIG=/etc/kubernetes/admin.conf
        if kubectl get namespace rapidfort &>/dev/null 2>&1; then
            if helm list -n rapidfort 2>/dev/null | grep -q rfruntime; then
                log_info "Uninstalling RapidFort Runtime..."
                helm uninstall rfruntime -n rapidfort 2>/dev/null || true
                kubectl delete namespace rapidfort --force --grace-period=0 2>/dev/null || true
            fi
        fi
    fi
    
    # Reset kubeadm
    if command -v kubeadm &> /dev/null; then
        log_info "Resetting kubeadm..."
        kubeadm reset -f --cri-socket="unix:///run/cri-dockerd.sock" 2>/dev/null || true
    fi
    
    # Stop services
    log_info "Stopping services..."
    systemctl stop kubelet 2>/dev/null || true
    systemctl stop cri-docker 2>/dev/null || true
    systemctl stop docker 2>/dev/null || true
    
    # Remove Kubernetes packages
    if command -v apt-get &> /dev/null; then
        log_info "Removing Kubernetes packages..."
        apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
        apt-get remove -y kubelet kubeadm kubectl 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
    fi
    
    # Remove cri-dockerd
    log_info "Removing cri-dockerd..."
    systemctl disable cri-docker.service cri-docker.socket 2>/dev/null || true
    rm -f /usr/local/bin/cri-dockerd
    rm -f /etc/systemd/system/cri-docker.service
    rm -f /etc/systemd/system/cri-docker.socket
    
    # Remove Docker (optional - comment out if you want to keep Docker)
    read -p "Remove Docker as well? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Removing Docker..."
        apt-get remove -y docker-ce docker-ce-cli containerd.io 2>/dev/null || true
        rm -rf /var/lib/docker
        rm -rf /etc/docker
    else
        # Just remove the registry
        docker rm -f local-registry 2>/dev/null || true
    fi
    
    # Clean up directories
    log_info "Cleaning up directories..."
    rm -rf /etc/kubernetes
    rm -rf /var/lib/kubelet
    rm -rf /var/lib/etcd
    rm -rf /opt/cni
    rm -rf $HOME/.kube
    
    # Clean up network interfaces
    log_info "Cleaning up network interfaces..."
    ip link delete cni0 2>/dev/null || true
    ip link delete flannel.1 2>/dev/null || true
    
    # Reset iptables
    log_info "Resetting iptables..."
    iptables -F
    iptables -t nat -F
    iptables -t mangle -F
    iptables -X
    
    systemctl daemon-reload
    
    log_success "Uninstall completed"
}

# Function to reset cluster
reset_cluster() {
    log_info "Resetting cluster (clean reinstall)..."
    uninstall_all
    sleep 5
    install_all "$1"
}

# Main function
main() {
    local command="${1:-help}"
    local registry_ip=""
    
    shift || true
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --registry-ip)
                registry_ip="$2"
                shift 2
                ;;
            --k8s-version)
                K8S_VERSION="$2"
                shift 2
                ;;
            --single-node)
                # Default behavior
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                # Pass remaining args to deploy-rapidfort
                break
                ;;
        esac
    done
    
    case "$command" in
        "install")
            install_all "$registry_ip"
            ;;
        "uninstall")
            uninstall_all
            ;;
        "status")
            show_status
            ;;
        "deploy-rapidfort")
            deploy_rapidfort "$@"
            ;;
        "reset")
            reset_cluster "$registry_ip"
            ;;
        "help"|"--help"|"-h")
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