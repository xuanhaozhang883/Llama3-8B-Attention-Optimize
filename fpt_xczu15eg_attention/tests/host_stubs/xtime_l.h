#ifndef TEST_XTIME_L_H
#define TEST_XTIME_L_H

#include <stdint.h>

typedef uint64_t XTime;
#define COUNTS_PER_SECOND 100000000ULL
void XTime_GetTime(XTime *value);

#endif
