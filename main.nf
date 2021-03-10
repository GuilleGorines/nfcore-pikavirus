#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/pikavirus
========================================================================================
 nf-core/pikavirus Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/pikavirus
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/pikavirus --input samplesheet.csv -profile docker

    Mandatory arguments:
      --input [file]                  Path to input data (must be surrounded with quotes)
      -profile [str]                  Configuration profile to use. Can use multiple (comma separated)
                                      Available: conda, docker, singularity, test, test_single_end, awsbatch

    Performance arguments:
      --max_memory [int].GB           Maximum quantity of memory to be used in the whole pipeline
      --max_cpus [int]                Maximum number of cpus to be used in the whole pipeline
      --max_time [int].h              Maximum time for the pipeline to finish

    Options:
      --trimming [bool]               Perform initial trimming of lower-quality sections (Default: true)
      --kraken2_db [path]             Kraken database for taxa identification (Default: hosted on Zenodo)
      --kraken2krona [bool]           Generate a Krona chart from results obtained from kraken (Default: false)
      --kaiju_db [path]               Kaiju database for contig identification (Default: @TODO )
      --virus [bool]                  Search for virus (Default: true)
      --bacteria [bool]               Search for bacteria (Default: true)
      --fungi [bool]                  Search for fungi (Default: true)
      --skip_assembly [bool]          Skip the assembly steps (Default: false)
      --cleanup [bool]                Remove intermediate files after pipeline completion (Default: false)
      --outdir [file]                 The output directory where the results will be saved (Default: './results')
      --publish_dir_mode [str]        Mode for publishing results in the output directory. Available: symlink, rellink, link, copy, copyNoFollow, move (Default: 'copy')
      --email [email]                 Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits (Default: false)
      --email_on_fail [email]         Same as --email, except only send mail if the workflow is not successful (Default: false)
      --max_multiqc_email_size [str]  Threshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name [str]                     Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic
      --version                       Show pipeline version

    References                        If not specified in the configuration file or you wish to overwrite any of the references

    AWSBatch options:
      --awsqueue [str]                The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion [str]               The AWS Region for your AWS Batch job to run on
      --awscli [str]                  Path to the AWS CLI tool
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()test
    exit 0
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Has the run name been specified by the user?
// this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

// Check AWS batch settings
if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

/*
 * Create a channel for input read files
 */

if (params.input) { ch_input = file(params.input, checkIfExists: true) } else { exit 1, "Samplesheet file (-input) not specified!" }

// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Input']            = params.input
summary['Trimming']       = params.outdir
summary['Virus Search']     = params.virus
summary['Bacteria Search']  = params.bacteria
summary['Fungi Search']     = params.fungi
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if (workflow.profile.contains('awsbatch')) {
    summary['AWS Region']   = params.awsregion
    summary['AWS Queue']    = params.awsqueue
    summary['AWS CLI']      = params.awscli
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Profile Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Profile Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config Profile URL']         = params.config_profile_url

summary['Config Files'] = workflow.configFiles.join(', ')
if (params.email || params.email_on_fail) {
    summary['E-mail Address']    = params.email
    summary['E-mail on failure'] = params.email_on_fail
    summary['MultiQC maxsize']   = params.max_multiqc_email_size
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

Channel.from(summary.collect{ [it.key, it.value] })
    .map { k,v -> "<dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }
    .reduce { a, b -> return [a, b].join("\n            ") }
    .map { x -> """
    id: 'nf-core-pikavirus-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/pikavirus Workflow Summary'
    section_href: 'https://github.com/nf-core/pikavirus'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
            $x
        </dl>
    """.stripIndent() }
    .set { ch_workflow_summary }

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.indexOf(".csv") > 0) filename
                      else null
                }

    output:
    file 'software_versions_mqc.yaml' into ch_software_versions_yaml
    file "software_versions.csv"

    script:
    // TODO nf-core: Get all tools to print their version number here
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    kraken2 --version > v_kraken2.txt
    fastp -v > v_fastp.txt
    kaiju -help 2>&1 v_kaiju.txt &
    bowtie2 --version > v_bowtie2.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}
/*
 * PREPROCESSING: Reformat samplesheet and check validity
 */
process CHECK_SAMPLESHEET {
    tag "$samplesheet"
    publishDir "${params.outdir}/", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.endsWith(".tsv")) "preprocess/sra/$filename"
                      else "pipeline_info/$filename"
                }

    input:
    path samplesheet from ch_input

    output:
    path "samplesheet.valid.csv" into ch_samplesheet_reformat
    path "sra_run_info.tsv" optional true

    script:  // These scripts are bundled with the pipeline, in nf-core/viralrecon/bin/
    run_sra = !params.skip_sra && !isOffline()
    """
    awk -F, '{if(\$1 != "" && \$2 != "") {print \$0}}' $samplesheet > nonsra_id.csv
    check_samplesheet.py nonsra_id.csv nonsra.samplesheet.csv
    awk -F, '{if(\$1 != "" && \$2 == "" && \$3 == "") {print \$1}}' $samplesheet > sra_id.list
    if $run_sra && [ -s sra_id.list ]
    then
        fetch_sra_runinfo.py sra_id.list sra_run_info.tsv --platform ILLUMINA --library_layout SINGLE,PAIRED
        sra_runinfo_to_samplesheet.py sra_run_info.tsv sra.samplesheet.csv
    fi
    if [ -f nonsra.samplesheet.csv ]
    then
        head -n 1 nonsra.samplesheet.csv > samplesheet.valid.csv
    else
        head -n 1 sra.samplesheet.csv > samplesheet.valid.csv
    fi
    tail -n +2 -q *sra.samplesheet.csv >> samplesheet.valid.csv
    """
}

// Function to get list of [ sample, single_end?, is_sra?, is_ftp?, [ fastq_1, fastq_2 ], [ md5_1, md5_2] ]
def validate_input(LinkedHashMap sample) {
    def sample_id = sample.sample_id
    def single_end = sample.single_end.toBoolean()
    def is_sra = sample.is_sra.toBoolean()
    def is_ftp = sample.is_ftp.toBoolean()
    def fastq_1 = sample.fastq_1
    def fastq_2 = sample.fastq_2
    def md5_1 = sample.md5_1
    def md5_2 = sample.md5_2

    def array = []
    if (!is_sra) {
        if (single_end) {
            array = [ sample_id, single_end, is_sra, is_ftp, [ file(fastq_1, checkIfExists: true) ] ]
        } else {
            array = [ sample_id, single_end, is_sra, is_ftp, [ file(fastq_1, checkIfExists: true), file(fastq_2, checkIfExists: true) ] ]
        }
    } else {
        array = [ sample_id, single_end, is_sra, is_ftp, [ fastq_1, fastq_2 ], [ md5_1, md5_2 ] ]
    }

    return array
}

/*
 * Create channels for input fastq files
 */
ch_samplesheet_reformat
    .splitCsv(header:true, sep:',')
    .map { validate_input(it) }
    .into { ch_reads_all
            ch_reads_sra }



/*
 * Download and check SRA data
 */
if (!params.skip_sra || !isOffline()) {
    ch_reads_sra
        .filter { it[2] }
        .into { ch_reads_sra_ftp
                ch_reads_sra_dump }

    process SRA_FASTQ_FTP {
        tag "$sample"
        label 'process_medium'
        label 'error_retry'
        publishDir "${params.outdir}/preprocess/sra", mode: params.publish_dir_mode,
            saveAs: { filename ->
                          if (filename.endsWith(".md5")) "md5/$filename"
                          else params.save_sra_fastq ? filename : null
                    }

        when:
        is_ftp

        input:
        tuple val(sample), val(single_end), val(is_sra), val(is_ftp), val(fastq), val(md5) from ch_reads_sra_ftp

        output:
        tuple val(sample), val(single_end), val(is_sra), val(is_ftp), path("*.fastq.gz") into ch_sra_fastq_ftp
        path "*.md5"

        script:
        if (single_end) {
            """
            curl -L ${fastq[0]} -o ${sample}.fastq.gz
            echo "${md5[0]}  ${sample}.fastq.gz" > ${sample}.fastq.gz.md5
            md5sum -c ${sample}.fastq.gz.md5
            """
        } else {
            """
            curl -L ${fastq[0]} -o ${sample}_1.fastq.gz
            echo "${md5[0]}  ${sample}_1.fastq.gz" > ${sample}_1.fastq.gz.md5
            md5sum -c ${sample}_1.fastq.gz.md5
            curl -L ${fastq[1]} -o ${sample}_2.fastq.gz
            echo "${md5[1]}  ${sample}_2.fastq.gz" > ${sample}_2.fastq.gz.md5
            md5sum -c ${sample}_2.fastq.gz.md5
            """
        }
    }

    process SRA_FASTQ_DUMP {
        tag "$sample"
        label 'process_medium'
        label 'error_retry'
        publishDir "${params.outdir}/preprocess/sra", mode: params.publish_dir_mode,
            saveAs: { filename ->
                          if (filename.endsWith(".log")) "log/$filename"
                          else params.save_sra_fastq ? filename : null
                    }

        when:
        !is_ftp

        input:
        tuple val(sample), val(single_end), val(is_sra), val(is_ftp) from ch_reads_sra_dump.map { it[0..3] }

        output:
        tuple val(sample), val(single_end), val(is_sra), val(is_ftp), path("*.fastq.gz") into ch_sra_fastq_dump
        path "*.log"

        script:
        prefix = "${sample.split('_')[0..-2].join('_')}"
        pe = single_end ? "" : "--readids --split-e"
        rm_orphan = single_end ? "" : "[ -f  ${prefix}.fastq.gz ] && rm ${prefix}.fastq.gz"
        """
        parallel-fastq-dump \\
            --sra-id $prefix \\
            --threads $task.cpus \\
            --outdir ./ \\
            --tmpdir ./ \\
            --gzip \\
            $pe \\
            > ${prefix}.fastq_dump.log
        $rm_orphan
        """
    }

    ch_reads_all
        .filter { !it[2] }
        .concat(ch_sra_fastq_ftp, ch_sra_fastq_dump)
        .set { ch_reads_all }
}

ch_reads_all
    .map { [ it[0].split('_')[0..-2].join('_'), it[1], it[4] ] }
    .groupTuple(by: [0, 1])
    .map { [ it[0], it[1], it[2].flatten() ] }
    .set { ch_reads_all }


/*
 * Merge FastQ files with the same sample identifier (resequenced samples)
 */
process CAT_FASTQ {
    tag "$sample"

    input:
    tuple val(sample), val(single_end), path(reads) from ch_reads_all

    output:
    tuple val(sample), val(single_end), path("*.merged.fastq.gz") into ch_cat_fastqc,
                                                                       ch_cat_fastp

    script:
    readList = reads.collect{it.toString()}
    if (!single_end) {
        if (readList.size > 2) {
            def read1 = []
            def read2 = []
            readList.eachWithIndex{ v, ix -> ( ix & 1 ? read2 : read1 ) << v }
            """
            cat ${read1.sort().join(' ')} > ${sample}_1.merged.fastq.gz
            cat ${read2.sort().join(' ')} > ${sample}_2.merged.fastq.gz
            """
        } else {
            """
            ln -s ${reads[0]} ${sample}_1.merged.fastq.gz
            ln -s ${reads[1]} ${sample}_2.merged.fastq.gz
            """
        }
    } else {
        if (readList.size > 1) {
            """
            cat ${readList.sort().join(' ')} > ${sample}.merged.fastq.gz
            """
        } else {
            """
            ln -s $reads ${sample}.merged.fastq.gz
            """
        }
    }
}
/*
 * PREPROCESSING: KRAKEN2 DATABASE
 */
if (params.kraken2_db.contains('.gz') || params.kraken2_db.contains('.tar')){

    process UNCOMPRESS_KRAKEN2DB {
        label 'error_retry'

        input:
        path(database) from params.kraken2_db

        output:
        path("kraken2db") into kraken2_db_files

        script:
        dbname = "kraken2db"
        """
        mkdir $dbname
        tar -xvf $database --strip-components 1 -C $dbname
        """
    }
} else {
    kraken2_db_files = params.kraken2_db
}

/*
 * PREPROCESSING: KAIJU DATABASE
 */
if (params.kaiju_db.endsWith('.gz') || params.kaiju_db.endsWith('.tar')){

    process UNCOMPRESS_KAIJUDB {
        label 'error_retry'

        input:
        path(database) from params.kaiju_db

        output:
        tuple path("$kaijudb/*.fmi"), path("$kaijudb/nodes.dmp"), path("$kaijudb/names.dmp") into kaiju_db_files

        script:
        kaijudb = database.toString() - ".tar.gz"
        """
        tar -xf $database $kaijudb
        """
    }
} else {
    kaiju_db_files = params.kaiju_db
}

/*
 * STEP 1.1 - FastQC
 */
process RAW_SAMPLES_FASTQC {
    tag "$samplename"
    label "process_medium"
    publishDir "${params.outdir}/raw_fastqc", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"
                }

    input:
    set val(samplename), val(single_end), path(reads) from ch_cat_fastqc

    output:
    file "*_fastqc.{zip,html}" into fastqc_results

    script:

    """
    fastqc --quiet --threads $task.cpus *.fastq.gz
    """
}

/*
 * STEP 1.2 - TRIMMING
 */
if (params.trimming) {
    process FASTP {
        tag "$samplename"
        label "process_medium"
        publishDir "${params.outdir}/trimmed", mode: params.publish_dir_mode,
        saveAs: { filename ->
                        filename.indexOf(".fastq") > 0 ? "trimmed/$filename" : "$filename"
                    }

        input:
        tuple val(samplename), val(single_end), path(reads) from ch_cat_fastp

        output:
        tuple val(samplename), val(single_end), path("*fastq.gz") into trimmed_paired_kraken2, trimmed_paired_fastqc, trimmed_paired_extract_virus, trimmed_paired_extract_bacteria, trimmed_paired_extract_fungi
        tuple val(samplename), val(single_end), path("*fail.fastq.gz") into trimmed_unpaired

        script:
        detect_adapter =  single_end ? "" : "--detect_adapter_for_pe"
        reads1 = single_end ? "--in1 ${reads} --out1 ${samplename}_trim.fastq.gz --failed_out ${samplename}.fail.fastq.gz" : "--in1 ${reads[0]} --out1 ${samplename}_1.fastq.gz --unpaired1 ${samplename}_1_fail.fastq.gz"
        reads2 = single_end ? "" : "--in2 ${reads[1]} --out2 ${samplename}_2.fastq.gz --unpaired2 ${samplename}_2_fail.fastq.gz"
        
        """
        fastp \\
        $detect_adapter \\
        --cut_front \\
        --cut_tail \\
        --thread $task.cpus \\
        $reads1 \\
        $reads2
        """
    }

    /*
    * STEP 1.3 - FastQC on trimmed reads
    */
    process TRIMMED_SAMPLES_FASTQC {
        tag "$samplename"
        label "process_medium"
        publishDir "${params.outdir}/trimmed_fastqc", mode: params.publish_dir_mode

        input:
        tuple val(samplename), val(single_end), path(reads) from trimmed_paired_fastqc

        output:
        file "*_fastqc.{zip,html}" into trimmed_fastqc_results_html

        script:
        
        """
        fastqc --quiet --threads $task.cpus $reads
        """
    }
}

/*
 * STEP 2.1.1 - Scout with Kraken2
 */
process SCOUT_KRAKEN2 {
    tag "$samplename"
    label "process_high"

    input:
    path(kraken2db) from kraken2_db_files
    tuple val(samplename), val(single_end), path(reads) from trimmed_paired_kraken2

    output:
    tuple val(samplename), path("*.report") into kraken2_report_virus_references, kraken2_report_bacteria_references, kraken2_report_fungi_references,
                                                 kraken2_reports_krona
                        
    tuple val(samplename), path("*.report"), path("*.kraken") into kraken2_virus_extraction, kraken2_bacteria_extraction, kraken2_fungi_extraction
    tuple val(samplename), val(single_end), file("*_unclassified.fastq") into unclassified_reads

    script:
    paired_end = single_end ? "" : "--paired"
    unclass_name = single_end ? "${samplename}_unclassified.fastq" : "${samplename}_#_unclassified.fastq"
    """
    kraken2 --db $kraken2db \\
    ${paired_end} \\
    --threads $task.cpus \\
    --report ${samplename}.report \\
    --output ${samplename}.kraken \\
    --unclassified-out ${unclass_name} \\
    ${reads}
    """
}

/*
 * STEP 2.1.2 - Krona output for Kraken scouting
 */
if (params.kraken2krona) {

    process KRONA_KRAKEN_RESULTS {
        tag "$samplename"
        label "process_medium"
        publishDir "${resultsDir}/kraken2_results", mode: params.publish_dir_mode,
        saveAs: {}

        input:
        tuple val(samplename), path(report) from kraken2_reports_krona

        output:
        file("*.krona.html") into krona_taxonomy

        script:

        """
        kreport2krona.py \\
        --report-file $report \\
        --output ${samplename}.krona

        ktImportText \\
        -o ${samplename}.krona.html \\
        ${samplename}.krona
        """
    }
}

if (params.virus) {

    process EXTRACT_KRAKEN2_VIRUS {
        tag "$samplename"
        label "process_medium"
        
        input:
        tuple val(samplename), val(single_end), path(reads) from trimmed_paired_extract_virus
        tuple val(samplename), path(report), path(output) from kraken2_virus_extraction

        output:
        tuple val(samplename), val(single_end), path("*_virus.fastq") into virus_reads_mapping

        script:
        read = single_end ? "-s ${reads}" : "-s1 ${reads[0]} -s2 ${reads[1]}" 
        filename = "${samplename}_virus.fastq"
        """
        extract_kraken_reads.py \\
        --kraken-file $output \\
        --report-file $report \\
        --taxid 10239 \\
        $read \\
        --output $filename
        """
    }

    process GET_ASSEMBLIES_VIRUS {
        label "process_medium"

        input:
        tuple val(samplename),path(kraken2_report) from kraken2_report_virus_references
        
        output:
        path("*_virus.tsv") into assemblies_data_virus
        tuple val(samplename), path("*.fna") into virus_ref_assemblies
        
        script:
        
        """       
        curl 'ftp://ftp.ncbi.nlm.nih.gov/genomes/refseq/virus/assembly_summary.txt' > assembly_summary_virus.txt
        extract_reference_assemblies.py $kraken2_report assembly_summary_virus.txt virus
        
        ./url_download_virus.sh
        
        for compressedfile in ./*.gz
        do
            gzip -d \$compressedfile
        done
        """
    }
   
    virus_reads_mapping.join(virus_ref_assemblies).view()

    /*
    process BOWTIE2_MAPPING_VIRUS {
        tag "$samplename"
        label "process_high"
        
        input:

        output:

        script:

        """
        bowtie2-build \\
        --seed 1 \\
        --threads $task.cpus \\
        $fasta \\
        $sciname \\
        mkdir Bowtie2Index && mv $sciname Bowtie2Index

        bowtie2 \\
        -x
        -s

        """



    }

    process BOWTIE2_INDEX_BUILD_VIRUS {
        tag "$basename"
        label "process_medium"

        input:
        tuple val(sciname), file(fasta) from assemblies_virus

        output:
        tuple val(sciname), path("Bowtie2Index") into indexes_virus

        script:
        """
        bowtie2-build --seed 1 --threads $task.cpus $fasta $sciname
        mkdir Bowtie2Index && mv $sciname Bowtie2Index
        """
    }

    process BOWTIE2_ALIGN_VIRUS {
        tag "$basename"
        label "process_high"

        input:
        tuple val(single_end), path(individualized_read), val(sciname), path(indexes) from individualized_virus_reads.combine(indexes_virus)

        output:

        script:
        readname = single_end ? individualized_read.take(individualized_read.lastIndexOf("_")) : individualized_read[0].take(individualized_read[0].lastIndexOf("_"))
        sequence = single_end ? "-1 ${individualized_read}" : "-1 ${individualized_read[0]} -2 ${individualized_read[1]}" 
        sam_name = "${readname}_vs_${sciname}.sam"

        """
        bowtie2 \\
        -x ${indexes}/${sciname} \\
        -S $sam_name

        # bowtie2 [options]* -x <bt2-idx> {-1 <m1> -2 <m2> | -U <r> | --interleaved <i> | --sra-acc <acc> | b <bam>} -S [<sam>]
        """
    }
    */
}

if (params.bacteria) {

    process EXTRACT_KRAKEN2_BACTERIA {
        tag "$samplename"
        label "process_medium"
        
        input:
        tuple val(samplename), val(single_end), path(reads) from trimmed_paired_extract_bacteria
        tuple val(samplename), path(report), path(output) from kraken2_bacteria_extraction

        output:
        tuple val(samplename), val(single_end), path("*_bacteria.fastq") into bacteria_reads_mapping

        script:
        read = single_end ?  "-s ${reads}" : "-s1 ${reads[0]} -s2 ${reads[1]}"
        filename = "${samplename}_bacteria.fastq"
        """
        extract_kraken_reads.py \\
        --kraken-file ${output} \\
        --report-file ${report} \\
        --taxid 2 \\
        ${read} \\
        --output ${filename}
        """
    }


    process GET_ASSEMBLIES_BACTERIA {
        label "process_medium"

        input:
        tuple val(samplename),path(kraken2_report) from kraken2_report_bacteria_references
        
        output:
        path("*_bacteria.tsv") into assemblies_data_bacteria
        tuple val(samplename), path("*.fna") into bacteria_ref_assemblies
        script:
        
        """       
        curl 'ftp://ftp.ncbi.nlm.nih.gov/genomes/refseq/bacteria/assembly_summary.txt' > assembly_summary_bacteria.txt
        extract_reference_assemblies.py $kraken2_report assembly_summary_bacteria.txt bacteria
        
        ./url_download_bacteria.sh

        for compressedfile in ./*.gz
        do
            gzip -d \$compressedfile
        done
        """
    }

    bacteria_reads_mapping.join(bacteria_ref_assemblies).view()

    /*
    process BOWTIE2_INDEX_BUILD_BACTERIA {
        tag "$basename"
        label "process_medium"

        input:
        tuple val(samplename), file(fasta) from assemblies_bacteria

        output:
        tuple val(sciname), path("Bowtie2Index") into indexes_bacteria

        script:
        """
        bowtie2-build --seed 1 --threads $task.cpus $fasta $sciname
        mkdir Bowtie2Index && mv $sciname Bowtie2Index
        """
    }

    process BOWTIE2_ALIGN_BACTERIA {
        tag "$basename"
        label "process_high"

        input:
        tuple val(single_end), path(individualized_read), val(sciname), path(indexes) from individualized_bacteria_reads
        tuple 
        output:

        script:
        readname = single_end ? individualized_read.take(individualized_read.lastIndexOf("_")) : individualized_read[0].take(individualized_read[0].lastIndexOf("_"))
        sequence = single_end ? "-1 ${individualized_read}" : "-1 ${individualized_read[0]} -2 ${individualized_read[1]}" 
        sam_name = "${readname}_vs_${sciname}.sam"

        """
        bowtie2 \\
        -x ${indexes}/${sciname} \\
        -S $sam_name

        # bowtie2 [options]* -x <bt2-idx> {-1 <m1> -2 <m2> | -U <r> | --interleaved <i> | --sra-acc <acc> | b <bam>} -S [<sam>]
        """
    }
    */
}


if (params.fungi) {

    process EXTRACT_KRAKEN2_FUNGI {
        tag "$samplename"
        label "process_medium"

        input:
        tuple val(samplename), val(single_end), file(reads) from trimmed_paired_extract_fungi
        tuple val(samplename), file(report), file(output) from kraken2_fungi_extraction

        output:
        tuple val(samplename), val(single_end), file("*_fungi.fastq") into fungi_reads_mapping

        script:
        read = single_end ?  "-s ${reads}" : "-s1 ${reads[0]} -s2 ${reads[1]}"
        filename = "${samplename}_fungi.fastq"
        """
        extract_kraken_reads.py \\
        --kraken-file $output \\
        --report-file $report \\
        --taxid 4751 \\
        $read \\
        --output $filename
        """
    }


    process GET_ASSEMBLIES_FUNGI {
        label "process_medium"

        input:
        tuple val(samplename),path(kraken2_report) from kraken2_report_fungi_references
        
        output:
        path("*_fungi.tsv") into assemblies_data_fungi
        tuple val(samplename), path("*.fna") into fungi_ref_assemblies
        script:
        
        """       
        curl 'ftp://ftp.ncbi.nlm.nih.gov/genomes/refseq/fungi/assembly_summary.txt' > assembly_summary_fungi.txt
        extract_reference_assemblies.py $kraken2_report assembly_summary_fungi.txt fungi
        
        ./url_download_fungi.sh

        for compressedfile in ./*.gz
        do
            gzip -d \$compressedfile
        done
        """
    }

    fungi_reads_mapping.join(fungi_ref_assemblies).view()


    /*
    process BOWTIE2_INDEX_BUILD_FUNGI {
        tag "$basename"
        label "process_medium"

        input:
        tuple val(sciname), file(fasta) from assemblies_fungi

        output:
        tuple val(sciname), path("Bowtie2Index") into indexes_fungi

        script:
        """
        bowtie2-build --seed 1 --threads $task.cpus $fasta $sciname
        mkdir Bowtie2Index && mv $sciname Bowtie2Index
        """
    }

    process BOWTIE2_ALIGN_FUNGI {
        tag "$basename"
        label "process_high"

        input:
        tuple val(single_end), path(individualized_read), val(sciname), path(indexes) from individualized_fungi_reads.combine(indexes_fungi)

        output:

        script:
        readname = single_end ? individualized_read.take(individualized_read.lastIndexOf("_")) : individualized_read[0].take(individualized_read[0].lastIndexOf("_"))
        sequence = single_end ? "-1 ${individualized_read}" : "-1 ${individualized_read[0]} -2 ${individualized_read[1]}" 
        sam_name = "${readname}_vs_${sciname}.sam"

        """
        bowtie2 \\
        -x ${indexes}/${sciname} \\
        -S $sam_name

        # bowtie2 [options]* -x <bt2-idx> {-1 <m1> -2 <m2> | -U <r> | --interleaved <i> | --sra-acc <acc> | b <bam>} -S [<sam>]
        """
    }
    */
}

/*
* STEP 3.0 - Mapping
*/
process MAPPING_METASPADES {
    tag "$samplename"
    label "process_high"

    input:
    tuple val(samplename), val(single_end), path(reads) from unclassified_reads


    output:
    tuple val(samplename), path("metaspades_result/contigs.fasta") into contigs, contigs_quast

    script:
    read = single_end ? "--s ${reads}" : "--meta -1 ${reads[0]} -2 ${reads[1]}"

    """
    spades.py \\
    $read \\
    --threads $task.cpus \\
    -o $samplename
    """
}

/*
* STEP 3.1 - Evaluating assembly
*/
process QUAST_EVALUATION {
    tag "$samplename"
    label "process_medium"

    input:
    tuple val(samplename), file(contig) from contigs_quast

    output:
    file "/quast_results/report.html" into quast_results

    script:

    """
    metaquast.py \\
    -f $contigs \\
    -o quast_results
    """
}

/*
* STEP 4 - Contig search with kaiju
*/
process KAIJU {
    tag "$samplename"
    label "process_high"

    input:
    tuple val(samplename), file(contig) from contigs
    tuple path(fmi), path(nodes), path(names) from kaiju_db_files

    output:
        
    script:

    """
    kaiju \\
    -t nodes.dmp \\
    -f $fmi \\
    -i $contig \\
    -o ${samplename}_kaiju.out \\
    -z $task.cpus \\
    -v
    """
}


/*
 * STEP 9 - Completion e-mail notification - Courtesy of nf-core
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/pikavirus] Successful: $workflow.runName"
    if (!workflow.success) {
        subject = "[nf-core/pikavirus] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // TODO nf-core: If not using MultiQC, strip out this code (including params.max_multiqc_email_size)
    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = ch_multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nf-core/pikavirus] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/pikavirus] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$projectDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$projectDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, projectDir: "$projectDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$projectDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nf-core/pikavirus] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            def mail_cmd = [ 'mail', '-s', subject, '--content-type=text/html', email_address ]
            if ( mqc_report.size() <= params.max_multiqc_email_size.toBytes() ) {
              mail_cmd += [ '-A', mqc_report ]
            }
            mail_cmd.execute() << email_html
            log.info "[nf-core/pikavirus] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "-${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}-"
        log.info "-${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}-"
        log.info "-${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}-"
    }

    if (workflow.success) {
        log.info "-${c_purple}[nf-core/pikavirus]${c_green} Pipeline completed successfully${c_reset}-"
    } else {
        checkHostname()
        log.info "-${c_purple}[nf-core/pikavirus]${c_red} Pipeline completed with errors${c_reset}-"
    }

}


// nf-core functions


def nfcoreHeader() {
    // Log colors ANSI codes
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/pikavirus v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}

def isOffline() {
    try {
        return NXF_OFFLINE as Boolean
    }
    catch( Exception e ) {
        return false
    }
}