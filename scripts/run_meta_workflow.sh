#!/usr/bin/env bash
#
# run_meta_workflow.sh
#
# Orchestrates the three-step spatialvi meta-workflow using Tower CLI.
# Launches each step sequentially and waits for completion.
#
# Prerequisites:
#   - Tower CLI installed: https://github.com/seqeralabs/tower-cli
#   - TOWER_ACCESS_TOKEN environment variable set
#   - TOWER_WORKSPACE_ID environment variable set (or use --workspace flag)
#
# Usage:
#   ./run_meta_workflow.sh \
#     --input s3://bucket/samplesheet.csv \
#     --outdir s3://bucket/project \
#     --results-parent-id syn123456 \
#     --spatialvi-pipeline sagebio-ada/spatialvi \
#     --spatialvi-revision dev
#

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

# Default values
STAGING_PIPELINE="ajs3nj/synapse_spatialvi_nf_pipeline"  # This repo on Tower
STAGING_REVISION="meta-workflow"
SPATIALVI_PIPELINE="sagebio-ada/spatialvi"
SPATIALVI_REVISION="dev"
COMPUTE_ENV=""  # Use workspace default if not specified
POLL_INTERVAL=60  # seconds between status checks

# =============================================================================
# Parse Arguments
# =============================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required:
  --input FILE              Samplesheet CSV with Synapse IDs (S3 path)
  --outdir URI              S3 output directory
  --results-parent-id ID    Synapse folder ID for results

Optional:
  --spatialvi-pipeline STR  spatialvi pipeline (default: sagebio-ada/spatialvi)
  --spatialvi-revision STR  spatialvi revision (default: dev)
  --spaceranger-ref URI     Spaceranger reference tarball
  --spaceranger-probeset URI Spaceranger probeset file
  --compute-env ID          Tower compute environment ID
  --workspace ID            Tower workspace ID (or set TOWER_WORKSPACE_ID)
  --skip-stage              Skip staging step (data already staged)
  --skip-spatialvi          Skip spatialvi step
  --skip-synindex           Skip synindex step
  --dry-run                 Print commands without executing
  -h, --help                Show this help

Environment:
  TOWER_ACCESS_TOKEN        Tower API access token (required)
  TOWER_WORKSPACE_ID        Default workspace ID

Example:
  export TOWER_ACCESS_TOKEN=<your-token>
  export TOWER_WORKSPACE_ID=<your-workspace>

  ./run_meta_workflow.sh \\
    --input s3://bucket/samplesheet.csv \\
    --outdir s3://bucket/spatialvi_project \\
    --results-parent-id syn73722889 \\
    --spaceranger-ref s3://bucket/refdata-gex-GRCh38-2020-A.tar.gz \\
    --spaceranger-probeset s3://bucket/Visium_Human_Transcriptome_Probe_Set_v2.0.csv
EOF
}

INPUT=""
OUTDIR=""
RESULTS_PARENT_ID=""
SPACERANGER_REF=""
SPACERANGER_PROBESET=""
WORKSPACE="${TOWER_WORKSPACE_ID:-}"
SKIP_STAGE=false
SKIP_SPATIALVI=false
SKIP_SYNINDEX=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --input) INPUT="$2"; shift 2 ;;
        --outdir) OUTDIR="$2"; shift 2 ;;
        --results-parent-id) RESULTS_PARENT_ID="$2"; shift 2 ;;
        --spatialvi-pipeline) SPATIALVI_PIPELINE="$2"; shift 2 ;;
        --spatialvi-revision) SPATIALVI_REVISION="$2"; shift 2 ;;
        --spaceranger-ref) SPACERANGER_REF="$2"; shift 2 ;;
        --spaceranger-probeset) SPACERANGER_PROBESET="$2"; shift 2 ;;
        --compute-env) COMPUTE_ENV="$2"; shift 2 ;;
        --workspace) WORKSPACE="$2"; shift 2 ;;
        --skip-stage) SKIP_STAGE=true; shift ;;
        --skip-spatialvi) SKIP_SPATIALVI=true; shift ;;
        --skip-synindex) SKIP_SYNINDEX=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# Validate required arguments
[[ -z "$INPUT" ]] && { echo "Error: --input is required" >&2; exit 1; }
[[ -z "$OUTDIR" ]] && { echo "Error: --outdir is required" >&2; exit 1; }
[[ -z "$RESULTS_PARENT_ID" ]] && { echo "Error: --results-parent-id is required" >&2; exit 1; }
[[ -z "${TOWER_ACCESS_TOKEN:-}" ]] && { echo "Error: TOWER_ACCESS_TOKEN not set" >&2; exit 1; }
[[ -z "$WORKSPACE" ]] && { echo "Error: --workspace or TOWER_WORKSPACE_ID required" >&2; exit 1; }

# Normalize outdir (remove trailing slash)
OUTDIR="${OUTDIR%/}"

# =============================================================================
# Helper Functions
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

run_cmd() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] $*"
    else
        "$@"
    fi
}

# Launch a pipeline and return the run ID
launch_pipeline() {
    local pipeline="$1"
    local revision="$2"
    local name="$3"
    shift 3
    local params=("$@")
    
    local cmd=(
        tw launch "$pipeline"
        --revision "$revision"
        --workspace "$WORKSPACE"
        --name "$name"
    )
    
    [[ -n "$COMPUTE_ENV" ]] && cmd+=(--compute-env "$COMPUTE_ENV")
    
    cmd+=("${params[@]}")
    
    log "Launching: ${cmd[*]}"
    
    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] Would launch: ${cmd[*]}"
        echo "dry-run-id-$(date +%s)"
        return
    fi
    
    # Launch and capture run ID from output
    local output
    output=$("${cmd[@]}" 2>&1)
    echo "$output" >&2
    
    # Extract run ID (format varies, try common patterns)
    local run_id
    run_id=$(echo "$output" | grep -oE '[a-zA-Z0-9]{20,}' | head -1)
    
    if [[ -z "$run_id" ]]; then
        echo "Error: Could not extract run ID from output" >&2
        return 1
    fi
    
    echo "$run_id"
}

# Wait for a run to complete
wait_for_run() {
    local run_id="$1"
    local name="$2"
    
    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] Would wait for run: $run_id"
        return 0
    fi
    
    log "Waiting for $name (run: $run_id) to complete..."
    
    while true; do
        local status
        status=$(tw runs view --id "$run_id" --workspace "$WORKSPACE" -o json 2>/dev/null | jq -r '.status' 2>/dev/null || echo "UNKNOWN")
        
        case "$status" in
            SUCCEEDED)
                log "$name completed successfully"
                return 0
                ;;
            FAILED|CANCELLED|UNKNOWN)
                log "ERROR: $name failed with status: $status"
                return 1
                ;;
            *)
                log "$name status: $status (checking again in ${POLL_INTERVAL}s)"
                sleep "$POLL_INTERVAL"
                ;;
        esac
    done
}

# =============================================================================
# Main Workflow
# =============================================================================

log "=========================================="
log "spatialvi Meta-Workflow Orchestrator"
log "=========================================="
log ""
log "Configuration:"
log "  Input:              $INPUT"
log "  Output:             $OUTDIR"
log "  Results Parent ID:  $RESULTS_PARENT_ID"
log "  Workspace:          $WORKSPACE"
log "  Spatialvi Pipeline: $SPATIALVI_PIPELINE"
log "  Spatialvi Revision: $SPATIALVI_REVISION"
log ""

STAGED_SAMPLESHEET="${OUTDIR}/spatialvi_samplesheet.csv"
SPATIALVI_OUTDIR="${OUTDIR}/spatialvi_results"

# ---------------------------------------------------------------------------
# Step 1: Stage files from Synapse
# ---------------------------------------------------------------------------
if [[ "$SKIP_STAGE" == false ]]; then
    log "=========================================="
    log "STEP 1: Staging files from Synapse"
    log "=========================================="
    
    STAGE_RUN_ID=$(launch_pipeline \
        "$STAGING_PIPELINE" \
        "$STAGING_REVISION" \
        "stage-$(date +%Y%m%d-%H%M%S)" \
        --params-file <(cat <<EOF
entry: stage
input: "$INPUT"
outdir: "$OUTDIR"
results_parent_id: "$RESULTS_PARENT_ID"
EOF
))
    
    wait_for_run "$STAGE_RUN_ID" "Stage"
else
    log "Skipping Stage step (--skip-stage)"
fi

# ---------------------------------------------------------------------------
# Step 2: Run spatialvi
# ---------------------------------------------------------------------------
if [[ "$SKIP_SPATIALVI" == false ]]; then
    log "=========================================="
    log "STEP 2: Running spatialvi"
    log "=========================================="
    
    SPATIALVI_PARAMS=(
        --params-file <(cat <<EOF
input: "$STAGED_SAMPLESHEET"
outdir: "$SPATIALVI_OUTDIR"
EOF
)
    )
    
    # Add optional spaceranger params if provided
    if [[ -n "$SPACERANGER_REF" ]]; then
        SPATIALVI_PARAMS+=(--params-file <(echo "spaceranger_reference: \"$SPACERANGER_REF\""))
    fi
    if [[ -n "$SPACERANGER_PROBESET" ]]; then
        SPATIALVI_PARAMS+=(--params-file <(echo "spaceranger_probeset: \"$SPACERANGER_PROBESET\""))
    fi
    
    SPATIALVI_RUN_ID=$(launch_pipeline \
        "$SPATIALVI_PIPELINE" \
        "$SPATIALVI_REVISION" \
        "spatialvi-$(date +%Y%m%d-%H%M%S)" \
        "${SPATIALVI_PARAMS[@]}")
    
    wait_for_run "$SPATIALVI_RUN_ID" "spatialvi"
else
    log "Skipping spatialvi step (--skip-spatialvi)"
fi

# ---------------------------------------------------------------------------
# Step 3: Index results to Synapse
# ---------------------------------------------------------------------------
if [[ "$SKIP_SYNINDEX" == false ]]; then
    log "=========================================="
    log "STEP 3: Indexing results to Synapse"
    log "=========================================="
    
    SYNINDEX_RUN_ID=$(launch_pipeline \
        "$STAGING_PIPELINE" \
        "$STAGING_REVISION" \
        "synindex-$(date +%Y%m%d-%H%M%S)" \
        --params-file <(cat <<EOF
entry: synindex
input: "$INPUT"
outdir: "$OUTDIR"
results_parent_id: "$RESULTS_PARENT_ID"
EOF
))
    
    wait_for_run "$SYNINDEX_RUN_ID" "Synindex"
else
    log "Skipping Synindex step (--skip-synindex)"
fi

log ""
log "=========================================="
log "Meta-workflow completed successfully!"
log "=========================================="
log ""
log "Results indexed to Synapse folder: $RESULTS_PARENT_ID"
