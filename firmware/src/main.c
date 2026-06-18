
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

#include "platform/platform.h"
#include "modules/dma/dma_ctrl.h"

#include <metal/log.h>
#include <metal/sys.h>

/******************** Constant Definitions **********************************/
#define ENABLE_METAL_PRINTS

#if !defined(BOARD_CUSTOM_XCZU47DR)
#error "Define BOARD_CUSTOM_XCZU47DR"
#endif

#define URAM_PLAY_BASE XPAR_HIER_PLAY_AXI_BRAM_CTRL_0_S_AXI_BASEADDR

// XAxiDma AxiDma;

void my_metal_default_log_handler(enum metal_log_level level,
								  const char *format, ...);

void reverse32bArray(u32 *src, int size);
int rfdcStartup(void);
int Configure_DAC_Output_Current(void);
int Configure_Custom_DAC_Nyquist(void);
int Configure_Custom_DAC_NCO(double NcoFreqGHz);

/* Default baseband NCO frequency in GHz. Fs=6.0 GS/s Zone2 image:
 * RF = 6.0 + NcoFreqGHz. -1.5 GHz NCO => 4.5 GHz RF output. */
#define CUSTOM_DAC_NCO_DEFAULT_GHZ (-1.5)

/************************** Variable Definitions *****************************/

// VT100 esc sequences
char CHAR_ATTRIB_OFF[5] = "\x1B[0m";
char BOLD_ON[5] = "\x1B[1m";
char UNDERLINE_ON[5] = "\x1B[4m";
char BLINK_ON[5] = "\x1B[5m";
char REVERSE_ON[5] = "\x1B[5m";
char CLR_SCREEN[5] = "\x1B[2J";

#include "xtime_l.h"
#define TEST_LENGTH (32 * 1024 * 1024)

XRFdc RFdcInst; /* RFdc driver instance */

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
		{0, 0},
		{0, 2},
		{1, 0},
		{1, 2},
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

int Configure_Custom_DAC_Nyquist(void)
{
	static const struct {
		u32 Tile_Id;
		u32 Block_Id;
	} CustomDacBlocks[] = {
		{0, 0},
		{0, 2},
		{1, 0},
		{1, 2},
		{2, 0},
		{2, 2},
		{3, 0},
		{3, 2},
	};
	unsigned int i;

	for (i = 0; i < sizeof(CustomDacBlocks) / sizeof(CustomDacBlocks[0]); i++)
	{
		u32 Tile_Id = CustomDacBlocks[i].Tile_Id;
		u32 Block_Id = CustomDacBlocks[i].Block_Id;
		int Status = XRFdc_SetNyquistZone(&RFdcInst, XRFDC_DAC_TILE, Tile_Id, Block_Id, XRFDC_EVEN_NYQUIST_ZONE);

		if (Status != XST_SUCCESS)
		{
			xil_printf("XRFdc_SetNyquistZone Zone2 failed for DAC Tile%d Block%d status=%d\r\n",
				   Tile_Id, Block_Id, Status);
			return XST_FAILURE;
		}

		xil_printf("Success: DAC Tile%d Block%d Nyquist zone set to 2\r\n", Tile_Id, Block_Id);
	}

	return XST_SUCCESS;
}

/*
 * Fine NCO digital up-conversion. Baseband is at DC (the PL streams a constant
 * I level with Q=0), so the C2R fine mixer translates the tone entirely by the
 * NCO frequency. Because the baseband is a real DC level, the C2R real output
 * is cos(2*pi*f*t), which is identical for +f and -f: the sign of the NCO
 * frequency does not change the emitted tone. With Fs = 6.0 GS/s the |f| = 1.5
 * GHz fundamental aliases into Nyquist Zone 2 at 6.0 - 1.5 = 4.5 GHz, which the
 * analog front end selects.
 *
 * NcoFreqGHz is the signed baseband NCO frequency in GHz; the emitted Zone 2
 * tone is 6.0 - |NcoFreqGHz| (e.g. -1.5 or +1.5 -> 4.5 GHz, -2.0 -> 4.0 GHz,
 * -1.0 -> 5.0 GHz). This wrapper lets firmware retune the output across 4-5 GHz
 * at runtime without rebuilding the bitstream.
 */
int Configure_Custom_DAC_NCO(double NcoFreqGHz)
{
	static const struct {
		u32 Tile_Id;
		u32 Block_Id;
	} CustomDacBlocks[] = {
		{0, 0},
		{0, 2},
		{1, 0},
		{1, 2},
		{2, 0},
		{2, 2},
		{3, 0},
		{3, 2},
	};
	unsigned int i;

	for (i = 0; i < sizeof(CustomDacBlocks) / sizeof(CustomDacBlocks[0]); i++)
	{
		u32 Tile_Id = CustomDacBlocks[i].Tile_Id;
		u32 Block_Id = CustomDacBlocks[i].Block_Id;
		XRFdc_Mixer_Settings MixerSettings;
		int Status;

		Status = XRFdc_GetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, Tile_Id, Block_Id, &MixerSettings);
		if (Status != XST_SUCCESS)
		{
			xil_printf("XRFdc_GetMixerSettings failed for DAC Tile%d Block%d status=%d\r\n",
				   Tile_Id, Block_Id, Status);
			return XST_FAILURE;
		}

		MixerSettings.Freq = NcoFreqGHz * 1000.0; /* driver expects MHz */
		MixerSettings.PhaseOffset = 0.0;
		MixerSettings.EventSource = XRFDC_EVNT_SRC_IMMEDIATE;
		MixerSettings.CoarseMixFreq = XRFDC_COARSE_MIX_BYPASS;
		MixerSettings.MixerMode = XRFDC_MIXER_MODE_C2R;
		MixerSettings.FineMixerScale = XRFDC_MIXER_SCALE_1P0;
		MixerSettings.MixerType = XRFDC_MIXER_TYPE_FINE;

		Status = XRFdc_SetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, Tile_Id, Block_Id, &MixerSettings);
		if (Status != XST_SUCCESS)
		{
			xil_printf("XRFdc_SetMixerSettings failed for DAC Tile%d Block%d status=%d\r\n",
				   Tile_Id, Block_Id, Status);
			return XST_FAILURE;
		}

		XRFdc_UpdateEvent(&RFdcInst, XRFDC_DAC_TILE, Tile_Id, Block_Id, XRFDC_EVENT_MIXER);

		xil_printf("Success: DAC Tile%d Block%d NCO set to %d MHz (baseband)\r\n",
			   Tile_Id, Block_Id, (int)(NcoFreqGHz * 1000.0));
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
	if (Configure_Custom_DAC_Nyquist() != XST_SUCCESS)
	{
		return XST_FAILURE;
	}
	if (Configure_Custom_DAC_NCO(CUSTOM_DAC_NCO_DEFAULT_GHZ) != XST_SUCCESS)
	{
		return XST_FAILURE;
	}
	if (Configure_DAC_Output_Current() != XST_SUCCESS)
	{
		return XST_FAILURE;
	}

	// init_dma_ip(&AxiDma, CH0_DMA_DEV_ID, CH0_MM2S_INTR_ID, &INST);

	if (Init_GPIO() != XST_SUCCESS)
		return XST_FAILURE;

#if defined(ENABLE_FIRMWARE_DEBUG_WAVEFORM_PRELOAD)
	// DDR offsets 0/0x1000 are host-uploaded PL regions; firmware must not preload them.
	preload_debug_waveforms();
#endif

	// measure_dma_bandwidth();
	while (1)
	{
		sleep(1);
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
