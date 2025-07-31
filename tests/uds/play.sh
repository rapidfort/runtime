#!/bin/bash

# UDS (Defense Unicorns) Installation and Management Script
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
UDS_PACKAGE_REPO="https://github.com/defenseunicorns/uds-package-jira"
UDS_WORK_DIR="/tmp/uds-work"
K3D_CLUSTER_NAME="uds-jira"

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
UDS (Defense Unicorns) Installation and Management Script

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    install         Install UDS with k3d, uds-core, and JIRA
    uninstall       Remove everything completely
    status          Show UDS cluster status
    deploy-rapidfort Deploy RapidFort Runtime to existing UDS cluster
    help            Show this help message

OPTIONS:
    --registry-ip   IP address for registry (optional, defaults to RF_LOCAL_REGISTRY)
    --local-registry Use local registry for RapidFort images
    --image-tag     Tag for RapidFort images (e.g., 3.1.32-dev6)
    -h, --help      Show this help

EXAMPLES:
    $0 install
    $0 status
    $0 deploy-rapidfort
    $0 deploy-rapidfort --local-registry --image-tag 3.1.32-dev6
    $0 uninstall

WHAT IT DOES:
    - Installs uds-cli
    - Installs k3d
    - Clones uds-package-jira repo
    - Runs 'uds run default' to create cluster
    - Applies RapidFort exemptions
    - Deploys RapidFort Runtime to default namespace
    - Labels JIRA namespace for profiling

PREREQUISITES:
    - Docker should be running
    - Git for cloning repositories
    - For RapidFort: ~/.rapidfort/credentials file
    - rfruntime-exemption.yaml file
    - jira-profiling-exemption.yaml file

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

    if ! command -v git &> /dev/null; then
        log_error "Git is required but not installed"
        exit 1
    fi

    log_success "System requirements check passed"
}

# Function to install uds-cli
install_uds_cli() {
    if command -v uds &> /dev/null; then
        log_info "uds-cli already installed"
        return
    fi

    log_info "Installing uds-cli..."
    
    # Get latest UDS CLI
    local arch=$(get_k8s_arch)
    local os="linux"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        os="darwin"
    fi
    
    # Download latest release
    local download_url="https://github.com/defenseunicorns/uds-cli/releases/latest/download/uds-cli_${os}_${arch}"
    
    log_info "Downloading from: $download_url"
    curl -L -o /tmp/uds "$download_url"
    chmod +x /tmp/uds
    
    # Install to /usr/local/bin
    if [[ -w /usr/local/bin ]]; then
        mv /tmp/uds /usr/local/bin/uds
    else
        sudo mv /tmp/uds /usr/local/bin/uds
    fi
    
    log_success "uds-cli installed"
}

# Function to install k3d
install_k3d() {
    if command -v k3d &> /dev/null; then
        log_info "k3d already installed"
        return
    fi

    log_info "Installing k3d..."
    
    # Install latest k3d
    curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
    
    log_success "k3d installed"
}

# Function to check if UDS is running
is_uds_running() {
    k3d cluster list 2>/dev/null | grep -q "^${K3D_CLUSTER_NAME}"
}

# Function to show status
show_status() {
    log_info "UDS Status Report"
    echo "=================="

    if ! command -v uds &> /dev/null; then
        log_warning "uds-cli not installed"
        return
    fi

    log_success "uds-cli installed: $(uds version)"

    if is_uds_running; then
        log_success "UDS cluster '$K3D_CLUSTER_NAME' is running"
        
        if command -v kubectl &> /dev/null; then
            echo ""
            log_info "Cluster nodes:"
            kubectl get nodes 2>/dev/null || echo "  Unable to get cluster info"
            
            echo ""
            log_info "UDS namespaces:"
            kubectl get ns | grep -E "(uds|jira|default)" || true
            
            # Check JIRA
            if kubectl get namespace jira &>/dev/null 2>&1; then
                echo ""
                log_info "JIRA status:"
                kubectl get pods -n jira --no-headers | head -5 || echo "  No JIRA pods found"
            fi
            
            # Check RapidFort Runtime
            echo ""
            log_info "RapidFort Runtime (in default namespace):"
            local rf_status=$(kubectl get pods -n default -l app=rfruntime --no-headers 2>/dev/null | grep -c Running || echo 0)
            if [[ "$rf_status" -gt 0 ]]; then
                log_success "RapidFort: Running ($rf_status pods)"
                kubectl get pods -n default -l app=rfruntime --no-headers | awk '{print "  " $1 " " $3}'
            else
                log_warning "RapidFort: Not running in default namespace"
            fi
        fi
    else
        log_warning "UDS cluster not running"
    fi
}

# Function to apply exemption files
apply_exemptions() {
    log_info "Applying RapidFort exemptions..."
    
    # Check for exemption files in script directory
    local exemption_dir="${SCRIPT_DIR}"
    
    # Check for rfruntime-exemption.yaml
    if [[ -f "$exemption_dir/rfruntime-exemption.yaml" ]]; then
        log_info "Applying rfruntime-exemption.yaml..."
        kubectl apply -f "$exemption_dir/rfruntime-exemption.yaml"
    else
        log_warning "rfruntime-exemption.yaml not found in $exemption_dir"
        log_info "Please ensure rfruntime-exemption.yaml is in the same directory as this script"
    fi
    
    # Check for jira-profiling-exemption.yaml
    if [[ -f "$exemption_dir/jira-profiling-exemption.yaml" ]]; then
        log_info "Applying jira-profiling-exemption.yaml..."
        kubectl apply -f "$exemption_dir/jira-profiling-exemption.yaml"
    else
        log_warning "jira-profiling-exemption.yaml not found in $exemption_dir"
        log_info "Please ensure jira-profiling-exemption.yaml is in the same directory as this script"
    fi
    
    log_success "Exemptions applied"
}

# Function to deploy RapidFort Runtime
deploy_rapidfort() {
    log_info "Deploying RapidFort Runtime to UDS cluster (default namespace)"
    
    # Check if UDS cluster is running
    if ! is_uds_running || ! kubectl cluster-info &>/dev/null; then
        log_error "UDS cluster is not running. Install UDS first with: $0 install"
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
    
    # Create credentials secret in default namespace
    kubectl create secret generic rfruntime-credentials \
        --namespace default \
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
        # Apply to default namespace
        kubectl apply -f - <<EOF
$(kubectl get secret rapidfort-registry-secret -n default -o yaml 2>/dev/null || cat "$registry_secret_path" | sed 's/namespace: .*/namespace: default/')
EOF
    fi
    
    # Deploy RapidFort Runtime to default namespace
    log_info "Installing RapidFort Runtime with Helm in default namespace..."
    
    local helm_args=(
        "upgrade" "--install" "rfruntime"
        "$runtime_chart"
        "--namespace" "default"  # Deploy to default namespace
        "--set" "ClusterName=uds"
        "--set" "ClusterCaption=UDS Cluster"
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
        log_success "RapidFort Runtime helm chart installed in default namespace"
    else
        log_error "Helm installation failed"
        kubectl describe pods -n default -l app=rfruntime
        exit 1
    fi
    
    # Label JIRA namespace for profiling
    log_info "Labeling JIRA namespace for profiling..."
    kubectl label namespace jira rapidfort.io/profile=enabled --overwrite || log_warning "Failed to label JIRA namespace"
    
    # Check deployment
    log_info "Waiting for RapidFort Runtime pods to be ready..."
    if kubectl wait --for=condition=ready pod -l app=rfruntime -n default --timeout=300s; then
        log_success "RapidFort Runtime deployed successfully"
        kubectl get pods -n default -l app=rfruntime -o wide
        
        # Delete JIRA pod to trigger restart with profiling
        log_info "Restarting JIRA pods to enable profiling..."
        kubectl delete pods -n jira --all || log_warning "Failed to restart JIRA pods"
        
    else
        log_error "RapidFort Runtime deployment failed"
        kubectl describe pods -n default -l app=rfruntime
        exit 1
    fi
}

# Function to install UDS
install_all() {
    local registry_ip="$1"
    
    log_info "Installing UDS with k3d, uds-core, and JIRA"
    
    check_requirements
    
    # Install uds-cli
    install_uds_cli
    
    # Install k3d
    install_k3d
    
    # Create work directory
    mkdir -p "$UDS_WORK_DIR"
    cd "$UDS_WORK_DIR"
    
    # Clone uds-package-jira repo
    log_info "Cloning uds-package-jira repository..."
    if [[ -d "uds-package-jira" ]]; then
        log_info "Repository already exists, updating..."
        cd uds-package-jira
        git pull
    else
        git clone "$UDS_PACKAGE_REPO"
        cd uds-package-jira
    fi
    
    # Run uds default deployment
    log_info "Running 'uds run default' to create k3d cluster, install uds-core, and JIRA..."
    log_info "This may take 10-15 minutes..."
    
    if uds run default; then
        log_success "UDS deployment completed"
    else
        log_error "UDS deployment failed"
        exit 1
    fi
    
    # Setup kubeconfig
    log_info "Setting up kubeconfig..."
    mkdir -p ~/.kube
    k3d kubeconfig get "$K3D_CLUSTER_NAME" > "$KUBECONFIG_PATH"
    chmod 600 "$KUBECONFIG_PATH"
    export KUBECONFIG="$KUBECONFIG_PATH"
    
    # Wait for cluster to stabilize
    log_info "Waiting for cluster to stabilize..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s || log_warning "Some nodes not ready yet"
    
    # Apply exemptions
    apply_exemptions
    
    log_success "UDS installation completed!"
    
    echo ""
    log_info "UDS Cluster Details:"
    echo "  • k3d cluster: $K3D_CLUSTER_NAME"
    echo "  • UDS Core installed"
    echo "  • JIRA installed"
    echo "  • Exemptions applied"
    echo ""
    
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
    
    # Delete k3d cluster
    if is_uds_running; then
        log_info "Deleting UDS k3d cluster..."
        k3d cluster delete "$K3D_CLUSTER_NAME"
    fi
    
    # Clean up work directory
    if [[ -d "$UDS_WORK_DIR" ]]; then
        log_info "Cleaning up work directory..."
        rm -rf "$UDS_WORK_DIR"
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