#!/bin/bash

# ============================================
# Magpie AI — Client Bootstrap Script
# ============================================
# Sets up and starts the Magpie AI platform.
# Usage: chmod +x setup.sh && ./setup.sh

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

echo ""
echo "=========================================="
echo "  Magpie AI — Setup"
echo "=========================================="
echo ""

# ── Prerequisites ──────────────────────────────

log_info "Checking prerequisites..."

if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed. Install it from https://docs.docker.com/get-docker/"
    exit 1
fi
log_success "Docker found"

if ! docker compose version &> /dev/null; then
    log_error "Docker Compose plugin is not installed."
    exit 1
fi
log_success "Docker Compose found"

if ! docker info &> /dev/null 2>&1; then
    log_error "Docker daemon is not running. Start Docker and try again."
    exit 1
fi
log_success "Docker daemon running"

# ── Environment Configuration ──────────────────

if [ -f .env ]; then
    log_warning ".env file already exists. Skipping generation."
    log_info "To regenerate, delete .env and run this script again."
else
    log_info "Generating .env from .env.example..."

    if [ ! -f .env.example ]; then
        log_error ".env.example not found. Are you in the magpie-deploy/ directory?"
        exit 1
    fi

    cp .env.example .env

    # Generate secure random values
    POSTGRES_PASS=$(openssl rand -hex 16)
    REDIS_PASS=$(openssl rand -hex 16)
    SECRET=$(openssl rand -hex 32)
    JWT_SECRET=$(openssl rand -hex 32)
    ADMIN_PASS=$(openssl rand -base64 16)

    # Platform-compatible sed (macOS vs Linux)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        SED_CMD="sed -i ''"
    else
        SED_CMD="sed -i"
    fi

    $SED_CMD "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASS|" .env
    $SED_CMD "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=$REDIS_PASS|" .env
    $SED_CMD "s|^SECRET_KEY=.*|SECRET_KEY=$SECRET|" .env
    $SED_CMD "s|^JWT_SECRET_KEY=.*|JWT_SECRET_KEY=$JWT_SECRET|" .env
    $SED_CMD "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=$ADMIN_PASS|" .env

    log_success ".env file created with generated secrets"
fi

# ── Registry Authentication ───────────────────

# Read license key and hub server from .env
LICENSE_KEY=$(grep "^MAGPIE_LICENSE_KEY=" .env 2>/dev/null | cut -d= -f2)
LICENSE_SERVER=$(grep "^MAGPIE_LICENSE_SERVER=" .env 2>/dev/null | cut -d= -f2)

if [ -z "$LICENSE_KEY" ] || [ -z "$LICENSE_SERVER" ]; then
    log_error "MAGPIE_LICENSE_KEY and MAGPIE_LICENSE_SERVER must be set in .env"
    log_info "Contact your Magpie AI account manager to obtain a license key."
    exit 1
fi

log_info "Authenticating with container registry..."

# Request registry credentials from hub using the license key
REGISTRY_RESPONSE=$(curl -sf -X POST "${LICENSE_SERVER}/api/v1/license/registry-token" \
    -H "Content-Type: application/json" \
    -d "{\"license_key\": \"${LICENSE_KEY}\"}" 2>&1) || {
    log_error "Failed to authenticate with license server."
    log_info "Verify MAGPIE_LICENSE_KEY and MAGPIE_LICENSE_SERVER in .env"
    exit 1
}

GHCR_TOKEN=$(echo "$REGISTRY_RESPONSE" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
GHCR_REGISTRY=$(echo "$REGISTRY_RESPONSE" | grep -o '"registry":"[^"]*"' | cut -d'"' -f4)
GHCR_USERNAME=$(echo "$REGISTRY_RESPONSE" | grep -o '"username":"[^"]*"' | cut -d'"' -f4)

if [ -z "$GHCR_TOKEN" ]; then
    log_error "Invalid response from license server. Is your license active?"
    exit 1
fi

echo "$GHCR_TOKEN" | docker login "$GHCR_REGISTRY" -u "$GHCR_USERNAME" --password-stdin > /dev/null 2>&1 || {
    log_error "Docker registry login failed."
    exit 1
}
log_success "Registry authentication successful"

# ── SSL Certificates ───────────────────────────

if [ ! -f ssl/fullchain.pem ] || [ ! -f ssl/privkey.pem ]; then
    log_warning "No SSL certificates found in ssl/. Generating self-signed certificates for initial setup."
    log_warning "Replace ssl/fullchain.pem and ssl/privkey.pem with real certificates before going to production."
    mkdir -p ssl
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout ssl/privkey.pem \
        -out ssl/fullchain.pem \
        -subj "/C=US/ST=Local/L=Local/O=Magpie/CN=localhost" > /dev/null 2>&1
    log_success "Self-signed certificates generated"
else
    log_success "SSL certificates found"
fi

# ── Start Services ─────────────────────────────

log_info "Pulling application images..."
docker compose pull

# Build and start the local LLM only when explicitly requested via MAGPIE_LOCAL_LLM=true.
# When using a remote LLM (RunPod, cloud-hosted vLLM, etc.) set VLLM_URL in .env instead.
USE_LOCAL_LLM=$(grep "^MAGPIE_LOCAL_LLM=" .env 2>/dev/null | cut -d= -f2 || echo "false")

if [ "$USE_LOCAL_LLM" = "true" ]; then
    log_info "Building local LLM service (GPU required)..."
    docker compose --profile local-gpu build llm
    log_info "Starting all services including local LLM..."
    docker compose --profile local-gpu up -d
else
    log_info "Starting services (remote LLM mode — VLLM_URL from .env)..."
    docker compose up -d
fi

# ── Wait for Health ────────────────────────────

log_info "Waiting for services to be healthy (this may take a minute)..."

HTTP_PORT=$(grep "^HTTP_PORT=" .env 2>/dev/null | cut -d= -f2 || echo "80")
MAX_WAIT=120
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -sf "http://localhost:${HTTP_PORT}/health" > /dev/null 2>&1; then
        break
    fi
    sleep 5
    WAITED=$((WAITED + 5))
    echo -n "."
done
echo ""

if [ $WAITED -ge $MAX_WAIT ]; then
    log_warning "Some services may still be starting. Check with: docker compose ps"
else
    log_success "Services are healthy"
fi

# ── Summary ────────────────────────────────────

ADMIN_EMAIL=$(grep "^ADMIN_EMAIL=" .env 2>/dev/null | cut -d= -f2 || echo "admin@magpie.local")

echo ""
echo "=========================================="
echo "  Magpie AI — Setup Complete"
echo "=========================================="
echo ""
log_info "Access URLs:"
echo "   Dashboard:  http://localhost:${HTTP_PORT}"
echo "   API:        http://localhost:${HTTP_PORT}/api/"
echo "   API Docs:   http://localhost:${HTTP_PORT}/docs"
echo "   Health:     http://localhost:${HTTP_PORT}/health"
echo ""
log_info "Admin Credentials:"
echo "   Email:    ${ADMIN_EMAIL}"
echo "   Password: (see .env file)"
echo ""
log_info "Useful Commands:"
echo "   View logs:       docker compose logs -f"
echo "   View status:     docker compose ps"
echo "   Restart:         docker compose restart"
echo "   Stop:            docker compose down"
echo "   Update:          ./setup.sh   (re-run to pull latest images)"
echo ""
