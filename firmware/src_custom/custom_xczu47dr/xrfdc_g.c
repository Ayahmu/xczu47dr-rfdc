/******************************************************************************
* Custom RFDC configuration for the XCZU47DR target.
*
* The RFDC IP is instantiated outside the Vivado block design for this target,
* so Vitis cannot derive the usual XRFdc metadata from the XSA. This table keeps
* the standalone driver deterministic while preserving the fixed AXI-Lite base
* address and 6.0 GS/s, 8x-interpolated, 8-output DAC configuration used by the
* hardware flow.
******************************************************************************/

#ifdef __BAREMETAL__

#include "xparameters.h"
#include "xrfdc.h"

/*
 * This config-table MixMode is not the same enum as XRFdc_Mixer_Settings.
 * The RFDC driver initialization path treats DAC analog MixMode 0 as C2R,
 * 1 as C2C, and XRFDC_MIXER_MODE_BYPASS (2) as bypass/real.
 */
#define CUSTOM_RFDC_DAC_CFG_MIXMODE_C2R 0U

#define CUSTOM_RFDC_DAC_ANALOG_CFG                                                   \
	{                                                                                \
		.BlockAvailable = 1U, .InvSyncEnable = 0U,                                  \
		.MixMode = CUSTOM_RFDC_DAC_CFG_MIXMODE_C2R, .DecoderMode = 0U              \
	}

#define CUSTOM_RFDC_DAC_DIGITAL_CFG                                                  \
	{                                                                                \
		.MixerInputDataType = XRFDC_DATA_TYPE_IQ, .DataWidth = 4U,                 \
		.InterpolationMode = XRFDC_INTERP_DECIM_8X, .FifoEnable = 1U,              \
		.AdderEnable = 0U, .MixerType = XRFDC_MIXER_TYPE_FINE, .NCOFreq = 1.5      \
	}

#define CUSTOM_RFDC_DAC_TILE_CFG(PLL_ENABLE)                                         \
	{                                                                                \
		.Enable = 1U, .PLLEnable = (PLL_ENABLE), .SamplingRate = 6.0,              \
		.RefClkFreq = 125.0, .FabClkFreq = 93.75, .FeedbackDiv = 48U,              \
		.OutputDiv = 1U, .RefClkDiv = 1U, .MultibandConfig = XRFDC_MB_MODE_SB,     \
		.MaxSampleRate = 6.0, .NumSlices = XRFDC_DUAL_TILE, .LinkCoupling = 0U,    \
		.DACBlock_Analog_Config = {                                                \
			[0] = CUSTOM_RFDC_DAC_ANALOG_CFG,                                     \
			[2] = CUSTOM_RFDC_DAC_ANALOG_CFG                                      \
		},                                                                         \
		.DACBlock_Digital_Config = {                                               \
			[0] = CUSTOM_RFDC_DAC_DIGITAL_CFG,                                    \
			[2] = CUSTOM_RFDC_DAC_DIGITAL_CFG                                     \
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
			[0] = CUSTOM_RFDC_DAC_TILE_CFG(0U),
			[1] = CUSTOM_RFDC_DAC_TILE_CFG(0U),
			[2] = CUSTOM_RFDC_DAC_TILE_CFG(1U),
			[3] = CUSTOM_RFDC_DAC_TILE_CFG(0U)
		},
		.ADCTile_Config = {0}
	}
};

#endif
