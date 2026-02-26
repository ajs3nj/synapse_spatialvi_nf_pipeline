# spatialvi_nf_pipeline (Meta-Workflow)

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

## Quick Start

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

## Notes

- The same `--input` samplesheet and `--outdir` should be used for Steps 1 and 3
- Step 2's `--outdir` should be `{your-outdir}/spatialvi_results` so Step 3 can find the results
- spatialvi identifies reads by filename convention (`_R1_`, `_R2_`, `_I1_`, `_I2_`), not by order
