#!/usr/bin/env bash

output_file=${OUTPUT_BASE}.log

echo 'import core.stdc.stdio; void main() { puts("Success"); }' | \
	$DMD -m${MODEL} -run - > ${output_file}
grep -q 'Success' ${output_file}

rm_retry "${output_file}"
