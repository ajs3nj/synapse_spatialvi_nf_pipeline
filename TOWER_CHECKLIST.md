# Pre-flight checklist for full run on Nextflow Tower

Designed for **Seqera Tower**. Outputs are stored in **S3** (`--outdir` must be an S3 URI). Use this checklist before your run.

## 1. Required inputs

- [ ] **Samplesheet CSV**  
  - Columns: `sample`, `synapse_id_fastq_1`–`synapse_id_fastq_4`, `synapse_id_image`, `slide`, `area`, (optional) `results_parent_id`.  
  - Available to Tower (uploaded to Tower data, or a URL Tower can reach).

- [ ] **Synapse secret**  
  - Secret name: **`SYNAPSE_AUTH_TOKEN`**  
  - Value: Synapse personal access token with view, download, and modify scopes.  
  - Attached to the pipeline launch (workspace or pipeline secret).

- [ ] **Results folder**  
  - Either `results_parent_id` in every row of the CSV, or `--results_parent_id` / Tower parameter set to the Synapse folder where each sample’s full spatialvi results will be indexed.

## 2. Tower parameters to set

| Parameter | What to set |
|-----------|-------------|
| `input` | Path to your samplesheet (Tower data path or URL). |
| `results_parent_id` | Synapse folder ID where each sample’s full results will be indexed (if not in CSV). |
| `outdir` | **S3 URI** (required), e.g. `s3://your-bucket/your-prefix` (no trailing slash). Staging and results go under this. |
| `test_staging_only` | `false` for full run (default). |

Optional for this run:

- `cytassist`: set to `true` if using Cytassist images (samplesheet will use `cytaimage` column).

## 3. Config / defaults (already set in `nextflow.config`)

- **Reference:** `s3://ntap-add5-project-tower-bucket/reference/refdata-gex-GRCh38-2020-A.tar.gz`
- **Probeset:** `s3://ntap-add5-project-tower-bucket/spatialvi_testing/Visium_Human_Transcriptome_Probe_Set_v2.0_GRCh38-2020-A.csv`
- **SpatialVI:** `sagebio-ada/spatialvi` @ `dev`, profile `docker`

Override in Tower params or a custom config if you need different paths or branches.

## 4. Compute

- **RUN_SPATIALVI** requests: **8 CPUs**, **32 GB RAM**, **7 days** max time.  
- Ensure your Tower compute environment (e.g. AWS Batch) offers at least this (or adjust the process in `main.nf` / config).
- Container runtime: Docker.

## 5. Pipeline flow

Matches [nf-synapse meta-usage](https://github.com/Sage-Bionetworks-Workflows/nf-synapse): **SYNSTAGE → make tarball → workflow → SYNINDEX**.

**Full run:**  
1. **PREPARE_SYNSTAGE_INPUT** – Builds a CSV with `syn://` URIs from your samplesheet.  
2. **RUN_SYNSTAGE** – Runs [nf-synapse SYNSTAGE](https://github.com/Sage-Bionetworks-Workflows/nf-synapse) to stage all Synapse files to S3; updated CSV with S3 paths at `{outdir}/synstage/`.  
3. **MAKE_TARBALL** – Per sample: copies the 5 staged files from S3 into the task work dir (S3 is the only storage; tar needs local paths), packs 4 FASTQs into `{sample}_fastqs.tar.gz`, writes spatialvi samplesheet; publishDir writes to `{outdir}/staging/{sample}/`.  
4. **RUN_SPATIALVI** – Runs nf-core/spatialvi with reference and probeset; publishDir writes results to `{outdir}/spatialvi_results/{sample}/`.  
5. **INDEX_TO_SYNAPSE** – Runs [nf-synapse SYNINDEX](https://github.com/Sage-Bionetworks-Workflows/nf-synapse) to index that S3 prefix into Synapse.

**Test run (`--test_staging_only`):**  
1. **PREPARE_SYNSTAGE_INPUT** → **RUN_SYNSTAGE** → **MAKE_TARBALL** (same as above; staging written to S3 via publishDir).  
2. **INDEX_TO_SYNAPSE** – Indexes staged files into Synapse (no spatialvi).

## 6. Quick sanity checks

- [ ] Samplesheet has no header typos; column names match exactly (e.g. `synapse_id_fastq_1`, not `synapse_id_fastq1`).
- [ ] Synapse IDs are valid and the token has access to those files and the results folder.
- [ ] If using Cytassist, `--cytassist` (or `cytassist: true`) is set.
- [ ] `outdir` is set to an S3 URI you have write access to from Tower (e.g. bucket in same AWS account as Tower).

## 7. After the run

- **Staging:** `{outdir}/staging/` will have per-sample tarball, image, and samplesheet (with S3 or absolute paths).
- **S3:** Full spatialvi results per sample at `{outdir}/spatialvi_results/{sample}/`.
- **Synapse:** Each sample’s full results folder structure is indexed into the configured `results_parent_id` (via SYNINDEX).
- **Logs:** Use Tower’s logs and Nextflow report for any failed tasks.

---

*Remove or ignore this file once you’re done; it’s for pre-run checking only.*
