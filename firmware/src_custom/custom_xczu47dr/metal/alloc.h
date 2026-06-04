#ifndef CUSTOM_XCZU47DR_METAL_ALLOC_H
#define CUSTOM_XCZU47DR_METAL_ALLOC_H

#include <stdlib.h>

static inline void *metal_allocate_memory(size_t size)
{
	return malloc(size);
}

#endif
