# spatialvi_nf_pipeline (Meta-Workflow Orchestrator)

A **meta-workflow** for running [spatialvi](https://github.com/sagebio-ada/spatialvi) with data from Synapse and indexing results back to Synapse.

## Overview

Running nested Nextflow pipelines on AWS Batch/Tower is problematic due to Docker-in-Docker limitations. This meta-workflow splits the process into three separate steps:

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  STEP 1: stage  │ ──▶ │ STEP 2: spatialvi│ ──▶ │ STEP 3: synindex│
│  (this pipeline)│     │ (run separately) │     │ (this pipeline) │
└─────────────────┘     └─────────────────┘     └─────────────────┘
   Download from           Run spatialvi          Index results
   Synapse, create         directly on Tower      back to Synapse
   samplesheet
```

---

## Parameters

| Parameter | Description | Required |
|-----------|-------------|----------|
| `--entry` | Workflow entry point: `stage` or `synindex` | Yes |
| `--input` | Path to samplesheet CSV | Yes |
| `--outdir` | S3 URI for outputs | Yes |
| `--results_parent_id` | Synapse folder ID for results | Yes |
| `--cytassist` | Use `cytaimage` column instead of `image` | No (default: false) |

---

## Input Samplesheet

Create a CSV with one row per sample:

| Column | Description |
|--------|-------------|
| `sample` | Unique sample ID |
| `synapse_id_fastq_1` | Synapse ID of first FASTQ file |
| `synapse_id_fastq_2` | Synapse ID of second FASTQ file |
| `synapse_id_fastq_3` | Synapse ID of third FASTQ file |
| `synapse_id_fastq_4` | Synapse ID of fourth FASTQ file |
| `synapse_id_image` | Synapse ID of the microscopy image |
| `slide` | Visium slide ID (e.g. `V11J26`) |
| `area` | Slide area (e.g. `B1`), can be empty |
| `results_parent_id` | (Optional) Synapse folder ID for this sample's results |

Example:
```csv
sample,synapse_id_fastq_1,synapse_id_fastq_2,synapse_id_fastq_3,synapse_id_fastq_4,synapse_id_image,slide,area,results_parent_id
SAMPLE1,syn001,syn002,syn003,syn004,syn005,V11J26,B1,syn999
```

---

## Outputs

### After Step 1 (stage)

```
s3://your-bucket/project/
├── staging/
│   ├── SAMPLE1/
│   │   ├── SAMPLE1_fastqs.tar.gz
│   │   └── image.tif
│   └── SAMPLE2/
│       ├── SAMPLE2_fastqs.tar.gz
│       └── image.tif
└── spatialvi_samplesheet.csv    ← Use this for Step 2
```

### After Step 2 (spatialvi)

```
s3://your-bucket/project/
├── staging/
│   └── ...
├── spatialvi_samplesheet.csv
└── spatialvi_results/           ← Created by spatialvi
    ├── SAMPLE1/
    │   └── ...
    └── SAMPLE2/
        └── ...
```

### After Step 3 (synindex)

Results from `spatialvi_results/` are uploaded to your Synapse folder.

---

## Notes

- The same `--input` samplesheet and `--outdir` should be used for Steps 1 and 3
- Step 2's `--outdir` must be `{your-outdir}/spatialvi_results` so Step 3 can find the results
- spatialvi identifies reads by filename convention (`_R1_`, `_R2_`, `_I1_`, `_I2_`), not by order
- Requires `SYNAPSE_AUTH_TOKEN` secret configured in Tower

---

## Running the Workflow

Three options for orchestrating the three steps:

### Option A: Manual Tower Launches

Launch each step manually in the Tower UI.

**Step 1 - Stage:**
1. Create pipeline run with this repository (`meta-workflow` branch)
2. Set parameters:
   - `entry`: `stage`
   - `input`: path to your samplesheet
   - `outdir`: `s3://your-bucket/project`
   - `results_parent_id`: Synapse folder ID
3. Add secret: `SYNAPSE_AUTH_TOKEN`
4. Launch

**Step 2 - spatialvi:**
1. Create pipeline run with `sagebio-ada/spatialvi`
2. Set parameters:
   - `input`: `s3://your-bucket/project/spatialvi_samplesheet.csv`
   - `outdir`: `s3://your-bucket/project/spatialvi_results`
   - `spaceranger_reference`: your reference tarball
   - `spaceranger_probeset`: your probeset (if needed)
3. Launch

**Step 3 - Synindex:**
1. Create pipeline run with this repository
2. Set parameters:
   - `entry`: `synindex`
   - `input`: same samplesheet as Step 1
   - `outdir`: same as Step 1
   - `results_parent_id`: same Synapse folder ID
3. Add secret: `SYNAPSE_AUTH_TOKEN`
4. Launch

---

### Option B: Tower CLI Script (Automated)

Use the provided script to orchestrate all three steps automatically.

**Prerequisites:**
- Tower CLI installed: https://github.com/seqeralabs/tower-cli
- `TOWER_ACCESS_TOKEN` and `TOWER_WORKSPACE_ID` environment variables set

**Usage:**
```bash
export TOWER_ACCESS_TOKEN=<your-token>
export TOWER_WORKSPACE_ID=<your-workspace-id>

./scripts/run_meta_workflow.sh \
  --input s3://bucket/samplesheet.csv \
  --outdir s3://bucket/spatialvi_project \
  --results-parent-id syn73722889 \
  --spaceranger-ref s3://bucket/refdata-gex-GRCh38-2020-A.tar.gz \
  --spaceranger-probeset s3://bucket/probeset.csv
```

The script launches each step, waits for completion, then launches the next.

**All options:**
```
./scripts/run_meta_workflow.sh --help

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
  --workspace ID            Tower workspace ID
  --skip-stage              Skip staging step (data already staged)
  --skip-spatialvi          Skip spatialvi step
  --skip-synindex           Skip synindex step
  --dry-run                 Print commands without executing
```

---

### Option C: Tower Actions (Event-Driven)

Configure Tower Actions to automatically trigger subsequent steps when each completes.

**Setup:**

1. **Add pipelines to Launchpad:**
   - `ajs3nj/synapse_spatialvi_nf_pipeline` (revision: `meta-workflow`)
   - `sagebio-ada/spatialvi`

2. **Create Action: "Launch spatialvi after staging"**
   - Go to Launchpad → Actions → Create Action
   - Trigger: `Pipeline completion`
   - Source pipeline: `ajs3nj/synapse_spatialvi_nf_pipeline`
   - Source status: `Succeeded`
   - Target pipeline: `sagebio-ada/spatialvi`
   - Set target parameters for spatialvi

3. **Create Action: "Launch synindex after spatialvi"**
   - Trigger: `Pipeline completion`
   - Source pipeline: `sagebio-ada/spatialvi`
   - Source status: `Succeeded`
   - Target pipeline: `ajs3nj/synapse_spatialvi_nf_pipeline`
   - Set target parameters with `entry: synindex`

**Limitation:** Tower Actions trigger on *any* completion of the source pipeline, so unrelated runs may trigger the action. The CLI script (Option B) provides more control.

---

### Option D: Local / Command Line

For local testing or non-Tower environments:

```bash
# Step 1: Stage
nextflow run . --entry stage \
  --input samplesheet.csv \
  --outdir s3://your-bucket/project \
  --results_parent_id syn123456 \
  -profile docker

# Step 2: Run spatialvi separately
nextflow run sagebio-ada/spatialvi \
  --input s3://your-bucket/project/spatialvi_samplesheet.csv \
  --outdir s3://your-bucket/project/spatialvi_results \
  --spaceranger_reference <ref> \
  --spaceranger_probeset <probeset>

# Step 3: Synindex
nextflow run . --entry synindex \
  --input samplesheet.csv \
  --outdir s3://your-bucket/project \
  --results_parent_id syn123456 \
  -profile docker
```
