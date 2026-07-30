#ifndef TEST_XIL_CACHE_H
#define TEST_XIL_CACHE_H

#include <stdint.h>

typedef uintptr_t INTPTR;
void Xil_DCacheFlushRange(INTPTR address, uint32_t length);
void Xil_DCacheInvalidateRange(INTPTR address, uint32_t length);

#endif
