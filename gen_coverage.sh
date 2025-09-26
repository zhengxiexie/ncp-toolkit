#!/bin/bash

# =============================================================================
# NSX Operator Coverage Generation Script
# =============================================================================
#
# Usage:
# bash -c "$(curl -LsSf https://tinyurl.com/257b9e9x); main"
# DESCRIPTION:
#   This script automates the generation of code coverage reports for the 
#   NSX Operator project. It performs a complete end-to-end workflow including:
#   - Installing system dependencies (Git, Make, Wget, Build-essential)
#   - Installing Go programming language (v1.23.1)
#   - Cloning the NSX Operator repository from GitHub
#   - Triggering coverage data dumps from running Kubernetes pods
#   - Processing and merging coverage data into comprehensive reports
#
# PREREQUISITES:
#   - Linux system with root access (tested on PhotonOS/TDNF-based systems)
#   - Kubernetes cluster with kubectl configured and accessible
#   - NSX Operator deployed in the target cluster
#   - Internet connectivity for downloading dependencies
#   - Sufficient disk space in /root and /tmp directories
#
# KUBERNETES REQUIREMENTS:
#   - NSX Operator pods must be running in 'vmware-system-nsx' namespace
#   - Pods must be labeled with 'component=nsx-ncp'
#   - Coverage instrumentation must be enabled in the NSX Operator build
#   - kubectl must have permissions to:
#     * List and describe pods in vmware-system-nsx namespace
#     * Execute commands in nsx-operator containers
#     * Send signals (SIGTERM) to processes in containers
#
# USAGE:
#   Basic usage:
#     ./gen_coverage.sh
#
#   Make executable and run:
#     chmod +x gen_coverage.sh && ./gen_coverage.sh
#
# OUTPUT:
#   - Coverage data is processed in /root/nsx-operator/
#   - Final coverage report: coverage-overall.txt
#   - Function-level coverage displayed in console output
#   - Merged coverage data stored in 'merged/' directory
#
# CONFIGURATION:
#   Key variables can be modified at the top of the script:
#   - REPO_URL: NSX Operator GitHub repository URL
#   - NAMESPACE: Kubernetes namespace (default: vmware-system-nsx)
#   - DEPLOYMENT: Target deployment name (default: nsx-ncp)
#   - GO_VERSION: Go language version to install (default: 1.23.1)
#   - TIMEOUT: Maximum wait time for pod readiness (default: 60s)
#   - COVERAGE_DIR: Temporary coverage data location (default: /tmp/nsx-operator)
#
# WORKFLOW STEPS:
#   1. Clean up any existing coverage data
#   2. Install system tools (git, make, wget, build-essential)
#   3. Install Go programming language
#   4. Clone NSX Operator repository
#   5. Trigger coverage dump by sending SIGTERM to nsx-operator containers
#   6. Wait for pods to restart and become ready
#   7. Process coverage data using Go coverage tools
#   8. Generate function-level coverage reports
#
# ERROR HANDLING:
#   - Script exits on first error (set -e)
#   - Comprehensive logging with timestamps and caller information
#   - Pod readiness validation with timeout handling
#   - Graceful handling of missing coverage files
#
# LOGGING:
#   - Color-coded log levels: INFO (green), WARN (yellow), ERROR (red)
#   - Timestamps in blue, caller information in gray
#   - Detailed pod status monitoring during coverage collection
#
# TROUBLESHOOTING:
#   - Ensure NSX Operator pods are running and healthy
#   - Verify kubectl connectivity and permissions
#   - Check that coverage instrumentation is enabled in NSX Operator
#   - Monitor logs for specific error messages and pod status
#   - Verify sufficient disk space in /root and /tmp directories
#
# AUTHOR: NSX OperatorTeam
# VERSION: 2.0
# DATE: 2025-09-25
# =============================================================================

set -e

# Global Configuration
readonly REPO_URL="https://github.com/vmware-tanzu/nsx-operator"
readonly SRC_DIR="nsx-operator"
readonly NAMESPACE="vmware-system-nsx"
readonly DEPLOYMENT="nsx-ncp"
readonly COVERAGE_DIR="/tmp/nsx-operator"
readonly LOCAL_COVERAGE_DIR="coverage-data"
readonly MERGED_DIR="merged"
readonly COVERAGE_OUT="coverage-overall.txt"
readonly GO_VERSION="1.23.1"
readonly TIMEOUT=60
readonly SLEEP_INTERVAL=5

# Logging functions with colors and caller information
# ANSI color codes
readonly COLOR_GREEN='\033[32m'     # Green for INFO
readonly COLOR_YELLOW='\033[33m'    # Yellow for WARN
readonly COLOR_RED='\033[31m'       # Red for ERROR
readonly COLOR_BLUE='\033[94m'      # Blue for timestamp
readonly COLOR_GRAY='\033[90m'      # Gray for caller info
readonly COLOR_RESET='\033[0m'      # Reset color

# Get caller information (file:line)
get_caller_info() {
    local caller_file caller_line
    caller_file=$(basename "${BASH_SOURCE[2]}")
    caller_line="${BASH_LINENO[1]}"
    echo "${COLOR_GRAY}[${caller_file}:${caller_line}]${COLOR_RESET}"
}

log_info() {
    local timestamp caller_info
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    caller_info=$(get_caller_info)
    echo -e "${COLOR_BLUE}${timestamp}${COLOR_RESET} ${COLOR_GREEN}[INFO]${COLOR_RESET} ${caller_info} $*"
}

log_warn() {
    local timestamp caller_info
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    caller_info=$(get_caller_info)
    echo -e "${COLOR_BLUE}${timestamp}${COLOR_RESET} ${COLOR_YELLOW}[WARN]${COLOR_RESET} ${caller_info} $*" >&2
}

log_error() {
    local timestamp caller_info
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    caller_info=$(get_caller_info)
    echo -e "${COLOR_BLUE}${timestamp}${COLOR_RESET} ${COLOR_RED}[ERROR]${COLOR_RESET} ${caller_info} $*" >&2
}

# Check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Check if a package is installed (rpm-based systems)
package_exists() {
    local package="$1"
    rpm -q "$package" &>/dev/null
}

# Install a package if it doesn't exist
install_if_missing() {
    local package="$1"
    local command_name="${2:-$1}"
    
    if ! command_exists "$command_name"; then
        log_info "$command_name not found, installing $package..."
        tdnf install -y "$package"
    else
        log_info "$command_name is already installed"
    fi
}

# Install system dependencies
install_system_tools() {
    log_info "Installing base tools and dependencies..."
    
    # Update package manager first if installing anything
    local need_update=false
    
    if ! command_exists git || ! command_exists make || ! command_exists wget; then
        need_update=true
    fi
    
    if ! package_exists build-essential; then
        need_update=true
    fi
    
    if [ "$need_update" = true ]; then
        log_info "Updating package manager..."
        tdnf update -y
    fi
    
    # Install individual tools
    install_if_missing git
    install_if_missing make
    install_if_missing wget
    
    # Install build-essential if not present
    if ! package_exists build-essential; then
        log_info "Build-essential not found, installing..."
        tdnf install -y build-essential
    else
        log_info "Build-essential is already installed"
    fi
}

# Setup Go environment variables
setup_go_environment() {
    export PATH=/root/.local/bin:/usr/local/go/bin:$PATH
    export GOROOT=/usr/local/go
}

# Install Go programming language
install_go() {
    log_info "Installing Go language and test tools..."
    
    if ! command_exists go; then
        log_info "Go not found, installing..."
        
        local go_archive="go${GO_VERSION}.linux-amd64.tar.gz"
        local download_url="https://go.dev/dl/$go_archive"
        
        cd /root
        wget "$download_url"
        tar -C /usr/local -xzf "$go_archive"
        
        # Add Go to PATH permanently
        {
            echo 'export PATH=/root/.local/bin:/usr/local/go/bin:$PATH'
            echo 'export GOROOT=/usr/local/go'
        } >> ~/.bashrc
        
        setup_go_environment
        log_info "Go $GO_VERSION installed successfully"
    else
        log_info "Go is already installed"
        setup_go_environment
    fi
}

# Clone the nsx-operator repository
clone_repository() {
    log_info "Cloning nsx-operator repository..."
    
    cd /root
    if [ ! -d "$SRC_DIR" ]; then
        git clone --depth 1 "$REPO_URL"
        log_info "Repository cloned successfully"
    else
        log_info "$SRC_DIR directory already exists"
    fi
}

# Get pod names for the deployment
get_pod_names() {
    kubectl get pods -n "$NAMESPACE" -l component=nsx-ncp -o jsonpath='{.items[*].metadata.name}'
}

# Check if a pod is ready and has a host assigned
is_pod_ready() {
    local pod="$1"
    local pod_status pod_node
    
    pod_status=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    pod_node=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
    
    [ "$pod_status" = "Running" ] && [ -n "$pod_node" ]
}

# Send SIGTERM to nsx-operator container in a pod
signal_pod_coverage_dump() {
    local pod="$1"
    
    if is_pod_ready "$pod"; then
        log_info "Sending SIGTERM to nsx-operator container in pod $pod..."
        kubectl exec -n "$NAMESPACE" "$pod" -c nsx-operator -- pkill -SIGTERM manager || true
        return 0
    else
        local pod_status pod_node
        pod_status=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        pod_node=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
        log_warn "Skipping pod $pod (status: $pod_status, node: ${pod_node:-unassigned})"
        return 1
    fi
}

# Trigger coverage dump for all pods
trigger_coverage_dump() {
    log_info "Triggering coverage dump for nsx-operator pods..."
    
    local pods
    pods=$(get_pod_names)
    
    if [ -z "$pods" ]; then
        log_error "No pods found for deployment $DEPLOYMENT in namespace $NAMESPACE"
        return 1
    fi
    
    local success_count=0
    for pod in $pods; do
        if signal_pod_coverage_dump "$pod"; then
            ((success_count++))
        fi
    done
    
    log_info "Coverage dump triggered for $success_count pods"
    return 0
}

# Check pod readiness with detailed status
check_pod_status() {
    local current_pods
    current_pods=$(get_pod_names)
    
    if [ -z "$current_pods" ]; then
        return 1  # No pods found
    fi
    
    local all_running=true
    local ready_count=0
    local total_count=0
    
    for pod in $current_pods; do
        ((total_count++))
        local pod_status pod_ready
        pod_status=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        pod_ready=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
        
        if [ "$pod_status" = "Running" ] && [ "$pod_ready" = "True" ]; then
            ((ready_count++))
        else
            all_running=false
        fi
    done
    
    log_info "Pod status: $ready_count/$total_count pods ready and running"
    
    # Return success if all pods are running, failure otherwise
    [ "$all_running" = true ]
}

# Check if at least one pod is ready and running
check_any_pod_ready() {
    local current_pods
    current_pods=$(get_pod_names)
    
    if [ -z "$current_pods" ]; then
        return 1  # No pods found
    fi
    
    local ready_count=0
    local total_count=0
    
    for pod in $current_pods; do
        ((total_count++))
        local pod_status pod_ready
        pod_status=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        pod_ready=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
        
        if [ "$pod_status" = "Running" ] && [ "$pod_ready" = "True" ]; then
            ((ready_count++))
        fi
    done
    
    # Return success if at least one pod is ready
    [ $ready_count -gt 0 ]
}

# Clean up covcounters files generated during pod shutdown
cleanup_covcounters() {
    log_info "Cleaning up covcounters files from coverage directory..."
    
    if [ ! -d "$COVERAGE_DIR" ]; then
        log_info "Coverage directory does not exist, no covcounters cleanup needed"
        return 0
    fi
    
    # Find and count covcounters files
    local covcounters_files
    covcounters_files=$(find "$COVERAGE_DIR" -name "covcounters.*" -type f 2>/dev/null || true)
    
    if [ -z "$covcounters_files" ]; then
        log_info "No covcounters files found, no cleanup needed"
        return 0
    fi
    
    local file_count
    file_count=$(echo "$covcounters_files" | wc -l)
    log_info "Found $file_count covcounters files, deleting them..."
    
    # Delete covcounters files
    echo "$covcounters_files" | while IFS= read -r file; do
        if [ -n "$file" ]; then
            log_info "Deleting covcounters file: $(basename "$file")"
            rm -f "$file"
        fi
    done
    
    log_info "Covcounters cleanup completed"
}

# Wait for pods to stop during restart
wait_for_pods_to_stop() {
    log_info "Waiting for pods to stop during restart..."
    
    local elapsed=0
    local initial_pods
    initial_pods=$(get_pod_names)
    
    # Wait until no pods are running or new pods are created
    while [ $elapsed -lt $TIMEOUT ]; do
        local current_pods
        current_pods=$(get_pod_names)
        
        # Check if pods have changed (old pods terminated, new pods starting)
        if [ "$current_pods" != "$initial_pods" ]; then
            log_info "Pod changes detected, restart is in progress"
            break
        fi
        
        # Check if all pods are terminating/terminated
        local terminating_count=0
        if [ -n "$current_pods" ]; then
            for pod in $current_pods; do
                local pod_status
                pod_status=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
                if [ "$pod_status" = "Terminating" ] || [ "$pod_status" = "NotFound" ]; then
                    ((terminating_count++))
                fi
            done
        fi
        
        # If all pods are terminating or no pods exist, break
        local initial_count
        initial_count=$(echo "$initial_pods" | wc -w)
        if [ "$terminating_count" -eq "$initial_count" ] || [ -z "$current_pods" ]; then
            log_info "All pods are stopping, proceeding with cleanup"
            break
        fi
        
        sleep $SLEEP_INTERVAL
        elapsed=$((elapsed + SLEEP_INTERVAL))
    done
    
    if [ $elapsed -ge $TIMEOUT ]; then
        log_warn "Timeout waiting for pods to stop, proceeding anyway"
    fi
    
    return 0
}

# Restart deployment to generate new coverage metadata
restart_deployment() {
    log_info "Restarting deployment $DEPLOYMENT to ensure fresh coverage metadata generation..."
    
    # Initiate deployment restart
    if ! kubectl rollout restart deployment "$DEPLOYMENT" -n "$NAMESPACE"; then
        log_error "Failed to restart deployment $DEPLOYMENT"
        return 1
    fi
    
    log_info "Deployment restart initiated successfully"
    
    # Wait for pods to stop and generate covcounters files
    wait_for_pods_to_stop
    
    # Clean up covcounters files after pods stop
    cleanup_covcounters
    
    return 0
}

# Wait for pods to restart and become ready
wait_for_pods_ready() {
    log_info "Waiting for coverage files to be dumped..."
    log_info "Monitoring deployment restart and waiting for pods to be running..."
    
    local elapsed=0
    
    while [ $elapsed -lt $TIMEOUT ]; do
        if check_pod_status; then
            log_info "All pods are running and ready. Coverage files should be available."
            return 0
        fi
        
        local current_pods
        current_pods=$(get_pod_names)
        if [ -z "$current_pods" ]; then
            log_info "No pods found, waiting for deployment to create new pods..."
        fi
        
        sleep $SLEEP_INTERVAL
        elapsed=$((elapsed + SLEEP_INTERVAL))
    done
    
    # Timeout reached - check if at least one pod is ready
    if check_any_pod_ready; then
        log_warn "Timeout reached waiting for all pods to be ready, but at least one pod is running. Continuing..."
        return 0
    else
        log_error "Timeout reached and no pods are ready. Cannot proceed."
        return 1
    fi
}

# Clean up legacy coverage data
cleanup_coverage_dir() {
    log_info "Cleaning up legacy coverage data from $COVERAGE_DIR..."
    
    if [ ! -d "$COVERAGE_DIR" ]; then
        log_info "Coverage directory does not exist, creating fresh directory"
        mkdir -p "$COVERAGE_DIR"
        return 0
    fi
    
    # Check if directory has any contents
    local file_count
    file_count=$(find "$COVERAGE_DIR" -mindepth 1 | wc -l)
    
    if [ "$file_count" -eq 0 ]; then
        log_info "Coverage directory is already empty, no cleanup needed"
        return 0
    fi
    
    log_info "Found $file_count items in coverage directory, deleting all contents"
    
    # Delete all contents of the coverage directory
    rm -rf "${COVERAGE_DIR:?}"/*
    
    log_info "Cleanup completed: deleted all contents from $COVERAGE_DIR"
}

# Process coverage data
process_coverage_data() {
    log_info "Processing coverage data..."
    
    # Check if coverage directory exists and has files
    log_info "Checking coverage directory: $COVERAGE_DIR"
    if [ ! -d "$COVERAGE_DIR" ]; then
        log_error "Coverage directory $COVERAGE_DIR does not exist"
        return 1
    fi
    
    local file_count=$(find "$COVERAGE_DIR" -type f | wc -l)
    log_info "Found $file_count files in coverage directory"
    
    if [ "$file_count" -eq 0 ]; then
        log_warn "No coverage files found in $COVERAGE_DIR"
        log_info "Coverage directory contents:"
        ls -la "$COVERAGE_DIR" || true
        return 1
    fi
    
    log_info "Coverage files found:"
    find "$COVERAGE_DIR" -type f -exec basename {} \; | head -5
    
    cd "/root/$SRC_DIR"
    
    # Create merged directory
    rm -fr "$MERGED_DIR"
    mkdir -p "$MERGED_DIR"
    
    # Merge coverage data
    log_info "Merging coverage data from $COVERAGE_DIR..."
    go tool covdata merge -i="$COVERAGE_DIR" -o "$MERGED_DIR"
    
    # Convert to text format
    log_info "Converting coverage data to text format..."
    go tool covdata textfmt -i="$MERGED_DIR" -o "$COVERAGE_OUT"
    
    # Generate function-level coverage report
    log_info "Generating function-level coverage report..."
    go tool cover -func "$COVERAGE_OUT"
}

# Main execution flow
main() {
    log_info "Starting NSX Operator coverage generation..."
    
    # Step 0: Clean up legacy coverage data
    cleanup_coverage_dir
    
    # Step 1: Install system dependencies
    install_system_tools
    
    # Step 2: Install Go language
    install_go
    
    # Step 3: Clone repository
    clone_repository
    
    # Step 4: Change to source directory
    cd "/root/$SRC_DIR"
    
    # Step 4.1: Restart deployment to generate fresh coverage metadata
    if ! restart_deployment; then
        log_error "Failed to restart deployment"
        exit 1
    fi
    
    # Step 4.5: Wait for user to run NSX Operator and signal when ready
    log_info "Setup completed. Please ensure NSX Operator is running enough time and generating coverage data."
    log_info "When you are ready to generate the coverage report, press Ctrl+D to continue..."
    
    # Wait for user input (Ctrl+D sends EOF)
    log_info "Waiting for Ctrl+D signal..."
    read -r || true
    
    log_info "Continuing with coverage dump..."
    
    # Step 5: Trigger coverage dump
    if ! trigger_coverage_dump; then
        log_error "Failed to trigger coverage dump"
        exit 1
    fi
    
    # Step 6: Wait for pods to be ready
    wait_for_pods_ready
    
    # Step 7: Process coverage data
    if ! process_coverage_data; then
        log_error "Failed to process coverage data"
        exit 1
    fi
    
    log_info "Coverage generation completed successfully!"
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi