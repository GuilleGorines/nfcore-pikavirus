#!/usr/bin/env python

import sys

# necessary function to extract data

def print_basic_report_data(report, post_pre):
	with open(report,"r") as infile:
		infile = infile.readlines()
		for line in infile:
			if line.startswith("Filename"):
				filename = line.replace("Filename\t","")

			elif line.startswith("Total Sequences"):
				nseqs = line.replace("Total Sequences\t","")

			elif line.startswith("Sequence length"):
				seqlen = line.replace("Sequence length\t","")

			elif line.startswith("%GC"):
				gc_content = line.replace("%GC\t","")

			html_file_name = pre_report.replace(".txt",".html")
			html_path =f"{result_dir}/raw_fastqc/{html_file_name}"

			print(f"{samplename},{post_pre},{filename},{seqlen},{nseqs},{gc_content},{html_path}\n")

			return

## Going sample by sample
## Sample name is supplied

samplename = sys.argv[1]
paired_end = sys.argv[2]
result_dir = sys.argv[3]

if paired_end:
	pre_data= [sys.argv[4],sys.argv[5]].sort()
	post_data = [sys.argv[6],sys.argv[7]].sort()

else:
	pre_data = [sys.argv[4]]
	post_data= [sys.argv[5]]

## Organize reports based on trimmed (post) or not yet (pre)

for pre_report in pre_data:
	print_basic_report_data(pre_report,"pre")

for post_report in post_data:
	print_basic_report_data(pre_report,"post")