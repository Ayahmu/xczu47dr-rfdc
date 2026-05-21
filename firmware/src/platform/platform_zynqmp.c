#include "xparameters.h"
#include "xparameters_ps.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xil_exception.h"
#include "xscugic.h"
#include "xttcps.h"
#include "lwip/tcp.h"
#include "netif/xadapter.h"
#include "platform.h"
#include "../config/platform_config.h"

#define INTC_DEVICE_ID XPAR_SCUGIC_SINGLE_DEVICE_ID
#define TIMER_DEVICE_ID XPAR_XTTCPS_0_DEVICE_ID
#define TIMER_IRPT_INTR XPAR_XTTCPS_0_INTR
#define INTC_BASE_ADDR XPAR_SCUGIC_0_CPU_BASEADDR
#define INTC_DIST_BASE_ADDR XPAR_SCUGIC_0_DIST_BASEADDR
#define PLATFORM_TIMER_INTR_RATE_HZ 20U

static XTtcPs TimerInstance;
static XInterval Interval;
static u8 Prescaler;

volatile int TcpFastTmrFlag = 0;
volatile int TcpSlowTmrFlag = 0;

extern struct netif *echo_netif;

static void platform_clear_interrupt(XTtcPs *Timer)
{
	u32 StatusEvent = XTtcPs_GetInterruptStatus(Timer);
	XTtcPs_ClearInterruptStatus(Timer, StatusEvent);
}

static void timer_callback(XTtcPs *Timer)
{
	static int DetectEthLinkStatus = 0;
	static int Tcp_Fasttimer = 0;
	static int Tcp_Slowtimer = 0;

	DetectEthLinkStatus++;
	Tcp_Fasttimer++;
	Tcp_Slowtimer++;

	if ((Tcp_Fasttimer % 5) == 0) {
		TcpFastTmrFlag = 1;
	}

	if ((Tcp_Slowtimer % 10) == 0) {
		TcpSlowTmrFlag = 1;
	}

	if (DetectEthLinkStatus == ETH_LINK_DETECT_INTERVAL) {
		eth_link_detect(echo_netif);
		DetectEthLinkStatus = 0;
	}

	platform_clear_interrupt(Timer);
}

void platform_setup_timer(void)
{
	int Status;
	XTtcPs *Timer = &TimerInstance;
	XTtcPs_Config *Config;

	Config = XTtcPs_LookupConfig(TIMER_DEVICE_ID);
	if (Config == NULL) {
		xil_printf("Timer lookup failed\r\n");
		return;
	}

	Status = XTtcPs_CfgInitialize(Timer, Config, Config->BaseAddress);
	if (Status != XST_SUCCESS) {
		xil_printf("Timer Cfg initialization failed\r\n");
		return;
	}

	XTtcPs_SetOptions(Timer, XTTCPS_OPTION_INTERVAL_MODE | XTTCPS_OPTION_WAVE_DISABLE);
	XTtcPs_CalcIntervalFromFreq(Timer, PLATFORM_TIMER_INTR_RATE_HZ, &Interval, &Prescaler);
	XTtcPs_SetInterval(Timer, Interval);
	XTtcPs_SetPrescaler(Timer, Prescaler);
}

static void platform_setup_interrupts(void)
{
	Xil_ExceptionInit();
	XScuGic_DeviceInitialize(INTC_DEVICE_ID);
	Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_IRQ_INT,
				     (Xil_ExceptionHandler)XScuGic_DeviceInterruptHandler,
				     (void *)INTC_DEVICE_ID);
	XScuGic_RegisterHandler(INTC_BASE_ADDR, TIMER_IRPT_INTR,
			       (Xil_ExceptionHandler)timer_callback,
			       (void *)&TimerInstance);
	XScuGic_EnableIntr(INTC_DIST_BASE_ADDR, TIMER_IRPT_INTR);
}

void platform_enable_interrupts()
{
	Xil_ExceptionEnableMask(XIL_EXCEPTION_IRQ);
	XScuGic_EnableIntr(INTC_DIST_BASE_ADDR, TIMER_IRPT_INTR);
	XTtcPs_EnableInterrupts(&TimerInstance, XTTCPS_IXR_INTERVAL_MASK);
	XTtcPs_Start(&TimerInstance);
}

void init_platform()
{
	Xil_ICacheEnable();
	Xil_DCacheEnable();
	platform_setup_timer();
	platform_setup_interrupts();
	xil_printf("Platform initialized (ZynqMP)\r\n");
}

void cleanup_platform()
{
    Xil_DCacheDisable();
    Xil_ICacheDisable();
}
