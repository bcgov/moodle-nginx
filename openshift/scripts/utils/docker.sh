#!/bin/bash
# =============================================================================
# Docker Build & Push Utilities
# Standardized functions for building and pushing Docker images to Artifactory
#
# Usage:
#   source openshift/scripts/utils/docker.sh
#   push_to_artifactory "registry.example.com/my-image:tag"
#   build_and_push "docker buildx build ... --push" "registry.example.com/my-image:tag"
#
# See also:
#   - optimize-image-push.sh — base image mirroring (Docker Hub → Artifactory)
#   - docker-security.sh     — vulnerability scanning before push
# =============================================================================

_DOCKER_UTILS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$_DOCKER_UTILS_SCRIPT_DIR/openshift.sh" ]]; then
  source "$_DOCKER_UTILS_SCRIPT_DIR/openshift.sh"
else
  log_info()    { echo "ℹ️  $*" >&2; }
  log_warn()    { echo "⚠️  $*" >&2; }
  log_error()   { echo "❌ $*" >&2; }
  log_success() { echo "✅ $*" >&2; }
fi

# =============================================================================
# push_to_artifactory — Push a local Docker image to Artifactory with retry
#
# For images built with --output=type=docker (loaded into Docker daemon).
# Retries handle transient Artifactory errors like "upload must be restarted".
#
# Arguments:
#   $1  — Full image reference (e.g., registry.example.com/project/image:tag)
#   $2  — Max retry attempts (default: 3)
#   $3  — Backoff delay in seconds (default: 15)
#
# Returns:
#   0 on success, 1 after all retries exhausted
# =============================================================================
push_to_artifactory() {
  local image="${1:?push_to_artifactory: image reference required}"
  local max_attempts="${2:-3}"
  local backoff="${3:-15}"

  log_info "Pushing image to Artifactory: ${image}"

  for attempt in $(seq 1 "$max_attempts"); do
    log_info "Push attempt ${attempt}/${max_attempts}"

    if docker push "$image" 2>&1; then
      log_success "Push succeeded on attempt ${attempt}"
      return 0
    fi

    log_warn "Push failed on attempt ${attempt}"
    if [[ "$attempt" -lt "$max_attempts" ]]; then
      log_info "Waiting ${backoff}s before retry..."
      sleep "$backoff"
    fi
  done

  log_error "Push failed after ${max_attempts} attempts: ${image}"
  return 1
}

# =============================================================================
# build_and_push — Run a docker buildx build command with inline --push, with retry
#
# For builds that use --output=type=image,push=true (BuildKit pushes directly).
# On transient push failure, retries the full build+push command.
# BuildKit layer caching ensures rebuilds are near-instant.
#
# Arguments:
#   $1  — Image name (for logging only)
#   $2+ — The full docker buildx build command and arguments
#
# Returns:
#   0 on success, 1 after all retries exhausted
# =============================================================================
build_and_push() {
  local image_name="${1:?build_and_push: image name required}"
  shift
  local max_attempts=3
  local backoff=15

  log_info "Building and pushing: ${image_name}"

  for attempt in $(seq 1 "$max_attempts"); do
    log_info "Build+push attempt ${attempt}/${max_attempts}"

    if "$@" 2>&1; then
      log_success "Build+push succeeded on attempt ${attempt}"
      return 0
    fi

    log_warn "Build+push failed on attempt ${attempt}"
    if [[ "$attempt" -lt "$max_attempts" ]]; then
      log_info "Waiting ${backoff}s before retry (cached layers make rebuild fast)..."
      sleep "$backoff"
    fi
  done

  log_error "Build+push failed after ${max_attempts} attempts: ${image_name}"
  return 1
}
