#ifndef CUSTOM_XCZU47DR_METAL_LOG_H
#define CUSTOM_XCZU47DR_METAL_LOG_H

#include <stdarg.h>

enum metal_log_level {
	METAL_LOG_EMERGENCY = 0,
	METAL_LOG_ALERT,
	METAL_LOG_CRITICAL,
	METAL_LOG_ERROR,
	METAL_LOG_WARNING,
	METAL_LOG_NOTICE,
	METAL_LOG_INFO,
	METAL_LOG_DEBUG,
};

typedef void (*metal_log_handler)(enum metal_log_level level, const char *format, ...);

static inline void metal_default_log_handler(enum metal_log_level level, const char *format, ...)
{
	(void)level;
	(void)format;
}

static inline void metal_log(enum metal_log_level level, const char *format, ...)
{
	(void)level;
	(void)format;
}

#endif
