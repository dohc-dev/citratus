#!/bin/bash
# ============================================================================
# build-mrpack.sh - Script to generate client and server .mrpack archives
# ============================================================================
# This script reads the Modrinth modpack structure and creates two .mrpack
# files (client and server variants) with configurable exclusions.
#
# Requirements:
#   - bash/sh shell
#   - jq (for JSON parsing)
#   - zip or tar (for archive creation)
#   - Standard Unix tools: mkdir, cp, rm, find, grep, cat, jq
#   - build/modrinth.index.json
#   - build/overrides/ (shared configs)
#   - build/client/overrides/ and build/server/overrides/ (variant configs)
#   - build/mods/, build/resourcepacks/, build/shaderpacks/
#
# Configuration:
#   - build-mrpack.json for exclude lists per variant
#
# Usage:
#   ./build-mrpack.sh
# ============================================================================

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
CONFIG_FILE="${SCRIPT_DIR}/build-mrpack.json"
BUILDS_OUTPUT_DIR="${SCRIPT_DIR}/builds"
MODRINTH_INDEX="${BUILD_DIR}/modrinth.index.json"
TEMP_BASE="${TMPDIR:-/tmp}"

# Global arrays for exclusions
CLIENT_EXCLUDE=()
SERVER_EXCLUDE=()

# Global manifest variables
MODPACK_NAME=""
VERSION_ID=""
CLIENT_MRPACK=""
SERVER_MRPACK=""

# ============================================================================
# Utility Functions - Logging
# ============================================================================

log_info() {
    echo -e "\033[36m[INFO]\033[0m $1"
}

log_success() {
    echo -e "\033[32m[SUCCESS]\033[0m $1"
}

log_warning() {
    echo -e "\033[33m[WARNING]\033[0m $1"
}

log_error() {
    echo -e "\033[31m[ERROR]\033[0m $1" >&2
}

# ============================================================================
# Utility Functions - Dependency & Structure Checks
# ============================================================================

test_dependencies() {
    log_info "Checking dependencies..."
    
    # Check for jq
    if ! command -v jq &> /dev/null; then
        log_error "jq not found. Please install jq for JSON parsing."
        exit 1
    fi
    log_success "jq found"
    
    # Check for zip or tar
    local has_zip=false
    local has_tar=false
    
    if command -v zip &> /dev/null; then
        has_zip=true
    fi
    
    if command -v tar &> /dev/null; then
        has_tar=true
    fi
    
    if ! $has_zip && ! $has_tar; then
        log_error "Neither 'zip' nor 'tar' found. Please install one of these tools."
        exit 1
    fi
    
    # Determine which tool to use
    if $has_zip; then
        ZIP_TOOL="zip"
        log_success "Using 'zip' for archive creation"
    else
        ZIP_TOOL="tar"
        log_success "Using 'tar' for archive creation"
    fi
}

test_build_structure() {
    log_info "Checking build structure..."
    
    if [[ ! -f "$MODRINTH_INDEX" ]]; then
        log_error "Missing: $MODRINTH_INDEX"
        exit 1
    fi
    
    if [[ ! -d "$BUILD_DIR/overrides" ]]; then
        log_error "Missing: $BUILD_DIR/overrides"
        exit 1
    fi
    
    log_success "Build structure is valid"
}

# ============================================================================
# Configuration Parsing
# ============================================================================

load_config() {
    log_info "Loading configuration..."
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_warning "Config file not found: $CONFIG_FILE"
        log_info "Using default (no exclusions)"
        return
    fi
    
    log_info "Parsing exclusion lists from $CONFIG_FILE"
    
    # Parse client exclusions using jq
    if command -v jq &> /dev/null; then
        local client_exclude_json
        client_exclude_json=$(jq -r '.client.exclude[]?' "$CONFIG_FILE" 2>/dev/null || echo "")
        if [[ -n "$client_exclude_json" ]]; then
            while IFS= read -r item; do
                if [[ -n "$item" ]]; then
                    CLIENT_EXCLUDE+=("$item")
                fi
            done <<< "$client_exclude_json"
        fi
        
        # Parse server exclusions using jq
        local server_exclude_json
        server_exclude_json=$(jq -r '.server.exclude[]?' "$CONFIG_FILE" 2>/dev/null || echo "")
        if [[ -n "$server_exclude_json" ]]; then
            while IFS= read -r item; do
                if [[ -n "$item" ]]; then
                    SERVER_EXCLUDE+=("$item")
                fi
            done <<< "$server_exclude_json"
        fi
    fi
    
    log_info "Client exclusions: ${#CLIENT_EXCLUDE[@]} items"
    log_info "Server exclusions: ${#SERVER_EXCLUDE[@]} items"
}

# ============================================================================
# Manifest Reading & Prompts
# ============================================================================

read_manifest() {
    log_info "Reading modrinth.index.json..."
    
    if ! command -v jq &> /dev/null; then
        log_error "jq required to parse modrinth.index.json"
        exit 1
    fi
    
    MODPACK_NAME=$(jq -r '.name // "UnknownPack"' "$MODRINTH_INDEX")
    VERSION_ID=$(jq -r '.versionId // "0.0.0"' "$MODRINTH_INDEX")
    
    log_success "Modpack: $MODPACK_NAME"
    log_success "Version: $VERSION_ID"
}

prompt_customization() {
    log_info "Customization prompts..."
    
    read -p "Version ID [$VERSION_ID]: " user_version
    if [[ -n "$user_version" ]]; then
        VERSION_ID="$user_version"
    fi
    
    read -p "Modpack name [$MODPACK_NAME]: " user_name
    if [[ -n "$user_name" ]]; then
        MODPACK_NAME="$user_name"
    fi
    
    # Build output file names
    CLIENT_MRPACK="${MODPACK_NAME}-${VERSION_ID}-client.mrpack"
    SERVER_MRPACK="${MODPACK_NAME}-${VERSION_ID}-server.mrpack"
    
    log_success "Output files:"
    log_success "  Client: $CLIENT_MRPACK"
    log_success "  Server: $SERVER_MRPACK"
}

# ============================================================================
# File Operations - Copy & Exclusions
# ============================================================================

copy_overrides() {
    local source_dir=$1
    local dest_dir=$2
    local variant=$3
    
    if [[ ! -d "$source_dir" ]]; then
        log_warning "Source directory not found: $source_dir (skipping)"
        return
    fi
    
    log_info "Copying overrides to $variant: $source_dir"
    
    # Create destination if needed
    mkdir -p "$dest_dir"
    
    # Copy all files and directories
    cp -r "$source_dir"/* "$dest_dir/" 2>/dev/null || true
}

apply_exclusions() {
    local work_dir=$1
    local variant=$2
    shift 2
    local exclude_patterns=("$@")
    
    if [[ ${#exclude_patterns[@]} -eq 0 ]]; then
        return
    fi
    
    log_info "Applying exclusions for $variant (${#exclude_patterns[@]} items)"
    
    for pattern in "${exclude_patterns[@]}"; do
        pattern=$(echo "$pattern" | xargs)  # Trim whitespace
        
        if [[ -z "$pattern" ]]; then
            continue
        fi
        
        # Find matching items using find with pattern matching
        local matched_count=0
        local found_any=false
        
        # Handle patterns with wildcards
        if [[ "$pattern" =~ [\*\?] ]]; then
            # Wildcard pattern - use find to recursively search
            while IFS= read -r -d '' item; do
                if [[ -n "$item" ]]; then
                    found_any=true
                    matched_count=$((matched_count + 1))
                    log_info "  Excluding: ${item#$work_dir/}"
                    rm -rf "$item"
                fi
            done < <(find "$work_dir" -path "*$pattern" -print0 2>/dev/null || true)
        else
            # Exact path match
            local full_path="${work_dir}/${pattern}"
            if [[ -e "$full_path" ]]; then
                found_any=true
                matched_count=1
                log_info "  Excluding: $pattern"
                rm -rf "$full_path"
            fi
        fi
        
        if ! $found_any; then
            log_warning "  Exclude pattern matched nothing: $pattern"
        fi
    done
}

copy_content_dirs() {
    local work_dir=$1
    local variant=$2
    
    local dirs=("mods" "resourcepacks" "shaderpacks")
    
    for dir in "${dirs[@]}"; do
        local source_path="${BUILD_DIR}/${dir}"
        if [[ -d "$source_path" ]]; then
            log_info "Copying $dir/ to $variant"
            local dest_path="${work_dir}/${dir}"
            mkdir -p "$dest_path"
            cp -r "$source_path"/* "$dest_path/" 2>/dev/null || true
        fi
    done
}

# ============================================================================
# Archive Creation
# ============================================================================

create_mrpack_archive() {
    local work_dir=$1
    local output_file=$2
    local variant=$3
    
    log_info "Creating $variant .mrpack archive..."
    
    # Create proper .mrpack structure: modrinth.index.json at root, everything else in overrides/
    local mrpack_dir
    mrpack_dir=$(mktemp -d "${TEMP_BASE}/mrpack_structure_${variant}_XXXXXX")
    
    # Cleanup on exit
    trap "rm -rf '$mrpack_dir'" RETURN
    
    # Copy modrinth.index.json to root of .mrpack
    cp "$MODRINTH_INDEX" "${mrpack_dir}/modrinth.index.json"
    
    # Move everything from work_dir into overrides/ subdirectory
    local overrides_dir="${mrpack_dir}/overrides"
    mkdir -p "$overrides_dir"
    
    cp -r "$work_dir"/* "$overrides_dir/" 2>/dev/null || true
    
    # Create the .mrpack archive
    local output_path="${BUILDS_OUTPUT_DIR}/${output_file}"
    
    if [[ "$ZIP_TOOL" == "zip" ]]; then
        # Use zip for compression
        (cd "$mrpack_dir" && zip -q -r "$output_path" . )
    else
        # Use tar for compression
        tar -czf "$output_path" -C "$mrpack_dir" .
    fi
    
    if [[ -f "$output_path" ]]; then
        local size_bytes
        size_bytes=$(stat -f%z "$output_path" 2>/dev/null || stat -c%s "$output_path" 2>/dev/null)
        local size_mb=$((size_bytes / 1024 / 1024))
        log_success "$variant archive created: $output_path (${size_mb} MB)"
    else
        log_error "Failed to create $variant archive at $output_path"
        exit 1
    fi
}

# ============================================================================
# Build Variant Orchestration
# ============================================================================

build_variant() {
    local variant=$1
    local output_file=$2
    shift 2
    local exclude_patterns=("$@")
    
    echo ""
    echo "=========================================="
    echo "Building $variant variant"
    echo "=========================================="
    
    # Create temporary working directory
    local temp_dir
    temp_dir=$(mktemp -d "${TEMP_BASE}/mrpack_${variant}_XXXXXX")
    log_info "Using temporary directory: $temp_dir"
    
    # Ensure cleanup on exit
    trap "rm -rf '$temp_dir'" RETURN
    
    # Step 1: Copy shared overrides
    copy_overrides "${BUILD_DIR}/overrides" "$temp_dir" "$variant"
    
    # Step 2: Copy variant-specific overrides
    local variant_dir="${BUILD_DIR}/${variant}/overrides"
    if [[ -d "$variant_dir" ]]; then
        log_info "Applying $variant-specific overrides from $variant_dir"
        copy_overrides "$variant_dir" "$temp_dir" "$variant"
    fi
    
    # Step 3: Copy content directories
    copy_content_dirs "$temp_dir" "$variant"
    
    # Step 4: Apply exclusions AFTER all content is copied
    apply_exclusions "$temp_dir" "$variant" "${exclude_patterns[@]}"
    
    # Step 5: Create the .mrpack archive
    create_mrpack_archive "$temp_dir" "$output_file" "$variant"
    
    log_success "$variant build complete"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║       Modrinth Modpack (.mrpack) Builder (Shell)           ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Phase 0: Check & Load
    test_dependencies
    test_build_structure
    load_config
    
    # Phase 1: Initialize
    read_manifest
    prompt_customization
    
    # Create output directory
    mkdir -p "$BUILDS_OUTPUT_DIR"
    log_info "Output directory: $BUILDS_OUTPUT_DIR"
    
    # Phase 2-3: Build variants
    build_variant "client" "$CLIENT_MRPACK" "${CLIENT_EXCLUDE[@]}"
    build_variant "server" "$SERVER_MRPACK" "${SERVER_EXCLUDE[@]}"
    
    # Summary
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                    BUILD COMPLETE ✓                        ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    log_success "Archives created in: $BUILDS_OUTPUT_DIR"
    log_success "  - $CLIENT_MRPACK"
    log_success "  - $SERVER_MRPACK"
    echo ""
}

# Run main function
main "$@"
