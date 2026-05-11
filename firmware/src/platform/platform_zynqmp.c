#include "xparameters.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "platform.h"

void init_platform()
{
    Xil_ICacheEnable();
    Xil_DCacheEnable();
    xil_printf("Platform initialized (ZynqMP)\r\n");
}

void cleanup_platform()
{
    Xil_DCacheDisable();
    Xil_ICacheDisable();
}
