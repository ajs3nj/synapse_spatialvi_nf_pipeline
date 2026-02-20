# Pre-flight checklist for full run on Nextflow Tower

Designed for **Seqera Tower**. Outputs are stored in **S3** (`--outdir` must be an S3 URI). Use this checklist before your run.

## 1. Required inputs

- [ ] **Samplesheet CSV**  
  - Columns: `sample`, `fastq_1`, `fastq_2`, `fastq_3`, `fastq_4`, `image`, `slide`, `area`, (optional) `results_parent_id`.  
  - File columns must use **syn://** URIs (e.g. `syn://syn28521174`).  
  - Available to Tower (uploaded to Tower data, or a URL Tower can reach).

- [ ] **Synapse secret**  
  - Secret name: **`SYNAPSE_AUTH_TOKEN`**  
  - Value: Synapse personal access token with view, download, and modify scopes.  
  - Attached to the pipeline launch (workspace or pipeline secret).

- [ ] **Results folder**  
  - Either `results_parent_id` in every row of the CSV, or `--results_parent_id` / Tower parameter set to the Synapse folder where each sample’s full spatialvi results will be indexed.

## 2. Containers and Wave (if you see “container does not exist or access is not authorized”)

This pipeline runs **Nextflow inside a container** for three processes (RUN_SYNSTAGE, RUN_SPATIALVI, INDEX_TO_SYNAPSE), so it needs an image that has Nextflow installed. That’s different from **nf-synapse** and **nf-vcf2maf**:

- **nf-synapse:** Does *not* run Nextflow in a container. The pipeline runs on the Tower runner; only individual processes use containers (Synapse client, aws-cli). It sets those in `nextflow.config` by label and uses **ghcr.io** for aws-cli (`ghcr.io/sage-bionetworks-workflows/aws-cli:1.0`) and Docker Hub for the Synapse client.
- **nf-vcf2maf:** Also no Nextflow-in-container. Each process has a fixed `container` (e.g. `sagebionetworks/synapsepythonclient`, `python:3.10.4`) from Docker Hub. No Wave-specific config.

**If Wave returns 400 when pulling `nextflow/nextflow`**, use one of these:

1. **Let the compute environment pull images (disable Wave)**  
   In the Tower launch **Nextflow config** (or in `nextflow.config`), set:
   ```groovy
   wave { enabled = false }
   ```
   Then the executor (e.g. AWS Batch) pulls images directly; Docker Hub often works there even when Wave doesn’t.

2. **Add Docker Hub credentials to Tower**  
   In Tower: **Credentials** → **Add** → **Container registry** → Registry server: `docker.io`, and your Docker Hub username + read-only PAT. Attach that credential to the workspace or compute environment so Wave can pull `nextflow/nextflow:25.10.4`.

3. **Override the Nextflow image**  
   Set pipeline parameter **`nextflow_container`** to an image your workspace *can* pull (e.g. the same image in your own ECR or another registry). Example: `123456789012.dkr.ecr.us-east-1.amazonaws.com/nextflow:25.10.4`.

## 3. Tower parameters to set

| Parameter | What to set |
|-----------|-------------|
| `input` | Path to your samplesheet (Tower data path or URL). |
| `results_parent_id` | Synapse folder ID where each sample’s full results will be indexed (if not in CSV). |
| `outdir` | **S3 URI** (required), e.g. `s3://your-bucket/your-prefix` (no trailing slash). Staging and results go under this. |
| `nextflow_container` | (Optional) Override if Wave cannot pull the default (`nextflow/nextflow:25.10.4`). Use an image URI from a registry your workspace can access (e.g. ECR). |
| `test_staging_only` | `false` for full run (default). |

Optional for this run:

- `cytassist`: set to `true` if using Cytassist images (samplesheet will use `cytaimage` column).

## 4. Config / defaults (already set in `nextflow.config`)

- **Reference:** `s3://ntap-add5-project-tower-bucket/reference/refdata-gex-GRCh38-2020-A.tar.gz`
- **Probeset:** `s3://ntap-add5-project-tower-bucket/spatialvi_testing/Visium_Human_Transcriptome_Probe_Set_v2.0_GRCh38-2020-A.csv`
- **SpatialVI:** `sagebio-ada/spatialvi` @ `dev`, profile `docker`

Override in Tower params or a custom config if you need different paths or branches.

## 5. Compute

- **RUN_SPATIALVI** requests: **8 CPUs**, **32 GB RAM**, **7 days** max time.  
- Ensure your Tower compute environment (e.g. AWS Batch) offers at least this (or adjust the process in `main.nf` / config).
- Container runtime: Docker.

## 6. Pipeline flow

Matches [nf-synapse meta-usage](https://github.com/Sage-Bionetworks-Workflows/nf-synapse): **SYNSTAGE → make tarball → workflow → SYNINDEX**.

**Full run:**  
1. **RUN_SYNSTAGE** – Runs [nf-synapse SYNSTAGE](https://github.com/Sage-Bionetworks-Workflows/nf-synapse) on your samplesheet (must contain syn:// URIs); stages all files to S3; updated CSV at `{outdir}/synstage/`.  
2. **MAKE_TARBALL** – Per sample: copies the 5 staged files from S3 into the task work dir, packs 4 FASTQs into `{sample}_fastqs.tar.gz`, writes spatialvi samplesheet; publishDir writes to `{outdir}/staging/{sample}/`.  
3. **RUN_SPATIALVI** – Runs nf-core/spatialvi; publishDir writes results to `{outdir}/spatialvi_results/{sample}/`.  
4. **INDEX_TO_SYNAPSE** – Runs [nf-synapse SYNINDEX](https://github.com/Sage-Bionetworks-Workflows/nf-synapse) to index that S3 prefix into Synapse.

**Test run (`--test_staging_only`):**  
1. **RUN_SYNSTAGE** → **MAKE_TARBALL** (staging written to S3 via publishDir).  
2. **INDEX_TO_SYNAPSE** – Indexes staged files into Synapse (no spatialvi).

## 7. Quick sanity checks

- [ ] Samplesheet has no header typos; column names match exactly (e.g. `fastq_1`, `image`), and file columns use **syn://** URIs.
- [ ] Synapse IDs are valid and the token has access to those files and the results folder.
- [ ] If using Cytassist, `--cytassist` (or `cytassist: true`) is set.
- [ ] `outdir` is set to an S3 URI you have write access to from Tower (e.g. bucket in same AWS account as Tower).

## 8. After the run

- **Staging:** `{outdir}/staging/` will have per-sample tarball, image, and samplesheet (with S3 or absolute paths).
- **S3:** Full spatialvi results per sample at `{outdir}/spatialvi_results/{sample}/`.
- **Synapse:** Each sample’s full results folder structure is indexed into the configured `results_parent_id` (via SYNINDEX).
- **Logs:** Use Tower’s logs and Nextflow report for any failed tasks.

---

*Remove or ignore this file once you’re done; it’s for pre-run checking only.*
