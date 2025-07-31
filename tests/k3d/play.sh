#!/bin/bash

# k3d Installation and Management Script
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
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-k3d-cluster}"
REGISTRY_NAME="${K3D_CLUSTER_NAME}-registry"
REGISTRY_PORT="5000"

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
k3d Installation and Management Script

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    install         Install k3d cluster with registry
    uninstall       Remove everything completely
    status          Show k3d and registry status
    deploy-rapidfort Deploy RapidFort Runtime to existing k3d cluster
    help            Show this help message

OPTIONS:
    --registry-ip   IP address for registry (optional, defaults to RF_LOCAL_REGISTRY)
    --cluster-name  k3d cluster name (default: k3d-cluster)
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
    - Installs k3d (k3s in Docker)
    - Creates cluster with built-in registry
    - Configures ingress controller
    - Automatically deploys RapidFort Runtime if credentials found

PREREQUISITES:
    - Docker should be running
    - RF_LOCAL_REGISTRY environment variable (or --registry-ip)

EOF
}

# Function to check system requirements
check_requirements() {
    log_info "Checking system requirements..."

    if ! command -v docker &> /dev/null; then
        log_error "Docker is required but not installed"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        log_error "Docker is not running. Please start docker first."
        exit 1
    fi

    log_success "System requirements check passed"
}

# Function to check if k3d is installed
is_k3d_installed() {
    command -v k3d &> /dev/null
}

# Function to install k3d binary
install_k3d_binary() {
    if is_k3d_installed; then
        log_info "k3d already installed"
        return
    fi

    log_info "Installing k3d binary..."
    
    # Install latest k3d
    curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
    
    log_success "k3d binary installed"
}

# Function to check if k3d cluster is running
is_k3d_running() {
    k3d cluster list 2>/dev/null | grep -q "^${K3D_CLUSTER_NAME}"
}

# Function to get k3d version
get_k3d_version() {
    if is_k3d_installed; then
        k3d version --short 2>/dev/null || echo "unknown"
    else
        echo "not installed"
    fi
}

# Function to show status
show_status() {
    log_info "k3d Status Report"
    echo "=================="

    if is_k3d_installed; then
        log_success "k3d installed: $(get_k3d_version)"
    else
        log_warning "k3d not installed"
        return
    fi

    if is_k3d_running; then
        log_success "k3d cluster '$K3D_CLUSTER_NAME' is running"
        
        echo ""
        log_info "Cluster info:"
        k3d cluster list | grep "${K3D_CLUSTER_NAME}"
        
        if command -v kubectl &> /dev/null; then
            echo ""
            log_info "Cluster nodes:"
            kubectl get nodes 2>/dev/null || echo "  Unable to get cluster info"
            
            # Check RapidFort Runtime
            if kubectl get namespace rapidfort &>/dev/null 2>&1; then
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
        log_warning "k3d cluster not running"
    fi
}

# Function to deploy RapidFort Runtime
deploy_rapidfort() {
    log_info "Deploying RapidFort Runtime to k3d cluster"
    
    # Check if k3d cluster is running
    if ! k3d cluster list 2>/dev/null | grep -q "^${K3D_CLUSTER_NAME}"; then
        log_error "k3d cluster is not running. Install k3d first with: $0 install"
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
        "--set" "ClusterName=k3d"
        "--set" "ClusterCaption=k3d Cluster"
        "--set" "rapidfort.credentialsSecret=rfruntime-credentials"
        "--set" "variant=k3s"
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

# Function to install k3d cluster
install_all() {
    local registry_ip="$1"
    
    if [[ -z "$registry_ip" ]]; then
        registry_ip=$(detect_host_ip)
        if [[ -z "$registry_ip" ]]; then
            log_error "Could not determine registry IP. Please set RF_LOCAL_REGISTRY or use --registry-ip"
            exit 1
        fi
    fi
    
    log_info "Installing k3d cluster with registry at $registry_ip:$REGISTRY_PORT"
    
    check_requirements
    
    # Check for existing kubeconfig
    if [[ -f "$KUBECONFIG_PATH" ]]; then
        log_warning "Existing kubeconfig found, backing up..."
        mv "$KUBECONFIG_PATH" "$KUBECONFIG_PATH.backup"
    fi
    
    if is_k3d_running; then
        log_warning "k3d cluster already running"
        show_status
        return 0
    fi
    
    # Install k3d binary
    install_k3d_binary
    
    # Create k3d cluster with registry
    log_info "Creating k3d cluster with registry..."
    
    # Create registry config for k3d
    cat > /tmp/k3d-registries.yaml << EOF
mirrors:
  "${registry_ip}:${REGISTRY_PORT}":
    endpoint:
      - "http://${REGISTRY_NAME}:5000"
  "${REGISTRY_NAME}:5000":
    endpoint:
      - "http://${REGISTRY_NAME}:5000"
configs:
  "${registry_ip}:${REGISTRY_PORT}":
    tls:
      insecure_skip_verify: true
  "${REGISTRY_NAME}:5000":
    tls:
      insecure_skip_verify: true
EOF
    
    # Create cluster with registry
    k3d cluster create "${K3D_CLUSTER_NAME}" \
        --api-port 6550 \
        --servers 1 \
        --agents 0 \
        --port "80:80@loadbalancer" \
        --port "443:443@loadbalancer" \
        --registry-create "${REGISTRY_NAME}:0.0.0.0:${REGISTRY_PORT}" \
        --registry-config /tmp/k3d-registries.yaml \
        --k3s-arg "--disable=traefik@server:0" \
        --wait
    
    # Clean up temp file
    rm -f /tmp/k3d-registries.yaml
    
    # Setup kubeconfig
    log_info "Setting up kubeconfig..."
    mkdir -p ~/.kube
    k3d kubeconfig get "${K3D_CLUSTER_NAME}" > "$KUBECONFIG_PATH"
    chmod 600 "$KUBECONFIG_PATH"
    export KUBECONFIG="$KUBECONFIG_PATH"
    
    # Install NGINX ingress controller
    log_info "Installing NGINX ingress controller..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/cloud/deploy.yaml
    
    # Wait for ingress controller
    log_info "Waiting for ingress controller..."
    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=300s || log_warning "Ingress taking longer to start, continuing..."
    
    # Test registry
    log_info "Testing registry connectivity..."
    sleep 5
    
    if curl -s "http://$registry_ip:$REGISTRY_PORT/v2/" > /dev/null 2>&1; then
        log_success "Registry is accessible"
    else
        log_warning "Registry may not be fully ready yet"
    fi
    
    log_success "Installation completed!"
    
    echo ""
    log_info "Cluster Details:"
    echo "  • k3d cluster: $K3D_CLUSTER_NAME"
    echo "  • Registry: $registry_ip:$REGISTRY_PORT"
    echo "  • Ingress: NGINX"
    echo ""
    log_info "Usage:"
    echo "  # Push images:"
    echo "  docker tag myimage:latest $registry_ip:$REGISTRY_PORT/myimage:latest"
    echo "  docker push $registry_ip:$REGISTRY_PORT/myimage:latest"
    echo ""
    echo "  # Use in Kubernetes:"
    echo "  image: ${REGISTRY_NAME}:5000/myimage:latest"
    
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
    
    # Delete k3d cluster
    if is_k3d_running; then
        log_info "Deleting k3d cluster..."
        k3d cluster delete "${K3D_CLUSTER_NAME}"
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
    local cluster_name=""
    
    shift || true
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --registry-ip)
                registry_ip="$2"
                shift 2
                ;;
            --cluster-name)
                K3D_CLUSTER_NAME="$2"
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