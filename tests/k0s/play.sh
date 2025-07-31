#!/bin/bash

# k0s Installation and Management Script
# Usage: ./play.sh [install|uninstall|status|help]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration
K0S_VERSION=${K0S_VERSION:-"v1.33.3+k0s.0"}  # Latest stable version
INSTALL_TYPE=${INSTALL_TYPE:-"single"}
KUBECONFIG_PATH="$HOME/.kube/config"
K0S_BINARY="/usr/local/bin/k0s"
K0S_CONFIG="/etc/k0s/k0s.yaml"

# Try to load RF_LOCAL_REGISTRY from credentials if not set
if [[ -z "$RF_LOCAL_REGISTRY" ]] && [[ -f "$HOME/.rapidfort/credentials" ]]; then
    # Try to extract RF_APP_HOST and use as registry
    RF_LOCAL_REGISTRY=$(grep -E "^RF_APP_HOST=" "$HOME/.rapidfort/credentials" 2>/dev/null | cut -d'=' -f2 | tr -d ' "' || true)
fi

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

# Function to detect system architecture
get_system_arch() {
    local arch=""
    local machine=$(uname -m)
    
    case $machine in
        x86_64|amd64)
            arch="amd64"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        armv7l|armhf|armv7)
            arch="arm"
            ;;
        i386|i686)
            arch="386"
            ;;
        *)
            log_error "Unsupported architecture: $machine"
            log_info "Supported architectures: amd64, arm64, arm, 386"
            exit 1
            ;;
    esac
    
    echo "$arch"
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
k0s Installation and Management Script

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    install         Install k0s cluster with registry, ingress, and RapidFort Runtime
    uninstall       Remove everything completely (including iptables cleanup)
    status          Show k0s and registry status
    debug           Show debugging information
    deploy-rapidfort Deploy RapidFort Runtime to existing k0s cluster
    help            Show this help message

OPTIONS:
    --registry-ip   IP address for registry (optional, defaults to RF_LOCAL_REGISTRY)
    --local-registry Use local registry for RapidFort images
    --image-tag     Tag for RapidFort images (e.g., 3.1.32-dev6)
    -h, --help      Show this help

EXAMPLES:
    $0 install --registry-ip 10.0.0.100
    $0 install  # Uses RF_LOCAL_REGISTRY or auto-detects IP
    $0 status
    $0 debug
    $0 deploy-rapidfort
    $0 deploy-rapidfort --local-registry --image-tag 3.1.32-dev6
    $0 uninstall

WHAT IT DOES:
    - Installs k0s single-node cluster
    - Deploys container registry on IP:5000 (HTTP)
    - Sets up ingress controller
    - Configures containerd for registry access
    - Includes local-path storage provisioner
    - Automatically deploys RapidFort Runtime if credentials found
    - Cleans up k8s-specific iptables rules on uninstall

REGISTRY IP DETECTION:
    - If --registry-ip not provided, uses RF_LOCAL_REGISTRY env var
    - If RF_LOCAL_REGISTRY not set, tries from ~/.rapidfort/credentials
    - Falls back to auto-detect primary network interface IP

RAPIDFORT RUNTIME:
    - Automatically deployed if both exist:
      1. ~/.rapidfort/credentials (RF_ACCESS_ID, RF_SECRET_ACCESS_KEY, RF_ROOT_URL)
      2. Helm installed
    - Can be deployed later with: $0 deploy-rapidfort

EOF
}

# Function to check system requirements
check_requirements() {
    log_info "Checking system requirements..."

    if [[ ! "$OSTYPE" == "linux-gnu"* ]]; then
        log_error "This script only supports Linux"
        exit 1
    fi

    # Check architecture
    local arch=$(get_system_arch)
    log_info "System architecture: $(uname -m) -> $arch"

    # Check if running as root or with sudo
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi

    local required_commands=("curl" "systemctl" "openssl")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command '$cmd' not found"
            exit 1
        fi
    done

    # Check available memory
    local mem_available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    if [[ $mem_available -lt 2097152 ]]; then  # 2GB in KB
        log_warning "Less than 2GB of available memory. k0s may have issues."
    fi

    # Check CPU count
    local cpu_count=$(nproc)
    if [[ $cpu_count -lt 2 ]]; then
        log_warning "Less than 2 CPUs detected. k0s may run slowly."
    fi

    log_success "System requirements check passed"
}

# Function to save iptables rules
save_iptables() {
    local backup_file="/tmp/iptables-backup-$(date +%Y%m%d-%H%M%S).rules"
    log_info "Saving current iptables rules to $backup_file"
    iptables-save > "$backup_file" 2>/dev/null || true
    echo "$backup_file"
}

# Function to clean iptables rules (safer version - only k8s/k0s specific)
clean_iptables() {
    log_info "Cleaning k8s/k0s specific iptables rules..."
    
    # Save current rules for debugging
    local backup_file=$(save_iptables)
    log_info "Current rules backed up to: $backup_file"
    
    # Clean up k8s/k0s specific rules from default chains
    log_info "Removing k8s/k0s rules from default chains..."
    
    # Remove KUBE-* and CNI-* jumps from default chains
    for table in filter nat mangle; do
        # Get all rules with KUBE- or CNI- references
        iptables -t $table -S 2>/dev/null | grep -E "(KUBE-|CNI-|cali-|kube-)" | while read -r rule; do
            # Convert -A to -D to delete the rule
            if [[ "$rule" =~ ^-A ]]; then
                del_rule=$(echo "$rule" | sed 's/^-A /-D /')
                iptables -t $table $del_rule 2>/dev/null || true
            fi
        done
    done
    
    # Clean nat table k8s chains
    log_info "Cleaning Kubernetes NAT chains..."
    for chain in KUBE-SERVICES KUBE-NODEPORTS KUBE-POSTROUTING KUBE-MARK-MASQ KUBE-MARK-DROP KUBE-FORWARD KUBE-KUBELET-CANARY KUBE-PROXY-CANARY KUBE-SEP-* KUBE-SVC-* KUBE-FW-* KUBE-EXT-*; do
        # List all chains and filter for our pattern
        iptables -t nat -L -n 2>/dev/null | grep "^Chain $chain" | awk '{print $2}' | while read -r found_chain; do
            if [[ "$found_chain" =~ ^KUBE- ]]; then
                log_info "Removing NAT chain: $found_chain"
                iptables -t nat -F "$found_chain" 2>/dev/null || true
                iptables -t nat -X "$found_chain" 2>/dev/null || true
            fi
        done
    done
    
    # Clean filter table k8s chains
    log_info "Cleaning Kubernetes filter chains..."
    for chain in KUBE-FORWARD KUBE-FIREWALL KUBE-KUBELET-CANARY KUBE-PROXY-CANARY KUBE-EXTERNAL-SERVICES KUBE-SERVICES KUBE-NODEPORTS; do
        if iptables -L "$chain" &>/dev/null 2>&1; then
            log_info "Removing filter chain: $chain"
            iptables -F "$chain" 2>/dev/null || true
            iptables -X "$chain" 2>/dev/null || true
        fi
    done
    
    # Clean up CNI chains
    log_info "Cleaning CNI chains..."
    for chain in CNI-FORWARD CNI-ISOLATION-STAGE-1 CNI-ISOLATION-STAGE-2 CNI-*; do
        # List all chains and filter for CNI pattern
        iptables -L -n 2>/dev/null | grep "^Chain CNI-" | awk '{print $2}' | while read -r found_chain; do
            log_info "Removing CNI chain: $found_chain"
            iptables -F "$found_chain" 2>/dev/null || true
            iptables -X "$found_chain" 2>/dev/null || true
        done
    done
    
    # Clean up Calico chains if present
    log_info "Cleaning Calico chains if present..."
    for table in filter nat mangle raw; do
        iptables -t $table -L -n 2>/dev/null | grep "^Chain cali-" | awk '{print $2}' | while read -r found_chain; do
            log_info "Removing Calico chain from $table: $found_chain"
            iptables -t $table -F "$found_chain" 2>/dev/null || true
            iptables -t $table -X "$found_chain" 2>/dev/null || true
        done
    done
    
    # Clean up any k0s-specific interfaces
    log_info "Cleaning up k8s/k0s network interfaces..."
    for iface in kube-bridge cni0 flannel.1 vxlan.calico veth* cali*; do
        # Use more careful matching
        ip link show 2>/dev/null | grep -E "^[0-9]+: ($iface)" | awk -F: '{print $2}' | tr -d ' ' | while read -r found_iface; do
            if [[ "$found_iface" =~ ^(kube-|cni|flannel|vxlan\.calico|veth|cali) ]]; then
                log_info "Removing interface: $found_iface"
                ip link set "$found_iface" down 2>/dev/null || true
                ip link delete "$found_iface" 2>/dev/null || true
            fi
        done
    done
    
    log_success "k0s/k8s specific iptables rules cleaned"
    log_info "Note: General system iptables rules were preserved"
}

# Function to check for existing kubeconfig
check_existing_kubeconfig() {
    if [[ -f "$KUBECONFIG_PATH" ]]; then
        log_warning "Existing kubeconfig found at: $KUBECONFIG_PATH"
        log_warning "Backing it up to: $KUBECONFIG_PATH.backup"
        mv "$KUBECONFIG_PATH" "$KUBECONFIG_PATH.backup"
    fi
}

# Function to check if k0s is installed
is_k0s_installed() {
    [[ -f "$K0S_BINARY" ]]
}

# Function to check if k0s is running
is_k0s_running() {
    systemctl is-active --quiet k0scontroller 2>/dev/null || k0s status &>/dev/null
}

# Function to get k0s version
get_k0s_version() {
    if is_k0s_installed; then
        k0s version 2>/dev/null | head -n1 || echo "unknown"
    else
        echo "not installed"
    fi
}

# Create k0s configuration file
create_k0s_config() {
    local registry_ip="$1"
    
    log_info "Creating k0s configuration..."
    
    mkdir -p /etc/k0s
    
    cat > "$K0S_CONFIG" << EOF
apiVersion: k0s.k0sproject.io/v1beta1
kind: ClusterConfig
metadata:
  name: k0s
spec:
  api:
    sans:
    - 127.0.0.1
    - localhost
    - $registry_ip
  storage:
    type: etcd
  network:
    provider: kuberouter
    kubeRouter:
      autoMTU: true
      metricsPort: 8080
  podSecurityPolicy:
    defaultPolicy: 00-k0s-privileged
  telemetry:
    enabled: false
  extensions:
    storage:
      create_default_storage_class: false  # We'll use local-path-provisioner
EOF

    log_success "k0s configuration created"
}

# Function to show status
show_status() {
    log_info "k0s Status Report"
    echo "=================="

    if is_k0s_installed; then
        log_success "k0s installed: $(get_k0s_version)"
    else
        log_warning "k0s not installed"
        return
    fi

    if is_k0s_running; then
        log_success "k0s is running"
        
        # Show k0s status
        echo ""
        log_info "k0s system status:"
        k0s status || true
        
        if [[ -f "$KUBECONFIG_PATH" ]] && command -v kubectl &> /dev/null; then
            echo ""
            log_info "Cluster nodes:"
            kubectl get nodes -o wide 2>/dev/null || echo "  Unable to get cluster info"
            
            echo ""
            log_info "System pods:"
            kubectl get pods -A | grep -E "(kube-system|kube-router)" || true
            
            # Check storage
            echo ""
            log_info "Storage classes:"
            kubectl get storageclass 2>/dev/null || echo "  No storage classes found"
            
            # Check registry
            if kubectl get namespace registry &>/dev/null; then
                echo ""
                log_info "Registry status:"
                local registry_status=$(kubectl get deployment registry -n registry -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
                if [[ "$registry_status" == "1" ]]; then
                    log_success "Registry: Running"
                    local registry_ip=$(kubectl get svc registry -n registry -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
                    echo "  Registry Cluster IP: $registry_ip:5000"
                    local external_ip=$(kubectl get svc registry -n registry -o jsonpath='{.spec.externalIPs[0]}' 2>/dev/null)
                    echo "  Registry External IP: $external_ip:5000"
                else
                    log_warning "Registry: Not ready"
                fi
            fi
            
            # Check ingress
            if kubectl get namespace ingress-nginx &>/dev/null; then
                echo ""
                log_info "Ingress controller:"
                local ingress_status=$(kubectl get deployment ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
                if [[ "$ingress_status" == "1" ]]; then
                    log_success "Ingress: Running"
                else
                    log_warning "Ingress: Not ready"
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
        log_warning "k0s not running"
    fi
}

# Debug function
show_debug() {
    log_info "k0s Debug Information"
    echo "====================="
    
    # System info
    echo ""
    log_info "System Information:"
    echo "  OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    echo "  Kernel: $(uname -r)"
    echo "  Architecture: $(uname -m) ($(get_system_arch))"
    echo "  CPUs: $(nproc)"
    echo "  Memory: $(free -h | grep Mem | awk '{print $2}')"
    echo "  Disk: $(df -h / | tail -1 | awk '{print $4}' ) free"
    
    # k0s logs
    if is_k0s_installed; then
        echo ""
        log_info "k0s controller logs (last 50 lines):"
        journalctl -u k0scontroller -n 50 --no-pager || true
        
        echo ""
        log_info "k0s configuration:"
        cat "$K0S_CONFIG" 2>/dev/null || echo "  No config file found"
    fi
    
    # Kubernetes debugging
    if [[ -f "$KUBECONFIG_PATH" ]] && command -v kubectl &> /dev/null; then
        echo ""
        log_info "Kubernetes events:"
        kubectl get events -A --sort-by='.lastTimestamp' | tail -20 || true
        
        echo ""
        log_info "Pending pods:"
        kubectl get pods -A | grep -v Running | grep -v Completed || echo "  No pending pods"
        
        echo ""
        log_info "Node conditions:"
        kubectl describe nodes | grep -A5 Conditions || true
    fi
    
    # Network debugging
    echo ""
    log_info "Network interfaces:"
    ip addr show | grep -E "^[0-9]+:|inet " || true
    
    echo ""
    log_info "Firewall status:"
    if command -v ufw &> /dev/null; then
        ufw status || true
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --list-all || true
    else
        echo "  No firewall detected"
    fi
}

# Function to wait for k0s API
wait_for_k0s_api() {
    log_info "Waiting for k0s API to be ready..."
    local retries=60
    
    while [[ $retries -gt 0 ]]; do
        if k0s kubectl get --raw /healthz &>/dev/null; then
            log_success "k0s API is ready"
            return 0
        fi
        echo -n "."
        sleep 5
        ((retries--))
    done
    
    echo ""
    log_error "k0s API failed to become ready"
    return 1
}

# Function to detect registry IP
detect_registry_ip() {
    local registry_ip=""
    
    # First, try RF_LOCAL_REGISTRY from environment
    if [[ -n "$RF_LOCAL_REGISTRY" ]]; then
        registry_ip="$RF_LOCAL_REGISTRY"
        log_info "Using RF_LOCAL_REGISTRY as registry IP: $registry_ip"
    else
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
                registry_ip="$rf_host"
                log_info "Using RF_APP_HOST from credentials file: $registry_ip"
            fi
        fi
    fi
    
    # If still no IP, try to auto-detect
    if [[ -z "$registry_ip" ]]; then
        # Get primary IP address (exclude localhost and docker interfaces)
        registry_ip=$(hostname -I | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
        
        if [[ -z "$registry_ip" ]]; then
            # Fallback to getting IP from default route
            registry_ip=$(ip route get 1.1.1.1 | awk '{print $7; exit}' 2>/dev/null || true)
        fi
        
        if [[ -n "$registry_ip" ]]; then
            log_warning "Auto-detected IP address: $registry_ip"
            log_warning "If this is incorrect, specify with --registry-ip"
        fi
    fi
    
    echo "$registry_ip"
}

# Function to deploy RapidFort Runtime
deploy_rapidfort() {
    log_info "Deploying RapidFort Runtime to k0s cluster"
    
    # Check if k0s is running
    if ! k0s status &>/dev/null || ! kubectl cluster-info &>/dev/null; then
        log_error "k0s is not running. Install k0s first with: $0 install"
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
        "--set" "ClusterName=k0s"
        "--set" "ClusterCaption=k0s Cluster"
        "--set" "rapidfort.credentialsSecret=rfruntime-credentials"
        "--set" "variant=k0s"
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
    
    # If no registry IP provided, try to detect it
    if [[ -z "$registry_ip" ]]; then
        registry_ip=$(detect_registry_ip)
        
        if [[ -z "$registry_ip" ]]; then
            log_error "Could not determine registry IP address"
            log_error "Please specify with: $0 install --registry-ip <IP>"
            log_error "Or set RF_LOCAL_REGISTRY environment variable"
            exit 1
        fi
    fi
    
    log_info "Installing k0s cluster with registry at $registry_ip:5000"
    
    check_requirements
    check_existing_kubeconfig
    
    if is_k0s_installed && is_k0s_running; then
        log_warning "k0s already running"
        show_status
        return 0
    fi
    
    # Clean up any previous failed installation
    if is_k0s_installed && ! is_k0s_running; then
        log_warning "Found non-running k0s installation, cleaning up..."
        k0s stop 2>/dev/null || true
        k0s reset 2>/dev/null || true
        systemctl stop k0scontroller 2>/dev/null || true
        systemctl disable k0scontroller 2>/dev/null || true
        rm -rf /var/lib/k0s
    fi
    
    # Create k0s configuration
    create_k0s_config "$registry_ip"
    
    # Install k0s with multiple fallback methods
    log_info "Installing k0s version $K0S_VERSION..."
    
    # Detect system architecture
    local arch=$(get_system_arch)
    log_info "System architecture: $arch"
    
    # Method 1: Try get.k0s.sh script
    if curl -sSLf https://get.k0s.sh --connect-timeout 10 | K0S_VERSION="$K0S_VERSION" sh 2>/dev/null; then
        log_success "k0s installed via get.k0s.sh"
    else
        log_warning "Installation via get.k0s.sh failed, trying direct download..."
        
        # Method 2: Direct download from GitHub
        local k0s_url="https://github.com/k0sproject/k0s/releases/download/${K0S_VERSION}/k0s-${K0S_VERSION}-${arch}"
        log_info "Downloading from: $k0s_url"
        
        if curl -sSLf -o /tmp/k0s "$k0s_url" --connect-timeout 30; then
            chmod +x /tmp/k0s
            mv /tmp/k0s "$K0S_BINARY"
            log_success "k0s binary installed from GitHub"
        else
            # Method 3: Try with wget
            log_warning "curl failed, trying wget..."
            if command -v wget &> /dev/null; then
                if wget -q -O /tmp/k0s "$k0s_url" --timeout=30; then
                    chmod +x /tmp/k0s
                    mv /tmp/k0s "$K0S_BINARY"
                    log_success "k0s binary installed with wget"
                else
                    log_error "All download methods failed"
                    log_info "Manual installation required:"
                    echo "  1. Download k0s from: $k0s_url"
                    echo "  2. Copy to: $K0S_BINARY"
                    echo "  3. Make executable: chmod +x $K0S_BINARY"
                    exit 1
                fi
            else
                log_error "wget not available and curl failed"
                exit 1
            fi
        fi
    fi
    
    if ! is_k0s_installed; then
        log_error "k0s installation failed"
        exit 1
    fi
    
    log_info "Installing k0s as a service..."
    k0s install controller --single --config="$K0S_CONFIG"
    
    log_info "Starting k0s cluster..."
    k0s start
    
    # Wait for k0s API
    if ! wait_for_k0s_api; then
        log_error "k0s API failed to start. Check logs with: journalctl -u k0scontroller"
        exit 1
    fi
    
    # Setup kubeconfig
    log_info "Setting up kubeconfig..."
    mkdir -p ~/.kube
    k0s kubeconfig admin > "$KUBECONFIG_PATH"
    chmod 600 "$KUBECONFIG_PATH"
    export KUBECONFIG="$KUBECONFIG_PATH"
    
    # Wait for node to be ready
    log_info "Waiting for node to be ready..."
    local node_retries=30
    while [[ $node_retries -gt 0 ]]; do
        if kubectl get nodes | grep -q Ready; then
            log_success "Node is ready"
            break
        fi
        echo -n "."
        sleep 5
        ((node_retries--))
    done
    echo ""
    
    if [[ $node_retries -eq 0 ]]; then
        log_error "Node failed to become ready"
        show_debug
        exit 1
    fi
    
    # Wait for kube-system pods
    log_info "Waiting for system pods to be ready..."
    kubectl wait --for=condition=ready pod -n kube-system -l k8s-app=kube-dns --timeout=300s || true
    kubectl wait --for=condition=ready pod -n kube-system -l app=kube-router --timeout=300s || true
    
    # Install local storage provisioner FIRST
    log_info "Installing local storage provisioner..."
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.24/deploy/local-path-storage.yaml
    
    # Wait for storage provisioner
    log_info "Waiting for storage provisioner..."
    kubectl wait --for=condition=ready pod -n local-path-storage -l app=local-path-provisioner --timeout=300s
    
    # Set as default storage class
    kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    
    # Verify storage class
    kubectl get storageclass
    
    # Install ingress controller
    log_info "Installing ingress controller..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/baremetal/deploy.yaml
    
    # Create registry namespace
    kubectl create namespace registry
    
    # Install registry
    log_info "Installing registry with HTTP..."
    
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
    log_info "Waiting for registry to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/registry -n registry
    
    # Configure containerd
    log_info "Configuring containerd for registry..."
    
    # Create k0s containerd config that includes registry
    mkdir -p /etc/k0s/containerd.d
    cat > /etc/k0s/containerd.d/registry.toml << EOF
version = 2

[plugins."io.containerd.grpc.v1.cri"]
  [plugins."io.containerd.grpc.v1.cri".registry]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors."$registry_ip:5000"]
        endpoint = ["http://$registry_ip:5000"]
    [plugins."io.containerd.grpc.v1.cri".registry.configs]
      [plugins."io.containerd.grpc.v1.cri".registry.configs."$registry_ip:5000".tls]
        insecure_skip_verify = true
EOF
    
    # Restart k0s to pick up new containerd config
    log_info "Restarting k0s to pick up registry configuration..."
    k0s stop
    sleep 10
    k0s start
    
    # Wait for k0s to be ready again
    if ! wait_for_k0s_api; then
        log_error "k0s failed to restart properly"
        exit 1
    fi
    
    # Wait for node to be ready again
    log_info "Waiting for node to be ready after restart..."
    kubectl wait --for=condition=Ready node --all --timeout=120s
    
    # Test registry connectivity
    log_info "Testing registry connectivity..."
    sleep 10
    
    if curl -s "http://$registry_ip:5000/v2/" > /dev/null 2>&1; then
        log_success "Registry is accessible at http://$registry_ip:5000"
    else
        log_warning "Registry may not be fully ready yet"
    fi
    
    # Test with containerd
    log_info "Testing containerd can access registry..."
    ctr --address /run/k0s/containerd.sock --namespace k8s.io images pull docker.io/library/hello-world:latest || true
    ctr --address /run/k0s/containerd.sock --namespace k8s.io images tag docker.io/library/hello-world:latest $registry_ip:5000/hello-world:test || true
    ctr --address /run/k0s/containerd.sock --namespace k8s.io images push $registry_ip:5000/hello-world:test || true
    
    log_success "Installation completed!"
    
    echo ""
    log_info "Registry Details:"
    echo "  • Registry URL: http://$registry_ip:5000"
    echo ""
    log_info "Next steps:"
    echo "  # For docker (if using), configure insecure registry:"
    echo "  # Add to /etc/docker/daemon.json:"
    echo '  { "insecure-registries": ["'$registry_ip':5000"] }'
    echo "  # Then: systemctl restart docker"
    echo ""
    echo "  # Push with docker:"
    echo "  docker tag myimage:latest $registry_ip:5000/myimage:latest"
    echo "  docker push $registry_ip:5000/myimage:latest"
    echo ""
    echo "  # Use in Kubernetes:"
    echo "  image: $registry_ip:5000/myimage:latest"
    
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
    log_info "Useful commands:"
    echo "  # Check status: $0 status"
    echo "  # Debug issues: $0 debug"
    echo "  # Watch pods: watch kubectl get pods -A"
    
    echo ""
    log_warning "IMPORTANT: Set KUBECONFIG for kubectl to work:"
    echo "  export KUBECONFIG=$KUBECONFIG_PATH"
    echo ""
    echo "  Or add to your shell profile:"
    echo "  echo 'export KUBECONFIG=$KUBECONFIG_PATH' >> ~/.bashrc"
    echo "  source ~/.bashrc"
    
    # Test kubectl connectivity
    if KUBECONFIG="$KUBECONFIG_PATH" kubectl cluster-info &>/dev/null; then
        log_success "kubectl is properly configured and can connect to the cluster"
    else
        log_warning "kubectl cannot connect. Make sure to export KUBECONFIG=$KUBECONFIG_PATH"
    fi
}

# Function to uninstall everything
uninstall_all() {
    log_info "Uninstalling everything..."
    
    # Uninstall RapidFort Runtime if present
    if command -v helm &> /dev/null && helm list -n rapidfort 2>/dev/null | grep -q rfruntime; then
        log_info "Uninstalling RapidFort Runtime..."
        helm uninstall rfruntime -n rapidfort 2>/dev/null || true
        kubectl delete namespace rapidfort --force --grace-period=0 2>/dev/null || true
    fi
    
    if is_k0s_installed; then
        log_info "Stopping k0s..."
        k0s stop 2>/dev/null || true
        k0s reset 2>/dev/null || true
        k0s uninstall 2>/dev/null || true
        
        log_info "Removing k0s binary and data..."
        rm -f "$K0S_BINARY"
        rm -rf /var/lib/k0s/ /etc/k0s/ /opt/k0s/ /run/k0s/
        
        systemctl stop k0scontroller 2>/dev/null || true
        systemctl disable k0scontroller 2>/dev/null || true
    fi
    
    # Clean iptables rules - only on uninstall
    clean_iptables
    
    # Remove any remaining network interfaces
    log_info "Cleaning up network interfaces..."
    for iface in $(ip link show | grep -E "veth|cni|flannel|kube" | awk -F: '{print $2}' | tr -d ' '); do
        ip link delete $iface 2>/dev/null || true
    done
    
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
    log_info "iptables rules have been cleaned. Backup saved in /tmp/iptables-backup-*.rules"
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
                # Pass through for deploy-rapidfort
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
        "debug")
            show_debug
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