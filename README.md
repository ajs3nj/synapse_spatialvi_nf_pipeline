# spatialvi_nf_pipeline

This repository contains two things:

1. **`make_tarball` pipeline** - A Nextflow pipeline that creates FASTQ tarballs from staged files for spatialvi
2. **Orca recipe** - A Python script that orchestrates the full spatialvi meta-workflow on Tower

---

## The make_tarball Pipeline

A simple Nextflow pipeline that takes files staged by [nf-synapse](https://github.com/Sage-Bionetworks-Workflows/nf-synapse) SYNSTAGE and prepares them for [spatialvi](https://github.com/sagebio-ada/spatialvi).

**What it does:**
- Takes individual FASTQ files and creates a tarball per sample
- Copies the microscopy image
- Generates a `spatialvi_samplesheet.csv` with S3 paths

### Parameters

| Parameter | Description | Required |
|-----------|-------------|----------|
| `--entry` | Must be `make_tarball` | Yes |
| `--input` | Path to synstage output samplesheet (with S3 paths) | Yes |
| `--outdir` | S3 URI for outputs | Yes |
| `--cytassist` | Use `cytaimage` column instead of `image` | No (default: false) |

### Input Samplesheet

The input is the output from nf-synapse SYNSTAGE - a CSV where `syn://` URIs have been replaced with S3 paths:

| Column | Description |
|--------|-------------|
| `sample` | Unique sample ID |
| `fastq_1` | S3 path to FASTQ file 1 |
| `fastq_2` | S3 path to FASTQ file 2 |
| `fastq_3` | S3 path to FASTQ file 3 |
| `fastq_4` | S3 path to FASTQ file 4 |
| `image` | S3 path to microscopy image |
| `slide` | Visium slide ID (e.g., `V11J26`) |
| `area` | Slide area (e.g., `B1`), can be empty |

### Outputs

```
s3://bucket/project/
├── tarballs/
│   └── SAMPLE1/
│       ├── SAMPLE1_fastqs.tar.gz
│       └── image_out/
│           └── image.tif
└── spatialvi_samplesheet.csv
```

### Running Standalone

```bash
nextflow run . --entry make_tarball \
  --input s3://bucket/project/synstage/samplesheet.csv \
  --outdir s3://bucket/project \
  -profile docker
```

---

## Orca Orchestration

The `orca/spatialvi_workflow.py` script orchestrates a complete spatialvi workflow using [Orca](https://github.com/Sage-Bionetworks-Workflows/py-orca) to chain four pipelines on Tower:

```
┌─────────────────────┐     ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────────┐
│ 1. nf-synapse       │ ──▶ │ 2. make_tarball │ ──▶ │ 3. spatialvi    │ ──▶ │ 4. nf-synapse       │
│    SYNSTAGE         │     │ (this repo)     │     │                 │     │    SYNINDEX         │
└─────────────────────┘     └─────────────────┘     └─────────────────┘     └─────────────────────┘
   Download from              Create FASTQ            Run spatialvi         Index results
   Synapse to S3              tarballs +              analysis              back to Synapse
                              samplesheet
```

**How it works:**
- The Orca script runs locally (or in CI/CD)
- It launches each pipeline on Tower and waits for completion before starting the next
- All configuration is defined in the script's `generate_datasets()` function

### Prerequisites

```bash
pip install py-orca
```

### Configuration

Edit `orca/spatialvi_workflow.py` and modify `generate_datasets()`:

```python
def generate_datasets() -> list[SpatialviDataset]:
    return [
        SpatialviDataset(
            id="my_dataset",
            synstage_input_samplesheet="s3://bucket/project/synstage_input.csv",
            synapse_output_folder="syn123456",
            bucket_name="my-bucket",
            project_prefix="spatialvi_project",
            spaceranger_reference="s3://bucket/refdata-gex-GRCh38-2020-A.tar.gz",
            spaceranger_probeset="s3://bucket/probeset.csv",  # optional
        )
    ]
```

### Input Samplesheet for SYNSTAGE

Create a CSV with `syn://` URIs. SYNSTAGE will download files and replace URIs with S3 paths.

| Column | Description |
|--------|-------------|
| `sample` | Unique sample ID |
| `fastq_1` | Synapse URI (e.g., `syn://syn64002035`) |
| `fastq_2` | Synapse URI |
| `fastq_3` | Synapse URI |
| `fastq_4` | Synapse URI |
| `image` | Synapse URI for microscopy image |
| `slide` | Visium slide ID |
| `area` | Slide area (can be empty) |

Example (`examples/1_synstage_input.csv`):
```csv
sample,fastq_1,fastq_2,fastq_3,fastq_4,image,slide,area
ANNUBP_V42N08_047_A1,syn://syn64002035,syn://syn64002036,syn://syn64002037,syn://syn64002038,syn://syn64002032,V42N08-047,A1
```

### Running

```bash
cd orca/
python spatialvi_workflow.py
```

The script will:
1. Launch SYNSTAGE on Tower and wait for completion
2. Launch make_tarball on Tower and wait for completion
3. Launch spatialvi on Tower and wait for completion
4. Launch SYNINDEX on Tower and wait for completion

---

## Running Manually on Tower (Without Orca)

If you prefer to run each step manually in Tower:

### Step 1: SYNSTAGE
- Pipeline: `Sage-Bionetworks-Workflows/nf-synapse`
- Parameters:
  - `entry`: `synstage`
  - `input`: `s3://bucket/project/synstage_input.csv`
  - `outdir`: `s3://bucket/project/synstage`
- Secrets: `SYNAPSE_AUTH_TOKEN`

### Step 2: make_tarball
- Pipeline: `ajs3nj/synapse_spatialvi_nf_pipeline` (branch: `orca-orchestration`)
- Parameters:
  - `entry`: `make_tarball`
  - `input`: `s3://bucket/project/synstage/synstage_input.csv`
  - `outdir`: `s3://bucket/project`

### Step 3: spatialvi
- Pipeline: `sagebio-ada/spatialvi`
- Parameters:
  - `input`: `s3://bucket/project/spatialvi_samplesheet.csv`
  - `outdir`: `s3://bucket/project/spatialvi_results`
  - `spaceranger_reference`: your reference
  - `spaceranger_probeset`: your probeset (if needed)

### Step 4: SYNINDEX
- Pipeline: `Sage-Bionetworks-Workflows/nf-synapse`
- Parameters:
  - `entry`: `synindex`
  - `s3_prefix`: `s3://bucket/project/spatialvi_results`
  - `parent_id`: `syn123456`
- Secrets: `SYNAPSE_AUTH_TOKEN`

---

## Notes

- SYNSTAGE replaces `syn://` URIs with S3 paths in-place in the samplesheet
- The `slide` and `area` columns pass through all steps unchanged
- spatialvi identifies reads by filename convention (`_R1_`, `_R2_`, `_I1_`, `_I2_`)
- Requires `SYNAPSE_AUTH_TOKEN` secret configured in Tower workspace
