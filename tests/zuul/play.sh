#!/bin/bash

# Zuul-based Kubernetes Deployment Script
# Simulates a Zuul CI/CD environment with restricted containerd configuration
# Usage: ./play.sh [install|uninstall|status|debug|help]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Script configuration
K8S_VERSION="1.32.7"  # Matching customer's server version
CONTAINERD_VERSION="1.7.27"  # Matching customer's version
KUBECONFIG_PATH="$HOME/.kube/config"
POD_NETWORK_CIDR="10.244.0.0/16"
ZUUL_USER="zuul"
ZUUL_NAMESPACE="zuul-system"

# Make apt non-interactive
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

# Configure apt to be fully non-interactive
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99non-interactive << 'EOF'
APT::Get::Assume-Yes "true";
APT::Get::allow-unauthenticated "true";
Dpkg::Options:: "--force-confdef";
Dpkg::Options:: "--force-confold";
EOF

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

log_header() {
    echo -e "\n${PURPLE}===================================================${NC}"
    echo -e "${PURPLE}$1${NC}"
    echo -e "${PURPLE}===================================================${NC}\n"
}

# Function to detect host IP if RF_LOCAL_REGISTRY not set
detect_host_ip() {
    local host_ip=""
    
    # First try RF_LOCAL_REGISTRY
    if [[ -n "$RF_LOCAL_REGISTRY" ]]; then
        echo "$RF_LOCAL_REGISTRY"
        return
    fi
    
    # Try to load from RapidFort credentials file
    local creds_file="$HOME/.rapidfort/credentials"
    if [[ -f "$creds_file" ]]; then
        # Try to extract RF_APP_HOST from credentials file
        local rf_host=$(grep -E "^RF_APP_HOST=" "$creds_file" 2>/dev/null | cut -d'=' -f2 | tr -d ' "' || true)
        if [[ -z "$rf_host" ]]; then
            # Try rf_root_url format
            rf_host=$(grep -E "^rf_root_url\s*=" "$creds_file" 2>/dev/null | awk -F'=' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | tr -d ' ' | sed 's|^https\?://||' | sed 's|/.*||' || true)
        fi
        
        if [[ -n "$rf_host" ]]; then
            echo "$rf_host"
            return
        fi
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
Zuul-based Kubernetes Deployment Script

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    install         Install Kubernetes with Zuul-like restrictions
    uninstall       Remove everything completely
    status          Show cluster and containerd status
    debug           Show debugging information
    test-ctr        Test ctr image operations
    deploy-rapidfort Deploy RapidFort Runtime to existing cluster
    help            Show this help message

OPTIONS:
    --registry-ip   IP address for registry (optional)
    --strict        Apply strict Zuul-like security policies
    --local-registry Use local registry for RapidFort images
    --image-tag     Tag for RapidFort images (e.g., 3.1.32-dev6)
    -h, --help      Show this help

WHAT IT DOES:
    - Installs Kubernetes ${K8S_VERSION} with containerd ${CONTAINERD_VERSION}
    - Creates zuul user with restricted permissions
    - Configures containerd with namespace isolation
    - Sets up AppArmor/SELinux policies (if available)
    - Implements Zuul-like CI/CD restrictions
    - Creates restricted containerd socket permissions
    - Automatically deploys RapidFort Runtime (if credentials exist)

PREREQUISITES:
    - Root access required
    - For RapidFort Runtime:
      • ~/.rapidfort/credentials file with RF_ACCESS_ID, RF_SECRET_ACCESS_KEY, RF_ROOT_URL
      • helm installed (optional, for automatic deployment)
      • rapidfort-registry-secret.yaml (optional)

FEATURES:
    - Namespace-isolated containerd configuration
    - Restricted ctr access patterns
    - Zuul-specific security contexts
    - Limited container runtime permissions
    - Automatic RapidFort Runtime deployment (if credentials exist)
    - Manual RapidFort deployment with deploy-rapidfort command

EXAMPLES:
    $0 install
    $0 install --strict
    $0 deploy-rapidfort
    $0 deploy-rapidfort --local-registry --image-tag 3.1.32-dev6
    $0 uninstall

EOF
}

# Function to create zuul user
create_zuul_user() {
    log_info "Creating zuul user..."
    
    if ! id "$ZUUL_USER" &>/dev/null; then
        useradd -m -s /bin/bash "$ZUUL_USER"
    fi
    
    # Create docker group if it doesn't exist and add zuul to it
    getent group docker >/dev/null 2>&1 || groupadd docker
    usermod -aG docker "$ZUUL_USER" 2>/dev/null || true
    
    # Create restricted sudoers entry
    cat > /etc/sudoers.d/zuul << EOF
# Zuul user restrictions
${ZUUL_USER} ALL=(ALL) NOPASSWD: /usr/local/bin/ctr
${ZUUL_USER} ALL=(ALL) NOPASSWD: /usr/local/bin/crictl
${ZUUL_USER} ALL=(ALL) NOPASSWD: /usr/bin/kubectl
${ZUUL_USER} ALL=(ALL) NOPASSWD: /bin/systemctl status containerd
${ZUUL_USER} ALL=(ALL) NOPASSWD: /bin/journalctl -u containerd
EOF
    
    chmod 440 /etc/sudoers.d/zuul
    log_success "Zuul user created with restricted permissions"
}

# Function to install specific containerd version
install_containerd() {
    log_info "Installing containerd ${CONTAINERD_VERSION}..."
    
    # Remove any existing containerd
    apt-get remove -y containerd containerd.io docker.io 2>/dev/null || true
    
    # Install dependencies
    apt-get update
    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release
    
    # Add Docker's official GPG key
    mkdir -p /etc/apt/keyrings
    # Remove existing key if present to avoid prompt
    rm -f /etc/apt/keyrings/docker.gpg
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    # Set up the repository
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install specific containerd version
    apt-get update
    # Force installation even if there are prompts
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" containerd.io=${CONTAINERD_VERSION}-1
    
    log_success "Containerd ${CONTAINERD_VERSION} installed"
    
    # Install crictl
    log_info "Installing crictl..."
    VERSION="v1.28.0"
    curl -L -o crictl-${VERSION}-linux-amd64.tar.gz \
        https://github.com/kubernetes-sigs/cri-tools/releases/download/${VERSION}/crictl-${VERSION}-linux-amd64.tar.gz
    tar zxf crictl-${VERSION}-linux-amd64.tar.gz
    mv crictl /usr/local/bin/
    rm -f crictl-${VERSION}-linux-amd64.tar.gz
    
    # Create crictl configuration
    cat > /etc/crictl.yaml << EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
    
    log_success "crictl installed"
    
    # Ensure ctr is in PATH
    if [[ ! -f /usr/local/bin/ctr ]]; then
        ln -s /usr/bin/ctr /usr/local/bin/ctr 2>/dev/null || true
    fi
}

# Function to configure containerd with Zuul restrictions
configure_containerd_zuul() {
    log_info "Configuring containerd with Zuul-like restrictions..."
    
    # Create containerd config directory
    mkdir -p /etc/containerd
    
    # Generate config with restrictions
    cat > /etc/containerd/config.toml << 'EOF'
version = 2
root = "/var/lib/containerd"
state = "/run/containerd"
oom_score = -999

# Restrict to specific namespaces
disabled_plugins = []

[grpc]
  address = "/run/containerd/containerd.sock"
  uid = 0
  gid = 0
  max_recv_message_size = 16777216
  max_send_message_size = 16777216

[debug]
  address = "/run/containerd/debug.sock"
  uid = 0
  gid = 0
  level = "info"

[metrics]
  address = ""
  grpc_histogram = false

[cgroup]
  path = ""

[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    enable_selinux = true
    enable_apparmor = true
    restrict_oom_score_adj = true
    sandbox_image = "registry.k8s.io/pause:3.10"
    
    [plugins."io.containerd.grpc.v1.cri".containerd]
      default_runtime_name = "runc"
      snapshotter = "overlayfs"
      
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          pod_annotations = ["seccomp.security.alpha.kubernetes.io/*", "apparmor.security.beta.kubernetes.io/*"]
          
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true
            BinaryName = "/usr/bin/runc"
            Root = ""
            NoNewKeyring = false
            ShimCgroup = ""
            IoUid = 0
            IoGid = 0
            CriuPath = ""
            NoPivotRoot = false
    
    [plugins."io.containerd.grpc.v1.cri".cni]
      bin_dir = "/opt/cni/bin"
      conf_dir = "/etc/cni/net.d"
      max_conf_num = 1
    
    [plugins."io.containerd.grpc.v1.cri".registry]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
          endpoint = ["https://registry-1.docker.io"]
    
    # Image encryption settings (Zuul-like)
    [plugins."io.containerd.grpc.v1.cri".image_decryption]
      key_model = "node"
    
    # Restrict runtime privileges
    [plugins."io.containerd.runtime.v1.linux"]
      runtime = "runc"
      runtime_root = ""
      no_shim = false
      shim = "containerd-shim"
      shim_debug = false
    
    [plugins."io.containerd.runtime.v2.task"]
      platforms = ["linux/amd64"]
    
    # Content sharing policy (restricted)
    [plugins."io.containerd.content.v1.content"]
      share_policy = "isolated"
  
  # Namespace restrictions
  [plugins."io.containerd.internal.v1.opt"]
    path = "/opt/containerd"
  
  [plugins."io.containerd.snapshotter.v1.overlayfs"]
    root_path = "/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs"
    upperdir_label = true
  
  # Metadata restrictions
  [plugins."io.containerd.metadata.v1.bolt"]
    content_sharing_policy = "isolated"
EOF
    
    # Create namespace-specific configuration
    mkdir -p /etc/containerd/certs.d
    
    # Set restrictive permissions on containerd socket
    mkdir -p /etc/systemd/system/containerd.service.d
    
    # Create docker group if it doesn't exist
    getent group docker >/dev/null 2>&1 || groupadd docker
    
    cat > /etc/systemd/system/containerd.service.d/override.conf << EOF
[Service]
ExecStartPost=/bin/bash -c 'sleep 2 && chmod 660 /run/containerd/containerd.sock && chgrp docker /run/containerd/containerd.sock'
EOF
    
    systemctl daemon-reload
    systemctl restart containerd
    
    log_success "Containerd configured with Zuul restrictions"
}

# Function to setup AppArmor profiles
setup_apparmor_profiles() {
    if ! command -v apparmor_parser &> /dev/null; then
        log_warning "AppArmor not available, skipping..."
        return
    fi
    
    log_info "Setting up AppArmor profiles for Zuul environment..."
    
    # Create restrictive profile for ctr
    cat > /etc/apparmor.d/zuul.ctr << 'EOF'
#include <tunables/global>

profile zuul-ctr flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>
  
  # Allow basic operations
  /usr/local/bin/ctr ix,
  /usr/bin/ctr ix,
  
  # Containerd socket access (restricted)
  /run/containerd/containerd.sock rw,
  /run/containerd/** r,
  
  # Limited filesystem access
  /var/lib/containerd/** r,
  /tmp/** rw,
  
  # Deny mount operations by default
  deny mount,
  deny umount,
  
  # Limited capability set
  capability sys_admin,
  capability dac_override,
  
  # Network restrictions
  network unix stream,
  
  # Deny ptrace
  deny ptrace,
}
EOF
    
    apparmor_parser -r /etc/apparmor.d/zuul.ctr || true
    
    log_success "AppArmor profiles configured"
}

# Function to create namespace isolation
create_namespace_isolation() {
    log_info "Creating namespace isolation..."
    
    # Create isolated containerd namespace
    ctr namespace create zuul-ci || true
    
    # Create Kubernetes namespace with restrictions
    kubectl create namespace $ZUUL_NAMESPACE --dry-run=client -o yaml | \
    kubectl label --dry-run=client -o yaml --local -f - \
        pod-security.kubernetes.io/enforce=restricted \
        pod-security.kubernetes.io/warn=restricted \
        pod-security.kubernetes.io/audit=restricted | \
    kubectl apply -f -
    
    # Create network policy for isolation
    cat << EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: zuul-isolation
  namespace: $ZUUL_NAMESPACE
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: $ZUUL_NAMESPACE
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: $ZUUL_NAMESPACE
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: TCP
      port: 53
    - protocol: UDP
      port: 53
EOF
    
    log_success "Namespace isolation created"
}

# Function to install Kubernetes
install_kubernetes() {
    log_info "Installing Kubernetes ${K8S_VERSION}..."
    
    # Add Kubernetes repository
    mkdir -p /etc/apt/keyrings
    # Remove existing key if present to avoid prompt
    rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%.*}/deb/Release.key | \
        gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%.*}/deb/ /" | \
        tee /etc/apt/sources.list.d/kubernetes.list
    
    # Install specific versions
    apt-get update
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
        kubelet=${K8S_VERSION}-* \
        kubeadm=${K8S_VERSION}-* \
        kubectl=${K8S_VERSION}-*
    
    apt-mark hold kubelet kubeadm kubectl
    
    # Configure kubelet for containerd
    mkdir -p /etc/systemd/system/kubelet.service.d
    cat > /etc/systemd/system/kubelet.service.d/0-containerd.conf << EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF
    
    systemctl daemon-reload
    systemctl restart kubelet
    
    log_success "Kubernetes ${K8S_VERSION} installed"
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
    
    # Install CNI plugins
    log_info "Installing CNI plugins..."
    mkdir -p /opt/cni/bin /etc/cni/net.d
    CNI_VERSION="v1.3.0"
    curl -L -o cni-plugins.tgz \
        https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz
    tar -C /opt/cni/bin -xzf cni-plugins.tgz
    rm -f cni-plugins.tgz
    
    # Initialize with specific configuration
    cat > /tmp/kubeadm-config.yaml << EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    pod-infra-container-image: registry.k8s.io/pause:3.10
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v${K8S_VERSION}
controllerManager:
  extraArgs:
    bind-address: "0.0.0.0"
scheduler:
  extraArgs:
    bind-address: "0.0.0.0"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serverTLSBootstrap: true
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
EOF
    
    kubeadm init --config=/tmp/kubeadm-config.yaml --v=5
    
    # Setup kubeconfig
    mkdir -p $HOME/.kube
    cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config
    
    # Setup kubeconfig for zuul user
    mkdir -p /home/$ZUUL_USER/.kube
    cp -f /etc/kubernetes/admin.conf /home/$ZUUL_USER/.kube/config
    chown -R $ZUUL_USER:$ZUUL_USER /home/$ZUUL_USER/.kube
    
    # Export KUBECONFIG
    export KUBECONFIG="$HOME/.kube/config"
    
    # Remove taints on control plane
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
    
    log_success "Cluster initialized"
}

# Function to test ctr operations
test_ctr_operations() {
    log_header "Testing ctr operations"
    
    # Ensure KUBECONFIG is set
    export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
    
    # Test as root
    log_info "Testing ctr as root..."
    ctr version
    
    # Pull test image
    log_info "Pulling test image..."
    ctr image pull docker.io/library/alpine:latest || log_error "Failed to pull image as root"
    
    # List images
    log_info "Listing images..."
    ctr image ls
    
    # Test mount operations
    log_info "Testing mount operations..."
    mkdir -p /tmp/ctr-mount-test
    
    # First create a snapshot
    log_info "Creating snapshot..."
    ctr snapshot prepare test-snapshot alpine:latest 2>&1 || log_error "Failed to prepare snapshot"
    
    # Try to mount image
    log_info "Attempting mount operation..."
    if ctr snapshot mounts /tmp/ctr-mount-test test-snapshot 2>&1; then
        log_success "Mount operation succeeded as root"
        # Show what was mounted
        ls -la /tmp/ctr-mount-test/ | head -5
        umount /tmp/ctr-mount-test 2>/dev/null || true
    else
        log_error "Mount operation failed as root"
        log_info "Error details:"
        ctr snapshot mounts /tmp/ctr-mount-test test-snapshot 2>&1 || true
    fi
    
    # Clean up snapshot
    ctr snapshot rm test-snapshot 2>/dev/null || true
    
    # Test as zuul user
    log_info "Testing ctr as zuul user..."
    su - $ZUUL_USER -c "sudo ctr version" || log_error "Failed to run ctr as zuul"
    
    # Test with namespace
    log_info "Testing ctr with zuul-ci namespace..."
    ctr -n zuul-ci image pull docker.io/library/alpine:latest || log_error "Failed to pull in zuul-ci namespace"
    
    # Test mount in namespace
    log_info "Creating snapshot in zuul-ci namespace..."
    ctr -n zuul-ci snapshot prepare test-snapshot-ns alpine:latest 2>&1 || log_error "Failed to prepare snapshot in namespace"
    
    log_info "Attempting mount operation in zuul-ci namespace..."
    if ctr -n zuul-ci snapshot mounts /tmp/ctr-mount-test test-snapshot-ns 2>&1; then
        log_success "Mount operation succeeded in zuul-ci namespace"
        umount /tmp/ctr-mount-test 2>/dev/null || true
    else
        log_error "Mount operation failed in zuul-ci namespace"
        log_info "Error details:"
        ctr -n zuul-ci snapshot mounts /tmp/ctr-mount-test test-snapshot-ns 2>&1 || true
    fi
    
    # Clean up
    ctr -n zuul-ci snapshot rm test-snapshot-ns 2>/dev/null || true
    
    # Test RapidFort-like operations
    log_info "Testing RapidFort-like layer extraction..."
    
    # Export image to tar
    log_info "Exporting image..."
    if ctr image export /tmp/alpine-test.tar alpine:latest 2>&1; then
        log_success "Image export succeeded"
        ls -lh /tmp/alpine-test.tar
        rm -f /tmp/alpine-test.tar
    else
        log_error "Image export failed"
    fi
    
    # Test snapshot view
    log_info "Testing snapshot view operations..."
    if ctr snapshot view test-view alpine:latest 2>&1; then
        log_success "Snapshot view created"
        ctr snapshot rm test-view 2>/dev/null || true
    else
        log_error "Snapshot view failed"
    fi
    
    # Check permissions
    log_info "Checking socket permissions..."
    ls -la /run/containerd/containerd.sock
    
    # Test crictl
    log_info "Testing crictl..."
    crictl version || log_error "crictl failed"
    crictl info || log_error "crictl info failed"
}

# Function to show status
show_status() {
    log_header "Zuul Kubernetes Deployment Status"
    
    # Ensure KUBECONFIG is set
    export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
    
    log_info "System Information:"
    echo "  Kubernetes: $(kubectl version --short 2>/dev/null | grep Server || echo 'Not running')"
    echo "  Containerd: $(containerd --version)"
    echo "  Zuul User: $(id $ZUUL_USER 2>/dev/null || echo 'Not created')"
    
    if systemctl is-active --quiet containerd; then
        log_success "Containerd is running"
        
        # Show containerd info
        log_info "Containerd configuration:"
        ctr version
        ctr namespace ls
        
        # Check socket permissions
        log_info "Socket permissions:"
        ls -la /run/containerd/containerd.sock
    else
        log_error "Containerd is not running"
    fi
    
    if kubectl cluster-info &>/dev/null; then
        log_success "Kubernetes cluster is running"
        kubectl get nodes -o wide
        kubectl get ns
    else
        log_warning "Kubernetes cluster is not running"
    fi
    
    # Check AppArmor status
    if command -v aa-status &> /dev/null; then
        log_info "AppArmor profiles:"
        aa-status | grep zuul || echo "  No Zuul profiles loaded"
    fi
    
    # Check RapidFort Runtime status
    if kubectl get namespace rapidfort &>/dev/null 2>&1; then
        log_info "RapidFort Runtime status:"
        local rf_pods=$(kubectl get pods -n rapidfort -l app=rfruntime --no-headers 2>/dev/null | grep -c Running || echo 0)
        if [[ "$rf_pods" -gt 0 ]]; then
            log_success "RapidFort Runtime is running ($rf_pods pods)"
            kubectl get pods -n rapidfort --no-headers | head -5
        else
            log_warning "RapidFort Runtime not running"
            echo "  Deploy with: $0 deploy-rapidfort"
        fi
    else
        log_info "RapidFort Runtime: Not deployed"
        echo "  Deploy with: $0 deploy-rapidfort"
    fi
}

# Function to show debug information
show_debug() {
    log_header "Debug Information"
    
    # Ensure KUBECONFIG is set
    export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
    
    # Environment variables
    log_info "Zuul-related environment variables:"
    env | grep -i zuul || echo "  No ZUUL variables found"
    env | grep -i container || echo "  No CONTAINER variables found"
    
    # Containerd logs
    log_info "Recent containerd logs:"
    journalctl -u containerd -n 50 --no-pager
    
    # Check mounts
    log_info "Current mounts:"
    mount | grep containerd
    
    # Namespace info
    log_info "Containerd namespaces:"
    ctr namespace ls
    
    # Check cgroup info
    log_info "Cgroup information:"
    cat /proc/self/cgroup
    
    # SELinux status
    if command -v getenforce &> /dev/null; then
        log_info "SELinux status: $(getenforce)"
    fi
    
    # AppArmor status
    if command -v aa-status &> /dev/null; then
        log_info "AppArmor status:"
        aa-status --verbose 2>/dev/null || aa-status
    fi
    
    # Kernel capabilities
    log_info "Kernel capabilities:"
    capsh --print 2>/dev/null || log_warning "capsh not available"
    
    # Containerd config
    log_info "Containerd configuration:"
    cat /etc/containerd/config.toml 2>/dev/null | head -50 || log_warning "No containerd config found"
    
    # Check containerd plugins
    log_info "Containerd plugins:"
    ctr plugins ls 2>/dev/null || log_warning "Cannot list plugins"
    
    # File permissions
    log_info "Important file permissions:"
    ls -la /run/containerd/ 2>/dev/null || true
    ls -la /var/lib/containerd/ 2>/dev/null | head -10 || true
    
    # Test running container with ctr
    log_info "Testing container run with ctr:"
    ctr run --rm alpine:latest test-container echo "Hello from container" 2>&1 || log_error "Failed to run container"
    
    # Test specific mount scenarios that might fail in Zuul
    log_info "Testing specific mount failure scenarios..."
    
    # Test 1: Direct layer mount
    log_info "Test 1: Direct layer mount"
    LAYER_DIGEST=$(ctr image ls -q | xargs ctr image manifest | grep -m1 'digest:' | awk '{print $2}' | tr -d '"' 2>/dev/null || echo "")
    if [[ -n "$LAYER_DIGEST" ]]; then
        ctr snapshot mounts /tmp/layer-test "$LAYER_DIGEST" 2>&1 || log_warning "Direct layer mount failed (expected in restricted env)"
    fi
    
    # Test 2: Rootless mount attempt
    log_info "Test 2: Testing as non-root (zuul) user"
    su - $ZUUL_USER -c "ctr image ls" 2>&1 || log_warning "Non-root ctr access failed"
    
    # Test 3: Check for mount restrictions
    log_info "Test 3: Checking mount capabilities"
    if command -v capsh &>/dev/null; then
        capsh --print | grep -i cap_sys_admin || log_warning "CAP_SYS_ADMIN not available"
    fi
}

# Function to deploy RapidFort Runtime
deploy_rapidfort() {
    log_info "Deploying RapidFort Runtime to zuul cluster"
    
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
        "--set" "ClusterName=zuul"
        "--set" "ClusterCaption=Zuul Cluster"
        "--set" "rapidfort.credentialsSecret=rfruntime-credentials"
        "--set" "variant=generic"  # zuul uses generic variant
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
            helm_args+=("--set" "imagePullSecrets[0].name=rapidfort-registry-secret")
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

# Main installation function
install_all() {
    local registry_ip="$1"
    local strict_mode="$2"
    
    log_header "Installing Zuul-based Kubernetes Environment"
    
    # Set non-interactive mode for all apt operations
    export DEBIAN_FRONTEND=noninteractive
    
    # Check root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    # Create zuul user
    create_zuul_user
    
    # Install specific containerd version
    install_containerd
    
    # Configure containerd with restrictions
    configure_containerd_zuul
    
    # Setup security profiles if strict mode
    if [[ "$strict_mode" == "true" ]]; then
        setup_apparmor_profiles
    fi
    
    # Install Kubernetes
    install_kubernetes
    
    # Initialize cluster
    initialize_cluster
    
    # Install CNI (Using Weave Net to avoid Calico CRD issues)
    log_info "Installing Weave Net CNI..."
    
    # Ensure bridge netfilter is enabled
    sysctl net.bridge.bridge-nf-call-iptables=1 || true
    
    # Install Weave Net
    kubectl apply -f https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml
    
    # Wait for Weave Net to be ready
    log_info "Waiting for CNI to be ready..."
    kubectl wait --for=condition=ready pod -n kube-system -l name=weave-net --timeout=300s || log_warning "CNI taking longer to start"
    
    # Wait for cluster
    log_info "Waiting for cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
    
    # Create namespace isolation
    create_namespace_isolation
    
    # Install local-path storage
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.24/deploy/local-path-storage.yaml
    
    # Set default storage class
    kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    
    log_success "Installation complete!"
    
    # Clean up apt configuration
    rm -f /etc/apt/apt.conf.d/99non-interactive
    
    # Try to deploy RapidFort Runtime if credentials exist
    if [[ -f "$HOME/.rapidfort/credentials" ]]; then
        log_info "Found RapidFort credentials, attempting to deploy RapidFort Runtime..."
        
        # Load credentials
        source "$HOME/.rapidfort/credentials" 2>/dev/null || true
        
        # Check for alternate credential format
        if [[ -z "$RF_ACCESS_ID" ]]; then
            RF_ACCESS_ID=$(grep -E "^access_id\s*=" "$HOME/.rapidfort/credentials" 2>/dev/null | cut -d'=' -f2- | xargs)
        fi
        if [[ -z "$RF_SECRET_ACCESS_KEY" ]]; then
            RF_SECRET_ACCESS_KEY=$(grep -E "^secret_key\s*=" "$HOME/.rapidfort/credentials" 2>/dev/null | cut -d'=' -f2- | xargs)
        fi
        if [[ -z "$RF_ROOT_URL" ]]; then
            RF_ROOT_URL=$(grep -E "^rf_root_url\s*=" "$HOME/.rapidfort/credentials" 2>/dev/null | cut -d'=' -f2- | xargs)
        fi
        
        if [[ -n "$RF_ACCESS_ID" ]] && [[ -n "$RF_SECRET_ACCESS_KEY" ]] && [[ -n "$RF_ROOT_URL" ]]; then
            if command -v helm &> /dev/null; then
                deploy_rapidfort || log_warning "RapidFort Runtime deployment failed, you can deploy it later with: $0 deploy-rapidfort"
            else
                log_warning "Helm not installed, skipping RapidFort Runtime deployment"
                log_info "To deploy RapidFort Runtime later:"
                echo "  1. Install helm: https://helm.sh/docs/intro/install/"
                echo "  2. Run: $0 deploy-rapidfort"
            fi
        else
            log_warning "RapidFort credentials incomplete, skipping Runtime deployment"
        fi
    else
        log_info "RapidFort credentials not found"
        log_info "To deploy RapidFort Runtime later:"
        echo "  1. Place credentials in ~/.rapidfort/credentials"
        echo "  2. Run: $0 deploy-rapidfort"
    fi
    
    # Show important info
    echo ""
    log_info "Important Information:"
    echo "  • Zuul user: $ZUUL_USER"
    echo "  • Containerd namespace: zuul-ci"
    echo "  • Kubernetes namespace: $ZUUL_NAMESPACE"
    echo "  • Socket permissions: Restricted to root and docker group"
    echo "  • Kubeconfig: $HOME/.kube/config"
    echo ""
    log_info "To test ctr issues:"
    echo "  # As root: $0 test-ctr"
    echo "  # As zuul: su - $ZUUL_USER"
    echo "  # Then: sudo ctr -n zuul-ci image pull alpine"
    
    # Check if RapidFort Runtime was deployed
    if kubectl get namespace rapidfort &>/dev/null 2>&1; then
        echo ""
        log_info "RapidFort Runtime Commands:"
        echo "  # Check logs: kubectl logs -n rapidfort -l app=rfruntime -c sentry -f"
        echo "  # Check scan results: rfjobs"
        echo "  # Check runtime status: $0 status"
    fi
}

# Uninstall function
uninstall_all() {
    log_header "Uninstalling Zuul Kubernetes Environment"
    
    # Set non-interactive mode
    export DEBIAN_FRONTEND=noninteractive
    
    # Reset kubernetes
    if command -v kubeadm &> /dev/null; then
        kubeadm reset -f
    fi
    
    # Remove packages
    apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
    apt-get remove -y --purge kubeadm kubectl kubelet kubernetes-cni containerd.io
    apt-get autoremove -y
    
    # Clean up
    rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd /opt/cni /etc/cni
    rm -rf /etc/containerd /var/lib/containerd /run/containerd
    rm -f /etc/apt/sources.list.d/kubernetes.list
    rm -f /etc/apt/sources.list.d/docker.list
    rm -rf $HOME/.kube
    
    # Remove zuul user
    if id "$ZUUL_USER" &>/dev/null; then
        userdel -r "$ZUUL_USER" 2>/dev/null || true
    fi
    rm -f /etc/sudoers.d/zuul
    
    # Remove AppArmor profiles
    if [[ -f /etc/apparmor.d/zuul.ctr ]]; then
        apparmor_parser -R /etc/apparmor.d/zuul.ctr 2>/dev/null || true
        rm -f /etc/apparmor.d/zuul.ctr
    fi
    
    # Clean up apt configuration
    rm -f /etc/apt/apt.conf.d/99non-interactive
    
    log_success "Uninstall complete"
}

# Main function
main() {
    case "${1:-help}" in
        install)
            shift
            local registry_ip=""
            local strict_mode="false"
            
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --registry-ip) registry_ip="$2"; shift 2 ;;
                    --strict) strict_mode="true"; shift ;;
                    *) log_error "Unknown option: $1"; exit 1 ;;
                esac
            done
            
            install_all "$registry_ip" "$strict_mode"
            ;;
        uninstall)
            uninstall_all
            ;;
        status)
            show_status
            ;;
        debug)
            show_debug
            ;;
        test-ctr)
            test_ctr_operations
            ;;
        deploy-rapidfort)
            shift
            deploy_rapidfort "$@"
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

# Execute main
main "$@"