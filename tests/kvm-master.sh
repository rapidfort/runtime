#!/bin/bash

# KVM Master Management Script with Windows Support
# For Debian/Ubuntu headless systems
# Supports Ubuntu 20.04, 22.04, 24.04 and Windows 10/11/Server VMs

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
VM_DIR="/var/lib/libvirt/images"
CLOUD_IMG_DIR="/var/lib/libvirt/cloud-images"
ISO_DIR="/var/lib/libvirt/iso"
DRIVERS_DIR="/var/lib/libvirt/drivers"
DEFAULT_MEMORY=4096  # MB
DEFAULT_VCPUS=2
DEFAULT_DISK_SIZE=20 # GB
DEFAULT_NETWORK="default"

# Windows specific defaults
WINDOWS_DEFAULT_MEMORY=8192  # MB
WINDOWS_DEFAULT_VCPUS=4
WINDOWS_DEFAULT_DISK_SIZE=60 # GB

# Cloud image URLs for Ubuntu
declare -A CLOUD_IMAGES=(
    ["ubuntu20"]="https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"
    ["ubuntu22"]="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
    ["ubuntu24"]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
)

# Windows ISO URLs (evaluation versions for testing)
declare -A WINDOWS_EVAL_URLS=(
    ["win10"]="https://www.microsoft.com/en-us/evalcenter/download-windows-10-enterprise"
    ["win11"]="https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise"
    ["win2022"]="https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022"
)

# VirtIO drivers URL
VIRTIO_DRIVERS_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

# Function to print colored output
print_msg() {
    local color=$1
    local msg=$2
    echo -e "${color}${msg}${NC}"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_msg $RED "This script must be run as root"
        exit 1
    fi
}

# Detect distribution
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        print_msg $RED "Cannot detect OS"
        exit 1
    fi
}

# Install KVM and dependencies
install_kvm() {
    print_msg $BLUE "Installing KVM and dependencies..."

    detect_distro

    if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
        apt-get update
        apt-get install -y \
            qemu-kvm \
            libvirt-daemon-system \
            libvirt-clients \
            bridge-utils \
            virtinst \
            cloud-image-utils \
            cpu-checker \
            libguestfs-tools \
            libosinfo-bin \
            wget \
            whois \
            ovmf \
            swtpm \
            swtpm-tools
    else
        print_msg $RED "Unsupported distribution: $OS"
        exit 1
    fi

    # Enable and start libvirtd
    systemctl enable libvirtd
    systemctl start libvirtd

    # Create directories
    mkdir -p "$VM_DIR" "$CLOUD_IMG_DIR" "$ISO_DIR" "$DRIVERS_DIR"

    # Download VirtIO drivers for Windows
    download_virtio_drivers

    print_msg $GREEN "KVM installation completed!"
}

# Download VirtIO drivers
download_virtio_drivers() {
    local virtio_iso="$DRIVERS_DIR/virtio-win.iso"

    if [ ! -f "$virtio_iso" ]; then
        print_msg $BLUE "Downloading VirtIO drivers for Windows..."
        wget -q --show-progress -O "$virtio_iso" "$VIRTIO_DRIVERS_URL"
        print_msg $GREEN "VirtIO drivers downloaded!"
    else
        print_msg $YELLOW "VirtIO drivers already exist"
    fi
}

# Check KVM capabilities
check_kvm() {
    print_msg $BLUE "Checking KVM capabilities..."

    if ! kvm-ok &>/dev/null; then
        print_msg $RED "KVM acceleration not available. Check BIOS virtualization settings."
        exit 1
    fi

    if ! systemctl is-active --quiet libvirtd; then
        print_msg $RED "libvirtd is not running"
        exit 1
    fi

    print_msg $GREEN "KVM is ready!"
}

# Setup default network if not exists
setup_network() {
    print_msg $BLUE "Setting up network..."

    if ! virsh net-info default &>/dev/null; then
        print_msg $YELLOW "Creating default network..."
        virsh net-define /dev/stdin <<EOF
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
EOF
        virsh net-start default
        virsh net-autostart default
    fi

    print_msg $GREEN "Network setup completed!"
}

# Check for Windows ISO
check_windows_iso() {
    local os_type=$1
    local iso_path=""

    case $os_type in
        win10)
            iso_path="$ISO_DIR/win10.iso"
            ;;
        win11)
            iso_path="$ISO_DIR/win11.iso"
            ;;
        win2022)
            iso_path="$ISO_DIR/win2022.iso"
            ;;
    esac

    if [ ! -f "$iso_path" ]; then
        print_msg $YELLOW "Windows ISO not found at: $iso_path"
        print_msg $YELLOW "Please download the Windows ISO and place it at: $iso_path"
        print_msg $YELLOW "Download from: ${WINDOWS_EVAL_URLS[$os_type]}"
        return 1
    fi

    echo "$iso_path"
}

# Create Windows VM
create_windows_vm() {
    local vm_name=$1
    local os_type=$2
    local memory=${3:-$WINDOWS_DEFAULT_MEMORY}
    local vcpus=${4:-$WINDOWS_DEFAULT_VCPUS}
    local disk_size=${5:-$WINDOWS_DEFAULT_DISK_SIZE}

    print_msg $BLUE "Creating Windows VM: $vm_name"

    # Check if VM already exists
    if virsh dominfo "$vm_name" &>/dev/null; then
        print_msg $RED "VM $vm_name already exists!"
        return 1
    fi

    # Check for Windows ISO
    local iso_path=$(check_windows_iso "$os_type")
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Create VM disk
    local vm_disk="$VM_DIR/${vm_name}.qcow2"
    print_msg $BLUE "Creating VM disk..."
    qemu-img create -f qcow2 "$vm_disk" "${disk_size}G"

    # Get OS variant
    local os_variant=""
    local needs_tpm="no"
    case $os_type in
        win10)
            os_variant="win10"
            ;;
        win11)
            os_variant="win11"
            needs_tpm="yes"
            ;;
        win2022)
            os_variant="win2k22"
            ;;
    esac

    # VirtIO drivers ISO
    local virtio_iso="$DRIVERS_DIR/virtio-win.iso"

    # Build virt-install command
    local virt_install_cmd="virt-install \
        --name \"$vm_name\" \
        --memory \"$memory\" \
        --vcpus \"$vcpus\" \
        --disk \"$vm_disk\",device=disk,bus=virtio \
        --disk \"$virtio_iso\",device=cdrom \
        --cdrom \"$iso_path\" \
        --os-variant \"$os_variant\" \
        --network network=\"$DEFAULT_NETWORK\",model=virtio \
        --graphics vnc,listen=0.0.0.0 \
        --video qxl \
        --boot uefi"

    # Add TPM for Windows 11
    if [ "$needs_tpm" = "yes" ]; then
        # Create TPM directory for this VM
        local tpm_dir="/var/lib/libvirt/swtpm/${vm_name}"
        mkdir -p "$tpm_dir"

        virt_install_cmd="$virt_install_cmd --tpm backend.type=emulator,backend.version=2.0,model=tpm-tis"
    fi

    # Add noautoconsole for headless
    virt_install_cmd="$virt_install_cmd --noautoconsole"

    print_msg $BLUE "Creating Windows VM with virt-install..."
    eval $virt_install_cmd

    # Get VNC port
    local vnc_port=$(virsh vncdisplay "$vm_name" | sed 's/://g')
    if [ -n "$vnc_port" ]; then
        vnc_port=$((5900 + vnc_port))
    else
        vnc_port="5900"
    fi

    print_msg $GREEN "Windows VM created successfully!"
    print_msg $GREEN "VM Name: $vm_name"
    print_msg $GREEN "VNC Port: $vnc_port"
    print_msg $GREEN "Connect via VNC to $(hostname -I | cut -d' ' -f1):$vnc_port"
    print_msg $YELLOW ""
    print_msg $YELLOW "Installation Notes:"
    print_msg $YELLOW "1. Connect via VNC to complete Windows installation"
    print_msg $YELLOW "2. Load VirtIO drivers from the second CD drive during installation"
    print_msg $YELLOW "3. For disk driver: Browse to D:\\viostor\\w10\\amd64 (or appropriate version)"
    print_msg $YELLOW "4. For network driver: Browse to D:\\NetKVM\\w10\\amd64 (or appropriate version)"
    print_msg $YELLOW "5. After installation, install Guest Tools from D:\\"
}

# Download cloud image if not exists (Ubuntu)
download_cloud_image() {
    local os_type=$1
    local img_url=${CLOUD_IMAGES[$os_type]}
    local img_name=$(basename "$img_url")
    local img_path="$CLOUD_IMG_DIR/$img_name"

    if [ ! -f "$img_path" ]; then
        print_msg $BLUE "Downloading $os_type cloud image..." >&2
        wget -q --show-progress -O "$img_path" "$img_url"
        print_msg $GREEN "Download completed!" >&2
    else
        print_msg $YELLOW "Cloud image already exists: $img_path" >&2
    fi

    echo "$img_path"
}

# Generate cloud-init configuration (Ubuntu)
generate_cloud_init() {
    local vm_name=$1
    local password=$2
    local ssh_key=$3
    local cloud_init_dir="/tmp/cloud-init-${vm_name}"

    mkdir -p "$cloud_init_dir"

    # Create meta-data
    cat > "$cloud_init_dir/meta-data" <<EOF
instance-id: $vm_name
local-hostname: $vm_name
EOF

    # Create user-data
    cat > "$cloud_init_dir/user-data" <<EOF
#cloud-config
hostname: $vm_name
manage_etc_hosts: true
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, admin
    shell: /bin/bash
    lock_passwd: false
EOF

    if [ -n "$password" ]; then
        echo "    passwd: $(echo $password | mkpasswd -m sha-512 -s)" >> "$cloud_init_dir/user-data"
    fi

    if [ -n "$ssh_key" ]; then
        echo "    ssh_authorized_keys:" >> "$cloud_init_dir/user-data"
        echo "      - $ssh_key" >> "$cloud_init_dir/user-data"
    fi

    # Add package updates
    cat >> "$cloud_init_dir/user-data" <<EOF
package_update: true
package_upgrade: false
packages:
  - qemu-guest-agent
  - net-tools
runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
EOF

    # Create cloud-init ISO
    local iso_path="$VM_DIR/${vm_name}-cloud-init.iso"
    cloud-localds "$iso_path" "$cloud_init_dir/user-data" "$cloud_init_dir/meta-data"

    rm -rf "$cloud_init_dir"
    echo "$iso_path"
}

# Create Ubuntu VM (original function)
create_ubuntu_vm() {
    local vm_name=$1
    local os_type=$2
    local memory=${3:-$DEFAULT_MEMORY}
    local vcpus=${4:-$DEFAULT_VCPUS}
    local disk_size=${5:-$DEFAULT_DISK_SIZE}
    local password=${6:-"ubuntu"}
    local ssh_key=${7:-""}

    print_msg $BLUE "Creating Ubuntu VM: $vm_name"

    # Check if VM already exists
    if virsh dominfo "$vm_name" &>/dev/null; then
        print_msg $RED "VM $vm_name already exists!"
        return 1
    fi

    # Download cloud image
    local base_img=$(download_cloud_image "$os_type")

    # Create VM disk from cloud image
    local vm_disk="$VM_DIR/${vm_name}.qcow2"
    print_msg $BLUE "Creating VM disk..."
    qemu-img create -f qcow2 -F qcow2 -b "$base_img" "$vm_disk" "${disk_size}G"

    # Generate cloud-init ISO
    local cloud_init_iso=$(generate_cloud_init "$vm_name" "$password" "$ssh_key")

    # Get OS variant
    local os_variant=""
    case $os_type in
        ubuntu20) os_variant="ubuntu20.04" ;;
        ubuntu22) os_variant="ubuntu22.04" ;;
        ubuntu24) os_variant="ubuntu24.04" ;;
    esac

    # Create VM
    print_msg $BLUE "Creating VM with virt-install..."
    virt-install \
        --name "$vm_name" \
        --memory "$memory" \
        --vcpus "$vcpus" \
        --disk "$vm_disk",device=disk,bus=virtio \
        --disk "$cloud_init_iso",device=cdrom \
        --os-variant "$os_variant" \
        --network network="$DEFAULT_NETWORK",model=virtio \
        --graphics none \
        --console pty,target_type=serial \
        --import \
        --noautoconsole \
        --quiet

    # Wait for VM to start
    sleep 5

    # Get VM IP
    print_msg $BLUE "Waiting for VM to get IP address..."
    local ip=""
    for i in {1..30}; do
        ip=$(virsh domifaddr "$vm_name" | grep -oP '192\.168\.\d+\.\d+' | head -1)
        if [ -n "$ip" ]; then
            break
        fi
        sleep 2
    done

    if [ -n "$ip" ]; then
        print_msg $GREEN "VM created successfully!"
        print_msg $GREEN "VM Name: $vm_name"
        print_msg $GREEN "IP Address: $ip"
        print_msg $GREEN "Username: ubuntu"
        print_msg $GREEN "Password: $password"
        print_msg $GREEN "Connect: ssh ubuntu@$ip"
    else
        print_msg $YELLOW "VM created but IP not detected yet. Use 'virsh domifaddr $vm_name' to check later."
    fi
}

# Wrapper for create_vm to handle both Ubuntu and Windows
create_vm() {
    local vm_name=$1
    local os_type=$2
    shift 2

    case $os_type in
        ubuntu20|ubuntu22|ubuntu24)
            create_ubuntu_vm "$vm_name" "$os_type" "$@"
            ;;
        win10|win11|win2022)
            create_windows_vm "$vm_name" "$os_type" "$@"
            ;;
        *)
            print_msg $RED "Unknown OS type: $os_type"
            print_msg $YELLOW "Supported: ubuntu20, ubuntu22, ubuntu24, win10, win11, win2022"
            return 1
            ;;
    esac
}

# List VMs with more details
list_vms() {
    print_msg $BLUE "=== All VMs ==="
    virsh list --all
    echo
    print_msg $BLUE "=== VM Details ==="
    for vm in $(virsh list --all --name); do
        if [ -n "$vm" ]; then
            local state=$(virsh domstate "$vm")
            local vcpus=$(virsh dominfo "$vm" | grep "CPU(s)" | awk '{print $2}')
            local memory=$(virsh dominfo "$vm" | grep "Max memory" | awk '{print $3}')
            local ip=$(virsh domifaddr "$vm" 2>/dev/null | grep -oP '192\.168\.\d+\.\d+' | head -1)

            echo -e "${GREEN}$vm${NC}: State=$state, vCPUs=$vcpus, Memory=${memory}KB, IP=${ip:-N/A}"

            # Check for VNC
            local vnc=$(virsh vncdisplay "$vm" 2>/dev/null)
            if [ -n "$vnc" ]; then
                local vnc_port=$((5900 + $(echo $vnc | sed 's/://g')))
                echo "  VNC: $(hostname -I | cut -d' ' -f1):$vnc_port"
            fi
        fi
    done
}

# Delete VM
delete_vm() {
    local vm_name=$1

    print_msg $YELLOW "Deleting VM: $vm_name"

    # Stop VM if running
    if virsh domstate "$vm_name" 2>/dev/null | grep -q "running"; then
        virsh destroy "$vm_name"
    fi

    # Undefine VM
    virsh undefine "$vm_name" --remove-all-storage --tpm

    # Remove cloud-init ISO if exists
    rm -f "$VM_DIR/${vm_name}-cloud-init.iso"

    # Remove TPM state if exists
    rm -rf "/var/lib/libvirt/swtpm/${vm_name}"

    print_msg $GREEN "VM $vm_name deleted!"
}

# VM control functions
start_vm() {
    virsh start "$1"
    print_msg $GREEN "VM $1 started"
}

stop_vm() {
    virsh shutdown "$1"
    print_msg $GREEN "VM $1 shutdown initiated"
}

force_stop_vm() {
    virsh destroy "$1"
    print_msg $GREEN "VM $1 forcefully stopped"
}

restart_vm() {
    virsh reboot "$1"
    print_msg $GREEN "VM $1 restarted"
}

# Connect to VM console
connect_vm() {
    print_msg $BLUE "Connecting to $1 console (Ctrl+] to exit)..."
    virsh console "$1"
}

# Show VM info
vm_info() {
    local vm_name=$1
    print_msg $BLUE "VM Information: $vm_name"
    virsh dominfo "$vm_name"
    echo
    print_msg $BLUE "Network interfaces:"
    virsh domifaddr "$vm_name"
    echo
    print_msg $BLUE "VNC Display:"
    local vnc=$(virsh vncdisplay "$vm_name" 2>/dev/null)
    if [ -n "$vnc" ]; then
        local vnc_port=$((5900 + $(echo $vnc | sed 's/://g')))
        echo "  VNC Port: $vnc_port"
        echo "  Connect: $(hostname -I | cut -d' ' -f1):$vnc_port"
    else
        echo "  No VNC configured"
    fi
}

# Download Windows ISO helper
download_windows_iso() {
    print_msg $BLUE "=== Windows ISO Download Instructions ==="
    echo
    print_msg $YELLOW "Windows 10 Enterprise (Evaluation):"
    echo "  1. Visit: https://www.microsoft.com/en-us/evalcenter/download-windows-10-enterprise"
    echo "  2. Download the ISO"
    echo "  3. Move to: $ISO_DIR/win10.iso"
    echo
    print_msg $YELLOW "Windows 11 Enterprise (Evaluation):"
    echo "  1. Visit: https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise"
    echo "  2. Download the ISO"
    echo "  3. Move to: $ISO_DIR/win11.iso"
    echo
    print_msg $YELLOW "Windows Server 2022 (Evaluation):"
    echo "  1. Visit: https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022"
    echo "  2. Download the ISO"
    echo "  3. Move to: $ISO_DIR/win2022.iso"
    echo
    print_msg $BLUE "Note: Evaluation versions are free for testing (180 days)"
}

# Main menu
show_menu() {
    echo
    print_msg $BLUE "=== KVM VM Management (with Windows Support) ==="
    echo "== Setup =="
    echo "1)  Install KVM (first time setup)"
    echo "== Ubuntu VMs =="
    echo "2)  Create Ubuntu 20.04 VM"
    echo "3)  Create Ubuntu 22.04 VM"
    echo "4)  Create Ubuntu 24.04 VM"
    echo "== Windows VMs =="
    echo "5)  Create Windows 10 VM"
    echo "6)  Create Windows 11 VM"
    echo "7)  Create Windows Server 2022 VM"
    echo "8)  Download Windows ISO instructions"
    echo "== VM Management =="
    echo "9)  List VMs"
    echo "10) Start VM"
    echo "11) Stop VM"
    echo "12) Force stop VM"
    echo "13) Restart VM"
    echo "14) Connect to VM console"
    echo "15) Show VM info"
    echo "16) Delete VM"
    echo "17) Exit"
    echo
}

# Interactive mode
interactive_mode() {
    while true; do
        show_menu
        read -p "Select option: " choice

        case $choice in
            1)
                install_kvm
                setup_network
                ;;
            2|3|4)
                read -p "VM name: " vm_name
                read -p "Memory (MB) [$DEFAULT_MEMORY]: " memory
                memory=${memory:-$DEFAULT_MEMORY}
                read -p "vCPUs [$DEFAULT_VCPUS]: " vcpus
                vcpus=${vcpus:-$DEFAULT_VCPUS}
                read -p "Disk size (GB) [$DEFAULT_DISK_SIZE]: " disk_size
                disk_size=${disk_size:-$DEFAULT_DISK_SIZE}
                read -p "Password [ubuntu]: " password
                password=${password:-ubuntu}
                read -p "SSH public key (optional): " ssh_key

                case $choice in
                    2) os_type="ubuntu20" ;;
                    3) os_type="ubuntu22" ;;
                    4) os_type="ubuntu24" ;;
                esac

                create_vm "$vm_name" "$os_type" "$memory" "$vcpus" "$disk_size" "$password" "$ssh_key"
                ;;
            5|6|7)
                read -p "VM name: " vm_name
                read -p "Memory (MB) [$WINDOWS_DEFAULT_MEMORY]: " memory
                memory=${memory:-$WINDOWS_DEFAULT_MEMORY}
                read -p "vCPUs [$WINDOWS_DEFAULT_VCPUS]: " vcpus
                vcpus=${vcpus:-$WINDOWS_DEFAULT_VCPUS}
                read -p "Disk size (GB) [$WINDOWS_DEFAULT_DISK_SIZE]: " disk_size
                disk_size=${disk_size:-$WINDOWS_DEFAULT_DISK_SIZE}

                case $choice in
                    5) os_type="win10" ;;
                    6) os_type="win11" ;;
                    7) os_type="win2022" ;;
                esac

                create_vm "$vm_name" "$os_type" "$memory" "$vcpus" "$disk_size"
                ;;
            8)
                download_windows_iso
                ;;
            9)
                list_vms
                ;;
            10)
                read -p "VM name: " vm_name
                start_vm "$vm_name"
                ;;
            11)
                read -p "VM name: " vm_name
                stop_vm "$vm_name"
                ;;
            12)
                read -p "VM name: " vm_name
                force_stop_vm "$vm_name"
                ;;
            13)
                read -p "VM name: " vm_name
                restart_vm "$vm_name"
                ;;
            14)
                read -p "VM name: " vm_name
                connect_vm "$vm_name"
                ;;
            15)
                read -p "VM name: " vm_name
                vm_info "$vm_name"
                ;;
            16)
                read -p "VM name: " vm_name
                read -p "Are you sure? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    delete_vm "$vm_name"
                fi
                ;;
            17)
                print_msg $GREEN "Goodbye!"
                exit 0
                ;;
            *)
                print_msg $RED "Invalid option"
                ;;
        esac
    done
}

# CLI mode
cli_mode() {
    case "$1" in
        init)
            install_kvm
            setup_network
            ;;
        create)
            shift
            if [ $# -lt 2 ]; then
                print_msg $RED "Usage: $0 create <vm_name> <os_type> [memory_mb] [vcpus] [disk_gb] [password] [ssh_key]"
                print_msg $YELLOW "OS types: ubuntu20, ubuntu22, ubuntu24, win10, win11, win2022"
                exit 1
            fi
            create_vm "$@"
            ;;
        list)
            list_vms
            ;;
        start)
            start_vm "$2"
            ;;
        stop)
            stop_vm "$2"
            ;;
        force-stop)
            force_stop_vm "$2"
            ;;
        restart)
            restart_vm "$2"
            ;;
        console)
            connect_vm "$2"
            ;;
        info)
            vm_info "$2"
            ;;
        delete)
            delete_vm "$2"
            ;;
        download-virtio)
            download_virtio_drivers
            ;;
        windows-iso)
            download_windows_iso
            ;;
        *)
            cat <<EOF
Usage: $0 <command> [options]

Commands:
    init                    Install KVM and setup environment
    create <name> <os>      Create new VM
                           OS types: ubuntu20, ubuntu22, ubuntu24,
                                    win10, win11, win2022
    list                    List all VMs
    start <name>            Start VM
    stop <name>             Gracefully stop VM
    force-stop <name>       Force stop VM
    restart <name>          Restart VM
    console <name>          Connect to VM console
    info <name>             Show VM information
    delete <name>           Delete VM
    download-virtio         Download VirtIO drivers for Windows
    windows-iso             Show Windows ISO download instructions

Interactive mode:
    $0                      Run without arguments for menu

Examples:
    $0 init
    $0 create myvm ubuntu24 8192 4 50 mypassword
    $0 create win11vm win11 16384 8 100
    $0 start myvm
    $0 console myvm
EOF
            exit 1
            ;;
    esac
}

# Main
main() {
    check_root

    # Check if KVM is installed (skip for init command)
    if [ $# -eq 0 ] || ([ $# -gt 0 ] && [ "$1" != "init" ]); then
        if ! command -v virsh &>/dev/null; then
            print_msg $RED "KVM is not installed. Run: $0 init"
            exit 1
        fi
        check_kvm
    fi

    if [ $# -eq 0 ]; then
        interactive_mode
    else
        cli_mode "$@"
    fi
}

main "$@"

