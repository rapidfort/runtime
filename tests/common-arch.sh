#!/bin/bash

# Common architecture detection functions for all Kubernetes deployment scripts
# Source this file in your scripts: source "$(dirname "$0")/../common-arch.sh"

# Function to detect system architecture for general use
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
            echo "Error: Unsupported architecture: $machine" >&2
            exit 1
            ;;
    esac

    echo "$arch"
}

# Function to get Docker/containerd platform string
get_docker_platform() {
    local arch=$(get_system_arch)
    echo "linux/$arch"
}

# Function to get Kubernetes binary architecture
# Some K8s projects use different naming conventions
get_k8s_arch() {
    local arch=""
    local machine=$(uname -m)

    case $machine in
        x86_64)
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
        ppc64le)
            arch="ppc64le"
            ;;
        s390x)
            arch="s390x"
            ;;
        *)
            echo "Error: Unsupported architecture: $machine" >&2
            exit 1
            ;;
    esac

    echo "$arch"
}

# Function to get CNI plugins architecture
# CNI uses slightly different naming for some architectures
get_cni_arch() {
    local arch=""
    local machine=$(uname -m)

    case $machine in
        x86_64)
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
        ppc64le)
            arch="ppc64le"
            ;;
        s390x)
            arch="s390x"
            ;;
        *)
            echo "Error: Unsupported architecture: $machine" >&2
            exit 1
            ;;
    esac

    echo "$arch"
}

# Function to get Docker repository architecture
# Docker sometimes uses different arch names in repo paths
get_docker_repo_arch() {
    local arch=""
    local machine=$(uname -m)

    case $machine in
        x86_64)
            arch="amd64"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        armv7l|armhf|armv7)
            arch="armhf"
            ;;
        s390x)
            arch="s390x"
            ;;
        ppc64le)
            arch="ppc64el"
            ;;
        *)
            # Default to machine name if not mapped
            arch="$machine"
            ;;
    esac

    echo "$arch"
}

# Function to check if architecture is supported by a tool
# Usage: check_arch_support "tool_name" "arch1 arch2 arch3"
check_arch_support() {
    local tool_name="$1"
    local supported_archs="$2"
    local current_arch=$(get_system_arch)

    if [[ " $supported_archs " =~ " $current_arch " ]]; then
        return 0
    else
        echo "Error: $tool_name does not support architecture: $current_arch ($(uname -m))" >&2
        echo "Supported architectures: $supported_archs" >&2
        return 1
    fi
}

# Export functions for use in sourcing scripts
export -f get_system_arch
export -f get_docker_platform
export -f get_k8s_arch
export -f get_cni_arch
export -f get_docker_repo_arch
export -f check_arch_support

