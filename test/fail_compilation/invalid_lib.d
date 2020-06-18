/*
REQUIRED_ARGS: -lib
REQUIRED_ARGS(linux freebsd osx) fail_compilation/extra-files/fake.a
REQUIRED_ARGS(windows) -m32 fail_compilation/extra-files/fake.lib
PERMUTE_ARGS:

Use a regex because the path is really strange on Azure (OMF_32, 64):

{{RESULTS_DIR}}\fail_compilation\{{RESULTS_DIR}}\fail_compilation\invalid_omf_0.obj

TEST_OUTPUT:
----
$r:.*$: Error: corrupt $?:windows=OMF|osx=Mach|ELF$ object module $?:windows=fail_compilation\extra-files\fake.lib|fail_compilation/extra-files/fake.a$ $n$
----
*/
void main() {}
