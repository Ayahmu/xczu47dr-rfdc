#ifndef CUSTOM_XCZU47DR_METAL_SLEEP_H
#define CUSTOM_XCZU47DR_METAL_SLEEP_H

#include "sleep.h"

static inline void metal_sleep_usec(unsigned int usec)
{
	usleep(usec);
}

#endif
