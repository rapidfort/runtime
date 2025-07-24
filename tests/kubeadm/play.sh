#!/bin/bash

# Kubernetes Latest (kubeadm) Installation Script for Ubuntu 24.04
# Usage: ./play.sh [install|uninstall|status|help]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration - USING LATEST KUBERNETES
K8S_VERSION_PREFIX="1.33"  # Latest stable
KUBECONFIG_PATH="$HOME/.kube/config"
POD_NETWORK_CIDR="192.168.0.0/16"

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

# Function to show help
show_help() {
    cat << EOF
Kubernetes LATEST Installation Script for Ubuntu 24.04

USAGE:
    $0 [COMMAND]

COMMANDS:
    install         Install latest Kubernetes cluster with RapidFort Runtime
    uninstall       Remove Kubernetes completely  
    status          Show cluster status
    deploy-rapidfort Deploy RapidFort Runtime to existing cluster
    help            Show this help message

FEATURES:
    - Latest Kubernetes (1.33.x)
    - Ubuntu 24.04 compatibility
    - Container registry on port 30500
    - Calico CNI
    - Local-path storage
    - Automatic RapidFort Runtime deployment

REGISTRY:
    - Uses RF_LOCAL_REGISTRY environment variable
    - Registry accessible at RF_LOCAL_REGISTRY:30500

RAPIDFORT RUNTIME:
    - Automatically deployed if both exist:
      1. ~/.rapidfort/credentials
      2. Helm installed
    - Can be deployed later with: $0 deploy-rapidfort

EXAMPLES:
    $0 install
    $0 status
    $0 uninstall

EOF
}

# Function to detect host IP
detect_host_ip() {
    # First try RF_LOCAL_REGISTRY
    if [[ -n "$RF_LOCAL_REGISTRY" ]]; then
        echo "$RF_LOCAL_REGISTRY"
    else
        # Fall back to auto-detection
        ip route get 1.1.1.1 | awk '{print $7; exit}' || hostname -I | awk '{print $1}'
    fi
}

# Function to prepare system
prepare_system() {
    log_info "Preparing Ubuntu 24.04 system..."
    
    # Update system
    apt-get update
    
    # Install prerequisites
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        software-properties-common \
        conntrack \
        socat \
        ipset \
        ethtool \
        arptables \
        ebtables \
        jq
    
    # Disable swap
    swapoff -a
    sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
    
    # Load kernel modules
    cat > /etc/modules-load.d/k8s.conf << EOF
overlay
br_netfilter
EOF
    
    modprobe overlay
    modprobe br_netfilter
    
    # Sysctl settings
    cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    
    sysctl --system
    
    # Install and configure containerd
    if ! command -v containerd &> /dev/null; then
        apt-get install -y containerd
    fi
    
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    
    # Enable systemd cgroup driver
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    
    # Restart containerd
    systemctl restart containerd
    systemctl enable containerd
    
    log_success "System prepared"
}

# Function to install Kubernetes
install_kubernetes() {
    log_info "Installing latest Kubernetes..."
    
    # Add Kubernetes apt repository for LATEST version
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_PREFIX}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_PREFIX}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
    
    # Update and install
    apt-get update
    apt-get install -y kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl
    
    # Enable kubelet
    systemctl enable --now kubelet
    
    log_success "Kubernetes packages installed"
}

# Function to initialize cluster
initialize_cluster() {
    local host_ip=$(detect_host_ip)
    
    log_info "Initializing Kubernetes cluster..."
    log_info "Using host IP: $host_ip"
    
    # Initialize with latest best practices
    kubeadm init \
        --apiserver-advertise-address=$host_ip \
        --pod-network-cidr=$POD_NETWORK_CIDR \
        --cri-socket=unix:///var/run/containerd/containerd.sock \
        --v=5
    
    # Setup kubeconfig
    mkdir -p $HOME/.kube
    cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config
    export KUBECONFIG=$HOME/.kube/config
    
    # Allow workloads on control plane
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
    
    log_success "Cluster initialized"
}

# Function to install Calico CNI
install_calico() {
    log_info "Installing Calico CNI..."
    
    # Install Tigera operator
    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.30.0/manifests/tigera-operator.yaml
    
    # Wait for operator to be ready and CRDs to be available
    log_info "Waiting for Tigera operator to be ready..."
    kubectl wait --for=condition=Available deployment/tigera-operator -n tigera-operator --timeout=300s
    
    until kubectl get crd installations.operator.tigera.io >/dev/null 2>&1; do
        log_info "Waiting for Installation CRD..."
        sleep 5
    done
    
    # Configure Calico
    cat << EOF | kubectl create -f -
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
EOF
    
    # Wait for Calico
    log_info "Waiting for Calico to be ready..."
    sleep 60
    
    # Check node status
    kubectl get nodes
    
    log_success "CNI installed"
}

# Function to install addons
install_addons() {
    log_info "Installing cluster addons..."
    
    # Install local-path storage
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml
    kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    
    # Install metrics server
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    kubectl patch deployment metrics-server -n kube-system --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
    
    # Install registry
    log_info "Installing container registry..."
    kubectl create namespace registry || true
    
    local host_ip=$(detect_host_ip)
    
    cat << EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-pvc
  namespace: registry
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 20Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: registry
spec:
  replicas: 1
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      containers:
      - name: registry
        image: registry:2
        ports:
        - containerPort: 5000
        env:
        - name: REGISTRY_HTTP_ADDR
          value: 0.0.0.0:5000
        volumeMounts:
        - name: registry-storage
          mountPath: /var/lib/registry
      volumes:
      - name: registry-storage
        persistentVolumeClaim:
          claimName: registry-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: registry
spec:
  type: NodePort
  selector:
    app: registry
  ports:
  - port: 5000
    targetPort: 5000
    nodePort: 30500
EOF
    
    # Configure containerd for registry
    log_info "Configuring containerd for insecure registry..."
    
    # Create containerd config directory
    mkdir -p /etc/containerd/certs.d/${host_ip}:30500
    
    # Create hosts.toml for the registry
    cat > /etc/containerd/certs.d/${host_ip}:30500/hosts.toml << EOF
server = "http://${host_ip}:30500"

[host."http://${host_ip}:30500"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF
    
    # Update containerd config to use the new registry configuration
    if ! grep -q "config_path" /etc/containerd/config.toml; then
        sed -i '/\[plugins\."io.containerd.grpc.v1.cri"\.registry\]/a\      config_path = "/etc/containerd/certs.d"' /etc/containerd/config.toml
    fi
    
    # Restart containerd
    systemctl restart containerd
    
    log_success "Addons installed"
}

# Function to wait for cluster ready
wait_for_ready() {
    log_info "Waiting for cluster to be fully ready..."
    
    # Wait for all pods to be ready
    local retries=60
    while [ $retries -gt 0 ]; do
        if kubectl get pods -A | grep -v Running | grep -v Completed | grep -v STATUS | wc -l | grep -q "^0$"; then
            break
        fi
        echo -n "."
        sleep 10
        ((retries--))
    done
    echo ""
    
    log_success "Cluster is ready"
}

# Function to deploy RapidFort Runtime
deploy_rapidfort() {
    log_info "Deploying RapidFort Runtime to kubeadm cluster"
    
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
    
    # Look for registry secret in multiple locations
    local registry_secret_path=""
    local possible_paths=(
        "./rapidfort-registry-secret.yaml"
        "../rapidfort-registry-secret.yaml"
        "../../rapidfort-registry-secret.yaml"
        "$HOME/rapidfort-registry-secret.yaml"
    )
    
    for path in "${possible_paths[@]}"; do
        if [[ -f "$path" ]]; then
            registry_secret_path="$path"
            break
        fi
    done
    
    local creds_file="$HOME/.rapidfort/credentials"
    export RF_ACCESS_ID=$(grep "access_id" "$creds_file" | cut -d'=' -f2 | xargs)
    export RF_SECRET_ACCESS_KEY=$(grep "secret_key" "$creds_file" | cut -d'=' -f2 | xargs)
    export RF_ROOT_URL=$(grep "rf_root_url" "$creds_file" | cut -d'=' -f2 | xargs)

    
    if [[ -z "$RF_ACCESS_ID" ]] || [[ -z "$RF_SECRET_ACCESS_KEY" ]] || [[ -z "$RF_ROOT_URL" ]]; then
        log_error "Invalid or incomplete RapidFort credentials"
        return 1
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
    
    # Apply registry secret if found
    if [[ -n "$registry_secret_path" ]]; then
        kubectl apply -f "$registry_secret_path" -n rapidfort
    else
        log_warning "rapidfort-registry-secret.yaml not found in any standard location"
        log_info "Proceeding without registry secret..."
    fi
    
    # Deploy RapidFort Runtime
    log_info "Installing RapidFort Runtime with Helm..."
    helm upgrade --install rfruntime oci://quay.io/rapidfort/runtime \
        --namespace rapidfort \
        --set ClusterName="kubeadm" \
        --set ClusterCaption="Kubeadm Cluster" \
        --set rapidfort.credentialsSecret=rfruntime-credentials \
        --set variant=generic \
        --set scan.enabled=true \
        --set profile.enabled=false \
        --wait --timeout=5m
    
    # Check deployment
    if kubectl rollout status daemonset/rfruntime -n rapidfort --timeout=300s; then
        log_success "RapidFort Runtime deployed successfully"
        echo ""
        echo "Commands:"
        echo "  # Check logs: kubectl logs -n rapidfort -l app=rfruntime -c sentry -f"
        echo "  # Check scan results: rfjobs"
    else
        log_error "RapidFort Runtime deployment failed"
        exit 1
    fi
}

# Function to show status
show_status() {
    log_info "Kubernetes Cluster Status"
    echo "========================="
    
    if ! kubectl cluster-info &> /dev/null 2>&1; then
        log_error "Cannot connect to cluster"
        return 1
    fi
    
    kubectl cluster-info
    echo ""
    kubectl get nodes -o wide
    echo ""
    kubectl get pods -A -o wide | head -20
    echo ""
    
    local host_ip=$(detect_host_ip)
    if [[ -z "$host_ip" ]]; then
        log_warning "RF_LOCAL_REGISTRY not set, using auto-detected IP"
        host_ip=$(detect_host_ip)
    fi
    
    echo -e "Registry: http://$host_ip:30500"
    echo -e "\nTo test registry:"
    echo "  curl http://$host_ip:30500/v2/_catalog"
    
    # Check RapidFort Runtime
    if kubectl get namespace rapidfort &>/dev/null; then
        echo ""
        log_info "RapidFort Runtime:"
        local rf_status=$(kubectl get pods -n rapidfort -l app=rfruntime --no-headers 2>/dev/null | grep -c Running || echo 0)
        if [[ "$rf_status" -gt 0 ]]; then
            log_success "RapidFort: Running ($rf_status pods)"
            kubectl get pods -n rapidfort -l app=rfruntime --no-headers | awk '{print "  " $1 " " $3}'
        else
            log_warning "RapidFort: Not running"
        fi
    fi
}

# Function to uninstall
uninstall_all() {
    log_info "Uninstalling Kubernetes..."
    
    # Uninstall RapidFort Runtime if present
    if command -v helm &> /dev/null && kubectl get namespace rapidfort &>/dev/null 2>&1; then
        if helm list -n rapidfort 2>/dev/null | grep -q rfruntime; then
            log_info "Uninstalling RapidFort Runtime..."
            helm uninstall rfruntime -n rapidfort 2>/dev/null || true
            kubectl delete namespace rapidfort --force --grace-period=0 2>/dev/null || true
        fi
    fi
    
    # Delete Calico resources if exist
    kubectl delete -f https://raw.githubusercontent.com/projectcalico/calico/v3.30.0/manifests/tigera-operator.yaml --ignore-not-found=true
    
    # Reset cluster
    kubeadm reset -f || true
    
    # Remove packages
    apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
    apt-get remove -y --purge kubeadm kubectl kubelet kubernetes-cni
    apt-get autoremove -y
    
    # Clean up
    rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd /opt/cni /etc/cni
    rm -f /etc/apt/sources.list.d/kubernetes.list
    rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    rm -rf $HOME/.kube
    
    # Reset iptables
    iptables -F && iptables -X
    iptables -t nat -F && iptables -t nat -X
    iptables -t mangle -F && iptables -t mangle -X
    
    # Remove CNI interfaces
    ip link delete cni0 2>/dev/null || true
    ip link delete flannel.1 2>/dev/null || true
    ip link delete cali* 2>/dev/null || true
    
    log_success "Kubernetes uninstalled"
}

# Main installation function
install_all() {
    log_info "Installing latest Kubernetes on Ubuntu 24.04..."
    
    # Check RF_LOCAL_REGISTRY
    if [[ -z "$RF_LOCAL_REGISTRY" ]]; then
        log_warning "RF_LOCAL_REGISTRY not set, will auto-detect IP for registry"
    else
        log_info "Using RF_LOCAL_REGISTRY: $RF_LOCAL_REGISTRY"
    fi
    
    # Check if already running
    if kubectl cluster-info &> /dev/null 2>&1; then
        log_warning "Kubernetes is already running"
        show_status
        return 0
    fi
    
    # Install sequence
    prepare_system
    install_kubernetes
    initialize_cluster
    install_calico
    install_addons
    wait_for_ready
    
    # Deploy RapidFort Runtime if credentials exist and helm is available
    if [[ -f "$HOME/.rapidfort/credentials" ]] && command -v helm &> /dev/null; then
        log_info "Found RapidFort credentials and helm, deploying RapidFort Runtime..."
        deploy_rapidfort
    else
        if [[ ! -f "$HOME/.rapidfort/credentials" ]]; then
            log_info "RapidFort credentials not found at ~/.rapidfort/credentials"
        fi
        if ! command -v helm &> /dev/null; then
            log_info "Helm not found. Install helm to deploy RapidFort Runtime"
        fi
        log_info "To deploy RapidFort Runtime later:"
        echo "  1. Ensure credentials are in ~/.rapidfort/credentials"
        echo "  2. Install helm if not already installed"
        echo "  3. Run: $0 deploy-rapidfort"
    fi
    
    # Show final status
    show_status
    
    local host_ip=$(detect_host_ip)
    echo -e "\n${GREEN}Installation complete!${NC}"
    echo -e "\nRegistry: http://$host_ip:30500"
    echo -e "\nTo configure docker for the registry:"
    echo '  Add to /etc/docker/daemon.json:'
    echo '  { "insecure-registries": ["'$host_ip':30500"] }'
    echo '  Then: systemctl restart docker'
    echo -e "\nTest your runtime now!"
}

# Main
main() {
    case "${1:-help}" in
        install)
            install_all
            ;;
        uninstall)
            uninstall_all
            ;;
        status)
            show_status
            ;;
        deploy-rapidfort)
            deploy_rapidfort
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $1"
            show_help
            exit 1
            ;;
    esac
}

# Check root
if [[ $EUID -ne 0 ]]; then
   log_error "Run as root: sudo $0 $@"
   exit 1
fi

main "$@"