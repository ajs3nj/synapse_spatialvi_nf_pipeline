#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

/*
 * Pipeline: Aligns with nf-synapse meta-usage (https://github.com/Sage-Bionetworks-Workflows/nf-synapse):
 *   SYNSTAGE (stage Synapse files to S3) -> make tarball -> run nf-core/spatialvi -> SYNINDEX (index S3 results to Synapse).
 * Samplesheet: CSV with Synapse IDs for 4 FASTQs and 1 image per sample.
 * Compatible with Seqera Tower (use SYNAPSE_AUTH_TOKEN secret).
 */

// Build a CSV with syn:// URIs for nf-synapse SYNSTAGE (extracts URIs and stages files to S3)
process PREPARE_SYNSTAGE_INPUT {
  tag "synstage_input"
  publishDir "${params.outdir}", pattern: "synstage_input.csv", mode: 'copy'

  input:
  path(samplesheet)

  output:
  path("synstage_input.csv"), emit: synstage_input

  script:
  """
  awk -F',' 'NR==1{
    print "sample,fastq_1,fastq_2,fastq_3,fastq_4,image,slide,area,results_parent_id"
    next
  }
  {
    gsub(/^[ \\t]+|[ \\t]+$/,"")
    if (NF>=9)
      print \$1",syn://"\$2",syn://"\$3",syn://"\$4",syn://"\$5",syn://"\$6","\$7","\$8","\$9
    else if (NF>=8)
      print \$1",syn://"\$2",syn://"\$3",syn://"\$4",syn://"\$5",syn://"\$6","\$7","\$8","
  }' ${samplesheet} > synstage_input.csv
  """
}

// Run nf-synapse SYNSTAGE: stage all Synapse files to S3; updated CSV with S3 paths is at outdir/synstage/<input_basename>
// See https://github.com/Sage-Bionetworks-Workflows/nf-synapse
process RUN_SYNSTAGE {
  tag "synstage"
  container "nextflowio/nextflow:docker"
  secret "SYNAPSE_AUTH_TOKEN"

  input:
  path(synstage_input)

  output:
  path("staged_samplesheet.csv"), emit: staged_csv

  script:
  def outdirNorm = params.outdir.toString().replaceAll(/\/+$/, '')
  def input_basename = synstage_input.name
  """
  nextflow run Sage-Bionetworks-Workflows/nf-synapse \\
    -profile docker \\
    -name synstage \\
    --entry synstage \\
    --input ${synstage_input} \\
    --outdir "${outdirNorm}"
  aws s3 cp "${outdirNorm}/synstage/${input_basename}" staged_samplesheet.csv
  """
}

// From SYNSTAGE output CSV (S3 paths per sample): copy the 5 staged files from S3 into the task work dir
// (S3 is the only storage; tar needs local paths), pack 4 FASTQs into tarball, write spatialvi samplesheet.
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
  container "nextflowio/nextflow:docker"
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
  container "nextflowio/nextflow:docker"
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

  samplesheet_path = file(params.input, checkIfExists: true)
  sample_rows = Channel
    .fromPath(params.input, checkIfExists: true)
    .splitCsv(header: true, strip: true)
    .map { row -> parse_row(row) }
  sample_metas = sample_rows.map { meta, ids -> meta }

  // 1. SYNSTAGE: stage Synapse files to S3 (nf-synapse)
  PREPARE_SYNSTAGE_INPUT(samplesheet_path)
  RUN_SYNSTAGE(PREPARE_SYNSTAGE_INPUT.out.synstage_input)
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
