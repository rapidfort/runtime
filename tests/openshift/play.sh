#!/bin/bash

# OpenShift (CRI-O) Installation and Management Script
# Simulates OpenShift environment with CRI-O runtime
# Usage: ./play.sh [install|uninstall|status|help]

# Source common architecture detection
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common-arch.sh" || {
    echo "Error: common-arch.sh not found"
    exit 1
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
K8S_VERSION="1.29.0"
CRIO_VERSION="1.29"
POD_NETWORK_CIDR="10.244.0.0/16"

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
OpenShift (CRI-O) Installation and Management Script

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    install         Install Kubernetes with CRI-O runtime (OpenShift-like)
    uninstall       Remove everything completely
    status          Show cluster and CRI-O status
    deploy-rapidfort Deploy RapidFort Runtime to existing cluster
    help            Show this help message

OPTIONS:
    --registry-ip   IP address for registry (optional, defaults to RF_LOCAL_REGISTRY)
    --local-registry Use local registry for RapidFort images
    --image-tag     Tag for RapidFort images (e.g., 3.1.32-dev6)
    -h, --help      Show this help

EXAMPLES:
    $0 install --registry-ip 100.100.100.100
    $0 install  # Uses RF_LOCAL_REGISTRY
    $0 status
    $0 deploy-rapidfort
    $0 deploy-rapidfort --local-registry --image-tag 3.1.32-dev6
    $0 uninstall

WHAT IT DOES:
    - Installs Kubernetes with CRI-O runtime
    - Deploys container registry on IP:5000
    - Installs OpenShift Router (HAProxy based)
    - Configures CRI-O for registry access
    - Sets up OpenShift-like security contexts
    - Automatically deploys RapidFort Runtime if credentials found

PREREQUISITES:
    - RF_LOCAL_REGISTRY environment variable (or --registry-ip)
    - Root access required
    - For RapidFort: ~/.rapidfort/credentials file

EOF
}

# Function to check system requirements
check_requirements() {
    log_info "Checking system requirements..."

    if [[ ! "$OSTYPE" == "linux-gnu"* ]]; then
        log_error "This script only supports Linux"
        exit 1
    fi

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi

    # Detect OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        log_error "Cannot detect OS"
        exit 1
    fi

    log_success "System requirements check passed"
}

# Function to install CRI-O
install_crio() {
    log_info "Installing CRI-O ${CRIO_VERSION}..."

    # Detect OS and install accordingly
    case "$OS" in
        ubuntu|debian)
            # Add repositories
            echo "deb [signed-by=/usr/share/keyrings/libcontainers-archive-keyring.gpg] https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/ /" > /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
            echo "deb [signed-by=/usr/share/keyrings/libcontainers-crio-archive-keyring.gpg] https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIO_VERSION/$OS/ /" > /etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o:$CRIO_VERSION.list

            # Add keys
            mkdir -p /usr/share/keyrings
            curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/Release.key | gpg --dearmor -o /usr/share/keyrings/libcontainers-archive-keyring.gpg
            curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIO_VERSION/$OS/Release.key | gpg --dearmor -o /usr/share/keyrings/libcontainers-crio-archive-keyring.gpg

            apt-get update
            apt-get install -y cri-o cri-o-runc cri-tools
            ;;
        rhel|centos|fedora)
            # Add repositories
            curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable.repo https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/CentOS_8/devel:kubic:libcontainers:stable.repo
            curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable:cri-o:$CRIO_VERSION.repo https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable:cri-o:$CRIO_VERSION/CentOS_8/devel:kubic:libcontainers:stable:cri-o:$CRIO_VERSION.repo

            yum install -y cri-o cri-tools
            ;;
        *)
            log_error "Unsupported OS: $OS"
            exit 1
            ;;
    esac

    # Configure CRI-O
    mkdir -p /etc/crio/crio.conf.d

    # Create crictl configuration
    cat > /etc/crictl.yaml << EOF
runtime-endpoint: unix:///var/run/crio/crio.sock
image-endpoint: unix:///var/run/crio/crio.sock
timeout: 10
debug: false
EOF

    systemctl enable crio
    systemctl start crio

    log_success "CRI-O installed and configured"
}

# Function to configure CRI-O for registry
configure_crio_registry() {
    local registry_ip="$1"
    
    log_info "Configuring CRI-O for registry..."

    # Configure CRI-O for insecure registry
    cat > /etc/crio/crio.conf.d/10-insecure-registry.conf << EOF
[crio.image]
insecure_registries = ["$registry_ip:5000"]
EOF

    # Create registry configuration
    mkdir -p /etc/containers/registries.conf.d
    cat > /etc/containers/registries.conf.d/myregistry.conf << EOF
[[registry]]
location = "$registry_ip:5000"
insecure = true
EOF

    # Restart CRI-O
    systemctl restart crio
    
    log_success "CRI-O configured for registry"
}

# Function to check if CRI-O is running
is_crio_running() {
    systemctl is-active --quiet crio 2>/dev/null
}

# Function to install Kubernetes
install_kubernetes() {
    log_info "Installing Kubernetes ${K8S_VERSION}..."

    # Install dependencies
    apt-get update && apt-get install -y apt-transport-https ca-certificates curl

    # Add Kubernetes repository
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%.*}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%.*}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

    # Install specific versions
    apt-get update
    apt-get install -y kubelet=${K8S_VERSION}-* kubeadm=${K8S_VERSION}-* kubectl=${K8S_VERSION}-*
    apt-mark hold kubelet kubeadm kubectl

    # Configure kubelet for CRI-O
    mkdir -p /etc/systemd/system/kubelet.service.d
    cat > /etc/systemd/system/kubelet.service.d/0-crio.conf << EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--container-runtime-endpoint=unix:///var/run/crio/crio.sock --cgroup-driver=systemd"
EOF

    systemctl daemon-reload
    systemctl restart kubelet

    log_success "Kubernetes installed"
}

# Function to setup OpenShift-like security
setup_openshift_security() {
    log_info "Setting up OpenShift-like security contexts..."

    # Create OpenShift-like SCCs (Security Context Constraints)
    kubectl create namespace openshift-infra || true

    # Create restricted SCC equivalent
    cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-infra
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: openshift:scc:restricted
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: openshift:scc:restricted
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: openshift:scc:restricted
subjects:
- kind: Group
  name: system:authenticated
  apiGroup: rbac.authorization.k8s.io
EOF

    log_success "OpenShift-like security configured"
}

# Function to show status
show_status() {
    log_info "OpenShift (CRI-O) Status Report"
    echo "================================"

    if is_crio_running; then
        log_success "CRI-O is running"
        crictl version
        crictl info | grep -E "(version|config)" || true
    else
        log_error "CRI-O is not running"
    fi

    if systemctl is-active --quiet kubelet; then
        log_success "Kubernetes is running"

        if [[ -f "$KUBECONFIG_PATH" ]] && command -v kubectl &> /dev/null; then
            echo ""
            log_info "Cluster nodes:"
            kubectl get nodes 2>/dev/null || echo "  Unable to get cluster info"

            # Check registry
            if kubectl get namespace registry &>/dev/null; then
                echo ""
                log_info "Registry status:"
                local registry_status=$(kubectl get deployment registry -n registry -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
                if [[ "$registry_status" == "1" ]]; then
                    log_success "Registry: Running"
                    local external_ip=$(kubectl get svc registry -n registry -o jsonpath='{.spec.externalIPs[0]}' 2>/dev/null)
                    echo "  External IP: $external_ip:5000"
                else
                    log_warning "Registry: Not ready"
                fi
            fi

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
        fi
    else
        log_warning "Kubernetes not running"
    fi
}

# Function to deploy RapidFort Runtime
deploy_rapidfort() {
    log_info "Deploying RapidFort Runtime to OpenShift (CRI-O) cluster"
    
    # Check if cluster is running
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Kubernetes cluster is not running. Install cluster first with: $0 install"
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
    fi
    
    # Deploy RapidFort Runtime
    log_info "Installing RapidFort Runtime with Helm..."
    
    local helm_args=(
        "upgrade" "--install" "rfruntime"
        "$runtime_chart"
        "--namespace" "rapidfort"
        "--set" "ClusterName=openshift"
        "--set" "ClusterCaption=OpenShift Cluster"
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

# Function to initialize cluster
initialize_cluster() {
    log_info "Initializing Kubernetes cluster..."

    # Disable swap
    swapoff -a
    sed -i '/ swap / s/^/#/' /etc/fstab

    # Load required modules
    modprobe overlay
    modprobe br_netfilter

    # Set sysctl params
    cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    sysctl --system

    # Initialize with CRI-O
    cat > /tmp/kubeadm-config.yaml << EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///var/run/crio/crio.sock
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v${K8S_VERSION}
networking:
  podSubnet: $POD_NETWORK_CIDR
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///var/run/crio/crio.sock
EOF

    kubeadm init --config=/tmp/kubeadm-config.yaml

    # Setup kubeconfig
    mkdir -p $HOME/.kube
    cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config

    # Remove taints on control plane
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

    log_success "Cluster initialized"
}

# Function to install everything
install_all() {
    local registry_ip="$1"

    # If no registry IP provided, use RF_LOCAL_REGISTRY or auto-detect
    if [[ -z "$registry_ip" ]]; then
        registry_ip=$(detect_host_ip)
        if [[ -z "$registry_ip" ]]; then
            log_error "Could not determine registry IP. Please set RF_LOCAL_REGISTRY or use --registry-ip"
            exit 1
        fi
    fi

    log_info "Installing OpenShift-like cluster with CRI-O and registry at $registry_ip:5000"

    check_requirements

    # Check for existing kubeconfig
    if [[ -f "$KUBECONFIG_PATH" ]]; then
        log_warning "Existing kubeconfig found, backing up..."
        mv "$KUBECONFIG_PATH" "$KUBECONFIG_PATH.backup"
    fi

    # Install CRI-O
    install_crio

    # Configure CRI-O for registry
    configure_crio_registry "$registry_ip"

    # Install Kubernetes
    install_kubernetes

    # Initialize cluster
    initialize_cluster

    # Install CNI plugin (Weave Net)
    log_info "Installing Weave Net CNI..."
    kubectl apply -f https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml

    # Wait for CNI to be ready
    log_info "Waiting for CNI to be ready..."
    kubectl wait --for=condition=ready pod -n kube-system -l name=weave-net --timeout=300s

    # Setup OpenShift-like security
    setup_openshift_security

    # Install registry
    log_info "Installing registry..."

    kubectl create namespace registry

    # Deploy registry
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
  selector:
    app: registry
  ports:
  - port: 5000
    targetPort: 5000
  externalIPs:
  - $registry_ip
EOF

    # Wait for registry
    kubectl wait --for=condition=available --timeout=300s deployment/registry -n registry

    # Install OpenShift Router (simplified HAProxy ingress)
    log_info "Installing OpenShift-like router..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/baremetal/deploy.yaml

    # Test registry
    log_info "Testing registry connectivity..."
    sleep 10

    if curl -s "http://$registry_ip:5000/v2/" > /dev/null 2>&1; then
        log_success "Registry is accessible"
    else
        log_warning "Registry may not be fully ready yet"
    fi

    # Test CRI-O with registry
    log_info "Testing CRI-O image pull..."
    crictl pull docker.io/library/hello-world:latest || true

    log_success "Installation completed!"

    echo ""
    log_info "OpenShift-like Cluster Details:"
    echo "  • Container Runtime: CRI-O"
    echo "  • Registry URL: http://$registry_ip:5000"
    echo "  • Security: OpenShift-like SCCs enabled"
    echo ""
    log_info "Usage:"
    echo "  # Push with docker/podman:"
    echo "  docker tag myimage:latest $registry_ip:5000/myimage:latest"
    echo "  docker push $registry_ip:5000/myimage:latest"
    echo ""
    echo "  # Use in Kubernetes:"
    echo "  image: $registry_ip:5000/myimage:latest"
    echo ""
    echo "  # CRI-O commands:"
    echo "  crictl images  # List images"
    echo "  crictl ps      # List containers"
    
    # Deploy RapidFort Runtime if credentials exist
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
}

# Function to uninstall everything
uninstall_all() {
    log_info "Uninstalling everything..."

    # Uninstall RapidFort Runtime if present
    if command -v helm &> /dev/null && kubectl get namespace rapidfort &>/dev/null 2>&1; then
        if helm list -n rapidfort 2>/dev/null | grep -q rfruntime; then
            log_info "Uninstalling RapidFort Runtime..."
            helm uninstall rfruntime -n rapidfort 2>/dev/null || true
            kubectl delete namespace rapidfort --force --grace-period=0 2>/dev/null || true
        fi
    fi

    # Reset kubernetes
    if command -v kubeadm &> /dev/null; then
        kubeadm reset -f
    fi

    # Remove packages
    apt-get remove -y --purge kubeadm kubectl kubelet kubernetes-cni cri-o cri-o-runc
    apt-get autoremove -y

    # Clean up
    rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd /opt/cni /etc/cni
    rm -rf /etc/crio /var/lib/containers /run/containers
    rm -f /etc/apt/sources.list.d/kubernetes.list
    rm -f /etc/apt/sources.list.d/devel*

    # Remove kubeconfig
    if [[ -f "$KUBECONFIG_PATH" ]]; then
        rm -f "$KUBECONFIG_PATH"
    fi
    
    # Restore backup if exists
    if [[ -f "$KUBECONFIG_PATH.backup" ]]; then
        mv "$KUBECONFIG_PATH.backup" "$KUBECONFIG_PATH"
        log_info "Restored previous kubeconfig"
    fi

    log_success "Uninstall completed"
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