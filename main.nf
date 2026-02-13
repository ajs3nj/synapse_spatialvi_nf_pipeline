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
  """
  set -e
  mkdir -p staged/fastqs
  synapse get ${id1} && mv \$(ls -t -p | grep -v / | head -1) staged/fastqs/
  synapse get ${id2} && mv \$(ls -t -p | grep -v / | head -1) staged/fastqs/
  synapse get ${id3} && mv \$(ls -t -p | grep -v / | head -1) staged/fastqs/
  synapse get ${id4} && mv \$(ls -t -p | grep -v / | head -1) staged/fastqs/
  synapse get ${id_img} && mv \$(ls -t -p | grep -v / | head -1) staged/image_file
  shopt -s nullglob
  for f in staged/fastqs/*\\ *; do [ -e "\$f" ] && mv "\$f" "\${f// /_}"; done
  # Pack FASTQs into a tarball with sample name as prefix (spatialvi accepts .tar.gz for fastq_dir)
  tar -czvf staged/${sample}_fastqs.tar.gz -C staged/fastqs .
  rm -rf staged/fastqs
  if [ -f staged/image_file ]; then
    ext=\$(echo staged/image_file | sed 's/.*\\.//' 2>/dev/null)
    [ -z "\$ext" ] || [ "\$ext" = image_file ] && ext=img
    mv staged/image_file "staged/image.\$ext"
    imgname="image.\$ext"
  else
    imgname=\$(ls staged/ | grep -v fastqs | grep -v samplesheet | grep -v '*.tar.gz' || true | head -1)
  fi
  # Samplesheet for spatialvi: fastq_dir = sample-prefixed tarball (paths relative to staged dir, which becomes workdir)
  echo "sample,fastq_dir,image,slide,area" > staged/samplesheet.csv
  echo "${sample},${sample}_fastqs.tar.gz,\${imgname},${slide},${area}" >> staged/samplesheet.csv
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
  """
  set -e
  cp -r ${staged} ./workdir
  cd workdir
  nextflow run ${params.spatialvi_pipeline} \\
    -r ${params.spatialvi_release} \\
    --input samplesheet.csv \\
    --outdir results \\
    ${refArg} \\
    -profile ${params.spatialvi_profile}
  cp -r results ../results
  """
}

// Upload the staged FASTQ tarball to Synapse (used in test_staging_only mode)
// Also outputs the spatialvi-formatted samplesheet for use in the full pipeline.
process STORE_STAGED_TARBALL {
  tag "${meta.sample}"
  container "sagebionetworks/synapsepythonclient:v2.6.0"
  secret "SYNAPSE_AUTH_TOKEN"
  publishDir "${params.outdir}/staging_test", pattern: 'samplesheet_spatialvi.csv', mode: 'copy'

  input:
  tuple val(meta), path(staged)

  output:
  tuple val(meta), path("*.tar.gz"), emit: stored
  path "samplesheet_spatialvi.csv", emit: samplesheet

  script:
  def parent = meta.results_parent_id ?: params.results_parent_id
  def sample = meta.sample
  """
  synapse store --parentId ${parent} staged/${sample}_fastqs.tar.gz
  cp staged/${sample}_fastqs.tar.gz ./
  cp staged/samplesheet.csv samplesheet_spatialvi.csv
  """
}

// Pack results and upload to Synapse
process PACK_AND_STORE {
  tag "${meta.sample}"
  container "sagebionetworks/synapsepythonclient:v2.6.0"
  secret "SYNAPSE_AUTH_TOKEN"

  input:
  tuple val(meta), path("results")

  output:
  tuple val(meta), path("*.tar.gz"), emit: stored

  script:
  def parent = meta.results_parent_id ?: params.results_parent_id
  def sample = meta.sample
  """
  tar -czvf ${sample}_spatialvi_results.tar.gz results
  synapse store --parentId ${parent} ${sample}_spatialvi_results.tar.gz
  """
}

workflow {
  if (!params.input) {
    exit 1, "Please provide --input with path to samplesheet CSV (see README)."
  }

  sample_rows = Channel
    .fromPath(params.input, checkIfExists: true)
    .splitCsv(header: true, strip: true)
    .map { row -> parse_row(row) }

  DOWNLOAD_AND_STAGE(sample_rows)

  if (params.test_staging_only) {
    // Small test: stage from Synapse -> tarball -> upload tarball to Synapse (no spatialvi)
    STORE_STAGED_TARBALL(DOWNLOAD_AND_STAGE.out.staged)
  } else {
    RUN_SPATIALVI(DOWNLOAD_AND_STAGE.out.staged)
    PACK_AND_STORE(RUN_SPATIALVI.out.results)
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
