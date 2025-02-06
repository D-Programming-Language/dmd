#!/bin/sh

die () {
	[ $# -ne 0 ] && echo "${@}"
	exit 1
}

usage () {
	echo "Usage: $0 <function_name> <header>"
}

[ $# -ne 2 ] && usage && die "Invalid usage!"

tmp="${FEATURE_TMPDIR}"

mkdir -p "${tmp}" || die "Could not create temp directory"
outfile="${tmp}/check_${1}.c"

# Check taken from the meson build system
cat > "${outfile}" <<DRUNTIME_CHECK_EOF || die "Could not generate sample C program"
${2}
int main(void) {{
	void *a = (void*) &${1};
	long long b = (long long) a;
	return (int) b;
}}
DRUNTIME_CHECK_EOF

echo -n "Checking for the existence of '${1}'... "
${CC} -o "${outfile}.prog" "${outfile}" > /dev/null 2>&1
res=$?
[ "${res}" -eq 0 ] && echo "found" || echo "NOT found"

rm -f "${outfile}" "${outfile}.prog"
exit "${res}"
