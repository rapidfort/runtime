#!/bin/bash

# MicroK8s Installation and Management Script
# Usage: ./play.sh [install|uninstall|status|help]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration
KUBECONFIG_PATH="$HOME/.kube/config"

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
MicroK8s Installation and Management Script

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    install         Install MicroK8s cluster with registry, ingress, and RapidFort Runtime
    uninstall       Remove everything completely
    status          Show MicroK8s and registry status
    deploy-rapidfort Deploy RapidFort Runtime to existing MicroK8s cluster
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
    - Installs MicroK8s cluster
    - Enables registry addon on IP:5000
    - Enables ingress addon
    - Configures containerd for registry access
    - Automatically deploys RapidFort Runtime if credentials found

REGISTRY:
    - Uses RF_LOCAL_REGISTRY environment variable (or --registry-ip)
    - Registry accessible at RF_LOCAL_REGISTRY:5000

RAPIDFORT RUNTIME:
    - Automatically deployed if both exist:
      1. ~/.rapidfort/credentials
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

    local required_commands=("snap")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command '$cmd' not found. Install snapd first."
            exit 1
        fi
    done

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

# Function to check if MicroK8s is installed
is_microk8s_installed() {
    snap list microk8s &>/dev/null
}

# Function to check if MicroK8s is running
is_microk8s_running() {
    microk8s status --wait-ready --timeout 5 &>/dev/null
}

# Function to get MicroK8s version
get_microk8s_version() {
    if is_microk8s_installed; then
        microk8s version --short 2>/dev/null | head -n1 || echo "unknown"
    else
        echo "not installed"
    fi
}

# Function to show status
show_status() {
    log_info "MicroK8s Status Report"
    echo "======================"

    if is_microk8s_installed; then
        log_success "MicroK8s installed: $(get_microk8s_version)"
    else
        log_warning "MicroK8s not installed"
        return
    fi

    if is_microk8s_running; then
        log_success "MicroK8s is running"

        echo ""
        log_info "Enabled addons:"
        microk8s status | grep "enabled:" -A 20 | grep -E "(registry|ingress)" || echo "  No registry/ingress addons enabled"

        if [[ -f "$KUBECONFIG_PATH" ]] && command -v kubectl &> /dev/null; then
            echo ""
            log_info "Cluster nodes:"
            kubectl get nodes 2>/dev/null || echo "  Unable to get cluster info"

            # Check registry
            if microk8s status | grep -q "registry.*enabled"; then
                echo ""
                log_info "Registry status:"
                local registry_pod_status=$(kubectl get pods -n container-registry -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
                if [[ "$registry_pod_status" == "Running" ]]; then
                    log_success "Registry: Running on port 5000"
                    local external_ip=$(kubectl get svc registry -n container-registry -o jsonpath='{.spec.externalIPs[0]}' 2>/dev/null)
                    if [[ -n "$external_ip" ]]; then
                        echo "  External IP: $external_ip:5000"
                    fi
                else
                    log_warning "Registry: Not ready"
                fi
            fi

            # Check ingress
            if microk8s status | grep -q "ingress.*enabled"; then
                echo ""
                log_info "Ingress controller:"
                local ingress_status=$(kubectl get daemonset nginx-ingress-microk8s-controller -n ingress -o jsonpath='{.status.numberReady}' 2>/dev/null)
                if [[ -n "$ingress_status" ]] && [[ "$ingress_status" -gt 0 ]]; then
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
        log_warning "MicroK8s not running"
    fi
}

# Function to deploy RapidFort Runtime
deploy_rapidfort() {
    log_info "Deploying RapidFort Runtime to microk8s cluster"
    
    # Check if MicroK8s is running
    if ! microk8s status --wait-ready --timeout 5 &>/dev/null; then
        log_error "MicroK8s is not running. Install MicroK8s first with: $0 install"
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
        "--set" "ClusterName=microk8s"
        "--set" "ClusterCaption=microk8s Cluster"
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

    log_info "Installing MicroK8s cluster with registry at $registry_ip:5000"

    check_requirements
    check_existing_kubeconfig

    if is_microk8s_installed && is_microk8s_running; then
        log_warning "MicroK8s already running"
        show_status
        return 0
    fi

    # Install MicroK8s
    log_info "Installing MicroK8s..."
    snap install microk8s --classic

    # Add user to microk8s group
    usermod -a -G microk8s $USER
    chown -f -R $USER ~/.kube || true

    # Wait for MicroK8s to be ready
    log_info "Waiting for MicroK8s to be ready..."
    microk8s status --wait-ready --timeout 300

    log_success "MicroK8s is ready"

    # Setup kubeconfig
    log_info "Setting up kubeconfig..."
    mkdir -p ~/.kube
    microk8s config > "$KUBECONFIG_PATH"
    chmod 600 "$KUBECONFIG_PATH"

    # Enable DNS addon first
    log_info "Enabling DNS addon..."
    microk8s enable dns

    # Enable registry addon
    log_info "Enabling registry addon..."
    microk8s enable registry

    # Wait for registry to be ready
    log_info "Waiting for registry to be ready..."
    kubectl wait --for=condition=ready pod -l app=registry -n container-registry --timeout=300s

    # Enable ingress addon
    log_info "Enabling ingress addon..."
    microk8s enable ingress

    # Wait for ingress to be ready
    log_info "Waiting for ingress controller..."
    kubectl wait --for=condition=ready pod -l name=nginx-ingress-microk8s -n ingress --timeout=300s || log_warning "Ingress taking longer to start, continuing..."

    # Configure registry for external access
    log_info "Configuring registry for external access on $registry_ip:5000..."

    # Patch registry service to use port 5000 instead of 32000
    log_info "Configuring registry to use port 5000..."
    kubectl patch service registry -n container-registry -p '{"spec":{"ports":[{"port":5000,"targetPort":5000,"nodePort":30500,"protocol":"TCP"}]}}'

    # Patch registry service to use the specified external IP
    kubectl patch service registry -n container-registry -p '{"spec":{"externalIPs":["'$registry_ip'"]}}'

    # Configure containerd for the registry
    log_info "Configuring containerd for registry..."

    # MicroK8s containerd config directory
    mkdir -p "/var/snap/microk8s/current/args/certs.d/$registry_ip:5000"

    cat > "/var/snap/microk8s/current/args/certs.d/$registry_ip:5000/hosts.toml" << EOF
server = "http://$registry_ip:5000"

[host."http://$registry_ip:5000"]
capabilities = ["pull", "resolve", "push"]
skip_verify = true

[host."http://localhost:5000"]
capabilities = ["pull", "resolve", "push"]
skip_verify = true
EOF

    # Restart MicroK8s to pick up containerd config
    log_info "Restarting MicroK8s to pick up registry configuration..."
    microk8s stop
    sleep 5
    microk8s start
    microk8s status --wait-ready --timeout 120

    # Test registry
    log_info "Testing registry connectivity..."
    sleep 10

    if curl -s "http://$registry_ip:5000/v2/" > /dev/null 2>&1; then
        log_success "Registry is accessible at $registry_ip:5000"
    else
        log_warning "Registry may not be fully ready yet"
    fi

    # Test with a real image
    log_info "Testing image push/pull..."
    if command -v docker &> /dev/null; then
        docker pull hello-world:latest
        docker tag hello-world:latest $registry_ip:5000/hello-world:test
        docker push $registry_ip:5000/hello-world:test

        # Test Kubernetes can pull the image
        kubectl run test-registry --image=$registry_ip:5000/hello-world:test --command -- sleep 30
        kubectl wait --for=condition=ready pod/test-registry --timeout=60s && log_success "Kubernetes can pull from registry" || log_warning "Kubernetes pull test failed"
        kubectl delete pod test-registry --force
    fi

    log_success "Installation completed!"

    echo ""
    log_info "Registry Details:"
    echo "  • Registry URL: http://$registry_ip:5000"
    echo "  • Internal URL: http://localhost:5000"
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
    log_info "MicroK8s Commands:"
    echo "  # Check status: microk8s status"
    echo "  # Enable addon: microk8s enable <addon>"
    echo "  # Use kubectl: microk8s kubectl <command>"
}

# Function to uninstall everything
uninstall_all() {
    log_info "Uninstalling everything..."

    # Uninstall RapidFort Runtime if present
    if command -v helm &> /dev/null && is_microk8s_installed && is_microk8s_running; then
        if kubectl get namespace rapidfort &>/dev/null 2>&1; then
            if helm list -n rapidfort 2>/dev/null | grep -q rfruntime; then
                log_info "Uninstalling RapidFort Runtime..."
                helm uninstall rfruntime -n rapidfort 2>/dev/null || true
                kubectl delete namespace rapidfort --force --grace-period=0 2>/dev/null || true
            fi
        fi
    fi

    if is_microk8s_installed; then
        log_info "Stopping MicroK8s..."
        microk8s stop 2>/dev/null || true

        log_info "Removing MicroK8s..."
        snap remove microk8s --purge

        log_info "Cleaning up containerd config..."
        rm -rf /var/snap/microk8s/
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