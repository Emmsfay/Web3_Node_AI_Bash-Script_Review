#!/bin/bash
# Corrected Web3 Node Setup & Health Check Script
# Purpose: Provision Ubuntu server with Ethereum execution client (geth) and verify RPC health
# Usage: sudo ./setup-eth-node.sh <RPC_URL> [CHAIN_ID] [NODE_NAME]
# Example: sudo ./setup-eth-node.sh http://127.0.0.1:8545 1 eth-node

set -euo pipefail
IFS=$'\n\t'

################################################################################
# Exit Codes
################################################################################
readonly EXIT_OK=0
readonly EXIT_GENERIC_ERROR=1
readonly EXIT_INVALID_ARGS=2
readonly EXIT_PRIV_ERROR=3
readonly EXIT_HEALTH_CHECK_FAILED=4
readonly EXIT_NETWORK_MISMATCH=5

################################################################################
# Configuration
################################################################################
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Arguments with defaults
RPC_URL="${1:-}"
EXPECTED_CHAIN_ID="${2:-1}"
NODE_NAME="${3:-eth-node}"

# Docker and client settings
readonly GETH_IMAGE="ethereum/client-go:latest"
readonly GETH_SYNC_MODE="snap"
readonly HTTP_TIMEOUT=10
readonly HEALTH_CHECK_RETRIES=3
readonly HEALTH_CHECK_DELAY=2

################################################################################
# Logging Functions
################################################################################

log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp
  timestamp=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  
  case "$level" in
    INFO)  echo "[${timestamp}] [INFO] $message" ;;
    WARN)  echo "[${timestamp}] [WARN] $message" >&2 ;;
    ERROR) echo "[${timestamp}] [ERROR] $message" >&2 ;;
    DEBUG) [[ "${DEBUG:-0}" == "1" ]] && echo "[${timestamp}] [DEBUG] $message" >&2 ;;
  esac
}

################################################################################
# Validation Functions
################################################################################

validate_root() {
  if [[ $EUID -ne 0 ]]; then
    log ERROR "This script requires root privileges or passwordless sudo"
    log ERROR "Usage: sudo $SCRIPT_NAME"
    exit $EXIT_PRIV_ERROR
  fi
  log INFO "Running with root privileges"
}

validate_args() {
  if [[ -z "$RPC_URL" ]]; then
    log ERROR "Missing required argument: RPC_URL"
    log ERROR "Usage: $SCRIPT_NAME <RPC_URL> [CHAIN_ID] [NODE_NAME]"
    exit $EXIT_INVALID_ARGS
  fi
  
  if ! validate_rpc_url "$RPC_URL"; then
    exit $EXIT_INVALID_ARGS
  fi
  
  if ! [[ "$EXPECTED_CHAIN_ID" =~ ^[0-9]+$ ]]; then
    log ERROR "Invalid CHAIN_ID: must be numeric (got: $EXPECTED_CHAIN_ID)"
    exit $EXIT_INVALID_ARGS
  fi
  
  if ! [[ "$NODE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log ERROR "Invalid NODE_NAME: must contain only alphanumerics, hyphens, underscores"
    exit $EXIT_INVALID_ARGS
  fi
  
  log INFO "Configuration: RPC_URL=$RPC_URL, CHAIN_ID=$EXPECTED_CHAIN_ID, NODE_NAME=$NODE_NAME"
}

validate_os() {
  if ! [[ -f /etc/os-release ]]; then
    log ERROR "Cannot determine OS; /etc/os-release not found"
    exit $EXIT_GENERIC_ERROR
  fi
  
  # Source OS info
  # shellcheck disable=SC1091
  source /etc/os-release
  
  if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    log WARN "This script is optimized for Ubuntu/Debian; $ID may not be fully supported"
  fi
  
  log INFO "OS: $PRETTY_NAME"
}

validate_rpc_url() {
  local url="$1"
  
  if [[ ! "$url" =~ ^https?:// ]]; then
    log ERROR "Invalid RPC URL format: must start with http:// or https://"
    log ERROR "Got: $url"
    return 1
  fi
  
  return 0
}

command_exists() {
  command -v "$1" &>/dev/null
}

################################################################################
# System Setup Functions
################################################################################

install_dependencies() {
  log INFO "Updating package lists..."
  apt-get update -qq || {
    log ERROR "apt-get update failed"
    return 1
  }
  
  log INFO "Installing required packages (curl, jq, docker.io)..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl \
    jq \
    docker.io \
    ca-certificates \
    2>&1 | grep -v "^Get:" || true
  
  log INFO "Verifying installed dependencies..."
  for cmd in curl jq docker; do
    if ! command_exists "$cmd"; then
      log ERROR "Required command '$cmd' not found after installation"
      return 1
    fi
  done
  
  log INFO "All dependencies installed successfully"
}

setup_docker() {
  log INFO "Starting Docker daemon..."
  systemctl start docker || {
    log ERROR "Failed to start Docker daemon"
    return 1
  }
  
  log INFO "Enabling Docker auto-start..."
  systemctl enable docker || {
    log WARN "Failed to enable Docker auto-start; manual restart may be required"
  }
  
  log INFO "Verifying Docker daemon connectivity..."
  if ! docker ps &>/dev/null; then
    log ERROR "Docker daemon is not responding; socket may be inaccessible"
    return 1
  fi
  
  log INFO "Docker is operational"
}

pull_client_image() {
  log INFO "Pulling Ethereum client image: $GETH_IMAGE"
  
  if ! docker pull "$GETH_IMAGE"; then
    log ERROR "Failed to pull Docker image: $GETH_IMAGE"
    return 1
  fi
  
  log INFO "Image pull successful"
}

cleanup_existing_container() {
  log INFO "Checking for existing container: $NODE_NAME"
  
  if docker ps -a --format '{{.Names}}' | grep -q "^${NODE_NAME}$"; then
    log WARN "Found existing container: $NODE_NAME; removing..."
    
    docker stop "$NODE_NAME" 2>/dev/null || true
    docker rm "$NODE_NAME" 2>/dev/null || true
    
    log INFO "Existing container removed"
  else
    log INFO "No existing container found"
  fi
}

run_node_container() {
  log INFO "Starting Ethereum node container..."
  
  if ! docker run \
    --detach \
    --name "$NODE_NAME" \
    --restart unless-stopped \
    -p 127.0.0.1:8545:8545 \
    --log-driver json-file \
    --log-opt max-size=100m \
    --log-opt max-file=5 \
    --memory 4g \
    --cpus 2 \
    "$GETH_IMAGE" \
      --http \
      --http.addr 127.0.0.1 \
      --http.port 8545 \
      --http.api eth,net,web3 \
      --http.vhosts localhost,127.0.0.1 \
      --syncmode "$GETH_SYNC_MODE" \
      --cache 2048 \
      --maxpeers 100; then
    
    log ERROR "Failed to start Ethereum client container"
    return 1
  fi
  
  log INFO "Container started: $NODE_NAME"
  
  # Wait for client initialization
  log INFO "Waiting for client to initialize (5 seconds)..."
  sleep 5
  
  # Verify container is still running
  if ! docker ps --format '{{.Names}}' | grep -q "^${NODE_NAME}$"; then
    log ERROR "Container exited unexpectedly"
    docker logs "$NODE_NAME" | tail -20 | while read -r line; do
      log ERROR "  $line"
    done
    return 1
  fi
  
  log INFO "Container is running"
}

################################################################################
# RPC Health Check Functions
################################################################################

hex_to_decimal() {
  local hex="$1"
  
  # Handle both "0x1" and "1" formats
  if [[ "$hex" =~ ^0x ]]; then
    printf "%d\n" "$hex"
  else
    printf "%d\n" "0x$hex"
  fi
}

rpc_call() {
  local method="$1"
  local params="${2:-[]}"
  local request_id="${3:-1}"
  
  local payload
  payload=$(cat <<EOF
{
  "jsonrpc": "2.0",
  "method": "$method",
  "params": $params,
  "id": $request_id
}
EOF
)
  
  curl \
    --silent \
    --max-time "$HTTP_TIMEOUT" \
    --fail \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$RPC_URL" 2>/dev/null || return 1
}

check_rpc_block() {
  log INFO "Fetching latest block number from RPC..."
  
  local response
  local block
  
  response=$(rpc_call "eth_blockNumber") || {
    log ERROR "RPC call failed (eth_blockNumber)"
    return 1
  }
  
  block=$(echo "$response" | jq -r '.result // .error.message' 2>/dev/null)
  
  if [[ -z "$block" ]] || [[ "$block" == "null" ]]; then
    log ERROR "No block number returned from RPC"
    log DEBUG "Response: $response"
    return 1
  fi
  
  # Convert block from hex to decimal for display
  local block_decimal
  block_decimal=$(hex_to_decimal "$block") || {
    log ERROR "Invalid block format: $block"
    return 1
  }
  
  log INFO "✓ Latest block: $block_decimal (0x$block)"
  echo "$block_decimal"
}

check_rpc_chain_id() {
  log INFO "Fetching chain ID from RPC..."
  
  local response
  local chain_id_hex
  local chain_id_dec
  
  response=$(rpc_call "eth_chainId") || {
    log ERROR "RPC call failed (eth_chainId)"
    return 1
  }
  
  chain_id_hex=$(echo "$response" | jq -r '.result // .error.message' 2>/dev/null)
  
  if [[ -z "$chain_id_hex" ]] || [[ "$chain_id_hex" == "null" ]]; then
    log ERROR "No chain ID returned from RPC"
    log DEBUG "Response: $response"
    return 1
  fi
  
  # Convert to decimal for comparison
  chain_id_dec=$(hex_to_decimal "$chain_id_hex") || {
    log ERROR "Invalid chain ID format: $chain_id_hex"
    return 1
  }
  
  if [[ "$chain_id_dec" -ne "$EXPECTED_CHAIN_ID" ]]; then
    log ERROR "Chain ID mismatch: expected $EXPECTED_CHAIN_ID, got $chain_id_dec"
    return 1
  fi
  
  log INFO "✓ Chain ID matches: $chain_id_dec"
  echo "$chain_id_dec"
}

health_check() {
  log INFO "Starting RPC health check (up to $HEALTH_CHECK_RETRIES attempts)..."
  
  local attempt=0
  local block_num=""
  local chain_id=""
  
  while [[ $attempt -lt $HEALTH_CHECK_RETRIES ]]; do
    attempt=$((attempt + 1))
    log INFO "Health check attempt $attempt/$HEALTH_CHECK_RETRIES"
    
    # Check block number
    if block_num=$(check_rpc_block); then
      log INFO "Block fetch succeeded"
      
      # Check chain ID
      if chain_id=$(check_rpc_chain_id); then
        log INFO "Chain ID verification succeeded"
        log INFO "════════════════════════════════════════════"
        log INFO "✓ Node health check PASSED"
        log INFO "  Block: $block_num"
        log INFO "  Chain ID: $chain_id"
        log INFO "════════════════════════════════════════════"
        return 0
      fi
    fi
    
    if [[ $attempt -lt $HEALTH_CHECK_RETRIES ]]; then
      log WARN "Attempt $attempt failed; retrying in ${HEALTH_CHECK_DELAY}s..."
      sleep "$HEALTH_CHECK_DELAY"
    fi
  done
  
  log ERROR "Health check failed after $HEALTH_CHECK_RETRIES attempts"
  return 1
}

################################################################################
# Cleanup & Error Handling
################################################################################

cleanup() {
  local exit_code=$?
  
  if [[ $exit_code -ne 0 ]]; then
    log ERROR "Setup failed with exit code $exit_code"
    log ERROR "Docker logs (last 30 lines):"
    if docker ps -a --format '{{.Names}}' | grep -q "^${NODE_NAME}$"; then
      docker logs "$NODE_NAME" 2>/dev/null | tail -30 | sed 's/^/  /'
    fi
  fi
  
  return $exit_code
}

trap cleanup EXIT

################################################################################
# Main Execution
################################################################################

main() {
  log INFO "═══════════════════════════════════════════════"
  log INFO "Ethereum Node Setup & Health Check"
  log INFO "═══════════════════════════════════════════════"
  log INFO ""
  
  # Validation
  validate_root
  validate_args
  validate_os
  
  log INFO ""
  log INFO "Phase 1: System Setup"
  install_dependencies || exit $EXIT_GENERIC_ERROR
  setup_docker || exit $EXIT_GENERIC_ERROR
  
  log INFO ""
  log INFO "Phase 2: Container Deployment"
  pull_client_image || exit $EXIT_GENERIC_ERROR
  cleanup_existing_container
  run_node_container || exit $EXIT_GENERIC_ERROR
  
  log INFO ""
  log INFO "Phase 3: Health Verification"
  health_check || exit $EXIT_HEALTH_CHECK_FAILED
  
  log INFO ""
  log INFO "═══════════════════════════════════════════════"
  log INFO "✓ Setup completed successfully"
  log INFO "Node is ready for use at: $RPC_URL"
  log INFO "═══════════════════════════════════════════════"
  
  exit $EXIT_OK
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
