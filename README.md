# spatialvi_nf_pipeline

Nextflow pipeline that stages **4 FASTQ files** and **1 image file** from Synapse, runs the [Sage Bionetworks spatialvi fork](https://github.com/sagebio-ada/spatialvi) (Visium spatial transcriptomics, forked from nf-core/spatialvi), and uploads result tarballs back to Synapse. Designed to run on **Seqera Tower**.

Pattern is similar to [Sage-Bionetworks-Workflows/nf-vcf2maf](https://github.com/Sage-Bionetworks-Workflows/nf-vcf2maf): Synapse → stage → run pipeline → index results to Synapse.

## Requirements

- Nextflow (22.10+)
- Access to Synapse (personal access token)
- Seqera Tower (optional but recommended) for orchestration
- Container runtime: Docker or Singularity

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
   | `results_parent_id` | (Optional) Synapse folder ID where the result tarball will be uploaded. If omitted, use `--results_parent_id` in params. |

   Example: see `examples/samplesheet.csv`.

2. **Synapse token**  
   Create a Synapse personal access token with **view**, **download**, and **modify** scopes, then configure Nextflow secrets:

   ```bash
   export NXF_ENABLE_SECRETS=true
   nextflow secrets put -n SYNAPSE_AUTH_TOKEN -v "<your-synapse-pat>"
   ```

3. **Run**  
   With Docker:

   ```bash
   nextflow run . --input ./samplesheet.csv --results_parent_id syn12345678 -profile docker
   ```

   Or with a params file:

   ```bash
   nextflow run . -params-file params.yml -profile docker
   ```

## Staging-only test

To verify **file staging → tarball generation → upload to Synapse** without running spatialvi (faster, smaller test):

1. Use a samplesheet with **one sample** and real Synapse IDs for the 4 FASTQs and 1 image.
2. Set **`--results_parent_id`** (or `results_parent_id` in the CSV) to the folder where you want the FASTQ tarball uploaded.
3. Run with **`--test_staging_only`**:

   ```bash
   nextflow run . --input ./samplesheet.csv --results_parent_id syn12345678 --test_staging_only -profile docker
   ```

This runs: **DOWNLOAD_AND_STAGE** (download 5 files from Synapse, pack FASTQs into `{sample}_fastqs.tar.gz`) → **STORE_STAGED_TARBALL** (upload that tarball to Synapse). No spatialvi or heavy compute. Check the target Synapse folder for `{sample}_fastqs.tar.gz`.

## Running on Seqera Tower

1. **Pipeline**  
   Use this repo as the pipeline source (Git URL or Tower-linked repo).

2. **Secrets**  
   In Tower, add a pipeline/workspace secret named **`SYNAPSE_AUTH_TOKEN`** with your Synapse personal access token. Use it when launching the run.

3. **Parameters**  
   Set at launch:
   - **`input`**: path to the samplesheet CSV (e.g. in Tower data or a URL).
   - **`results_parent_id`**: Synapse folder for result tarballs (if not set per sample in the CSV).

4. **Profiles**  
   Use `-profile docker` or `-profile singularity` (and Tower’s default executor, e.g. AWS Batch).

5. **Compute**  
   `RUN_SPATIALVI` requests 8 CPUs and 32 GB RAM; Space Ranger and spatialvi can be heavy. Adjust in `nextflow.config` or Tower’s compute environment if needed.

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `input` | Path to samplesheet CSV | *(required)* |
| `results_parent_id` | Synapse folder for result tarballs (if not in CSV) | null |
| `test_staging_only` | If true, only stage files, create fastq tarball, and upload it to Synapse (no spatialvi) | false |
| `spatialvi_pipeline` | SpatialVI pipeline repo (GitHub `org/repo`) | `sagebio-ada/spatialvi` |
| `spatialvi_release` | Branch or tag to run (e.g. `dev`, `main`) | `dev` |
| `spatialvi_profile` | Profile for spatialvi sub-run: `docker` or `singularity` | `docker` |
| `outdir` | Local outdir for spatialvi (inside process) | `./results` |

Additional spatialvi options (e.g. `--spaceranger_reference`, `--spaceranger_probeset`) can be passed via `nextflow.config` or Tower parameter overrides if you add them to the `RUN_SPATIALVI` process.

## Outputs

- **Per sample**: a tarball `{sample}_spatialvi_results.tar.gz` containing the nf-core/spatialvi output (Space Ranger outputs, reports, data, etc.) is uploaded to the Synapse folder given by `results_parent_id` or the row’s `results_parent_id`.

## Notes

- The 4 FASTQ files are assumed to be in the order given in the samplesheet (e.g. read1, read2, index1, index2 or lane1/lane2). Names from Synapse are preserved when placed in the staged `fastq_dir`.
- Space Ranger and the spatialvi pipeline have their own requirements (reference, probeset for FFPE/Cytassist). Use spatialvi’s `--spaceranger_reference` and `--spaceranger_probeset` as needed; you can wire these through params and the `RUN_SPATIALVI` script if required.
- For Tower, ensure the compute environment has enough memory and that Docker (or Singularity) is available for the spatialvi sub-run.
- The pipeline uses the [sagebio-ada/spatialvi](https://github.com/sagebio-ada/spatialvi) fork by default; override `--spatialvi_pipeline` to use another repo (e.g. `nf-core/spatialvi`).

## License

Apache-2.0 (or match your organization’s policy).
