// PERMUTE_ARGS:
// POST_SCRIPT: runnable/extra-files/coverage-postscript.sh
// REQUIRED_ARGS: -cov
// EXECUTE_ARGS: ${RESULTS_DIR}/runnable

extern(C) void dmd_coverDestPath(string pathname) @system;

void main(string[] args)
{
    dmd_coverDestPath(args[1]);

    if (false)
    {
        static if (2 == 2)
        {
        }
        else
        {
        }
        alias type = int;
        enum k = 2;
        enum array = [1, 2];
        static foreach (i; array)
        {
        }
    }
}
