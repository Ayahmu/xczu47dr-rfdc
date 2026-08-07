
#ifndef BOARD_CUSTOM_XCZU47DR_BW

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
int Configure_DAC_MTS(void);
int Configure_DAC_Output_Current(void);
int Configure_Custom_DAC_Nyquist(void);
int Configure_Custom_DAC_NCO(void);
void Wait_Before_DAC_MTS(void);
int Align_DAC_NCO_To_SYSREF(void);
int Report_Custom_DAC_Status(const char *Stage);
int Poll_Rfdc_Nco_Mailbox(void);

/* Default 6.4 GS/s role map:
 * CH1-CH4 XY: target 4.5 GHz, Zone2 image, NCO = -1.9 GHz.
 * CH5-CH6 Z: baseband/DC envelope, NCO = 0 GHz, Zone1.
 * CH7-CH8 Readout: target 5.8/6.2 GHz, Zone2 images,
 * NCO = target - 6.4 GHz.
 */
#define CUSTOM_DAC_FS_GHZ (6.4)
#define RFDC_CTRL_MAILBOX_OFFSET 0x0FF00000U
#define RFDC_CTRL_MAILBOX_MAGIC_LO 0x43444652U /* "RFDCNCO0" little-endian */
#define RFDC_CTRL_MAILBOX_MAGIC_HI 0x304F434EU
#define RFDC_CTRL_MAILBOX_BYTES 160U
#define RFDC_CTRL_MAILBOX_HEADER_WORDS 8U
#define RFDC_CTRL_MAILBOX_ENTRY_WORDS 4U
#define RFDC_CTRL_MAILBOX_APPLY_IMMEDIATE 0x1U
#define RFDC_DAC_MTS_REF_TILE 2U
#define RFDC_DAC_SYSREF_ALIGN_DELAY_SEC 2U

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

typedef struct {
	u32 Tile_Id;
	u32 Block_Id;
	const char *Channel;
	const char *Role;
	double DefaultNcoGHz;
	u32 DefaultNyquistZone;
} CustomDacChannel;

static const CustomDacChannel CustomDacChannels[] = {
	{0, 0, "CH1", "XY", -1.9, XRFDC_EVEN_NYQUIST_ZONE},
	{0, 2, "CH2", "XY", -1.9, XRFDC_EVEN_NYQUIST_ZONE},
	{1, 0, "CH3", "XY", -1.9, XRFDC_EVEN_NYQUIST_ZONE},
	{1, 2, "CH4", "XY", -1.9, XRFDC_EVEN_NYQUIST_ZONE},
	{2, 0, "CH5", "Z", 0.0, XRFDC_ODD_NYQUIST_ZONE},
	{2, 2, "CH6", "Z", 0.0, XRFDC_ODD_NYQUIST_ZONE},
	{3, 0, "CH7", "Readout", -0.6, XRFDC_EVEN_NYQUIST_ZONE},
	{3, 2, "CH8", "Readout", -0.2, XRFDC_EVEN_NYQUIST_ZONE},
};

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
	unsigned int i;

	for (i = 0; i < sizeof(CustomDacChannels) / sizeof(CustomDacChannels[0]); i++)
	{
		if (Adjust_DAC_Power(CustomDacChannels[i].Tile_Id, CustomDacChannels[i].Block_Id, 20) != XST_SUCCESS)
		{
			return XST_FAILURE;
		}
	}

	return XST_SUCCESS;
}

int Configure_DAC_MTS(void)
{
	XRFdc *RFdcInstPtr = &RFdcInst;
	XRFdc_IPStatus ipStatus;
	XRFdc_MultiConverter_Sync_Config DACSyncConfig = {0};
	u32 enabledTiles = 0U;
	u32 refTile = RFDC_DAC_MTS_REF_TILE;
	int Tile_Id;
	u32 Status;

	XRFdc_GetIPStatus(RFdcInstPtr, &ipStatus);

	for (Tile_Id = 0; Tile_Id <= 3; Tile_Id++)
	{
		if (ipStatus.DACTileStatus[Tile_Id].IsEnabled == 1)
		{
			enabledTiles |= (1U << Tile_Id);
		}
	}

	if (enabledTiles == 0U)
	{
		xil_printf("RFDC DAC MTS failed: no enabled DAC tiles.\r\n");
		return XST_FAILURE;
	}

	if ((enabledTiles & (1U << refTile)) == 0U)
	{
		for (Tile_Id = 0; Tile_Id <= 3; Tile_Id++)
		{
			if ((enabledTiles & (1U << Tile_Id)) != 0U)
			{
				refTile = (u32)Tile_Id;
				break;
			}
		}
	}

	Status = XRFdc_MultiConverter_Init(&DACSyncConfig, NULL, NULL, refTile);
	if (Status != XRFDC_MTS_OK)
	{
		xil_printf("RFDC DAC MTS init failed: status=0x%08lx ref_tile=%lu\r\n",
			   (unsigned long)Status,
			   (unsigned long)refTile);
		return XST_FAILURE;
	}

	DACSyncConfig.Tiles = enabledTiles;
	DACSyncConfig.SysRef_Enable = 1;

	xil_printf("RFDC DAC MTS start: tiles=0x%08lx ref_tile=%lu\r\n",
		   (unsigned long)DACSyncConfig.Tiles,
		   (unsigned long)DACSyncConfig.RefTile);

	xil_printf("Checking DAC Tiles PLL status and configuration...\r\n");
	XRFdc_GetIPStatus(RFdcInstPtr, &ipStatus);
	for (Tile_Id = 0; Tile_Id <= 3; Tile_Id++)
	{
		if (ipStatus.DACTileStatus[Tile_Id].IsEnabled == 1)
		{
			XRFdc_PLL_Settings PLLSettings = {0};
			u32 PLLStatus = XRFdc_GetPLLConfig(RFdcInstPtr, XRFDC_DAC_TILE, Tile_Id, &PLLSettings);

			if (PLLStatus == XST_SUCCESS)
			{
				xil_printf("  DAC Tile%d: PLLState=%lu enabled=%lu refclk=%lu MHz sample=%lu MSPS "
					   "refdiv=%lu fbdiv=%lu outdiv=%lu\r\n",
					   Tile_Id,
					   (unsigned long)ipStatus.DACTileStatus[Tile_Id].PLLState,
					   (unsigned long)PLLSettings.Enabled,
					   (unsigned long)(PLLSettings.RefClkFreq + 0.5),
					   (unsigned long)(PLLSettings.SampleRate * 1000.0 + 0.5),
					   (unsigned long)PLLSettings.RefClkDivider,
					   (unsigned long)PLLSettings.FeedbackDivider,
					   (unsigned long)PLLSettings.OutputDivider);
			}
			else
			{
				xil_printf("  DAC Tile%d: PLLState=%lu XRFdc_GetPLLConfig failed status=%lu\r\n",
					   Tile_Id,
					   (unsigned long)ipStatus.DACTileStatus[Tile_Id].PLLState,
					   (unsigned long)PLLStatus);
			}
		}
	}

	Status = XRFdc_MultiConverter_Sync(RFdcInstPtr, XRFDC_DAC_TILE, &DACSyncConfig);
	if (Status != XRFDC_MTS_OK)
	{
		xil_printf("RFDC DAC MTS sync failed: status=0x%08lx tiles=0x%08lx ref_tile=%lu\r\n",
			   (unsigned long)Status,
			   (unsigned long)DACSyncConfig.Tiles,
			   (unsigned long)DACSyncConfig.RefTile);
		xil_printf("  decoded:%s%s%s%s%s%s%s%s%s%s%s%s\r\n",
			   (Status & XRFDC_MTS_NOT_SUPPORTED) ? " NOT_SUPPORTED" : "",
			   (Status & XRFDC_MTS_TIMEOUT) ? " TIMEOUT" : "",
			   (Status & XRFDC_MTS_MARKER_RUN) ? " MARKER_RUN" : "",
			   (Status & XRFDC_MTS_MARKER_MISM) ? " MARKER_MISM" : "",
			   (Status & XRFDC_MTS_DELAY_OVER) ? " DELAY_OVER" : "",
			   (Status & XRFDC_MTS_TARGET_LOW) ? " TARGET_LOW" : "",
			   (Status & XRFDC_MTS_IP_NOT_READY) ? " IP_NOT_READY" : "",
			   (Status & XRFDC_MTS_DTC_INVALID) ? " DTC_INVALID" : "",
			   (Status & XRFDC_MTS_NOT_ENABLED) ? " NOT_ENABLED" : "",
			   (Status & XRFDC_MTS_SYSREF_GATE_ERROR) ? " SYSREF_GATE_ERROR" : "",
			   (Status & XRFDC_MTS_SYSREF_FREQ_NDONE) ? " SYSREF_FREQ_NDONE" : "",
			   (Status & XRFDC_MTS_BAD_REF_TILE) ? " BAD_REF_TILE" : "");
		for (Tile_Id = 0; Tile_Id <= 3; Tile_Id++)
		{
			if ((DACSyncConfig.Tiles & (1U << Tile_Id)) != 0U)
			{
				xil_printf("  Tile%d: pll_target=%d pll_dtc=%d t1_target=%d t1_dtc=%d "
					   "latency=%d offset=%d\r\n",
					   Tile_Id,
					   DACSyncConfig.DTC_Set_PLL.Target[Tile_Id],
					   DACSyncConfig.DTC_Set_PLL.DTC_Code[Tile_Id],
					   DACSyncConfig.DTC_Set_T1.Target[Tile_Id],
					   DACSyncConfig.DTC_Set_T1.DTC_Code[Tile_Id],
					   DACSyncConfig.Latency[Tile_Id],
					   DACSyncConfig.Offset[Tile_Id]);
			}
		}
		xil_printf("  target_latency=%d marker_delay=%d\r\n",
			   DACSyncConfig.Target_Latency,
			   DACSyncConfig.Marker_Delay);
		return XST_FAILURE;
	}

	for (Tile_Id = 0; Tile_Id <= 3; Tile_Id++)
	{
		if ((DACSyncConfig.Tiles & (1U << Tile_Id)) != 0U)
		{
			xil_printf("RFDC DAC MTS Tile%d: pll_dtc=%d t1_dtc=%d latency=%d offset=%d\r\n",
				   Tile_Id,
				   DACSyncConfig.DTC_Set_PLL.DTC_Code[Tile_Id],
				   DACSyncConfig.DTC_Set_T1.DTC_Code[Tile_Id],
				   DACSyncConfig.Latency[Tile_Id],
				   DACSyncConfig.Offset[Tile_Id]);
		}
	}

	xil_printf("RFDC DAC MTS complete: target_latency=%d marker_delay=%d\r\n",
		   DACSyncConfig.Target_Latency,
		   DACSyncConfig.Marker_Delay);

	return XST_SUCCESS;
}

int Report_Custom_DAC_Status(const char *Stage)
{
	XRFdc *RFdcInstPtr = &RFdcInst;
	unsigned int i;

	xil_printf("RFDC DAC status readback (%s):\r\n", Stage);
	for (i = 0; i < sizeof(CustomDacChannels) / sizeof(CustomDacChannels[0]); i++)
	{
		u32 Tile_Id = CustomDacChannels[i].Tile_Id;
		u32 Block_Id = CustomDacChannels[i].Block_Id;
		u32 Coupling = 0U;
		u32 NyquistZone = 0U;
		u32 Interp = 0U;
		u32 OutputCurr = 0U;
		u32 RawCoupling = XRFdc_ReadReg(RFdcInstPtr,
						 XRFDC_CTRL_STS_BASE(XRFDC_DAC_TILE, Tile_Id),
						 XRFDC_CPL_TYPE_OFFSET);
		XRFdc_Mixer_Settings MixerSettings;
		int CouplingStatus = XRFdc_GetCoupling(RFdcInstPtr, XRFDC_DAC_TILE, Tile_Id, Block_Id, &Coupling);
		int NyquistStatus = XRFdc_GetNyquistZone(RFdcInstPtr, XRFDC_DAC_TILE, Tile_Id, Block_Id, &NyquistZone);
		int InterpStatus = XRFdc_GetInterpolationFactor(RFdcInstPtr, Tile_Id, Block_Id, &Interp);
		int MixerStatus = XRFdc_GetMixerSettings(RFdcInstPtr, XRFDC_DAC_TILE, Tile_Id, Block_Id, &MixerSettings);
		int CurrentStatus = XRFdc_GetOutputCurr(RFdcInstPtr, Tile_Id, Block_Id, &OutputCurr);

		xil_printf("  %s Tile%lu Block%lu role=%s coupling=%s(status=%d raw_cpl=0x%08lx) "
			   "nyquist=%lu(status=%d) interp=%lu(status=%d) "
			   "nco=%d MHz mixer_mode=%lu mixer_type=%u(status=%d) current_uA=%lu(status=%d)\r\n",
			   CustomDacChannels[i].Channel,
			   (unsigned long)Tile_Id,
			   (unsigned long)Block_Id,
			   CustomDacChannels[i].Role,
			   (CouplingStatus == XST_SUCCESS) ?
				   ((Coupling == XRFDC_LINK_COUPLING_DC) ? "DC" : "AC") :
				   "UNKNOWN",
			   CouplingStatus,
			   (unsigned long)RawCoupling,
			   (unsigned long)NyquistZone,
			   NyquistStatus,
			   (unsigned long)Interp,
			   InterpStatus,
			   (MixerStatus == XST_SUCCESS) ? (int)MixerSettings.Freq : 0,
			   (MixerStatus == XST_SUCCESS) ? (unsigned long)MixerSettings.MixerMode : 0UL,
			   (MixerStatus == XST_SUCCESS) ? (unsigned int)MixerSettings.MixerType : 0U,
			   MixerStatus,
			   (unsigned long)OutputCurr,
			   CurrentStatus);
	}

	return XST_SUCCESS;
}

int Configure_Custom_DAC_Nyquist(void)
{
	unsigned int i;

	for (i = 0; i < sizeof(CustomDacChannels) / sizeof(CustomDacChannels[0]); i++)
	{
		u32 Tile_Id = CustomDacChannels[i].Tile_Id;
		u32 Block_Id = CustomDacChannels[i].Block_Id;
		u32 NyquistZone = CustomDacChannels[i].DefaultNyquistZone;
		int Status = XRFdc_SetNyquistZone(&RFdcInst, XRFDC_DAC_TILE, Tile_Id, Block_Id, NyquistZone);

		if (Status != XST_SUCCESS)
		{
			xil_printf("XRFdc_SetNyquistZone Zone%d failed for DAC Tile%d Block%d status=%d\r\n",
				   (unsigned int)NyquistZone, Tile_Id, Block_Id, Status);
			return XST_FAILURE;
		}

		xil_printf("Success: DAC Tile%d Block%d Nyquist zone set to %u\r\n",
			   Tile_Id, Block_Id, (unsigned int)NyquistZone);
	}

	return XST_SUCCESS;
}

int Configure_Custom_DAC_NCO(void)
{
	unsigned int i;

	for (i = 0; i < sizeof(CustomDacChannels) / sizeof(CustomDacChannels[0]); i++)
	{
		u32 Tile_Id = CustomDacChannels[i].Tile_Id;
		u32 Block_Id = CustomDacChannels[i].Block_Id;
		double NcoFreqGHz = CustomDacChannels[i].DefaultNcoGHz;
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

		Status = XRFdc_UpdateEvent(&RFdcInst, XRFDC_DAC_TILE, Tile_Id, Block_Id, XRFDC_EVENT_MIXER);
		if (Status != XST_SUCCESS)
		{
			xil_printf("XRFdc_UpdateEvent failed for DAC Tile%d Block%d status=%d\r\n",
				   Tile_Id, Block_Id, Status);
			return XST_FAILURE;
		}

		xil_printf("Success: DAC Tile%d Block%d role=%s NCO set to %d MHz (baseband)\r\n",
			   Tile_Id, Block_Id, CustomDacChannels[i].Role, (int)(NcoFreqGHz * 1000.0));
	}

	return XST_SUCCESS;
}

void Wait_Before_DAC_MTS(void)
{
	xil_printf("Waiting %lu seconds before DAC MTS SYSREF alignment...\r\n",
		   (unsigned long)RFDC_DAC_SYSREF_ALIGN_DELAY_SEC);
	sleep(RFDC_DAC_SYSREF_ALIGN_DELAY_SEC);
}

int Align_DAC_NCO_To_SYSREF(void)
{
	unsigned int i;

	xil_printf("Aligning DAC NCO phase/update events to SYSREF.\r\n");

	for (i = 0; i < sizeof(CustomDacChannels) / sizeof(CustomDacChannels[0]); i++)
	{
		u32 Tile_Id = CustomDacChannels[i].Tile_Id;
		u32 Block_Id = CustomDacChannels[i].Block_Id;
		XRFdc_Mixer_Settings MixerSettings;
		int Status;

		Status = XRFdc_GetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, Tile_Id, Block_Id, &MixerSettings);
		if (Status != XST_SUCCESS)
		{
			xil_printf("SYSREF align: XRFdc_GetMixerSettings failed for DAC Tile%d Block%d status=%d\r\n",
				   Tile_Id, Block_Id, Status);
			return XST_FAILURE;
		}

		MixerSettings.EventSource = XRFDC_EVNT_SRC_SYSREF;
		MixerSettings.PhaseOffset = 0.0;

		Status = XRFdc_SetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, Tile_Id, Block_Id, &MixerSettings);
		if (Status != XST_SUCCESS)
		{
			xil_printf("SYSREF align: XRFdc_SetMixerSettings failed for DAC Tile%d Block%d status=%d\r\n",
				   Tile_Id, Block_Id, Status);
			return XST_FAILURE;
		}

		Status = XRFdc_ResetNCOPhase(&RFdcInst, XRFDC_DAC_TILE, Tile_Id, Block_Id);
		if (Status != XST_SUCCESS)
		{
			xil_printf("SYSREF align: XRFdc_ResetNCOPhase failed for DAC Tile%d Block%d status=%d\r\n",
				   Tile_Id, Block_Id, Status);
			return XST_FAILURE;
		}

		xil_printf("SYSREF align: %s Tile%d Block%d armed for next SYSREF NCO update/reset\r\n",
			   CustomDacChannels[i].Channel, Tile_Id, Block_Id);
	}

	xil_printf("DAC NCO SYSREF alignment complete.\r\n");

	return XST_SUCCESS;
}

static int Apply_Custom_DAC_Channel_NCO(unsigned int ChannelIndex, s64 NcoHz, u32 NyquistZone)
{
	const CustomDacChannel *Channel;
	XRFdc_Mixer_Settings MixerSettings;
	int Status;

	if (ChannelIndex >= (sizeof(CustomDacChannels) / sizeof(CustomDacChannels[0])))
	{
		return XST_FAILURE;
	}
	if ((NyquistZone != XRFDC_ODD_NYQUIST_ZONE) && (NyquistZone != XRFDC_EVEN_NYQUIST_ZONE))
	{
		xil_printf("RFDC mailbox: invalid Nyquist zone %lu for CH%u\r\n",
			   (unsigned long)NyquistZone, ChannelIndex + 1U);
		return XST_FAILURE;
	}

	Channel = &CustomDacChannels[ChannelIndex];
	Status = XRFdc_SetNyquistZone(&RFdcInst, XRFDC_DAC_TILE, Channel->Tile_Id, Channel->Block_Id, NyquistZone);
	if (Status != XST_SUCCESS)
	{
		xil_printf("RFDC mailbox: XRFdc_SetNyquistZone failed for %s Tile%lu Block%lu status=%d\r\n",
			   Channel->Channel, (unsigned long)Channel->Tile_Id, (unsigned long)Channel->Block_Id, Status);
		return XST_FAILURE;
	}

	Status = XRFdc_GetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, Channel->Tile_Id, Channel->Block_Id, &MixerSettings);
	if (Status != XST_SUCCESS)
	{
		xil_printf("RFDC mailbox: XRFdc_GetMixerSettings failed for %s Tile%lu Block%lu status=%d\r\n",
			   Channel->Channel, (unsigned long)Channel->Tile_Id, (unsigned long)Channel->Block_Id, Status);
		return XST_FAILURE;
	}

	MixerSettings.Freq = ((double)NcoHz) / 1000000.0; /* driver expects MHz */
	MixerSettings.PhaseOffset = 0.0;
	MixerSettings.EventSource = XRFDC_EVNT_SRC_SYSREF;
	MixerSettings.CoarseMixFreq = XRFDC_COARSE_MIX_BYPASS;
	MixerSettings.MixerMode = XRFDC_MIXER_MODE_C2R;
	MixerSettings.FineMixerScale = XRFDC_MIXER_SCALE_1P0;
	MixerSettings.MixerType = XRFDC_MIXER_TYPE_FINE;

	Status = XRFdc_SetMixerSettings(&RFdcInst, XRFDC_DAC_TILE, Channel->Tile_Id, Channel->Block_Id, &MixerSettings);
	if (Status != XST_SUCCESS)
	{
		xil_printf("RFDC mailbox: XRFdc_SetMixerSettings failed for %s Tile%lu Block%lu status=%d\r\n",
			   Channel->Channel, (unsigned long)Channel->Tile_Id, (unsigned long)Channel->Block_Id, Status);
		return XST_FAILURE;
	}

	Status = XRFdc_ResetNCOPhase(&RFdcInst, XRFDC_DAC_TILE, Channel->Tile_Id, Channel->Block_Id);
	if (Status != XST_SUCCESS)
	{
		xil_printf("RFDC mailbox: XRFdc_ResetNCOPhase failed for %s Tile%lu Block%lu status=%d\r\n",
			   Channel->Channel, (unsigned long)Channel->Tile_Id, (unsigned long)Channel->Block_Id, Status);
		return XST_FAILURE;
	}

	xil_printf("RFDC mailbox: %s role=%s Tile%lu Block%lu zone=%lu nco=%d MHz armed for SYSREF update\r\n",
	   Channel->Channel,
	   Channel->Role,
		   (unsigned long)Channel->Tile_Id,
		   (unsigned long)Channel->Block_Id,
		   (unsigned long)NyquistZone,
		   (int)(NcoHz / 1000000LL));
	return XST_SUCCESS;
}

int Poll_Rfdc_Nco_Mailbox(void)
{
	static u32 LastSeq = 0U;
	UINTPTR MailboxAddr = (UINTPTR)DDR4_BASE + RFDC_CTRL_MAILBOX_OFFSET;
	volatile u32 *Mailbox = (volatile u32 *)MailboxAddr;
	u32 Seq;
	u32 ApplyMask;
	u32 Flags;
	unsigned int i;

	Xil_DCacheInvalidateRange(MailboxAddr, RFDC_CTRL_MAILBOX_BYTES);

	if ((Mailbox[0] != RFDC_CTRL_MAILBOX_MAGIC_LO) || (Mailbox[1] != RFDC_CTRL_MAILBOX_MAGIC_HI))
	{
		return XST_SUCCESS;
	}

	Seq = Mailbox[2];
	if ((Seq == 0U) || (Seq == LastSeq))
	{
		return XST_SUCCESS;
	}

	ApplyMask = Mailbox[3] & 0xFFU;
	Flags = Mailbox[4];
	xil_printf("RFDC mailbox: seq=%lu apply_mask=0x%02lx flags=0x%08lx\r\n",
		   (unsigned long)Seq, (unsigned long)ApplyMask, (unsigned long)Flags);

	for (i = 0; i < sizeof(CustomDacChannels) / sizeof(CustomDacChannels[0]); i++)
	{
		volatile u32 *Entry;
		u64 RawNcoHz;
		s64 NcoHz;
		u32 Zone;

		if ((ApplyMask & (1U << i)) == 0U)
		{
			continue;
		}

		Entry = &Mailbox[RFDC_CTRL_MAILBOX_HEADER_WORDS + (i * RFDC_CTRL_MAILBOX_ENTRY_WORDS)];
		RawNcoHz = ((u64)Entry[1] << 32) | (u64)Entry[0];
		NcoHz = (s64)RawNcoHz;
		Zone = Entry[2];
		if (Apply_Custom_DAC_Channel_NCO(i, NcoHz, Zone) != XST_SUCCESS)
		{
			return XST_FAILURE;
		}
	}

	LastSeq = Seq;
	Report_Custom_DAC_Status("after RFDC mailbox retune");
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
	char start_command;
	XRFdc_Config *ConfigPtr;
	init_platform();

	// Initialize CLI commands structure

	xil_printf("\n\r###############################################\n\r");
	xil_printf("Hello RFSoC World!\n\r\n");
	xil_printf("RFDC playback target: Fs=6.4 GS/s, interpolation=16x, IQ sample=400 MS/s, AXIS=50 MHz, layout=interleaved_512b\r\n");
	xil_printf("RFDC runtime retune mailbox: DDR offset=0x%08lx magic=RFDCNCO0\r\n",
		   (unsigned long)RFDC_CTRL_MAILBOX_OFFSET);

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

	/* Match the engineer test flow: synchronize HMC7044 first, then arm RFDC. */
	xil_printf("\r\nRFDC initialization is paused.\r\n");
	xil_printf("Confirm HMC7044 PLL lock, complete the VIO SYNC sequence, and verify SYSREF is stable.\r\n");
	xil_printf("Type S to initialize RFDC and run MTS: ");
	do
	{
		start_command = inbyte();
	} while ((start_command != 'S') && (start_command != 's'));
	xil_printf("%c\r\n", start_command);
	xil_printf("Starting RFDC initialization and MTS...\r\n");
	sleep(2);

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
	Report_Custom_DAC_Status("after startup");
	if (Configure_Custom_DAC_Nyquist() != XST_SUCCESS)
	{
		return XST_FAILURE;
	}
	if (Configure_Custom_DAC_NCO() != XST_SUCCESS)
	{
		return XST_FAILURE;
	}
	if (Configure_DAC_Output_Current() != XST_SUCCESS)
	{
		return XST_FAILURE;
	}
	Report_Custom_DAC_Status("after custom config");
	Wait_Before_DAC_MTS();
	Status = Configure_DAC_MTS();
	if (Status != XST_SUCCESS)
	{
		return Status;
	}
	Report_Custom_DAC_Status("after DAC MTS");
	if (Align_DAC_NCO_To_SYSREF() != XST_SUCCESS)
	{
		return XST_FAILURE;
	}
	Report_Custom_DAC_Status("after SYSREF NCO align");

	// init_dma_ip(&AxiDma, CH0_DMA_DEV_ID, CH0_MM2S_INTR_ID, &INST);

	if (Init_GPIO() != XST_SUCCESS)
		return XST_FAILURE;

#if defined(ENABLE_FIRMWARE_DEBUG_WAVEFORM_PRELOAD)
		// Host uploads all PL DDR waveform slots; firmware must not preload them.
	preload_debug_waveforms();
#endif

	// measure_dma_bandwidth();
	while (1)
	{
		if (Poll_Rfdc_Nco_Mailbox() != XST_SUCCESS)
		{
			xil_printf("ERROR: RFDC mailbox retune failed.\r\n");
		}
		usleep(100000);
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
 * Startup DAC tiles for the UDP-to-DAC path.
 *
 * @param	None
 *
 * @return	XST_SUCCESS if enabled DAC tiles started, otherwise XST_FAILURE.
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

	XRFdc_GetIPStatus(RFdcInstPtr, &ipStatus);

	xil_printf("\r\nThe Power-on sequence step. 0xF is complete.\r\n");
	xil_printf("ADC Tile startup and status checks are skipped (DAC-only mode).\r\n");

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

	xil_printf("\n\rData Converter start up is complete!");
	xil_printf("\r\n###############################################\r\n");

	return XST_SUCCESS;
}

#endif /* BOARD_CUSTOM_XCZU47DR_BW */
