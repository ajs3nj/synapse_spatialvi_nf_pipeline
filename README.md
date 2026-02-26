# spatialvi_nf_pipeline (Meta-Workflow Orchestrator)

A **meta-workflow** for running [spatialvi](https://github.com/sagebio-ada/spatialvi) with data from Synapse and indexing results back to Synapse.

## Why Meta-Workflow?

Running nested Nextflow pipelines (Nextflow inside Nextflow) on AWS Batch/Tower is problematic due to Docker-in-Docker limitations. This meta-workflow splits the process into three separate Tower runs:

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  STEP 1: stage  │ ──▶ │ STEP 2: spatialvi│ ──▶ │ STEP 3: synindex│
│  (this pipeline)│     │ (run separately) │     │ (this pipeline) │
└─────────────────┘     └─────────────────┘     └─────────────────┘
   Download from           Run spatialvi          Index results
   Synapse, create         directly on Tower      back to Synapse
   samplesheet
```

## Orchestration Options

### Option A: Manual Tower Launches (Simple)

Launch each step manually in Tower. See [Manual Workflow](#manual-workflow) below.

### Option B: Tower CLI Script (Automated)

Use the provided script to orchestrate all three steps:

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

The script will:
1. Launch the staging step and wait for completion
2. Launch spatialvi and wait for completion
3. Launch synindex and wait for completion

See `./scripts/run_meta_workflow.sh --help` for all options.

### Option C: Tower Actions (Event-Driven)

Configure Tower Actions to automatically trigger subsequent steps. See `tower/actions.yml` for setup documentation.

---

## Manual Workflow

### Step 1: Stage files from Synapse

```bash
nextflow run . --entry stage \
  --input samplesheet.csv \
  --outdir s3://your-bucket/spatialvi_project \
  --results_parent_id syn123456 \
  -profile docker
```

**Output:** `s3://your-bucket/spatialvi_project/spatialvi_samplesheet.csv`

### Step 2: Run spatialvi on Tower

Launch `sagebio-ada/spatialvi` (or `nf-core/spatialvi`) as a **separate Tower run**:

- **Input:** `s3://your-bucket/spatialvi_project/spatialvi_samplesheet.csv`
- **Outdir:** `s3://your-bucket/spatialvi_project/spatialvi_results`
- **Other params:** `--spaceranger_reference`, `--spaceranger_probeset`, etc.

### Step 3: Index results to Synapse

```bash
nextflow run . --entry synindex \
  --input samplesheet.csv \
  --outdir s3://your-bucket/spatialvi_project \
  --results_parent_id syn123456 \
  -profile docker
```

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

## Parameters

| Parameter | Description | Required |
|-----------|-------------|----------|
| `--entry` | Workflow entry point: `stage` or `synindex` | Yes |
| `--input` | Path to samplesheet CSV | Yes |
| `--outdir` | S3 URI for outputs | Yes |
| `--results_parent_id` | Synapse folder ID for results | Yes |
| `--cytassist` | Use `cytaimage` column instead of `image` | No (default: false) |

## Running on Seqera Tower

### Step 1 (stage)

1. Create a new pipeline run with this repository
2. Set parameters:
   - `entry`: `stage`
   - `input`: path to your samplesheet
   - `outdir`: `s3://your-bucket/project`
   - `results_parent_id`: Synapse folder ID
3. Add secret: `SYNAPSE_AUTH_TOKEN`
4. Launch

### Step 2 (spatialvi)

1. Create a new pipeline run with `sagebio-ada/spatialvi`
2. Set parameters:
   - `input`: `s3://your-bucket/project/spatialvi_samplesheet.csv`
   - `outdir`: `s3://your-bucket/project/spatialvi_results`
   - `spaceranger_reference`: your reference tarball
   - `spaceranger_probeset`: your probeset (if needed)
3. Launch

### Step 3 (synindex)

1. Create a new pipeline run with this repository
2. Set parameters:
   - `entry`: `synindex`
   - `input`: same samplesheet as Step 1
   - `outdir`: same as Step 1 (`s3://your-bucket/project`)
   - `results_parent_id`: same Synapse folder ID
3. Add secret: `SYNAPSE_AUTH_TOKEN`
4. Launch

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

Results from `spatialvi_results/` are indexed into your Synapse folder.

## Tower CLI Script Options

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

## Notes

- The same `--input` samplesheet and `--outdir` should be used for Steps 1 and 3
- Step 2's `--outdir` should be `{your-outdir}/spatialvi_results` so Step 3 can find the results
- spatialvi identifies reads by filename convention (`_R1_`, `_R2_`, `_I1_`, `_I2_`), not by order
- Tower CLI requires `tw` to be installed: https://github.com/seqeralabs/tower-cli

## Related: Direct Integration into spatialvi Fork

For a single-pipeline approach (no orchestration needed), see the module files in `spatialvi_modules/` which can be integrated directly into the `sagebio-ada/spatialvi` fork.
