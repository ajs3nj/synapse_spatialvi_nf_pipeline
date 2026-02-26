#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

/*
 * Meta-workflow for Synapse -> spatialvi -> Synapse
 * 
 * This pipeline is designed to be orchestrated via Orca or Tower CLI:
 *   1. nf-synapse SYNSTAGE  : Download files from Synapse to S3
 *   2. This pipeline (make_tarball) : Create FASTQ tarballs + spatialvi samplesheet
 *   3. spatialvi            : Run spatialvi on staged data
 *   4. nf-synapse SYNINDEX  : Index results back to Synapse
 *
 * This file contains the MAKE_TARBALL workflow (step 2).
 */

// ============================================================================
// PROCESSES
// ============================================================================

// Create FASTQ tarball from staged files and generate spatialvi samplesheet row
process MAKE_TARBALL {
  tag "${meta.sample}"
  container "public.ecr.aws/amazonlinux/amazonlinux:2023"
  publishDir "${params.outdir}/tarballs/${meta.sample}", mode: 'copy'
  cpus 2
  memory '4 GB'

  input:
  tuple val(meta), path(fastq1), path(fastq2), path(fastq3), path(fastq4)

  output:
  tuple val(meta), path("${meta.sample}_fastqs.tar.gz"), emit: tarball
  tuple val(meta), path("samplesheet_row.csv"), emit: samplesheet_row

  script:
  def sample = meta.sample
  def slide = meta.slide
  def area = meta.area ?: ''
  def imagePath = meta.image_path
  def outdirNorm = params.outdir.toString().replaceAll(/\/+$/, '')
  def tarballPath = "${outdirNorm}/tarballs/${sample}/${sample}_fastqs.tar.gz"
  """
  set -e
  yum install -y tar gzip

  mkdir -p fastqs

  # Copy FASTQs to staging directory
  cp ${fastq1} fastqs/
  cp ${fastq2} fastqs/
  cp ${fastq3} fastqs/
  cp ${fastq4} fastqs/

  # Replace spaces in FASTQ filenames
  shopt -s nullglob
  for f in fastqs/*\\ *; do [ -e "\$f" ] && mv "\$f" "\${f// /_}"; done

  # Create FASTQ tarball
  tar -czvf ${sample}_fastqs.tar.gz -C fastqs .

  # Write samplesheet row - use original image path from synstage
  echo "${sample},${tarballPath},${imagePath},${slide},${area}" > samplesheet_row.csv
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

// ============================================================================
// WORKFLOWS
// ============================================================================

// Entry: make_tarball - Create tarballs from synstage output and generate spatialvi samplesheet
workflow MAKE_TARBALL_WF {
  if (!params.input) {
    exit 1, "Please provide --input with path to the synstage output samplesheet CSV."
  }
  if (!params.outdir?.toString()?.startsWith('s3://')) {
    exit 1, "Please set --outdir to an S3 URI (e.g. s3://your-bucket/prefix)."
  }

  // Parse the synstage output samplesheet
  // Expected columns: sample,fastq_1,fastq_2,fastq_3,fastq_4,image,slide,area
  // The fastq_* and image columns contain S3 paths (from synstage)
  sample_rows = Channel
    .fromPath(params.input, checkIfExists: true)
    .splitCsv(header: true, strip: true)
    .map { row -> 
      def meta = [
        sample: row.sample,
        slide: row.slide,
        area: row.area ?: '',
        image_path: row.image  // Store image path in meta to pass through
      ]
      tuple(
        meta,
        file(row.fastq_1),
        file(row.fastq_2),
        file(row.fastq_3),
        file(row.fastq_4)
      )
    }

  MAKE_TARBALL(sample_rows)
  
  // Collect all samplesheet rows and create final samplesheet
  all_rows = MAKE_TARBALL.out.samplesheet_row
    .map { meta, row -> row }
    .collect()
  
  CREATE_SPATIALVI_SAMPLESHEET(all_rows)
}

// Default workflow - show usage
workflow {
  log.info """
  =========================================
  spatialvi_nf_pipeline - Orca Orchestration
  =========================================
  
  This pipeline is designed to be orchestrated via Orca (or Tower CLI).
  
  STEP 1: nf-synapse SYNSTAGE
  ---------------------------
  Stages files from Synapse to S3. Run via Orca or Tower.
  Input: synstage_input.csv (with syn:// URIs)
  Output: synstage/synstage_input.csv (with S3 paths)
  
  STEP 2: This pipeline (make_tarball)
  ------------------------------------
  nextflow run . --entry make_tarball \\
    --input s3://bucket/synstage/synstage_input.csv \\
    --outdir s3://bucket/prefix
  
  Output: spatialvi_samplesheet.csv + tarballs
  
  STEP 3: spatialvi
  -----------------
  Run sagebio-ada/spatialvi via Orca or Tower.
  Input: spatialvi_samplesheet.csv from Step 2
  Output: spatialvi results
  
  STEP 4: nf-synapse SYNINDEX
  ---------------------------
  Index results back to Synapse. Run via Orca or Tower.
  Input: s3_prefix of spatialvi results
  Output: Files indexed in Synapse
  
  =========================================
  
  Required parameters for make_tarball:
    --input              : Samplesheet CSV (synstage output with S3 paths)
    --outdir             : S3 URI for outputs
  
  Optional parameters:
    --cytassist          : Use cytaimage column instead of image (default: false)
  
  See README.md for full Orca recipe and orchestration details.
  """
  exit 0
}

// Named workflow entry point
workflow make_tarball {
  MAKE_TARBALL_WF()
}
