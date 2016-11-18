#!/usr/bin/env nextflow
/*
vim: syntax=groovy
-*- mode: groovy;-*-
========================================================================================
             B S - S E Q   M E T H Y L A T I O N  :  B W A - M E T H
========================================================================================
 Methylation (BS-Seq) Analysis Pipeline using bwa-meth. Started November 2016.
 #### Homepage / Documentation
 https://github.com/SciLifeLab/NGI-MethylSeq
 #### Authors
 Phil Ewels <phil.ewels@scilifelab.se>
----------------------------------------------------------------------------------------
*/


/*
 * SET UP CONFIGURATION VARIABLES
 */

// Pipeline version
version = 0.1

// Configurable variables
params.genome = false
params.fasta = params.genome ? params.genomes[ params.genome ].fasta ?: false : false
params.fasta_index = params.genome ? params.genomes[ params.genome ].fasta_index ?: false : false
params.bwa_meth_index = params.genome ? params.genomes[ params.genome ].bwa_meth ?: false : false
params.saveReference = true
params.reads = "data/*_{1,2}.fastq.gz"
params.outdir = './results'
params.nodedup = false
params.allcontexts = false
params.mindepth = 0
params.ignoreFlags = false

// Validate inputs
if( params.bwa_meth_index ){
    bwa_meth_index = file("${params.bwa_meth_index}.bwameth.c2t.bwt")
    bwa_meth_indices = Channel.fromPath( "${params.bwa_meth_index}*" ).toList()
    if( !hisat2_index.exists() ) exit 1, "bwa-meth index not found: ${params.bwa_meth_index}"
}
if( params.fasta_index ){
    fasta_index = file(params.fasta_index)
    if( !fasta.exists() ) exit 1, "Fasta file not found: ${params.fasta_index}"
}
if ( params.fasta ){
    fasta = file(params.fasta)
    if( !fasta.exists() ) exit 1, "Fasta file not found: ${params.fasta}"
} else {
    exit 1, "No reference Fasta file specified! Please use --fasta"
}

params.pbat = false
params.single_cell = false
params.epignome = false
params.accel = false
params.cegx = false
if(params.pbat){
    params.clip_r1 = 6
    params.clip_r2 = 6
    params.three_prime_clip_r1 = 0
    params.three_prime_clip_r2 = 0
} else if(params.single_cell){
    params.clip_r1 = 9
    params.clip_r2 = 9
    params.three_prime_clip_r1 = 0
    params.three_prime_clip_r2 = 0
} else if(params.epignome){
    params.clip_r1 = 6
    params.clip_r2 = 6
    params.three_prime_clip_r1 = 6
    params.three_prime_clip_r2 = 6
} else if(params.accel){
    params.clip_r1 = 10
    params.clip_r2 = 15
    params.three_prime_clip_r1 = 10
    params.three_prime_clip_r2 = 10
} else if(params.cegx){
    params.clip_r1 = 6
    params.clip_r2 = 6
    params.three_prime_clip_r1 = 2
    params.three_prime_clip_r2 = 2
} else {
    params.clip_r1 = 0
    params.clip_r2 = 0
    params.three_prime_clip_r1 = 0
    params.three_prime_clip_r2 = 0
}

def single

log.info "===================================="
log.info " NGI-MethylSeq : Bisulfite-Seq Best Practice v${version}"
log.info "===================================="
log.info "Reads          : ${params.reads}"
log.info "Genome         : ${params.genome}"
log.info "Bismark Index  : ${params.bismark_index}"
log.info "Current home   : $HOME"
log.info "Current user   : $USER"
log.info "Current path   : $PWD"
log.info "Script dir     : $baseDir"
log.info "Working dir    : $workDir"
log.info "Output dir     : ${params.outdir}"
log.info "===================================="
log.info "Deduplication  : ${params.nodedup ? 'No' : 'Yes'}"
if(params.rrbs){        log.info "RRBS Mode      : On" }
if(params.pbat){        log.info "Trim Profile   : PBAT" }
if(params.single_cell){ log.info "Trim Profile   : Single Cell" }
if(params.epignome){    log.info "Trim Profile   : Epignome" }
if(params.accel){       log.info "Trim Profile   : Accel" }
if(params.cegx){        log.info "Trim Profile   : CEGX" }
log.info "Output dir     : ${params.outdir}"
log.info "Trim R1        : ${params.clip_r1}"
log.info "Trim R2        : ${params.clip_r2}"
log.info "Trim 3' R1     : ${params.three_prime_clip_r1}"
log.info "Trim 3' R2     : ${params.three_prime_clip_r2}"
log.info "Config Profile : ${workflow.profile}"
log.info "===================================="

// Validate inputs
if( workflow.profile == 'standard' && !params.project ) exit 1, "No UPPMAX project ID found! Use --project"

/*
 * Create a channel for input read files
 */
Channel
    .fromFilePairs( params.reads, size: -1 )
    .ifEmpty { error "Cannot find any reads matching: ${params.reads}" }
    .into { read_files_fastqc; read_files_trimming }



/*
 * PREPROCESSING - Build bwa-mem index
 */
if(!params.bwa_meth_index){
    process makeBwaMemIndex {
        tag fasta
        publishDir path: "${params.outdir}/reference_genome", saveAs: { params.saveReference ? it : null }, mode: 'copy'

        input:
        file fasta from fasta

        output:
        file "${fasta}.bwameth.c2t.bwt" into bwa_meth_index
        file "${fasta}*" into bwa_meth_indices
        
        script:
        """
        bwameth.py index $fasta
        """
    }
}

/*
 * PREPROCESSING - Index Fasta file
 */
if(!params.fasta_index){
    process makeFastaIndex {
        tag fasta
        publishDir path: "${params.outdir}/reference_genome", saveAs: { params.saveReference ? it : null }, mode: 'copy'

        input:
        file fasta

        output:
        file "${fasta}.fai" into fasta_index
        
        script:
        """
        samtools faidx $fasta
        """
    }
}



/*
 * STEP 1 - FastQC
 */
process fastqc {
    tag "$name"
    publishDir "${params.outdir}/fastqc", mode: 'copy'
    
    input:
    set val(name), file(reads) from read_files_fastqc
    
    output:
    file '*_fastqc.{zip,html}' into fastqc_results
    
    script:
    """
    fastqc -q $reads
    """
}

/*
 * STEP 2 - Trim Galore!
 */
process trim_galore {
    tag "$name"
    publishDir "${params.outdir}/trim_galore", mode: 'copy'
    
    input:
    set val(name), file(reads) from read_files_trimming
    
    output:
    file '*fq.gz' into trimmed_reads
    file '*trimming_report.txt' into trimgalore_results
    
    script:
    single = reads instanceof Path
    c_r1 = params.clip_r1 > 0 ? "--clip_r1 ${params.clip_r1}" : ''
    c_r2 = params.clip_r2 > 0 ? "--clip_r2 ${params.clip_r2}" : ''
    tpc_r1 = params.three_prime_clip_r1 > 0 ? "--three_prime_clip_r1 ${params.three_prime_clip_r1}" : ''
    tpc_r2 = params.three_prime_clip_r2 > 0 ? "--three_prime_clip_r2 ${params.three_prime_clip_r2}" : ''
    rrbs = params.rrbs ? "--rrbs" : ''
    if (single) {
        """
        trim_galore --gzip $rrbs $c_r1 $tpc_r1 $reads
        """
    } else {
        """
        trim_galore --paired --gzip $rrbs $c_r1 $c_r2 $tpc_r1 $tpc_r2 $reads
        """
    }
}

/*
 * STEP 3 - align with bwa-mem
 */
process bwamem_align {
    tag "$trimmed_reads"
    publishDir "${params.outdir}/bwa-mem/alignments", mode: 'copy'
    
    input:
    file reads from trimmed_reads
    file index from bwa_meth_index
    file bwa_meth_indices
    
    output:
    file '*.bam' into bam_aligned
    
    script:
    prefix = reads[0].toString() - ~/(_R1)?(_trimmed)?(_val_1)?(\.fq)?(\.fastq)?(\.gz)?$/
    """
    bwameth.py \\
        --threads ${task.cpus} \\
        --reference $index \\
        $reads | samtools view -b - > ${prefix}.bam
    """
}

/*
 * STEP 4 - sort and index alignments
 */
process samtools_postalignment {
    tag "${bam.baseName}"
    publishDir "${params.outdir}/bwa-mem/sorted", mode: 'copy'
    
    input:
    file bam from bam_aligned
    
    output:
    file '${bam.baseName}_flagstat.txt' into flagstat_results
    file '${bam.BaseName}.sorted.bam' into bam_sorted
    file '${bam.BaseName}.sorted.bam.bai' into bam_index
    
    script:
    """
    samtools flagstat $bam > ${bam.baseName}_flagstat.txt
    
    samtools sort \\
        -@ ${task.cpus} \\
        -m ${task.memory.toGigs()}G \\
        -o ${bam.BaseName}.sorted.bam \\
        $bam
    
    samtools index ${bam.BaseName}.sorted.bam
    """
}


/*
 * STEP 5 - Mark duplicates
 */
process markDuplicates {
    tag "${bam.baseName}"
    publishDir "${params.outdir}/bwa-mem/markDuplicates", mode: 'copy'

    input:
    file bam from bam_sorted

    output:
    file "${bam.baseName}.markDups.bam" into bam_md
    file "${bam.baseName}.markDups_metrics.txt" into picard_results

    script:
    """
    java -Xmx2g -jar \$PICARD_HOME/picard.jar MarkDuplicates \\
        INPUT=$bam \\
        OUTPUT=${bam.baseName}.markDups.bam \\
        METRICS_FILE=${bam.baseName}.markDups_metrics.txt \\
        REMOVE_DUPLICATES=false \\
        ASSUME_SORTED=true \\
        PROGRAM_RECORD_ID='null' \\
        VALIDATION_STRINGENCY=LENIENT

    # Print version number to standard out
    echo "File name: $bam Picard version "\$(java -Xmx2g -jar \$PICARD_HOME/picard.jar  MarkDuplicates --version 2>&1)
    """
}


/*
 * STEP 6 - extract methylation with PileOMeth
 */
process pileOMeth {
    tag "${bam.baseName}"
    publishDir "${params.outdir}/PileOMeth", mode: 'copy'
    
    input:
    file bam from bam_sorted
    file fasta
    file fasta_index
    
    output:
    file '*' into pileometh_results
    
    script:
    allcontexts = params.allcontexts ? '--CHG --CHH' : ''
    mindepth = params.mindepth > 0 ? "--minDepth ${params.mindepth}" : ''
    ignoreFlags = params.ignoreFlags ? "--ignoreFlags" : ''
    """
    PileOMeth extract $allcontexts $ignoreFlags $mindepth $fasta $bam
    PileOMeth mbias $allcontexts $ignoreFlags $fasta $bam ${bam.baseName}
    """
}


/*
 * STEP 7 - MultiQC
 */
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'
    
    input:
    file ('fastqc/*') from fastqc_results.flatten().toList()
    file ('trimgalore/*') from trimgalore_results.flatten().toList()
    file ('samtools/*') from flagstat_results.flatten().toList()
    file ('picard/*') from picard_results.flatten().toList()
    file ('pileometh/*') from pileometh_results.flatten().toList()
    
    output:
    file '*multiqc_report.html'
    file '*multiqc_data'
    
    script:
    """
    multiqc -f .
    """
}
