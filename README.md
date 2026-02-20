# spatialvi_nf_pipeline

Nextflow pipeline that follows the [nf-synapse meta-usage](https://github.com/Sage-Bionetworks-Workflows/nf-synapse) pattern: **SYNSTAGE** (stage Synapse files to S3) → **make tarball** → **run nf-core/spatialvi** → **SYNINDEX** (index S3 results back into Synapse). It stages **4 FASTQ files** and **1 image file** per sample from Synapse via [nf-synapse SYNSTAGE](https://github.com/Sage-Bionetworks-Workflows/nf-synapse), builds a FASTQ tarball and samplesheet, runs the [Sage Bionetworks spatialvi fork](https://github.com/sagebio-ada/spatialvi), then indexes full results into Synapse via [nf-synapse SYNINDEX](https://github.com/Sage-Bionetworks-Workflows/nf-synapse). Designed for **Seqera Tower**. All outputs are in **S3** — `--outdir` must be an S3 URI.

## Requirements

- Nextflow (22.10+)
- Access to Synapse (personal access token)
- Seqera Tower (optional but recommended) for orchestration
- Container runtime: Docker

## Quick start

1. **Samplesheet**  
   Create a CSV with one row per sample. Required columns:

   | Column | Description |
   |--------|-------------|
   | `sample` | Unique sample ID (must match FASTQ prefix expected by Space Ranger where applicable) |
   | `synapse_id_fastq_1` | Synapse ID of first FASTQ file |
   | `synapse_id_fastq_2` | Synapse ID of second FASTQ file |
   | `synapse_id_fastq_3` | Synapse ID of third FASTQ file |
   | `synapse_id_fastq_4` | Synapse ID of fourth FASTQ file |
   | `synapse_id_image` | Synapse ID of the microscopy image (e.g. brightfield) |
   | `slide` | Visium slide ID (e.g. `V11J26`) |
   | `area` | Slide area (e.g. `B1`), can be empty for unknown layout |
   | `results_parent_id` | (Optional) Synapse folder ID where results will be indexed. If omitted, use `--results_parent_id` in params. |

   Example: see `examples/samplesheet.csv`.

2. **Synapse token**  
   Create a Synapse personal access token with **view**, **download**, and **modify** scopes, then configure Nextflow secrets:

   ```bash
   export NXF_ENABLE_SECRETS=true
   nextflow secrets put -n SYNAPSE_AUTH_TOKEN -v "<your-synapse-pat>"
   ```

3. **Run**  
   Set **`--outdir`** to an S3 URI (required). With Docker:

   ```bash
   nextflow run . --input ./samplesheet.csv --outdir s3://your-bucket/prefix --results_parent_id syn12345678 -profile docker
   ```

   Or with a params file:

   ```bash
   nextflow run . -params-file params.yml -profile docker
   ```

## Staging-only test

To verify **file staging from Synapse → tarball generation → upload to Synapse** without running spatialvi (faster, smaller test):

1. Use a samplesheet with **one sample** and real Synapse IDs for the 4 FASTQs and 1 image.
2. Set **`--results_parent_id`** (or `results_parent_id` in the CSV) to the folder where you want the FASTQ tarball uploaded.
3. Run with **`--test_staging_only`**:

   ```bash
   nextflow run . --input ./samplesheet.csv --outdir s3://your-bucket/prefix --results_parent_id syn12345678 --test_staging_only -profile docker
   ```

**PREPARE_SYNSTAGE_INPUT** → **RUN_SYNSTAGE** ([nf-synapse SYNSTAGE](https://github.com/Sage-Bionetworks-Workflows/nf-synapse)) → **MAKE_TARBALL** (publishDir to `{outdir}/staging/{sample}/`) → **INDEX_TO_SYNAPSE** ([nf-synapse SYNINDEX](https://github.com/Sage-Bionetworks-Workflows/nf-synapse)). No spatialvi or heavy compute.

## Running on Seqera Tower

1. **Pipeline**  
   Use this repo as the pipeline source (Git URL or Tower-linked repo).

2. **Secrets**  
   In Tower, add a pipeline/workspace secret named **`SYNAPSE_AUTH_TOKEN`** with your Synapse personal access token. Use it when launching the run.

3. **Parameters**  
   Set at launch:
   - **`input`**: path to the samplesheet CSV (e.g. in Tower data or a URL).
   - **`results_parent_id`**: Synapse folder where each sample’s full spatialvi results will be indexed (if not set per sample in the CSV).
   - **`outdir`**: S3 URI (e.g. `s3://your-bucket/prefix`) — required; all outputs and indexing go through S3.

4. **Profiles**  
   Use `-profile docker` (and Tower’s default executor, e.g. AWS Batch).

5. **Compute**  
   `RUN_SPATIALVI` requests 8 CPUs and 32 GB RAM; Space Ranger and spatialvi can be heavy. Adjust in `nextflow.config` or Tower’s compute environment if needed.

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `input` | Path to samplesheet CSV | *(required)* |
| `results_parent_id` | Synapse folder where each sample’s full spatialvi results are indexed (if not in CSV) | null |
| `test_staging_only` | If true, only stage files, create fastq tarball, and upload it to Synapse (no spatialvi) | false |
| `spatialvi_pipeline` | SpatialVI pipeline repo (GitHub `org/repo`) | `sagebio-ada/spatialvi` |
| `spatialvi_release` | Branch or tag to run (e.g. `dev`, `main`) | `dev` |
| `cytassist` | If true, use `cytaimage` column (Cytassist tissue image) instead of `image` (brightfield) in the spatialvi samplesheet; see [nf-core/spatialvi usage](https://nf-co.re/spatialvi/dev/docs/usage/) | false |
| `outdir` | S3 URI for all outputs (staging and results); required | *(required)* |

Additional spatialvi options (e.g. `--spaceranger_reference`, `--spaceranger_probeset`) can be passed via `nextflow.config` or Tower parameter overrides if you add them to the `RUN_SPATIALVI` process.

## Outputs

- **SYNSTAGE:** nf-synapse stages all Synapse files to `{outdir}/` (id_folders by Synapse ID); the updated samplesheet with S3 paths is at `{outdir}/synstage/`.
- **Staging (MAKE_TARBALL):** Per sample, the FASTQ tarball `{sample}_fastqs.tar.gz`, image, and spatialvi samplesheet are written to S3 via publishDir at `{outdir}/staging/{sample}/`.
- **Full pipeline:** Per sample, spatialvi runs on the staged input; full results are written to S3 via publishDir at `{outdir}/spatialvi_results/{sample}/`, then [nf-synapse SYNINDEX](https://github.com/Sage-Bionetworks-Workflows/nf-synapse) indexes that prefix into the Synapse folder (`results_parent_id`), preserving folder structure.
- **Test run (`--test_staging_only`):** Staged files at `{outdir}/staging/{sample}/` are indexed into Synapse via SYNINDEX (no spatialvi).

## Notes

- The 4 FASTQ files are all FASTQ files. Column order in the input samplesheet (e.g. read 1, read 2, index 1, index 2) is for your bookkeeping; the pipeline preserves Synapse filenames when staging. spatialvi/Space Ranger identifies reads by filename convention (e.g. `_R1_`, `_R2_`, `_I1_`, `_I2_` in the filename), not by order in the directory.
- Space Ranger and the spatialvi pipeline have their own requirements (reference, probeset for FFPE/Cytassist). Use spatialvi’s `--spaceranger_reference` and `--spaceranger_probeset` as needed; you can wire these through params and the `RUN_SPATIALVI` script if required. For Cytassist samples, set `--cytassist` so the generated samplesheet uses the `cytaimage` column.
- The pipeline requires **`outdir`** to be an S3 URI; it will exit with an error otherwise. Ensure the compute environment has enough memory and that Docker is available for the spatialvi sub-run.
- The pipeline uses the [sagebio-ada/spatialvi](https://github.com/sagebio-ada/spatialvi) fork by default; override `--spatialvi_pipeline` to use another repo (e.g. `nf-core/spatialvi`).
