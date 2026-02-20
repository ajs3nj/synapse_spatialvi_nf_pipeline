#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

/*
 * Pipeline: Aligns with nf-synapse meta-usage (https://github.com/Sage-Bionetworks-Workflows/nf-synapse):
 *   SYNSTAGE (stage Synapse files to S3) -> make tarball -> run nf-core/spatialvi -> SYNINDEX (index S3 results to Synapse).
 * Samplesheet: CSV with syn:// URIs for 4 FASTQs and 1 image per sample (see README).
 * Compatible with Seqera Tower (use SYNAPSE_AUTH_TOKEN secret).
 */

// Run nf-synapse SYNSTAGE: stage all Synapse files to S3; input CSV must contain syn:// URIs in file columns
// See https://github.com/Sage-Bionetworks-Workflows/nf-synapse
process RUN_SYNSTAGE {
  tag "synstage"
  container "${params.nextflow_container}"
  secret "SYNAPSE_AUTH_TOKEN"

  input:
  path(samplesheet)

  output:
  path("staged_samplesheet.csv"), emit: staged_csv

  script:
  def outdirNorm = params.outdir.toString().replaceAll(/\/+$/, '')
  def input_basename = samplesheet.name
  """
  nextflow run Sage-Bionetworks-Workflows/nf-synapse \\
    -profile docker \\
    -name synstage \\
    --entry synstage \\
    --input ${samplesheet} \\
    --outdir "${outdirNorm}"
  aws s3 cp "${outdirNorm}/synstage/${input_basename}" staged_samplesheet.csv
  """
}

// From SYNSTAGE output CSV (S3 paths per sample): copy the 5 staged files from S3 into the task work dir
// Pack 4 FASTQs into tarball, write spatialvi samplesheet.
// publishDir writes directly to S3 so SYNINDEX can index without a separate upload step.
process MAKE_TARBALL {
  tag "${meta.sample}"
  container "amazon/aws-cli:latest"
  publishDir "${params.outdir}/staging", path: { "${task.tag}" }, mode: 'copy'

  input:
  tuple val(meta), path(staged_csv)

  output:
  tuple val(meta), path("staged"), emit: staged

  script:
  def sample = meta.sample
  def slide = meta.slide
  def area = meta.area ?: ''
  def imageCol = params.cytassist ? 'cytaimage' : 'image'
  def outdirNorm = params.outdir.toString().replaceAll(/\/+$/, '')
  def stagingPrefix = "${outdirNorm}/staging/${sample}"
  """
  set -e
  mkdir -p staged/fastqs
  # Find this sample's row (skip header); assume sample is first column, then fastq_1..fastq_4, image
  line=\$(awk -F',' -v s="${sample}" 'NR>1 && \$1==s {print; exit}' ${staged_csv})
  f1=\$(echo "\$line" | cut -d',' -f2)
  f2=\$(echo "\$line" | cut -d',' -f3)
  f3=\$(echo "\$line" | cut -d',' -f4)
  f4=\$(echo "\$line" | cut -d',' -f5)
  img=\$(echo "\$line" | cut -d',' -f6)
  for u in "\$f1" "\$f2" "\$f3" "\$f4"; do aws s3 cp "\$u" staged/fastqs/; done
  aws s3 cp "\$img" staged/
  tar -czvf staged/${sample}_fastqs.tar.gz -C staged/fastqs .
  rm -rf staged/fastqs
  imgname=\$(basename "\$img")
  echo "sample,fastq_dir,${imageCol},slide,area" > staged/samplesheet.csv
  echo "${sample},${stagingPrefix}/${sample}_fastqs.tar.gz,${stagingPrefix}/\${imgname},${slide},${area}" >> staged/samplesheet.csv
  """
}

// Run nf-core/spatialvi on staged data
// publishDir writes results directly to S3 so SYNINDEX can index without a separate upload step
process RUN_SPATIALVI {
  tag "${meta.sample}"
  container "${params.nextflow_container}"
  cpus 8
  memory 32.GB
  time '7d'
  publishDir "${params.outdir}/spatialvi_results", path: { "${task.tag}" }, mode: 'copy'

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

// Index an S3 prefix into Synapse via nf-synapse SYNINDEX (files are already on S3 via publishDir)
// See https://github.com/Sage-Bionetworks-Workflows/nf-synapse
process INDEX_TO_SYNAPSE {
  tag "${meta.sample}"
  container "${params.nextflow_container}"
  secret "SYNAPSE_AUTH_TOKEN"

  input:
  tuple val(meta), val(s3_suffix)

  output:
  tuple val(meta), emit: indexed

  script:
  def outdirNorm = params.outdir.toString().replaceAll(/\/+$/, '')
  def s3_prefix = "${outdirNorm}/${s3_suffix}/${meta.sample}"
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

  // Samplesheet must contain syn:// URIs in file columns (sample, fastq_1..fastq_4, image, slide, area, results_parent_id)
  samplesheet_ch = Channel.fromPath(params.input, checkIfExists: true)
  sample_metas = Channel.fromPath(params.input, checkIfExists: true)
    .splitCsv(header: true, strip: true)
    .map { row -> meta_from_row(row) }

  // 1. SYNSTAGE: stage Synapse files to S3 (nf-synapse)
  RUN_SYNSTAGE(samplesheet_ch)
  // 2. Make tarball per sample from staged S3 paths
  make_tarball_input = RUN_SYNSTAGE.out.staged_csv.combine(sample_metas).map { csv, meta -> tuple(meta, csv) }
  MAKE_TARBALL(make_tarball_input)

  if (params.test_staging_only) {
    INDEX_TO_SYNAPSE(MAKE_TARBALL.out.staged.map { meta, staged -> tuple(meta, "staging") })
  } else {
    RUN_SPATIALVI(MAKE_TARBALL.out.staged)
    INDEX_TO_SYNAPSE(RUN_SPATIALVI.out.results.map { meta, results -> tuple(meta, "spatialvi_results") })
  }
}

// Extract meta from samplesheet row (samplesheet has syn:// URIs in fastq_1..fastq_4, image)
def meta_from_row(row) {
  def meta = [:]
  meta.sample    = row.sample
  meta.slide     = row.slide
  meta.area      = row.area ?: ''
  meta.results_parent_id = row.results_parent_id ?: params.results_parent_id
  return meta
}
