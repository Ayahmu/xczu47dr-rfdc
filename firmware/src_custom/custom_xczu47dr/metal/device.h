#ifndef CUSTOM_XCZU47DR_METAL_DEVICE_H
#define CUSTOM_XCZU47DR_METAL_DEVICE_H

#include "metal/sys.h"

struct metal_device {
	const char *name;
	struct metal_io_region *regions;
};

static inline struct metal_io_region *metal_device_io_region(struct metal_device *device, unsigned int index)
{
	(void)index;
	return device != 0 ? device->regions : 0;
}

static inline int metal_device_open(const char *bus_name, const char *dev_name, struct metal_device **device)
{
	(void)bus_name;
	(void)dev_name;
	if (device != 0) {
		*device = 0;
	}
	return -1;
}

static inline void metal_device_close(struct metal_device *device)
{
	(void)device;
}

static inline int metal_register_generic_device(struct metal_device *device)
{
	(void)device;
	return 0;
}

#endif
