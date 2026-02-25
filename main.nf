#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

/*
 * Pipeline: Stage FASTQ + image from Synapse -> run nf-core/spatialvi -> index results to Synapse.
 * Samplesheet: CSV with Synapse IDs for 4 FASTQ files and 1 image per sample.
 * Compatible with Seqera Tower (use SYNAPSE_AUTH_TOKEN secret).
 */

// Download all 5 Synapse files for one sample and stage for nf-core/spatialvi
process DOWNLOAD_AND_STAGE {
  tag "${meta.sample}"
  container "sagebionetworks/synapsepythonclient:v2.6.0"
  secret "SYNAPSE_AUTH_TOKEN"
  publishDir "${params.outdir}/staging", path: { "${task.tag}" }, mode: 'copy'

  input:
  tuple val(meta), val(synapse_ids)

  output:
  tuple val(meta), path("staged"), emit: staged

  script:
  def id1 = synapse_ids[0]
  def id2 = synapse_ids[1]
  def id3 = synapse_ids[2]
  def id4 = synapse_ids[3]
  def id_img = synapse_ids[4]
  def sample = meta.sample
  def slide = meta.slide
  def area = meta.area ?: ''
  def outdirNorm = params.outdir.toString().replaceAll(/\/+$/, '')
  def stagingPrefix = "${outdirNorm}/staging/${sample}"
  def imageCol = params.cytassist ? 'cytaimage' : 'image'
  """
  set -e
  mkdir -p staged/fastqs
  synapse get ${id1} && mv \$(ls -t -p | grep -v / | head -1) staged/fastqs/
  synapse get ${id2} && mv \$(ls -t -p | grep -v / | head -1) staged/fastqs/
  synapse get ${id3} && mv \$(ls -t -p | grep -v / | head -1) staged/fastqs/
  synapse get ${id4} && mv \$(ls -t -p | grep -v / | head -1) staged/fastqs/
  synapse get ${id_img} && mv \$(ls -t -p | grep -v / | head -1) staged/
  shopt -s nullglob
  for f in staged/fastqs/*\\ *; do [ -e "\$f" ] && mv "\$f" "\${f// /_}"; done
  for f in staged/*\\ *; do [ -e "\$f" ] && mv "\$f" "\${f// /_}"; done
  # Pack FASTQs into a tarball with sample name as prefix (spatialvi accepts .tar.gz for fastq_dir)
  tar -czvf staged/${sample}_fastqs.tar.gz -C staged/fastqs .
  rm -rf staged/fastqs
  imgname=\$(ls staged/ | grep -v '\\.tar\\.gz\$' || true | head -1)
  # Absolute paths to published staging dir; header uses cytaimage for Cytassist, image for brightfield
  echo "sample,fastq_dir,${imageCol},slide,area" > staged/samplesheet.csv
  echo "${sample},${stagingPrefix}/${sample}_fastqs.tar.gz,${stagingPrefix}/\${imgname},${slide},${area}" >> staged/samplesheet.csv
  """
}

// Run nf-core/spatialvi on staged data
process RUN_SPATIALVI {
  tag "${meta.sample}"
  container "nextflowio/nextflow:docker"
  cpus 8
  memory 32.GB
  time '7d'

  input:
  tuple val(meta), path(staged)

  output:
  tuple val(meta), path("results"), emit: results

  script:
  def refArg = params.spaceranger_reference ? "--spaceranger_reference ${params.spaceranger_reference}" : ''
  def probesetArg = params.spaceranger_probeset ? "--spaceranger_probeset ${params.spaceranger_probeset}" : ''
  """
  set -e
  cp -r ${staged} ./workdir
  cd workdir
  WORKDIR=\$(pwd)
  awk -v w="\$WORKDIR" -F',' 'NR==1{print;next}{ \$2=w"/"\$2; \$3=w"/"\$3; print }' OFS=',' samplesheet.csv > samplesheet_fullpath.csv && mv samplesheet_fullpath.csv samplesheet.csv
  nextflow run ${params.spatialvi_pipeline} \\
    -r ${params.spatialvi_release} \\
    --input samplesheet.csv \\
    --outdir results \\
    ${refArg} \\
    ${probesetArg} \\
    -profile docker
  cp -r results ../results
  """
}

// Index staged files (tarball, image, samplesheet) to Synapse via SYNINDEX (test run)
process INDEX_STAGING_TO_SYNAPSE {
  tag "${meta.sample}"
  container "nextflowio/nextflow:docker"
  secret "SYNAPSE_AUTH_TOKEN"
  when: params.test_staging_only

  input:
  tuple val(meta), path(staged)

  output:
  tuple val(meta), emit: indexed

  script:
  def outdirNorm = params.outdir.toString().replaceAll(/\/+$/, '')
  def s3_prefix = "${outdirNorm}/staging/${meta.sample}"
  def parent = meta.results_parent_id ?: params.results_parent_id
  """
  nextflow run Sage-Bionetworks-Workflows/nf-synapse \\
    -profile docker \\
    --entry synindex \\
    --s3_prefix "${s3_prefix}" \\
    --parent_id ${parent}
  """
}

// Upload full spatialvi results directory to S3 (for indexing into Synapse via SYNINDEX)
process UPLOAD_RESULTS_TO_S3 {
  tag "${meta.sample}"
  container "amazon/aws-cli:latest"

  input:
  tuple val(meta), path("results")

  output:
  tuple val(meta), path("results"), emit: uploaded

  script:
  def outdirNorm = params.outdir.toString().replaceAll(/\/+$/, '')
  def s3_prefix = "${outdirNorm}/spatialvi_results/${meta.sample}"
  """
  aws s3 cp --recursive results/ "${s3_prefix}/"
  """
}

// Index the uploaded S3 results into Synapse using nf-synapse SYNINDEX (full folder structure, no tarball)
// See https://github.com/Sage-Bionetworks-Workflows/nf-synapse
process INDEX_TO_SYNAPSE {
  tag "${meta.sample}"
  container "nextflowio/nextflow:docker"
  secret "SYNAPSE_AUTH_TOKEN"

  input:
  tuple val(meta), path(results)

  output:
  tuple val(meta), emit: indexed

  script:
  def outdirNorm = params.outdir.toString().replaceAll(/\/+$/, '')
  def s3_prefix = "${outdirNorm}/spatialvi_results/${meta.sample}"
  def parent = meta.results_parent_id ?: params.results_parent_id
  """
  nextflow run Sage-Bionetworks-Workflows/nf-synapse \\
    -profile docker \\
    --entry synindex \\
    --s3_prefix "${s3_prefix}" \\
    --parent_id ${parent}
  """
}

workflow {
  if (!params.input) {
    exit 1, "Please provide --input with path to samplesheet CSV (see README)."
  }
  if (!params.outdir?.toString()?.startsWith('s3://')) {
    exit 1, "Outputs are stored in S3. Please set --outdir to an S3 URI (e.g. s3://your-bucket/prefix)."
  }

  sample_rows = Channel
    .fromPath(params.input, checkIfExists: true)
    .splitCsv(header: true, strip: true)
    .map { row -> parse_row(row) }

  DOWNLOAD_AND_STAGE(sample_rows)

  if (params.test_staging_only) {
    INDEX_STAGING_TO_SYNAPSE(DOWNLOAD_AND_STAGE.out.staged)
  } else {
    RUN_SPATIALVI(DOWNLOAD_AND_STAGE.out.staged)
    UPLOAD_RESULTS_TO_S3(RUN_SPATIALVI.out.results)
    INDEX_TO_SYNAPSE(UPLOAD_RESULTS_TO_S3.out.uploaded)
  }
}

// Parse one CSV row into meta map and list of 5 synapse IDs [f1,f2,f3,f4,image]
def parse_row(row) {
  def meta = [:]
  meta.sample    = row.sample
  meta.slide     = row.slide
  meta.area      = row.area ?: ''
  meta.results_parent_id = row.results_parent_id ?: params.results_parent_id
  def ids = [
    row.synapse_id_fastq_1,
    row.synapse_id_fastq_2,
    row.synapse_id_fastq_3,
    row.synapse_id_fastq_4,
    row.synapse_id_image
  ]
  return tuple(meta, ids)
}
