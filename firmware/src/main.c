
/***************************** Include Files *********************************/
#include <stdio.h>
#include <stdarg.h>
#include "main.h"
#include "xparameters.h"
#include "xil_io.h"
#include "sleep.h"
#include "xstatus.h"
#include "xil_printf.h"
#include "xil_cache.h"

#include "xrfdc.h"
#include "modules/rf/LMK_display.h"
#include "modules/rf/LMX_display.h"
#if defined(BOARD_ZCU216)
#include "modules/rf/xrfclk.h"
#endif

#include "platform/platform.h"
#include "modules/dma/dma_ctrl.h"
#include "modules/net/lwip_user.h"

#include <metal/log.h>
#include <metal/sys.h>

/******************** Constant Definitions **********************************/
#define ENABLE_METAL_PRINTS

#if defined(BOARD_ZCU216) == defined(BOARD_CUSTOM_XCZU47DR)
#error "Define exactly one firmware board: BOARD_ZCU216 or BOARD_CUSTOM_XCZU47DR"
#endif

#define URAM_PLAY_BASE XPAR_HIER_PLAY_AXI_BRAM_CTRL_0_S_AXI_BASEADDR

// PLL debug defines. Will print all calculated values
#undef LMK_DEBUG
#undef LMX_DEBUG

// XAxiDma AxiDma;

volatile u8 *data_buffer = (u8 *)DDR4_BASE;
int data_len = 0;
int data_ready = 0;

struct netif server_netif;
struct netif *echo_netif = &server_netif;

void my_metal_default_log_handler(enum metal_log_level level,
								  const char *format, ...);

#if defined(BOARD_ZCU216)
static int resetAllClk104(void);
#endif
void reverse32bArray(u32 *src, int size);
#if defined(BOARD_ZCU216)
void printCLK104_settings(void);
#endif
int rfdcStartup(void);
int Configure_DAC_Output_Current(void);

/************************** Variable Definitions *****************************/

// VT100 esc sequences
char CHAR_ATTRIB_OFF[5] = "\x1B[0m";
char BOLD_ON[5] = "\x1B[1m";
char UNDERLINE_ON[5] = "\x1B[4m";
char BLINK_ON[5] = "\x1B[5m";
char REVERSE_ON[5] = "\x1B[5m";
char CLR_SCREEN[5] = "\x1B[2J";

#if defined(BOARD_ZCU216)
// data buffer used for reading PLL registers
static u32 data[256];
#endif

const char clkoutBrdNames[][18] = {
	"RFIN_RF1",
	"RF1_ADC_SYNC",
	"NC",
	"AMS_SYSREF",
	"RFIN_RF2",
	"RF2_DAC_SYNC",
	"DAC_REFCLK",
	"DDR_PL_CAP_SYNC",
	"PL_CLK",
	"PL_SYSREF",
	"NC",
	"J10 SINGLE END",
	"ADC_REFCLK",
	"NC",
};

lmk_config_t lmkConfig;
lmx_config_t lmxConfig;

#if defined(BOARD_ZCU216)
extern const u32 LMK_CKin[LMK_FREQ_NUM][LMK_COUNT];
extern const u32 LMX2594[][LMX2594_COUNT];
#endif

#include "xtime_l.h"
#define TEST_LENGTH (32 * 1024 * 1024)

XRFdc RFdcInst; /* RFdc driver instance */

#if defined(BOARD_CUSTOM_XCZU47DR)
#define DEBUG_WAVEFORM_BYTES 4096U
#define DEBUG_WAVEFORM_SAMPLES (DEBUG_WAVEFORM_BYTES / sizeof(s16))
#define HMC7044_POLL_COUNT 50
#define HMC7044_POLL_INTERVAL_US 100000

static void preload_debug_waveforms(void)
{
	s16 *ch1 = (s16 *)(UINTPTR)DDR4_BASE;
	s16 *ch2 = (s16 *)((UINTPTR)DDR4_BASE + DEBUG_WAVEFORM_BYTES);
	u32 i;

	for (i = 0U; i < DEBUG_WAVEFORM_SAMPLES; i++)
	{
		ch1[i] = (i & 0x20U) ? 12000 : -12000;
		ch2[i] = (i & 0x20U) ? -12000 : 12000;
	}

	Xil_DCacheFlushRange((UINTPTR)ch1, DEBUG_WAVEFORM_BYTES);
	Xil_DCacheFlushRange((UINTPTR)ch2, DEBUG_WAVEFORM_BYTES);
	xil_printf("Preloaded debug waveforms: ch1=0x%08lx%08lx ch2=0x%08lx%08lx bytes=%lu\r\n",
		   (unsigned long)(((u64)(UINTPTR)ch1) >> 32),
		   (unsigned long)(((u64)(UINTPTR)ch1) & 0xffffffffU),
		   (unsigned long)(((u64)(UINTPTR)ch2) >> 32),
		   (unsigned long)(((u64)(UINTPTR)ch2) & 0xffffffffU),
		   (unsigned long)DEBUG_WAVEFORM_BYTES);
}
#endif

int Init_GPIO(void)
{
	Xil_Out32(GPIO_BASE_ADDR + GPIO_TRI_CH1_OFFSET, 0x00000000);
	Xil_Out32(GPIO_BASE_ADDR + GPIO_TRI_CH2_OFFSET, 0x00000000);

	return XST_SUCCESS;
}

int Adjust_DAC_Power(u32 Tile_Id, u32 Block_Id, u32 CurrentMA)
{
	int Status;
	u32 uAmps;

	if (CurrentMA < 3 || CurrentMA > 40)
	{
		xil_printf("Error: Current %d mA out of range (2.25 - 40.5 mA)\r\n", CurrentMA);
		return XST_FAILURE;
	}

	uAmps = CurrentMA * 1000;

	Status = XRFdc_SetDACVOP(&RFdcInst, Tile_Id, Block_Id, uAmps);

	if (Status != XST_SUCCESS)
	{
		xil_printf("XRFdc_SetDACVOP Failed for Tile%d Block%d\r\n", Tile_Id, Block_Id);
		return XST_FAILURE;
	}

	xil_printf("Success: DAC Tile%d Block%d Current set to %d mA (%d uA)\r\n",
			   Tile_Id, Block_Id, CurrentMA, uAmps);

	return XST_SUCCESS;
}

int Configure_DAC_Output_Current(void)
{
	static const struct {
		u32 Tile_Id;
		u32 Block_Id;
	} CustomDacBlocks[] = {
		{2, 0},
		{2, 2},
		{3, 0},
		{3, 2},
	};
	unsigned int i;

	for (i = 0; i < sizeof(CustomDacBlocks) / sizeof(CustomDacBlocks[0]); i++)
	{
		if (Adjust_DAC_Power(CustomDacBlocks[i].Tile_Id, CustomDacBlocks[i].Block_Id, 20) != XST_SUCCESS)
		{
			return XST_FAILURE;
		}
	}

	return XST_SUCCESS;
}

/*****************************************************************************/
/**
 *
 * Main function
 *
 * TBD
 *
 * @param	None
 *
 * @return
 *		- XST_SUCCESS if tests pass
 *		- XST_FAILURE if fails.
 *
 * @note		None.
 *
 ******************************************************************************/
int main(void)
{
	u32 Val;
	u32 Minor;
	u32 Major;
	int Status;
	XRFdc_Config *ConfigPtr;
	#if defined(BOARD_ZCU216)
	int lmkConfigIndex;
	#endif

	init_platform();

	// Initialize CLI commands structure

	xil_printf("\n\r###############################################\n\r");
	xil_printf("Hello RFSoC World!\n\r\n");

	// Display IP version
	Val = Xil_In32(RFDC_BASE + 0x00000);
	Major = (Val >> 24) & 0xFF;
	Minor = (Val >> 16) & 0xFF;

	xil_printf("RFDC IP Version: %d.%d\r\n", Major, Minor);

	// Configure board clocks
	xil_printf("\nConfiguring the data converter clocks...\r\n");

#if defined(BOARD_ZCU216)
	// initialize and reset CLK104 devices on i2c and i2c muxes
	XRFClk_Init();

	if (resetAllClk104() == EXIT_FAILURE)
	{
		xil_printf("resetAllClk104() failed\n\r");
		return XST_FAILURE;
	}

	xil_printf("Configuring CLK104 LMK and LMX devices\r\n");

	/* Set config on all chips */
	// using below LMK config index
	lmkConfigIndex = 7;

	// LMX2594_FREQ_300M00_PD	if (XST_FAILURE == XRFClk_SetConfigOnAllChipsFromConfigId(lmkConfigIndex, LMX2594_FREQ_8192M00, LMX2594_FREQ_7864M32)) {
	if (XST_FAILURE == XRFClk_SetConfigOnAllChipsFromConfigId(lmkConfigIndex, LMX2594_FREQ_1474M56, LMX2594_FREQ_1474M56))
	{
		printf("Failure in XRFClk_SetConfigOnAllChipsFromConfigId()\n\r");
		return XST_FAILURE;
	}

	// Print clock settings to the terminal
	printCLK104_settings();
	/* Close spi connections to clk104 */
	XRFClk_Close();
#elif defined(BOARD_CUSTOM_XCZU47DR)
	xil_printf("Custom XCZU47DR clock policy: HMC7044 is programmed by PL sequencer.\r\n");
	xil_printf("HMC7044 reset policy: PL drives RESET_H7044_H_0 low to release the active-high reset net.\r\n");
	u32 hmcStatus = Xil_In32(GPIO_BASE_ADDR + GPIO_DATA_CH2_OFFSET);
	xil_printf("HMC7044 PL sequencer initial status: 0x%08lx (done mask 0x%08lx)\r\n",
		   (unsigned long)hmcStatus, (unsigned long)HMC7044_DONE_MASK);
	for (int hmcWait = 0; ((hmcStatus & HMC7044_DONE_MASK) == 0U) && (hmcWait < HMC7044_POLL_COUNT); hmcWait++)
	{
		usleep(HMC7044_POLL_INTERVAL_US);
		hmcStatus = Xil_In32(GPIO_BASE_ADDR + GPIO_DATA_CH2_OFFSET);
	}
	xil_printf("HMC7044 PL sequencer status: 0x%08lx\r\n", hmcStatus);
	if ((hmcStatus & HMC7044_DONE_MASK) == 0U)
	{
		xil_printf("ERROR: HMC7044 PL sequencer did not finish before RFDC startup.\r\n");
		return XST_FAILURE;
	}
#endif

	sleep(2);

#ifdef ENABLE_METAL_PRINTS
	xil_printf("=== Metal log enabled ===\n\r");

	struct metal_init_params init_param = {
		.log_handler = my_metal_default_log_handler,
		.log_level = METAL_LOG_DEBUG,

	};
#else
	struct metal_init_params init_param = METAL_INIT_DEFAULTS;
#endif

	if (metal_init(&init_param))
	{
		xil_printf("ERROR: Failed to run metal initialization\n");
		return XRFDC_FAILURE;
	}

	/* Initialize the RFdc driver. */
	ConfigPtr = XRFdc_LookupConfig(RFDC_DEVICE_ID);
	if (ConfigPtr == NULL)
	{
		xil_printf("Failed to init RFdc driver\r\n");
		return XST_FAILURE;
	}
	else
	{
		xil_printf("\n\rDeviceID: %d \r\nSilicon Revision: %d\r\n", ConfigPtr->DeviceId, ConfigPtr->SiRevision);
	}

	/* Initializes the controller */
	Status = XRFdc_CfgInitialize(&RFdcInst, ConfigPtr);
	if (Status != XST_SUCCESS)
	{
		xil_printf("Failed to init RFdc controller\r\n");
		return XST_FAILURE;
	}
	else
	{
		xil_printf("The RFDC controller is initialized.\r\n");
	}
	// Display and verify the Power-on Status
	Status = rfdcStartup();
	if (Status != XST_SUCCESS)
	{
		return Status;
	}
	if (Configure_DAC_Output_Current() != XST_SUCCESS)
	{
		return XST_FAILURE;
	}

	// init_dma_ip(&AxiDma, CH0_DMA_DEV_ID, CH0_MM2S_INTR_ID, &INST);

	if (Init_GPIO() != XST_SUCCESS)
		return XST_FAILURE;

	init_lwip();

#if defined(BOARD_CUSTOM_XCZU47DR) && defined(ENABLE_FIRMWARE_DEBUG_WAVEFORM_PRELOAD)
	// DDR offsets 0/0x1000 are host-uploaded PL regions; firmware must not preload them.
	preload_debug_waveforms();
#endif

	// measure_dma_bandwidth();
	while (1)
	{
		if (TcpFastTmrFlag)
		{
			tcp_fasttmr();
			TcpFastTmrFlag = 0;
		}
		if (TcpSlowTmrFlag)
		{
			tcp_slowtmr();
			TcpSlowTmrFlag = 0;
		}
		xemacif_input(echo_netif);
		if (data_ready)
		{
			// data_len = 4096;
			// u32 delay_a = 100;
			// u32 delay_b = 200;
			// u32 combined = (delay_b << 16) | (delay_a & 0xFFFF);
			// Xil_Out32(GPIO_BASE_ADDR + GPIO_DATA_CH2_OFFSET, combined);
			// xil_printf("DMA cur_wave_delay=%d @%p\r\n",
			// 		   combined, &combined);

			// xil_printf("Data Buffer Preview (First 32 bytes):\r\n");
			// u8 *chk_ptr = (u8 *)data_buffer;
			// for (int i = 0; i < 32; i++)
			// {
			// 	xil_printf("%02X ", chk_ptr[i]);

			// 	if ((i + 1) % 16 == 0)
			// 	{
			// 		xil_printf("\r\n");
			// 	}
			// }
			// xil_printf("\r\n");

			// xil_printf("Starting DMA transfer...\r\n");
			// dma_transfer(&AxiDma, (u64)data_buffer, data_len);

			// while (XAxiDma_Busy(&AxiDma, XAXIDMA_DMA_TO_DEVICE))
			// 	;

			// xil_printf("DMA transfer complete.\n\r");
			data_ready = 0;
		}
	}

	return 0;
}

/*****************************************************************************/
/**
 *
 * My libmetal logger
 * Intercepts log prints and adjusts \r\n prints to display the some on a uart
 * or through a jtagUart.
 *
 ******************************************************************************/

void my_metal_default_log_handler(enum metal_log_level level,
								  const char *format, ...)
{
	char msg[1024];
	char msgOut[1048];
	char *outPtr;
	int i;

	va_list args;
	static const char *level_strs[] = {
		"metal: emergency: ",
		"metal: alert:     ",
		"metal: critical:  ",
		"metal: error:     ",
		"metal: warning:   ",
		"metal: notice:    ",
		"metal: info:      ",
		"metal: debug:     ",
	};

	va_start(args, format);
	vsnprintf(msg, sizeof(msg), format, args);
	va_end(args);

	// replace single \n with \n\r
	outPtr = msgOut;
	for (i = 0; i < 1024; i++)
	{
		// if /n/r or /r/n combo
		if ((msg[i] == '\r' && msg[i + 1] == '\n') ||
			(msg[i] == '\n' && msg[i + 1] == '\r'))
		{
			*outPtr++ = msg[i++];
		}
		else if (msg[i] == '\n')
		{
			// if first char in string is \n, then remove
			if (i == 0)
			{
				continue;
			}
			else
			{
				*outPtr++ = '\r';
			}
		}
		*outPtr++ = msg[i];
		if (msg[i] == 0)
		{
			break;
		}
	}
	// if line doesn't end with \n\r, then add it
	if ((msg[i - 1] != '\n') && (msg[i - 1] != '\r'))
	{
		*(outPtr - 1) = '\r';
		*outPtr++ = '\n';
		*outPtr++ = 0;
	}

	if (level <= METAL_LOG_EMERGENCY || level > METAL_LOG_DEBUG)
		level = METAL_LOG_EMERGENCY;

	xil_printf("%s%s", level_strs[level], msgOut);
}

/****************************************************************************/
/**
 *
 * This function resets all CLK_104 PLL I2C devices.
 *
 * @param	None
 *
 * @return
 *	- XST_SUCCESS if successful.
 *	- XST_FAILURE if failed.
 *
 * @note		None
 *
 ****************************************************************************/
#if defined(BOARD_ZCU216)
static int resetAllClk104(void)
{
	int ret = EXIT_FAILURE;
	//	printf("Reset LMK\n\r");
	if (XST_FAILURE == XRFClk_ResetChip(RFCLK_LMK))
	{
		printf("Failure in XRFClk_ResetChip(RFCLK_LMK)\n\r");
		return ret;
	}

	//	printf("Reset LMX2594_1\n\r");
	if (XST_FAILURE == XRFClk_ResetChip(RFCLK_LMX2594_1))
	{
		printf("Failure in XRFClk_ResetChip(RFCLK_LMX2594_1)\n\r");
		return ret;
	}

	//	printf("Reset LMX2594_2\n\r");
	if (XST_FAILURE == XRFClk_ResetChip(RFCLK_LMX2594_2))
	{
		printf("Failure in XRFClk_ResetChip(RFCLK_LMX2594_2)\n\r");
		return ret;
	}

#ifdef XPS_BOARD_ZCU111
	//	printf("Reset LMX2594_3\n\r");
	if (XST_FAILURE == XRFClk_ResetChip(RFCLK_LMX2594_3))
	{
		printf("Failure in XRFClk_ResetChip(RFCLK_LMX2594_3)\n\r");
		return ret;
	}
#endif

	return EXIT_SUCCESS;
}
#endif

#if defined(BOARD_ZCU216)
/****************************************************************************/
/**
 *
 * Print LMK PLL device settings such as input and output clk frequencies.
 * The instance structure is initialized by calling LMK_init()
 *
 * @param
 *	- lmkInstPtr a pointer to the LMK instance structure
 *
 * @return
 *	- void
 *
 * @note		None
 *
 ****************************************************************************/
void printLMKsettings(lmk_config_t *lmkInstPtr)
{

#ifdef LMK_DEBUG
	LMK_intermediateDump(lmkInstPtr);
#endif

	// Print LMK CLKin frequencies
	if (lmkInstPtr->clkin_sel_mode == LMK_CLKin_SEL_MODE_AUTO_MODE)
	{
		xil_printf("CLKin Auto Mode Enabled\n\r");
	}
	for (int i = 0; i < 3; i++)
	{
		if (lmkInstPtr->clkin[i].freq != -1)
		{
			xil_printf("CLKin%d_freq: %12ldKHz\n\r", i, lmkInstPtr->clkin[i].freq / 1000);
		}
	}

	// Print LMK CLKout frequencies
	for (int i = 0; i < 7; i++)
	{
		xil_printf("DCLKout%02d(%-10s):", i * 2, clkoutBrdNames[i * 2]);
		if (lmkInstPtr->clkout[i].dclk_freq == -1)
		{
			xil_printf("%12s", "-----");
		}
		else
		{
			xil_printf("%9ldKHz", lmkInstPtr->clkout[i].dclk_freq / 1000);
		}

		xil_printf(" SDCLKout%02d(%-15s):", i * 2 + 1, clkoutBrdNames[i * 2 + 1]);
		if (lmkInstPtr->clkout[i].sclk_freq == -1)
		{
			xil_printf("%12s\n\r", "-----");
		}
		else
		{
			xil_printf("%9ldKHz\n\r", lmkInstPtr->clkout[i].sclk_freq / 1000);
		}
	}
}

/****************************************************************************/
/**
 *
 * Print LMX PLL device output clk frequencies.
 * The instance structure is initialized by calling LMX_SettingsInit()
 *
 * @param
 * 	- clkin is the clk freq fed into the LMX PLL. This value is used to
 * 	  calculate and display the output frequencies
 *	- lmxInstPtr a pointer to the LMX instance structure
 *
 * @return
 *	- void
 *
 * @note		None
 *
 ****************************************************************************/
void printLMXsettings(long int clkin, lmx_config_t *lmxInstPtr)
{

#ifdef LMX_DEBUG
	LMX_intermediateDump(lmxInstPtr);
#endif

	// Print LMX CLKin freq
	xil_printf("CLKin_freq: %10ldKHz\n\r", clkin / 1000);

	// Print LMX CLKout frequencies
	xil_printf("RFoutA Freq:");
	if (lmxInstPtr->RFoutA_freq == -1)
	{
		xil_printf("%13s\n\r", "-----");
	}
	else
	{
		xil_printf("%10ldKHz\n\r", lmxInstPtr->RFoutA_freq / 1000);
	}

	xil_printf("RFoutB Freq:");
	if (lmxInstPtr->RFoutB_freq == -1)
	{
		xil_printf("%13s\n\r", "-----");
	}
	else
	{
		xil_printf("%10ldKHz\n\r", lmxInstPtr->RFoutB_freq / 1000);
	}
}

/****************************************************************************/
/**
 *
 * Reads the configuration of LMK and LMX PLL then calculates and displays
 * the PLL frequencies and settings.
 * The instance structures ar initialized by calling LMK_init() or
 * LMX_SettingsInit()
 *
 * @param
 * 	- nil
 *
 * @return
 *	- void
 *
 * @note		None
 *
 ****************************************************************************/
void printCLK104_settings(void)
{
	char pllNames[3][9] = {"LMK ----", "LMX_RF1", "LMX_RF2"};
	u32 chipIds[3] = {RFCLK_LMK, RFCLK_LMX2594_1, RFCLK_LMX2594_2};

	for (int i = 0; i < 3; i++)
	{
		if (XST_FAILURE == XRFClk_GetConfigFromOneChip(chipIds[i], data))
		{
			printf("Failure in XRFClk_GetConfigFromOneChip()\n\r");
			return;
		}

		// For LMX, reverse readback data to match exported register sets and
		// order of LMX2594[][]
		if (chipIds[i] != RFCLK_LMK)
		{
			reverse32bArray(data, LMX2594_COUNT - 3);
		}

#if 0
		// Dump raw data read from device
		printf("Config data is:\n\r");
		for (int j = 0; j < ((chipIds[i]==RFCLK_LMK) ? LMK_COUNT : LMX2594_COUNT-3); j++) {
			printf("%08X, ", data[j]);
			if( !(j % 6) ) printf("\n\r");
		}
		printf("\n\r");
#endif

		// Display clock values of device
		printf("Clk settings read from %s ---------------------\n\r", pllNames[i]);
		if (chipIds[i] == RFCLK_LMK)
		{
			LMK_init(data, &lmkConfig);
			printLMKsettings(&lmkConfig);
		}
		else
		{
			// clkout index is i=1 idx = 0, i=2 idx=2. i&2 meets this alg
			LMX_SettingsInit(lmkConfig.clkout[(i & 2)].dclk_freq, data, &lmxConfig);
			printLMXsettings(lmkConfig.clkout[(i & 2)].dclk_freq, &lmxConfig);
		}
		xil_printf("\n\r");
	}
}
#endif

void reverse32bArray(u32 *src, int size)
{
	u32 tmp[200];
	int i, j;

	// copy src into temp
	for (i = 0, j = size - 1; i < size; i++, j--)
	{
		tmp[i] = src[j];
	}

	// copy swapped array to original
	for (i = 0; i < size; i++)
	{
		src[i] = tmp[i];
	}
	return;
}

/*****************************************************************************/
/**
 *
 * Startup DAC's and ADC's
 *
 * @param	None
 *
 * @return	XST_SUCCESS if enabled RFDC tiles started, otherwise XST_FAILURE.
 *
 * @note		TBD
 *
 ******************************************************************************/
// void rfdcStartup (u32 *cmdVals) {
int rfdcStartup(void)
{

	int Tile_Id;
	int Status;
	XRFdc_IPStatus ipStatus;
	XRFdc *RFdcInstPtr = &RFdcInst;
	u32 val;
	//	u32 test;

	// Calling this function gets the status of the IP
	XRFdc_GetIPStatus(RFdcInstPtr, &ipStatus);

	xil_printf("\r\n###############################################\r\n");
	xil_printf("Data Converter startup up is in progress...\n\r");

	// Master Reset
	Xil_Out32(RFDC_BASE + 0x0004, 1);

	//	xil_printf("RF Data Converters Powered up.\r\n");
	sleep(1);

	// startup
	for (Tile_Id = 0; Tile_Id <= 3; Tile_Id++)
	{
		if (ipStatus.DACTileStatus[Tile_Id].IsEnabled == 1)
		{
			val = XRFdc_ReadReg16(RFdcInstPtr, XRFDC_DAC_TILE_CTRL_STATS_ADDR(Tile_Id), XRFDC_ADC_DEBUG_RST_OFFSET);
			if (val & XRFDC_DBG_RST_CAL_MASK)
			{
				xil_printf("DAC Tile: %d NOT ready.\r\n", Tile_Id);
				return XST_FAILURE;
			}
			else
			{
				Status = XRFdc_StartUp(RFdcInstPtr, 1, Tile_Id);
				if (Status != XST_SUCCESS)
				{
					xil_printf("XRFdc_StartUp failed for DAC Tile: %d status=%d\r\n", Tile_Id, Status);
					return XST_FAILURE;
				}
				usleep(200000);
			}
		}
	}

	for (Tile_Id = 0; Tile_Id <= 3; Tile_Id++)
	{
		if (ipStatus.ADCTileStatus[Tile_Id].IsEnabled == 1)
		{
			val = XRFdc_ReadReg16(RFdcInstPtr, XRFDC_ADC_TILE_CTRL_STATS_ADDR(Tile_Id), XRFDC_ADC_DEBUG_RST_OFFSET);
			if (val & XRFDC_DBG_RST_CAL_MASK)
			{
				xil_printf("ADC Tile: %d NOT ready.\r\n", Tile_Id);
				return XST_FAILURE;
			}
			else
			{
				Status = XRFdc_StartUp(RFdcInstPtr, 0, Tile_Id);
				if (Status != XST_SUCCESS)
				{
					xil_printf("XRFdc_StartUp failed for ADC Tile: %d status=%d\r\n", Tile_Id, Status);
					return XST_FAILURE;
				}
				usleep(200000);
			}
		}
	}

	XRFdc_GetIPStatus(RFdcInstPtr, &ipStatus);

	xil_printf("\r\nThe Power-on sequence step. 0xF is complete.\r\n");

	for (Tile_Id = 0; Tile_Id <= 3; Tile_Id++)
	{
		if (ipStatus.DACTileStatus[Tile_Id].IsEnabled == 1)
		{
			val = XRFdc_ReadReg16(RFdcInstPtr, XRFDC_DAC_TILE_CTRL_STATS_ADDR(Tile_Id), XRFDC_ADC_DEBUG_RST_OFFSET);
			if (val & XRFDC_DBG_RST_CAL_MASK)
			{
				xil_printf("DAC Tile: %d NOT ready.\r\n", Tile_Id);
				return XST_FAILURE;
			}
			else
			{
				xil_printf("DAC Tile: %d Power-on Sequence Step: 0x%08x\r\n", Tile_Id,
						   Xil_In32(RFDC_BASE + 0x0000C + 0x04000 + Tile_Id * 0x4000));
			}
		}
	}

	for (Tile_Id = 0; Tile_Id <= 3; Tile_Id++)
	{
		if (ipStatus.ADCTileStatus[Tile_Id].IsEnabled == 1)
		{
			val = XRFdc_ReadReg16(RFdcInstPtr, XRFDC_ADC_TILE_CTRL_STATS_ADDR(Tile_Id), XRFDC_ADC_DEBUG_RST_OFFSET);
			if (val & XRFDC_DBG_RST_CAL_MASK)
			{
				xil_printf("ADC Tile: %d NOT ready.\r\n", Tile_Id);
				return XST_FAILURE;
			}
			else
			{
				xil_printf("ADC Tile: %d Power-on Sequence Step: 0x%08x\r\n", Tile_Id,
						   Xil_In32(RFDC_BASE + 0x0000C + 0x14000 + Tile_Id * 0x4000));
			}
		}
	}

	xil_printf("\n\rData Converter start up is complete!");
	xil_printf("\r\n###############################################\r\n");

	return XST_SUCCESS;
}
