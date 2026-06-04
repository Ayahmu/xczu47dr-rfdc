#ifndef CUSTOM_XCZU47DR_METAL_SYS_H
#define CUSTOM_XCZU47DR_METAL_SYS_H

#include <stdint.h>
#include <stddef.h>
#include "metal/log.h"

typedef uintptr_t metal_phys_addr_t;

struct metal_io_region {
	void *virt;
	metal_phys_addr_t *physmap;
	size_t size;
};

struct metal_init_params {
	metal_log_handler log_handler;
	enum metal_log_level log_level;
};

#define METAL_INIT_DEFAULTS { 0 }

static inline int metal_init(const struct metal_init_params *params)
{
	(void)params;
	return 0;
}

static inline void metal_io_init(struct metal_io_region *io, void *virt, metal_phys_addr_t *physmap,
		size_t size, unsigned page_shift, unsigned flags, void *ops)
{
	(void)page_shift;
	(void)flags;
	(void)ops;
	io->virt = virt;
	io->physmap = physmap;
	io->size = size;
}

static inline uint8_t metal_io_read8(struct metal_io_region *io, unsigned long offset)
{
	return *((volatile uint8_t *)((uintptr_t)io->virt + offset));
}

static inline uint16_t metal_io_read16(struct metal_io_region *io, unsigned long offset)
{
	return *((volatile uint16_t *)((uintptr_t)io->virt + offset));
}

static inline uint32_t metal_io_read32(struct metal_io_region *io, unsigned long offset)
{
	return *((volatile uint32_t *)((uintptr_t)io->virt + offset));
}

static inline uint64_t metal_io_read64(struct metal_io_region *io, unsigned long offset)
{
	uint32_t lo = metal_io_read32(io, offset);
	uint32_t hi = metal_io_read32(io, offset + 4U);
	return ((uint64_t)hi << 32) | lo;
}

static inline void metal_io_write8(struct metal_io_region *io, unsigned long offset, uint8_t value)
{
	*((volatile uint8_t *)((uintptr_t)io->virt + offset)) = value;
}

static inline void metal_io_write16(struct metal_io_region *io, unsigned long offset, uint16_t value)
{
	*((volatile uint16_t *)((uintptr_t)io->virt + offset)) = value;
}

static inline void metal_io_write32(struct metal_io_region *io, unsigned long offset, uint32_t value)
{
	*((volatile uint32_t *)((uintptr_t)io->virt + offset)) = value;
}

static inline void metal_io_write64(struct metal_io_region *io, unsigned long offset, uint64_t value)
{
	metal_io_write32(io, offset, (uint32_t)value);
	metal_io_write32(io, offset + 4U, (uint32_t)(value >> 32));
}

#endif
