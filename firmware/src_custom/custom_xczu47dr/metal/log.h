#ifndef CUSTOM_XCZU47DR_METAL_LOG_H
#define CUSTOM_XCZU47DR_METAL_LOG_H

#include <stdarg.h>
#include <stdio.h>

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
	static const char *const prefixes[] = {
		"metal: emergency: ",
		"metal: alert: ",
		"metal: critical: ",
		"metal: error: ",
		"metal: warning: ",
		"metal: notice: ",
		"metal: info: ",
		"metal: debug: ",
	};
	va_list args;

	if ((unsigned int)level > (unsigned int)METAL_LOG_DEBUG) {
		level = METAL_LOG_EMERGENCY;
	}
	printf("%s", prefixes[level]);
	va_start(args, format);
	vprintf(format, args);
	va_end(args);
}

#endif
