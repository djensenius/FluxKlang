#include "census.h"
#include <unistd.h>

#if defined(XC_FIXTURE)
#error Production main must never be linked with the fixture seam
#endif

int
main(int argc, char **argv)
{
    static struct xc_report report;
    (void)argv;
    if (getuid() == 0 || geteuid() == 0)
        xc_refuse(&report, XC_ROOT);
    else if (argc != 1)
        xc_refuse(&report, XC_ARGUMENTS);
    else
        (void)xc_fixed(&report);
    if (xc_emit(&report) != 0)
        return 1;
    return report.errors == 0 ? 0 : 1;
}
