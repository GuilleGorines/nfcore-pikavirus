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

    nextflow run nf-core/pikavirus --input '*_R{1,2}.fastq.gz' -profile docker

    Mandatory arguments:
      --input [file]                  Path to input data (must be surrounded with quotes)
      -profile [str]                  Configuration profile to use. Can use multiple (comma separated)
                                      Available: conda, docker, singularity, test, test_single_end, awsbatch

    Performance arguments:
      --max_memory [int].GB           Maximum quantity of memory to be used in the whole pipeline
      --max_cpus [int]                Maximum number of cpus to be used in the whole pipeline
      --max_time [int].h              Maximum time for the pipeline to finish

    Options:
      --single_end [bool]             Specifies that the input is single-end reads (Default: false)
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

// Stage config files
ch_multiqc_config = file("$projectDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config, checkIfExists: true) : Channel.empty()
ch_output_docs = file("$projectDir/docs/output.md", checkIfExists: true)
ch_output_docs_images = file("$projectDir/docs/images/", checkIfExists: true)

/*
 * Create a channel for input read files
 */
if (params.input_paths) {
    if (params.single_end) {
        Channel
            .from(params.input_paths)
            .map { row -> [ row[0], [ file(row[1][0], checkIfExists: true) ] ] }
            .ifEmpty { exit 1, "params.input_paths was empty - no input files supplied" }
            .into { raw_reads }
    } else {
        Channel
            .from(params.input_paths)
            .map { row -> [ row[0], [ file(row[1][0], checkIfExists: true), file(row[1][1], checkIfExists: true) ] ] }
            .ifEmpty { exit 1, "params.input_paths was empty - no input files supplied" }
            .into { raw_reads }
    }
} else {
    Channel
        .fromFilePairs(params.input, size: params.single_end ? 1 : 2)
        .ifEmpty { exit 1, "Cannot find any reads matching: ${params.input}\nNB: Path needs to be enclosed in quotes!\nIf this is single-end data, please specify --single_end on the command line." }
        .into { raw_reads }
}

// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Input']            = params.input
summary['Data Type']        = params.single_end ? 'Single-End' : 'Paired-End'
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
    section_href: 'https://github.com/ads $task.cpus \\
            --unclassified-out $unclassified \\
            --classified-out $classified \\
            --report ${sample}.kraken2.report.txt \\
            --report-zero-counts \\nf-core/pikavirus'
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
process GET_SOFTWARE_VERSION {
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
    trimmomatic -version > v_trimmomatic.txt
    kaiju -help > v_kaiju.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}

/*
 * PREPROCESSING: KRAKEN2 DATABASE
 */
if (params.kraken2_db.endsWith('gz') || params.kraken2_db.endsWith('.tar')){

    process UNCOMPRESS_KRAKEN2DB {
        label 'error_retry'

        input:
        path(database) from params.kraken2_db

        output:
        path "$krakendb" into kraken2_db_files

        script:
        krakendb = database.toString() - ".tar.gz"

        """
        tar -xvf $database
        """
    }
} else {
    kraken2_db_files = params.kraken2_db
}

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
        tar -xvf $database
        """
    }
} else {
    kaiju_db_files = params.kaiju_db
}


/*
 * STEP 1.1 - FastQC
 */
process RAW_SAMPLES_FASTQC {
    tag "$name"
    label "process_medium"
    publishDir "${params.outdir}/raw_fastqc", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"
                }

    input:
    set val(name), file(reads) from raw_reads

    output:
    file "*_fastqc.{zip,html}" into fastqc_results

    script:

    """
    fastqc --quiet --threads $task.cpus $reads
    """
}

/*
 * STEP 1.2 - TRIMMING
 */
if (params.trimming) {
    process RAW_SAMPLES_TRIMMING_TRIMMOMATIC {
        tag "$name"
        label 
        publishDir "${params.outdir}/trimmed", mode: params.publish_dir_mode,
        saveAs: { filename ->
                        filename.indexOf(".fastq") > 0 ? "trimmed/$filename" : "$filename"
                    }

        input:
        tuple val(name), file(reads) from raw_reads

        output:
        tuple val(name), file("*_paired.fastq") into trimmed_paired
        tuple val(name), file("*_unpaired.fastq") into trimmed_unpaired

        script:
        paired_end = params.single_end ? "" : "PE"
        """
        Trimmomatic $paired_end -threads $task.cpus -phred33 $reads 
        """
    }

    /*
    * STEP 1.3 - FastQC on trimmed reads
    */
    process TRIMMED_SAMPLES_FASTQC {
        tag "$name"
        label 
        publishDir "${params.outdir}/trimmed_fastqc", mode: params.publish_dir_mode

        input:
        tuple val(name), file(reads) from trimmed_paired

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
    tag "$name"
    label
    publishDir "${resultsDir}/kraken2_results", mode: params.publish_dir_mode,
    saveAs: { filename ->
                      filename.indexOf(".krona") > 0 ? "trimmed/$filename" : "$filename"
    }

    input:
    path(kraken2db) from kraken2_db_files
    tuple val(name), file(reads) from trimmed_paired

    output:
    file "*.report" into kraken2_reports
    file "*.kraken" into kraken2_outputs
    file "*.krona.html" into krona_taxonomy
    tuple val(filename), file("*_unclassified.fastq") into unclassified_reads
    
    script:
    paired_end = params.single_end ? "" : "--paired"
    filename = "${name}_unclassified"

    """
    kraken2 --db $kraken2db \\
    ${paired_end} \\
    --threads $task.cpus \\
    --report ${name}.report \\
    --output ${name}.kraken \\
    --unclassified-out ${filename}.fastq \\
    ${reads}

    """
}

/*
 * STEP 2.1.2 - Krona output for Kraken scouting
 */
if (params.kraken2krona) {

    process KRONA_KRAKEN_RESULTS {
        tag "$name"
        label
        publishDir "${resultsDir}/kraken2_results", mode: params.publish_dir_mode,
        saveAs: {}

        input:
        file(report) from kraken2_reports

        output:
        file "*.krona.html" into krona_taxonomy

        script:
        name = ${report.baseName}

        """
        kreport2krona.py \\
        --report-file $report \\
        --output ${name}.krona

        ktImportText \\
        -o ${name}.krona.html \\
        ${name}.krona
        """
    }
}

if (!params.skip_assembly) {
/*
 * STEP 2.2 - Extract virus reads
 */
    if (params.virus) {
        process EXTRACT_KRAKEN2_VIRUS {
            tag "$name"
            label
            
            input:
            tuple val(name), file(reads) from trimmed_paired
            file(report) from kraken2_reports
            file(output) from kraken2_outputs

            output:
            tuple val(filename), file("*_virus.fastq") into virus_reads

            script:
            read = params.single_end ? "-s ${reads}" : "-s1 ${reads[0]} -s2 ${reads[1]}" 
            filename = "${name}_virus"
            """
            extract_kraken_reads.py \\
            --kraken-file ${output} \\
            --report-file ${report} \\
            --taxid 10239 \\
            ${read} \\
            --output ${filename}.fastq
            """
        }
    } else {
        virus_reads = Channel.empty()
    }


    /*
    * STEP 2.3 - Extract bacterial reads
    */
    if (params.bacteria) {
    process EXTRACT_KRAKEN2_BACTERIA {
        tag "$name"
        label
        
        input:
        tuple val(name), file(reads) from trimmed_paired
        file(report) from kraken2_reports
        file(output) from kraken2_outputs

        output:
        tuple val(filename), file("*_bacteria.fastq") into bacteria_reads

        script:
        read = params.single_end ?  "-s ${reads}" : "-s1 ${reads[0]} -s2 ${reads[1]}"
        filename = "${name}_bacteria"
        """
        extract_kraken_reads.py \\
        --kraken-file ${output} \\
        --report-file ${report} \\
        --taxid 2 \\
        ${read} \\
        --output ${filename}.fastq
        """
    }
    } else {
        bacteria_reads = Channel.empty()
    }

    /*
    * STEP 2.4 - Extract fungal reads
    */
    if (params.fungi){
    process EXTRACT_KRAKEN2_FUNGI {
        tag "$name"
        label

        input:
        tuple val(name), file(reads) from trimmed_paired
        file(report) from kraken2_reports
        file(output) from kraken2_outputs

        output:
        tuple val(filename), file("*_fungi.fastq") into fungi_reads

        script:
        read = params.single_end ?  "-s ${reads}" : "-s1 ${reads[0]} -s2 ${reads[1]}"
        filename = "${name}_fungi"
        """
        extract_kraken_reads.py \\
        --kraken-file ${output} \\
        --report-file ${report} \\
        --taxid 4751 \\
        ${read} \\
        --output ${filename}.fastq
        """
    }
    } else {
        fungi_reads = Channel.empty()
    }

    /*
    * STEP 3.0 - Mapping
    */
    process MAPPING_METASPADES {
        tag "$name"
        label

        input:
        tuple val(name), file(seq_reads) from virus_reads.concat(fungi_reads, bacteria_reads, unclassified_reads)


        output:
        tuple val(name), file("metaspades_result/contigs.fasta") into mapping

        script:
        read = params.single_end ? "--s ${reads}" : "--meta -1 ${reads[0]} -2 ${reads[1]}"

        """696, column 1
        spades.py \\
        $read \\
        --threads $task.cpus \\
        -o ${name}
        """
    }

    /*
    * STEP 3.1 - Mapping virus 
    */
    process MAPPING_METASPADES {
        tag "$name"
        label

        input:
        file(virus_read) from virus_reads

        output:
        tuple val(name), file("metaspades_result/contigs.fasta") into virus_mapping

        script:
        meta = params.single_end ? "" : "--meta"
        read = params.single_end ? "--s ${reads}" : "-1 ${reads[0]} -2 ${reads[1]}"
        name = "${virus_read.baseName}_virus"

        """
        spades.py \\
        $meta \\
        --threads $task.cpus \\
        $virus_read \\
        -o metaspades_result
        """
    }
    if (!params.virus){
        virus_mapping = Channel.create()
    } 

    /*
    * STEP 3.2 - Mapping bacteria
    */
    process BACTERIA_MAPPING_METASPADES {

        tag "$name"
        label

        input:
        file(bacteria_read) from bacteria_reads

        output:
        tuple val(name),file("metaspades_result/contigs.fasta") into bacteria_mapping

        when:
        

        script:
        meta = params.single_end ? "" : "--meta"
        read = params.single_end ? "--s ${reads}" : "-1 ${reads[0]} -2 ${reads[1]}"
        name = "${bacteria_read.baseName}_bacteria"

        """
        spades.py \\
        $meta \\
        --threads $task.cpus \\
        $bacteria_read \\
        -o metaspades_result
        """
    }

    if (!params.bacteria){
        bacteria_mapping = Channel.create()
    } 

    /*
    * STEP 3.3 - Mapping fungi
    */
    process FUNGI_MAPPING_METASPADES {
        tag "$name"
        label


        input:
        file(fungi_read) from fungi_reads

        output:
        tuple val(name), file("metaspades_result/contigs.fasta") into fungi_mapping

    
        script:
        meta = params.single_end ? "" : "--meta"
        read = params.single_end ? "--s ${reads}" : "-1 ${reads[0]} -2 ${reads[1]}"
        name = "${fungi_read.baseName}_fungi"

        """
        spades.py \\
        $meta \\
        --threads $task.cpus \\
        $reads \\
        -o metaspades_result
        """
    }

    if (!params.fungi){
        fungi_mapping = Channel.create()
    }

    /*
    * STEP 3.4 - Mapping unkwnown
    */

    process UNCLASS_MAPPING_METASPADES {
        tag "$name"
        label

        input:
        file(unclass_reads) from unclassified_reads

        output:
        tuple val(name), file("metaspades_result/contigs.fasta") into unclassified_mapping
    
        script:
        meta = params.single_end ? "" : "--meta"
        read = params.single_end ? "--s ${reads}" : "-1 ${reads[0]} -2 ${reads[1]}"
        name = "${unclass_read.baseName}"
        """
        spades.py \\
        $meta \\
        --threads $task.cpus \\
        $reads \\
        -o metaspades_result
        """
    }

    /*
    * STEP 3.5 - Evaluating assembly
    */
    process QUAST_EVALUATION {
        tag "$name"
        label

        input:
        tuple val(name), file(contig) from virus_mapping.concat( bacteria_mapping, fungi_mapping, unclassified_mapping )

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
    * STEP 4 - Contig 
    */

    process KAIJU {
        tag "$name"
        label

        input:
        tuple val(name), file(contig) from virus_mapping.concat( bacteria_mapping, fungi_mapping, unclassified_mapping )
        tuple path(fmi), path(nodes), path(names) from kaiju_db_files

        output:


        script:
        """
        kaiju \\
        -t nodes.dmp \\
        -f ${fmi} \\
        -i ${contig} \\
        -o ${name}_kaiju.out \\
        -z $task.cpus \\
        -v
        """




    }
/*
    kaiju \\
    -t nodes.dmp \\
    -f kaiju_db.fmi \\
    -i {reads[0]} \\
    -j {reads[1]} \\
    -o kaiju.out \\
    -z $task.cpus \\
    -v

    kaiju2table \\
    -t nodes.dmp \\
    -n names.dmp \\
    -r genus/superkingdom (superkingdom parece que no está, F) \\
    -o kaiju_summary.tsv \\
    kaiju.out

    kaiju-addTaxonNames 
    -t nodes.dmp 
    -n names.dmp 
    -i kaiju.out 
    -o kaiju.names.out


    kaiju2krona
    -t nodes.dmp 
    -n names.dmp 
    -i kaiju.out 
    -o kaiju.out.krona


    /*
    * STEP 4.1 - Bacteria BlastN
    */
    process BACTERIA_BLASTN {

        input:

        output:

        script:

    }

    /*
    * STEP 4.2 - Virus BlastN
    */ */

    process VIRUS_BLASTN {

        input:

        output:

        script:

    }

    /*
    * STEP 4.3 - Fungi BlastN
    */
    process FUNGI_BLASTN {

        input:

        output:

        script:

    }


    /*
    * STEP 5.1 - Remapping for bacteria
    */
    process BACTERIA_REMAPPING {

        input:

        output:

        script:

    }

    /*
    * STEP 5.2 - Remapping for virus
    */
    process VIRUS_REMAPPING {

        input:

        output:

        script:

    }

    /*
    * STEP 5.3 - Remapping for fungi
    */
    process FUNGI_REMAPPING {

        input:

        output:

        script:

    }

    /*
    * STEP 6.1 - Coverage and graphs for bacteria
    */
    process COVERAGE_BACTERIA {

        input:

        output:

        script:

    }

    /*
    * STEP 6.2 - Coverage and graphs for virus
    */
    process COVERAGE_VIRUS {

        input:

        output:

        script:

    }

    /*
    * STEP 6.3 - Coverage and graphs for fungi
    */
    process COVERAGE_FUNGI {

        input:

        output:

        script:

    }

    /*
    * STEP 7 - Generate output in HTML, and tsv table for all results
    */
    process HTML_TSV_GENERATION {

        input:

        output:

        script:

    }

    /*
    * STEP 8 - Cleanup 
    */
    process CLEANUP {

        input:

        output:

        script:

    }
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
