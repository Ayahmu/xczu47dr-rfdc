/******************************************************************************
* Custom RFDC configuration for the XCZU47DR target.
*
* The RFDC IP is instantiated outside the Vivado block design for this target,
* so Vitis cannot derive the usual XRFdc metadata from the XSA. This table keeps
* the standalone driver deterministic while preserving the fixed AXI-Lite base
* address and 6.4 GS/s, 16x-interpolated, 8-output DAC configuration used by
* the hardware flow.
******************************************************************************/

#ifdef __BAREMETAL__

#include "xparameters.h"
#include "xrfdc.h"

#if !defined(XPAR_XRFDC_NUM_INSTANCES)
#define XPAR_XRFDC_NUM_INSTANCES 1U
#endif

#if !defined(XPAR_XRFDC_0_DEVICE_ID)
#define XPAR_XRFDC_0_DEVICE_ID 0U
#endif

#if !defined(XPAR_XRFDC_0_BASEADDR)
#if defined(XPAR_TOP_I_DESIGN_1_I_M_AXI_RFDC_BASEADDR)
#define XPAR_XRFDC_0_BASEADDR XPAR_TOP_I_DESIGN_1_I_M_AXI_RFDC_BASEADDR
#else
#define XPAR_XRFDC_0_BASEADDR 0xA0040000U
#endif
#endif

/*
 * This config-table MixMode is not the same enum as XRFdc_Mixer_Settings.
 * The RFDC driver initialization path treats DAC analog MixMode 0 as C2R,
 * 1 as C2C, and XRFDC_MIXER_MODE_BYPASS (2) as bypass/real.
 */
#define CUSTOM_RFDC_DAC_CFG_MIXMODE_C2R 0U
/*
 * Vivado RFDC IP raw Link Coupling encoding for DAC tiles is AC=0, DC=1.
 * Keep this metadata aligned with the RFDC IP XCI so software status matches
 * the synthesized hardware configuration.
 */
#define CUSTOM_RFDC_DAC_LINK_COUPLING_AC 0U
#define CUSTOM_RFDC_DAC_LINK_COUPLING_DC 1U

#ifndef XRFDC_INTERP_DECIM_16X
#define XRFDC_INTERP_DECIM_16X 0x10U
#endif

#define CUSTOM_RFDC_DAC_ANALOG_CFG                                                   \
	{                                                                                \
		.BlockAvailable = 1U, .InvSyncEnable = 0U,                                  \
		.MixMode = CUSTOM_RFDC_DAC_CFG_MIXMODE_C2R, .DecoderMode = 0U              \
	}

#define CUSTOM_RFDC_DAC_DIGITAL_CFG(NCO_FREQ_GHZ)                                    \
	{                                                                                \
		.MixerInputDataType = XRFDC_DATA_TYPE_IQ, .DataWidth = 4U,                 \
		.InterpolationMode = XRFDC_INTERP_DECIM_16X, .FifoEnable = 1U,             \
		.AdderEnable = 0U, .MixerType = XRFDC_MIXER_TYPE_FINE,                    \
		.NCOFreq = (NCO_FREQ_GHZ)                                                  \
	}

#define CUSTOM_RFDC_DAC_TILE_CFG(PLL_ENABLE, LINK_COUPLING, BLOCK0_NCO_GHZ, BLOCK2_NCO_GHZ) \
	{                                                                                \
		.Enable = 1U, .PLLEnable = (PLL_ENABLE), .SamplingRate = 6.4,              \
		.RefClkFreq = 128.0, .FabClkFreq = 50.0, .FeedbackDiv = 100U,              \
		.OutputDiv = 2U, .RefClkDiv = 1U, .MultibandConfig = XRFDC_MB_MODE_SB,     \
		.MaxSampleRate = 7.0, .NumSlices = XRFDC_DUAL_TILE, .LinkCoupling = (LINK_COUPLING), \
		.DACBlock_Analog_Config = {                                                \
			[0] = CUSTOM_RFDC_DAC_ANALOG_CFG,                                     \
			[2] = CUSTOM_RFDC_DAC_ANALOG_CFG                                      \
		},                                                                         \
		.DACBlock_Digital_Config = {                                               \
			[0] = CUSTOM_RFDC_DAC_DIGITAL_CFG(BLOCK0_NCO_GHZ),                   \
			[2] = CUSTOM_RFDC_DAC_DIGITAL_CFG(BLOCK2_NCO_GHZ)                    \
		}                                                                          \
	}

XRFdc_Config XRFdc_ConfigTable[XPAR_XRFDC_NUM_INSTANCES] = {
	{
		.DeviceId = XPAR_XRFDC_0_DEVICE_ID,
		.BaseAddr = XPAR_XRFDC_0_BASEADDR,
		.ADCType = 0U,
		.MasterADCTile = 0U,
		.MasterDACTile = 2U,
		.ADCSysRefSource = 0U,
		.DACSysRefSource = 2U,
		.IPType = XRFDC_GEN3,
		.SiRevision = 0U,
		.DACTile_Config = {
			[0] = CUSTOM_RFDC_DAC_TILE_CFG(0U, CUSTOM_RFDC_DAC_LINK_COUPLING_AC, -1.9, -1.9),
			[1] = CUSTOM_RFDC_DAC_TILE_CFG(0U, CUSTOM_RFDC_DAC_LINK_COUPLING_AC, -1.9, -1.9),
			[2] = CUSTOM_RFDC_DAC_TILE_CFG(1U, CUSTOM_RFDC_DAC_LINK_COUPLING_DC, 0.0, 0.0),
			[3] = CUSTOM_RFDC_DAC_TILE_CFG(0U, CUSTOM_RFDC_DAC_LINK_COUPLING_AC, -0.6, -0.2)
		},
		.ADCTile_Config = {0}
	}
};

#endif
