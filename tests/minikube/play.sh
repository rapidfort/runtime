#!/bin/bash

# Minikube Installation and Management Script
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
MINIKUBE_PROFILE="minikube"
REGISTRY_NAME="minikube-registry"
REGISTRY_PORT="5000"
DRIVER="auto"  # Can be: auto, docker, none

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
Minikube Installation and Management Script

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    install         Install Minikube cluster with registry, ingress, and RapidFort Runtime
    uninstall       Remove everything completely
    status          Show Minikube and registry status
    deploy-rapidfort Deploy RapidFort Runtime to existing Minikube cluster
    help            Show this help message

OPTIONS:
    --registry-ip   IP address for registry (optional, defaults to RF_LOCAL_REGISTRY)
    --driver        Minikube driver (auto|docker|none) [default: auto]
    --force         Force docker driver even as root
    --fix-containerd Try to fix containerd issues (use with install)
    --clean         Force clean existing minikube installation
    --skip-ingress  Skip installing ingress addon
    --local-registry Use local registry for RapidFort images
    --image-tag     Tag for RapidFort images (e.g., 3.1.32-dev6)
    -h, --help      Show this help

EXAMPLES:
    $0 install --registry-ip 100.100.100.100
    $0 install  # Uses RF_LOCAL_REGISTRY
    $0 install --driver none
    $0 status
    $0 deploy-rapidfort
    $0 deploy-rapidfort --local-registry --image-tag 3.1.32-dev6
    $0 uninstall

WHAT IT DOES:
    - Installs Minikube with containerd runtime
    - Runs registry container on IP:5000 (HTTP)
    - Enables NGINX ingress addon
    - Configures containerd for registry access
    - Auto-detects best driver based on environment
    - Automatically deploys RapidFort Runtime if credentials found

PREREQUISITES:
    - For docker driver: Docker should be running (non-root user)
    - For none driver: containerd or docker should be installed
    - RF_LOCAL_REGISTRY environment variable (or --registry-ip)
    - System configured with insecure-registries for IP:5000

RAPIDFORT RUNTIME:
    - Automatically deployed if both exist:
      1. ~/.rapidfort/credentials
      2. Helm installed
    - Can be deployed later with: $0 deploy-rapidfort

EOF
}

# Function to detect if running as root
is_root() {
    [[ $EUID -eq 0 ]]
}

# Function to check containerd
check_containerd() {
    if command -v containerd &> /dev/null && systemctl is-active --quiet containerd; then
        return 0
    fi
    return 1
}

# Function to install crictl
install_crictl() {
    log_info "Installing crictl..."
    
    # Get a compatible version - v1.28.0 is more stable with various containerd versions
    VERSION="v1.28.0"
    
    # Download crictl
    curl -L -o crictl-${VERSION}-linux-$(get_k8s_arch).tar.gz \
        https://github.com/kubernetes-sigs/cri-tools/releases/download/${VERSION}/crictl-${VERSION}-linux-$(get_k8s_arch).tar.gz
    
    # Extract and install
    tar zxf crictl-${VERSION}-linux-$(get_k8s_arch).tar.gz
    
    if is_root; then
        mv crictl /usr/local/bin/
    else
        sudo mv crictl /usr/local/bin/
    fi
    
    # Clean up
    rm -f crictl-${VERSION}-linux-$(get_k8s_arch).tar.gz
    
    # Create crictl configuration with more compatible settings
    mkdir -p /etc
    cat > /etc/crictl.yaml << EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
pull-image-on-create: false
EOF
    
    # Test crictl connectivity
    if /usr/local/bin/crictl version &>/dev/null; then
        log_success "crictl installed and connected to containerd"
    else
        log_warning "crictl installed but may have connectivity issues"
    fi
}

# Function to install CNI plugins
install_cni_plugins() {
    log_info "Installing CNI plugins..."
    
    CNI_VERSION="v1.3.0"
    
    # Create CNI directories
    mkdir -p /opt/cni/bin /etc/cni/net.d
    
    # Download and install CNI plugins
    curl -L -o cni-plugins.tgz \
        https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-$(get_cni_arch)-${CNI_VERSION}.tgz
    
    tar -C /opt/cni/bin -xzf cni-plugins.tgz
    rm -f cni-plugins.tgz
    
    log_success "CNI plugins installed"
}

# Function to determine best driver
determine_driver() {
    if [[ "$DRIVER" != "auto" ]]; then
        echo "$DRIVER"
        return
    fi

    if is_root; then
        if check_containerd; then
            log_info "Running as root with containerd available, using 'none' driver"
            echo "none"
        else
            log_warning "Running as root. Consider using --driver=none or running as non-root user"
            echo "none"
        fi
    else
        if command -v docker &> /dev/null && docker info &> /dev/null; then
            echo "docker"
        else
            echo "none"
        fi
    fi
}

# Function to check system requirements
check_requirements() {
    log_info "Checking system requirements..."

    if [[ ! "$OSTYPE" == "linux-gnu"* ]]; then
        log_error "This script only supports Linux"
        exit 1
    fi

    # Check basic required commands
    local basic_commands=("curl" "tar")
    for cmd in "${basic_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command '$cmd' not found. Please install it first."
            exit 1
        fi
    done

    local driver=$(determine_driver)
    
    if [[ "$driver" == "docker" ]]; then
        if ! command -v docker &> /dev/null; then
            log_error "Docker is required for docker driver"
            exit 1
        fi
        
        if ! docker info &> /dev/null; then
            log_error "Docker is not running. Please start docker first."
            exit 1
        fi
    elif [[ "$driver" == "none" ]]; then
        # Check for container runtime
        if ! check_containerd && ! command -v docker &> /dev/null; then
            log_error "No container runtime found. Please install containerd or docker"
            exit 1
        fi
        
        # Install required system packages
        log_info "Installing required packages for none driver..."
        if command -v apt-get &> /dev/null; then
            apt-get update
            apt-get install -y conntrack socat iptables ethtool
        elif command -v yum &> /dev/null; then
            yum install -y conntrack-tools socat iptables ethtool
        fi
        
        # Check required tools for none driver
        if ! command -v conntrack &> /dev/null; then
            log_warning "Installing conntrack..."
            if command -v apt-get &> /dev/null; then
                apt-get update && apt-get install -y conntrack
            elif command -v yum &> /dev/null; then
                yum install -y conntrack
            fi
        fi
        
        # Install crictl if not present
        if ! command -v crictl &> /dev/null; then
            install_crictl
        else
            # Reconfigure crictl if already installed
            log_info "crictl already installed, updating configuration..."
            cat > /etc/crictl.yaml << EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
pull-image-on-create: false
EOF
        fi
        
        # Install CNI plugins if not present
        if [[ ! -d /opt/cni/bin ]] || [[ -z "$(ls -A /opt/cni/bin 2>/dev/null)" ]]; then
            install_cni_plugins
        fi
    fi

    log_success "System requirements check passed"
}

# Function to check for existing kubeconfig
check_existing_kubeconfig() {
    if [[ -f "$KUBECONFIG_PATH" ]]; then
        log_warning "Existing kubeconfig found at: $KUBECONFIG_PATH"
        log_warning "Backing it up to: $KUBECONFIG_PATH.backup"
        mv "$KUBECONFIG_PATH" "$KUBECONFIG_PATH.backup"
    fi
}

# Function to check if minikube is installed
is_minikube_installed() {
    command -v minikube &> /dev/null
}

# Function to check if minikube cluster is running
is_minikube_running() {
    minikube status -p $MINIKUBE_PROFILE &>/dev/null && minikube status -p $MINIKUBE_PROFILE | grep -q "host: Running"
}

# Function to check if registry is running
is_registry_running() {
    docker ps --format "table {{.Names}}" | grep -q "^${REGISTRY_NAME}$"
}

# Function to get minikube version
get_minikube_version() {
    if is_minikube_installed; then
        minikube version --short 2>/dev/null || echo "unknown"
    else
        echo "not installed"
    fi
}

# Function to configure containerd for insecure registry
configure_containerd_registry() {
    local registry_ip="$1"
    
    if ! check_containerd; then
        return
    fi
    
    log_info "Configuring containerd for insecure registry..."
    
    # Create containerd config directory
    mkdir -p /etc/containerd
    
    # Backup existing config if it exists
    if [[ -f /etc/containerd/config.toml ]]; then
        cp /etc/containerd/config.toml /etc/containerd/config.toml.backup
    fi
    
    # Create hosts.toml directory for new registry configuration method
    mkdir -p /etc/containerd/certs.d/${registry_ip}:${REGISTRY_PORT}
    
    # Create hosts.toml for the registry
    cat > /etc/containerd/certs.d/${registry_ip}:${REGISTRY_PORT}/hosts.toml << EOF
server = "http://${registry_ip}:${REGISTRY_PORT}"

[host."http://${registry_ip}:${REGISTRY_PORT}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF
    
    # Create or update containerd config
    cat > /etc/containerd/config.toml << EOF
version = 2
root = "/var/lib/containerd"
state = "/run/containerd"
oom_score = 0

[grpc]
  address = "/run/containerd/containerd.sock"
  uid = 0
  gid = 0

[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    enable_selinux = false
    sandbox_image = "registry.k8s.io/pause:3.9"
    
    [plugins."io.containerd.grpc.v1.cri".containerd]
      snapshotter = "overlayfs"
      default_runtime_name = "runc"
      
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true
    
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
EOF
    
    # Restart containerd
    systemctl restart containerd
    sleep 5
    
    # Verify containerd is running
    if ! systemctl is-active --quiet containerd; then
        log_error "Failed to restart containerd"
        log_info "Restoring original config..."
        if [[ -f /etc/containerd/config.toml.backup ]]; then
            mv /etc/containerd/config.toml.backup /etc/containerd/config.toml
        fi
        systemctl restart containerd
        exit 1
    fi
    
    log_success "Containerd configured for insecure registry"
}

# Function to show status
show_status() {
    log_info "Minikube Status Report"
    echo "======================"

    if is_minikube_installed; then
        log_success "Minikube installed: $(get_minikube_version)"
    else
        log_warning "Minikube not installed"
        return
    fi

    if is_minikube_running; then
        log_success "Minikube cluster '$MINIKUBE_PROFILE' is running"

        if command -v kubectl &> /dev/null; then
            echo ""
            log_info "Cluster info:"
            minikube profile list 2>/dev/null | grep "$MINIKUBE_PROFILE" || true
            
            echo ""
            log_info "Cluster nodes:"
            kubectl get nodes 2>/dev/null || echo "  Unable to get cluster info"

            # Check ingress
            if kubectl get namespace ingress-nginx &>/dev/null; then
                echo ""
                log_info "NGINX ingress controller:"
                local ingress_status=$(kubectl get deployment ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
                if [[ -n "$ingress_status" ]] && [[ "$ingress_status" -gt 0 ]]; then
                    log_success "NGINX Ingress: Running"
                else
                    log_warning "NGINX Ingress: Not ready"
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
        log_warning "Minikube cluster not running"
    fi

    # Check registry
    if is_registry_running; then
        echo ""
        log_info "Registry status:"
        log_success "Registry: Running on port $REGISTRY_PORT"
        local registry_ip=$(docker inspect $REGISTRY_NAME --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
        if [[ -n "$registry_ip" ]]; then
            echo "  Registry Container IP: $registry_ip:$REGISTRY_PORT"
        fi
    else
        echo ""
        log_warning "Registry: Not running"
    fi
}

# Function to install minikube binary
install_minikube_binary() {
    if is_minikube_installed; then
        log_info "Minikube already installed"
        return
    fi

    log_info "Installing Minikube binary..."

    # Download minikube binary
    curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-$(get_k8s_arch)
    chmod +x minikube-linux-$(get_k8s_arch)
    
    if is_root; then
        mv minikube-linux-$(get_k8s_arch) /usr/local/bin/minikube
    else
        sudo mv minikube-linux-$(get_k8s_arch) /usr/local/bin/minikube
    fi

    log_success "Minikube binary installed"
}

# Function to install kubectl if needed
install_kubectl() {
    if command -v kubectl &> /dev/null; then
        return
    fi
    
    log_info "Installing kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/$(get_k8s_arch)/kubectl"
    chmod +x kubectl
    
    if is_root; then
        mv kubectl /usr/local/bin/
    else
        sudo mv kubectl /usr/local/bin/
    fi
    
    log_success "kubectl installed"
}

# Function to fix common containerd issues
fix_containerd_issues() {
    log_info "Attempting to fix common containerd issues..."
    
    # Stop containerd
    systemctl stop containerd
    
    # Clean up any stale sockets
    rm -f /run/containerd/containerd.sock
    
    # Clear containerd state if needed
    if [[ -d /var/lib/containerd ]]; then
        log_warning "Clearing containerd state (this will remove all containers/images)"
        rm -rf /var/lib/containerd/*
    fi
    
    # Ensure containerd directories exist
    mkdir -p /var/lib/containerd /run/containerd /etc/containerd
    
    # Start containerd
    systemctl start containerd
    sleep 5
    
    if systemctl is-active --quiet containerd; then
        log_success "Containerd restarted successfully"
        return 0
    else
        log_error "Failed to restart containerd"
        return 1
    fi
}

# Function to verify containerd CRI is working
verify_containerd_cri() {
    log_info "Verifying containerd CRI plugin..."
    
    # Check if containerd is running
    if ! systemctl is-active --quiet containerd; then
        log_error "Containerd is not running"
        return 1
    fi
    
    # Check CRI plugin with ctr
    if command -v ctr &> /dev/null; then
        if ctr plugins ls | grep -q "io.containerd.grpc.v1.cri.*ok"; then
            log_success "Containerd CRI plugin is active"
        else
            log_warning "Containerd CRI plugin may not be properly configured"
        fi
    fi
    
    # Test with crictl
    if command -v crictl &> /dev/null; then
        if crictl version &>/dev/null; then
            log_success "crictl can connect to containerd"
            return 0
        else
            log_error "crictl cannot connect to containerd"
            log_info "Trying to diagnose the issue..."
            
            # Check socket exists
            if [[ ! -S /run/containerd/containerd.sock ]]; then
                log_error "Containerd socket not found at /run/containerd/containerd.sock"
                return 1
            fi
            
            # Check permissions
            ls -la /run/containerd/containerd.sock
            
            return 1
        fi
    fi
    
    return 0
}

# Function to deploy RapidFort Runtime
deploy_rapidfort() {
    log_info "Deploying RapidFort Runtime to minikube cluster"
    
    # Check if minikube is running
    if ! minikube status -p minikube &>/dev/null || ! kubectl cluster-info &>/dev/null; then
        log_error "Minikube is not running. Install Minikube first with: $0 install"
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
        "--set" "ClusterName=minikube"
        "--set" "ClusterCaption=minikube Cluster"
        "--set" "rapidfort.credentialsSecret=rfruntime-credentials"
        "--set" "variant=generic"
        "--set" "scan.enabled=true"
        "--set" "profile.enabled=true"
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

# Function to install everything
install_all() {
    local registry_ip="$1"
    local force_docker="$2"
    local fix_containerd="$3"
    local clean_install="$4"
    local skip_ingress="$5"

    # If no registry IP provided, use RF_LOCAL_REGISTRY or auto-detect
    if [[ -z "$registry_ip" ]]; then
        registry_ip=$(detect_host_ip)
        if [[ -z "$registry_ip" ]]; then
            log_error "Could not determine registry IP. Please set RF_LOCAL_REGISTRY or use --registry-ip"
            exit 1
        fi
    fi

    local driver=$(determine_driver)
    
    log_info "Installing Minikube cluster with:"
    log_info "  • Driver: $driver"
    log_info "  • Registry: $registry_ip:$REGISTRY_PORT"
    log_info "  • Runtime: containerd"

    check_requirements
    check_existing_kubeconfig

    # Force clean if requested
    if [[ "$clean_install" == "true" ]]; then
        log_info "Performing clean installation..."
        if is_minikube_running || minikube profile list 2>/dev/null | grep -q "$MINIKUBE_PROFILE"; then
            log_info "Removing existing minikube installation..."
            minikube delete -p $MINIKUBE_PROFILE --purge 2>/dev/null || true
            sleep 2
        fi
    fi

    if is_minikube_running && is_registry_running && [[ "$clean_install" != "true" ]]; then
        log_warning "Minikube cluster and registry already running"
        show_status
        return 0
    fi

    # Install minikube binary
    install_minikube_binary
    install_kubectl

    # Configure containerd if using none driver
    if [[ "$driver" == "none" ]]; then
        # Fix containerd if requested
        if [[ "$fix_containerd" == "true" ]]; then
            fix_containerd_issues
        fi
        
        configure_containerd_registry "$registry_ip"
        
        # Verify containerd CRI is working
        if ! verify_containerd_cri; then
            log_error "Containerd CRI verification failed"
            log_info "Please check containerd logs: journalctl -u containerd -n 50"
            log_info "You can try running with --fix-containerd option"
            exit 1
        fi
    fi

    # Create registry container
    if ! is_registry_running; then
        log_info "Creating registry container..."
        docker run -d --restart=always \
            -p $registry_ip:$REGISTRY_PORT:5000 \
            --name $REGISTRY_NAME \
            registry:2

        # Wait for registry to be ready
        sleep 5
        if curl -s "http://$registry_ip:$REGISTRY_PORT/v2/" > /dev/null 2>&1; then
            log_success "Registry is running at $registry_ip:$REGISTRY_PORT"
        else
            log_warning "Registry may not be fully ready yet"
        fi
    fi

    # Start minikube with appropriate driver
    if ! is_minikube_running; then
        log_info "Starting Minikube with $driver driver..."
        
        # Clean up any existing Kubernetes artifacts if using none driver
        if [[ "$driver" == "none" ]]; then
            log_info "Cleaning up any existing Kubernetes components..."
            # Stop any existing kubelet
            systemctl stop kubelet 2>/dev/null || true
            
            # Clean up kubernetes directories
            rm -rf /etc/kubernetes/manifests/*
            rm -rf /var/lib/kubelet/*
            rm -rf /var/lib/etcd/*
            
            # Reset iptables rules if needed
            if command -v kubeadm &> /dev/null; then
                kubeadm reset -f 2>/dev/null || true
            fi
        fi
        
        # Check if there's an existing profile that might cause issues
        if minikube profile list 2>/dev/null | grep -q "$MINIKUBE_PROFILE"; then
            log_warning "Existing Minikube profile found. Cleaning up..."
            minikube delete -p $MINIKUBE_PROFILE --purge 2>/dev/null || true
            sleep 2
        fi

        local minikube_args=(
            "start"
            "--profile=$MINIKUBE_PROFILE"
            "--driver=$driver"
            "--container-runtime=containerd"
            "--insecure-registry=$registry_ip:$REGISTRY_PORT"
            "--memory=4096"
            "--cpus=2"
        )
        
        # Add force flag if using docker driver as root
        if [[ "$driver" == "docker" ]] && is_root && [[ "$force_docker" == "true" ]]; then
            minikube_args+=("--force")
        fi
        
        # Add extra args for none driver
        if [[ "$driver" == "none" ]]; then
            minikube_args+=("--extra-config=kubelet.cgroup-driver=systemd")
        fi

        minikube "${minikube_args[@]}"

        log_success "Minikube cluster started"
    fi

    # Setup kubeconfig
    log_info "Setting up kubeconfig..."
    mkdir -p ~/.kube
    
    if [[ "$driver" == "none" ]]; then
        # For none driver, copy admin.conf
        if [[ -f /etc/kubernetes/admin.conf ]]; then
            cp /etc/kubernetes/admin.conf "$KUBECONFIG_PATH"
        else
            minikube kubectl -- config view --raw > "$KUBECONFIG_PATH"
        fi
    else
        minikube kubectl -- config view --raw > "$KUBECONFIG_PATH"
    fi
    
    chmod 600 "$KUBECONFIG_PATH"
    
    # Set the current context
    export KUBECONFIG="$KUBECONFIG_PATH"
    
    # Verify kubectl works
    if ! kubectl get nodes &>/dev/null; then
        log_warning "kubectl not working yet, waiting for cluster to be ready..."
        sleep 10
        
        # Try again
        if [[ "$driver" == "none" ]] && [[ -f /etc/kubernetes/admin.conf ]]; then
            cp /etc/kubernetes/admin.conf "$KUBECONFIG_PATH"
        fi
    fi
    
    # Wait for cluster to be ready
    log_info "Waiting for cluster to be ready..."
    local retries=30
    while [[ $retries -gt 0 ]]; do
        if kubectl get nodes &>/dev/null; then
            log_success "Cluster is ready"
            break
        fi
        retries=$((retries - 1))
        sleep 5
    done

    # Enable ingress addon if not skipped
    if [[ "$skip_ingress" != "true" ]]; then
        log_info "Enabling ingress addon..."
        minikube addons enable ingress -p $MINIKUBE_PROFILE

        # Wait for ingress controller
        log_info "Waiting for ingress controller..."
        kubectl wait --namespace ingress-nginx \
            --for=condition=ready pod \
            --selector=app.kubernetes.io/component=controller \
            --timeout=300s || log_warning "Ingress taking longer to start, continuing..."
    else
        log_info "Skipping ingress addon installation as requested"
    fi

    # Test registry
    log_info "Testing registry connectivity..."
    sleep 5

    if curl -s "http://$registry_ip:$REGISTRY_PORT/v2/" > /dev/null 2>&1; then
        log_success "Registry is accessible"
    else
        log_warning "Registry may not be fully ready yet"
    fi

    # Test with a real image
    log_info "Testing image push/pull..."
    if command -v docker &> /dev/null; then
        docker pull hello-world:latest
        docker tag hello-world:latest $registry_ip:$REGISTRY_PORT/hello-world:test
        docker push $registry_ip:$REGISTRY_PORT/hello-world:test

        # Test Kubernetes can pull the image
        kubectl run test-registry --image=$registry_ip:$REGISTRY_PORT/hello-world:test --restart=Never
        sleep 10
        if kubectl logs test-registry 2>/dev/null | grep -q "Hello from Docker"; then
            log_success "Kubernetes can pull from registry"
        else
            log_warning "Kubernetes pull test inconclusive"
        fi
        kubectl delete pod test-registry --force --grace-period=0 2>/dev/null || true
    fi

    log_success "Installation completed!"

    echo ""
    log_info "Cluster Details:"
    echo "  • Minikube profile: $MINIKUBE_PROFILE"
    echo "  • Driver: $driver"
    echo "  • Container runtime: containerd"
    echo "  • Registry URL: http://$registry_ip:$REGISTRY_PORT"
    if [[ "$skip_ingress" != "true" ]]; then
        echo "  • Ingress: NGINX addon enabled"
    else
        echo "  • Ingress: Not installed (skipped)"
    fi
    echo ""
    log_info "Usage:"
    echo "  # Push with docker:"
    echo "  docker tag myimage:latest $registry_ip:$REGISTRY_PORT/myimage:latest"
    echo "  docker push $registry_ip:$REGISTRY_PORT/myimage:latest"
    echo ""
    echo "  # Use in Kubernetes:"
    echo "  image: $registry_ip:$REGISTRY_PORT/myimage:latest"
    
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
    
    echo ""
    log_info "Minikube Commands:"
    echo "  # Check status: minikube status -p $MINIKUBE_PROFILE"
    if [[ "$driver" != "none" ]]; then
        echo "  # SSH to node: minikube ssh -p $MINIKUBE_PROFILE"
    fi
    echo "  # Load image: minikube image load myimage:latest -p $MINIKUBE_PROFILE"
    echo "  # Dashboard: minikube dashboard -p $MINIKUBE_PROFILE"
    
    if [[ "$skip_ingress" == "true" ]]; then
        echo ""
        log_info "To enable ingress later, run:"
        echo "  minikube addons enable ingress -p $MINIKUBE_PROFILE"
    fi
}

# Function to uninstall everything
uninstall_all() {
    log_info "Uninstalling everything..."

    # Uninstall RapidFort Runtime if present
    if command -v helm &> /dev/null && is_minikube_running && kubectl get namespace rapidfort &>/dev/null 2>&1; then
        if helm list -n rapidfort 2>/dev/null | grep -q rfruntime; then
            log_info "Uninstalling RapidFort Runtime..."
            helm uninstall rfruntime -n rapidfort 2>/dev/null || true
            kubectl delete namespace rapidfort --force --grace-period=0 2>/dev/null || true
        fi
    fi

    # Stop and delete minikube cluster
    if is_minikube_running; then
        log_info "Stopping Minikube cluster..."
        minikube stop -p $MINIKUBE_PROFILE 2>/dev/null || true
        minikube delete -p $MINIKUBE_PROFILE 2>/dev/null || true
    fi

    # Clean up none driver artifacts if root
    if is_root && [[ -d /etc/kubernetes ]]; then
        log_info "Cleaning up Kubernetes artifacts..."
        kubeadm reset -f 2>/dev/null || true
        rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd
    fi

    # Remove registry container
    if is_registry_running; then
        log_info "Removing registry container..."
        docker stop $REGISTRY_NAME 2>/dev/null || true
        docker rm $REGISTRY_NAME 2>/dev/null || true
    fi

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
    local force_docker="false"
    local fix_containerd="false"
    local clean_install="false"
    local skip_ingress="false"

    shift || true

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --registry-ip)
                registry_ip="$2"
                shift 2
                ;;
            --driver)
                DRIVER="$2"
                shift 2
                ;;
            --force)
                force_docker="true"
                shift
                ;;
            --fix-containerd)
                fix_containerd="true"
                shift
                ;;
            --clean)
                clean_install="true"
                shift
                ;;
            --skip-ingress)
                skip_ingress="true"
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
            install_all "$registry_ip" "$force_docker" "$fix_containerd" "$clean_install" "$skip_ingress"
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
