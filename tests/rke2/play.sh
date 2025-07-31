#!/bin/bash

# RKE2 Installation and Management Script
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
RKE2_CONFIG="/etc/rancher/rke2/config.yaml"
RKE2_VERSION="${RKE2_VERSION:-latest}"

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
RKE2 Installation and Management Script

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    install         Install RKE2 cluster with registry and RapidFort Runtime
    uninstall       Remove everything completely
    status          Show RKE2 status
    deploy-rapidfort Deploy RapidFort Runtime to existing RKE2 cluster
    help            Show this help message

OPTIONS:
    --registry-ip   IP address for registry (optional, defaults to RF_LOCAL_REGISTRY)
    --version       RKE2 version to install (default: latest)
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
    - Installs RKE2 (Rancher Kubernetes Engine 2)
    - Deploys container registry on IP:5000
    - Uses built-in Nginx ingress controller
    - Configures containerd for registry access
    - Automatically deploys RapidFort Runtime if credentials found

PREREQUISITES:
    - RF_LOCAL_REGISTRY environment variable (or --registry-ip)
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

    # Check system resources
    local mem_available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    if [[ $mem_available -lt 4194304 ]]; then  # 4GB in KB
        log_warning "Less than 4GB of available memory. RKE2 may have issues."
    fi

    local cpu_count=$(nproc)
    if [[ $cpu_count -lt 2 ]]; then
        log_warning "Less than 2 CPUs detected. RKE2 may run slowly."
    fi

    log_success "System requirements check passed"
}

# Function to check if RKE2 is installed
is_rke2_installed() {
    command -v rke2 &> /dev/null || [[ -f /usr/local/bin/rke2 ]]
}

# Function to check if RKE2 is running
is_rke2_running() {
    systemctl is-active --quiet rke2-server 2>/dev/null
}

# Function to get RKE2 version
get_rke2_version() {
    if is_rke2_installed; then
        rke2 --version 2>/dev/null | head -n1 || echo "unknown"
    else
        echo "not installed"
    fi
}

# Function to show status
show_status() {
    log_info "RKE2 Status Report"
    echo "=================="

    if is_rke2_installed; then
        log_success "RKE2 installed: $(get_rke2_version)"
    else
        log_warning "RKE2 not installed"
        return
    fi

    if is_rke2_running; then
        log_success "RKE2 is running"

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
        log_warning "RKE2 not running"
    fi
}

# Function to deploy RapidFort Runtime
deploy_rapidfort() {
    log_info "Deploying RapidFort Runtime to RKE2 cluster"
    
    # Check if RKE2 is running
    if ! systemctl is-active --quiet rke2-server || ! kubectl cluster-info &>/dev/null; then
        log_error "RKE2 is not running. Install RKE2 first with: $0 install"
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
        "--set" "ClusterName=rke2"
        "--set" "ClusterCaption=RKE2 Cluster"
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
    local rke2_version="${2:-$RKE2_VERSION}"

    # If no registry IP provided, use RF_LOCAL_REGISTRY or auto-detect
    if [[ -z "$registry_ip" ]]; then
        registry_ip=$(detect_host_ip)
        if [[ -z "$registry_ip" ]]; then
            log_error "Could not determine registry IP. Please set RF_LOCAL_REGISTRY or use --registry-ip"
            exit 1
        fi
    fi

    log_info "Installing RKE2 cluster with registry at $registry_ip:5000"

    check_requirements

    # Check for existing kubeconfig
    if [[ -f "$KUBECONFIG_PATH" ]]; then
        log_warning "Existing kubeconfig found, backing up..."
        mv "$KUBECONFIG_PATH" "$KUBECONFIG_PATH.backup"
    fi

    if is_rke2_installed && is_rke2_running; then
        log_warning "RKE2 already running"
        show_status
        return 0
    fi

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

    # Install RKE2
    log_info "Installing RKE2..."
    
    # Download and run installation script
    curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="$rke2_version" sh -

    # Create RKE2 config directory
    mkdir -p /etc/rancher/rke2

    # Create RKE2 config
    cat > "$RKE2_CONFIG" << EOF
write-kubeconfig-mode: "0644"
tls-san:
  - $registry_ip
node-label:
  - "ingress-ready=true"
disable:
  - rke2-ingress-nginx
private-registry: "/etc/rancher/rke2/registries.yaml"
EOF

    # Configure registry
    cat > /etc/rancher/rke2/registries.yaml << EOF
mirrors:
  "$registry_ip:5000":
    endpoint:
      - "http://$registry_ip:5000"
configs:
  "$registry_ip:5000":
    tls:
      insecure_skip_verify: true
EOF

    # Enable and start RKE2
    systemctl enable rke2-server.service
    systemctl start rke2-server.service

    # Wait for RKE2 to be ready
    log_info "Waiting for RKE2 to be ready..."
    local retries=60
    while [[ $retries -gt 0 ]]; do
        if systemctl is-active --quiet rke2-server && [[ -f /etc/rancher/rke2/rke2.yaml ]]; then
            break
        fi
        sleep 5
        ((retries--))
    done

    if [[ $retries -eq 0 ]]; then
        log_error "RKE2 failed to start properly"
        exit 1
    fi

    # Setup kubeconfig
    log_info "Setting up kubeconfig..."
    mkdir -p ~/.kube
    cp -f /etc/rancher/rke2/rke2.yaml "$KUBECONFIG_PATH"
    chmod 600 "$KUBECONFIG_PATH"
    export KUBECONFIG="$KUBECONFIG_PATH"

    # Add kubectl and other tools to PATH
    export PATH="/var/lib/rancher/rke2/bin:$PATH"
    echo 'export PATH="/var/lib/rancher/rke2/bin:$PATH"' >> ~/.bashrc

    # Wait for nodes to be ready
    log_info "Waiting for nodes to be ready..."
    /var/lib/rancher/rke2/bin/kubectl wait --for=condition=Ready nodes --all --timeout=300s

    # Install NGINX ingress controller
    log_info "Installing NGINX ingress controller..."
    /var/lib/rancher/rke2/bin/kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/baremetal/deploy.yaml

    # Wait for ingress controller
    log_info "Waiting for ingress controller..."
    /var/lib/rancher/rke2/bin/kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=300s || log_warning "Ingress taking longer to start, continuing..."

    # Install registry
    log_info "Installing registry with HTTP..."

    /var/lib/rancher/rke2/bin/kubectl create namespace registry

    # Deploy registry
    cat << EOF | /var/lib/rancher/rke2/bin/kubectl apply -f -
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
    /var/lib/rancher/rke2/bin/kubectl wait --for=condition=available --timeout=300s deployment/registry -n registry

    # Test registry
    log_info "Testing registry connectivity..."
    sleep 10

    if curl -s "http://$registry_ip:5000/v2/" > /dev/null 2>&1; then
        log_success "Registry is accessible"
    else
        log_warning "Registry may not be fully ready yet"
    fi

    log_success "Installation completed!"

    echo ""
    log_info "Registry Details:"
    echo "  • Registry URL: http://$registry_ip:5000"
    echo ""
    log_info "Usage:"
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
    log_info "RKE2 Commands:"
    echo "  # Check status: systemctl status rke2-server"
    echo "  # Check logs: journalctl -u rke2-server -f"
    echo "  # RKE2 kubectl: /var/lib/rancher/rke2/bin/kubectl"
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

    if is_rke2_installed; then
        log_info "Stopping RKE2..."
        systemctl stop rke2-server 2>/dev/null || true
        systemctl disable rke2-server 2>/dev/null || true

        log_info "Running RKE2 uninstall script..."
        /usr/local/bin/rke2-uninstall.sh 2>/dev/null || true

        log_info "Cleaning up RKE2 configuration..."
        rm -rf /etc/rancher/rke2
        rm -rf /var/lib/rancher/rke2
        rm -f /usr/local/bin/rke2
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
    local rke2_version="$RKE2_VERSION"

    shift || true

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --registry-ip)
                registry_ip="$2"
                shift 2
                ;;
            --version)
                rke2_version="$2"
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
            install_all "$registry_ip" "$rke2_version"
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