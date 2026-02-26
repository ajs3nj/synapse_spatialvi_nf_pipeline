#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

/*
 * Meta-workflow for Synapse -> spatialvi -> Synapse
 * 
 * This pipeline is designed to be run in three separate steps on Tower:
 *   1. --entry stage    : Download from Synapse, create tarball, output spatialvi-ready samplesheet
 *   2. Run spatialvi directly on Tower with the output samplesheet
 *   3. --entry synindex : Index spatialvi results back to Synapse
 *
 * This avoids Docker-in-Docker issues by running spatialvi as a separate Tower pipeline.
 */

// ============================================================================
// PROCESSES
// ============================================================================

// Download all 5 Synapse files for one sample and stage for spatialvi
process DOWNLOAD_AND_STAGE {
  tag "${meta.sample}"
  container "sagebionetworks/synapsepythonclient:v2.6.0"
  secret "SYNAPSE_AUTH_TOKEN"
  publishDir "${params.outdir}/staging/${meta.sample}", mode: 'copy'
  cpus 2
  memory '4 GB'

  input:
  tuple val(meta), val(synapse_ids)

  output:
  tuple val(meta), path("${meta.sample}_fastqs.tar.gz"), path("*.{tif,tiff,jpg,jpeg,png,btf}"), emit: staged
  tuple val(meta), path("samplesheet_row.csv"), emit: samplesheet_row

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
  mkdir -p fastqs

  # Download FASTQs
  synapse get ${id1} && mv \$(ls -t -p | grep -v / | head -1) fastqs/
  synapse get ${id2} && mv \$(ls -t -p | grep -v / | head -1) fastqs/
  synapse get ${id3} && mv \$(ls -t -p | grep -v / | head -1) fastqs/
  synapse get ${id4} && mv \$(ls -t -p | grep -v / | head -1) fastqs/

  # Download image
  synapse get ${id_img}
  imgfile=\$(ls -t -p | grep -v / | head -1)

  # Replace spaces in filenames
  shopt -s nullglob
  for f in fastqs/*\\ *; do [ -e "\$f" ] && mv "\$f" "\${f// /_}"; done
  if [[ "\$imgfile" == *" "* ]]; then
    newimg="\${imgfile// /_}"
    mv "\$imgfile" "\$newimg"
    imgfile="\$newimg"
  fi

  # Create FASTQ tarball
  tar -czvf ${sample}_fastqs.tar.gz -C fastqs .
  rm -rf fastqs

  # Write samplesheet row (S3 paths for spatialvi)
  echo "${sample},${stagingPrefix}/${sample}_fastqs.tar.gz,${stagingPrefix}/\${imgfile},${slide},${area}" > samplesheet_row.csv
  """
}

// Collect all samplesheet rows and create final samplesheet
process CREATE_SPATIALVI_SAMPLESHEET {
  container "ubuntu:22.04"
  publishDir "${params.outdir}", mode: 'copy'
  cpus 1
  memory '1 GB'

  input:
  path(rows)

  output:
  path("spatialvi_samplesheet.csv"), emit: samplesheet

  script:
  def imageCol = params.cytassist ? 'cytaimage' : 'image'
  """
  echo "sample,fastq_dir,${imageCol},slide,area" > spatialvi_samplesheet.csv
  cat ${rows} >> spatialvi_samplesheet.csv
  """
}

// Index results from S3 to Synapse using synapse store
process SYNINDEX_RESULTS {
  tag "${sample}"
  container "sagebionetworks/synapsepythonclient:v2.6.0"
  secret "SYNAPSE_AUTH_TOKEN"
  cpus 2
  memory '4 GB'

  input:
  tuple val(sample), val(parent_id), path(results_dir)

  output:
  val(sample), emit: indexed

  script:
  """
  # Upload entire results directory to Synapse
  synapse store --parentId ${parent_id} ${results_dir}
  """
}

// Fetch results from S3 for indexing
process FETCH_RESULTS_FROM_S3 {
  tag "${sample}"
  container "public.ecr.aws/amazonlinux/amazonlinux:2023"
  cpus 2
  memory '8 GB'

  input:
  tuple val(sample), val(parent_id)

  output:
  tuple val(sample), val(parent_id), path("results"), emit: results

  script:
  def outdirNorm = params.outdir.toString().replaceAll(/\/+$/, '')
  def s3_prefix = "${outdirNorm}/spatialvi_results/${sample}"
  """
  yum install -y aws-cli
  mkdir -p results
  aws s3 cp --recursive "${s3_prefix}/" results/
  """
}

// ============================================================================
// WORKFLOWS
// ============================================================================

// Entry: stage - Download from Synapse and prepare for spatialvi
workflow STAGE {
  if (!params.input) {
    exit 1, "Please provide --input with path to samplesheet CSV."
  }
  if (!params.outdir?.toString()?.startsWith('s3://')) {
    exit 1, "Please set --outdir to an S3 URI (e.g. s3://your-bucket/prefix)."
  }

  sample_rows = Channel
    .fromPath(params.input, checkIfExists: true)
    .splitCsv(header: true, strip: true)
    .map { row -> 
      def meta = [
        sample: row.sample,
        slide: row.slide,
        area: row.area ?: '',
        results_parent_id: row.results_parent_id ?: params.results_parent_id
      ]
      def ids = [
        row.synapse_id_fastq_1,
        row.synapse_id_fastq_2,
        row.synapse_id_fastq_3,
        row.synapse_id_fastq_4,
        row.synapse_id_image
      ]
      tuple(meta, ids)
    }

  DOWNLOAD_AND_STAGE(sample_rows)
  
  // Collect all samplesheet rows and create final samplesheet
  all_rows = DOWNLOAD_AND_STAGE.out.samplesheet_row
    .map { meta, row -> row }
    .collect()
  
  CREATE_SPATIALVI_SAMPLESHEET(all_rows)
}

// Entry: synindex - Index spatialvi results back to Synapse
workflow SYNINDEX {
  if (!params.input) {
    exit 1, "Please provide --input with path to samplesheet CSV (same as used for staging)."
  }
  if (!params.outdir?.toString()?.startsWith('s3://')) {
    exit 1, "Please set --outdir to an S3 URI (same as used for spatialvi run)."
  }

  // Read samplesheet to get sample names and parent IDs
  sample_info = Channel
    .fromPath(params.input, checkIfExists: true)
    .splitCsv(header: true, strip: true)
    .map { row -> 
      def sample = row.sample
      def parent_id = row.results_parent_id ?: params.results_parent_id
      tuple(sample, parent_id)
    }

  FETCH_RESULTS_FROM_S3(sample_info)
  SYNINDEX_RESULTS(FETCH_RESULTS_FROM_S3.out.results)
}

// Default workflow - show usage
workflow {
  log.info """
  =========================================
  spatialvi_nf_pipeline - Meta Workflow
  =========================================
  
  This pipeline is designed to be run in three steps:
  
  STEP 1: Stage files from Synapse
  --------------------------------
  nextflow run . --entry stage \\
    --input samplesheet.csv \\
    --outdir s3://bucket/prefix \\
    --results_parent_id syn123456
  
  Output: spatialvi_samplesheet.csv in your outdir
  
  STEP 2: Run spatialvi on Tower
  ------------------------------
  Run sagebio-ada/spatialvi (or nf-core/spatialvi) directly on Tower:
  - Input: the spatialvi_samplesheet.csv from Step 1
  - Outdir: s3://bucket/prefix/spatialvi_results
  
  STEP 3: Index results to Synapse
  --------------------------------
  nextflow run . --entry synindex \\
    --input samplesheet.csv \\
    --outdir s3://bucket/prefix \\
    --results_parent_id syn123456
  
  =========================================
  
  Required parameters:
    --input              : Samplesheet CSV with Synapse IDs
    --outdir             : S3 URI for outputs
    --results_parent_id  : Synapse folder ID for results
  
  Optional parameters:
    --cytassist          : Use cytaimage column instead of image (default: false)
  
  """
  exit 0
}
