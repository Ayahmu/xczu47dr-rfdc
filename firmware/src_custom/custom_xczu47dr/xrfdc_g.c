/******************************************************************************
* Custom RFDC configuration for the XCZU47DR target.
*
* The RFDC IP is instantiated outside the Vivado block design for this target,
* so Vitis cannot derive the usual XRFdc metadata from the XSA. This table keeps
* the standalone driver deterministic while preserving the fixed AXI-Lite base
* address and 5.0 GS/s DAC configuration used by the hardware flow.
******************************************************************************/

#ifdef __BAREMETAL__

#include "xparameters.h"
#include "xrfdc.h"

#define CUSTOM_RFDC_DAC_ANALOG_CFG                                                   \
	{                                                                                \
		.BlockAvailable = 1U, .InvSyncEnable = 0U,                                  \
		.MixMode = XRFDC_DAC_MIXER_MODE_REAL, .DecoderMode = 0U                    \
	}

#define CUSTOM_RFDC_DAC_DIGITAL_CFG                                                  \
	{                                                                                \
		.MixerInputDataType = XRFDC_DATA_TYPE_REAL, .DataWidth = 4U,               \
		.InterpolationMode = XRFDC_INTERP_DECIM_4X, .FifoEnable = 1U,              \
		.AdderEnable = 0U, .MixerType = XRFDC_MIXER_TYPE_COARSE, .NCOFreq = 0.0    \
	}

#define CUSTOM_RFDC_DAC_TILE_CFG(PLL_ENABLE)                                         \
	{                                                                                \
		.Enable = 1U, .PLLEnable = (PLL_ENABLE), .SamplingRate = 5.0,              \
		.RefClkFreq = 125.0, .FabClkFreq = 312.5, .FeedbackDiv = 40U,              \
		.OutputDiv = 1U, .RefClkDiv = 1U, .MultibandConfig = XRFDC_MB_MODE_SB,     \
		.MaxSampleRate = 5.0, .NumSlices = XRFDC_DUAL_TILE, .LinkCoupling = 0U,    \
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
			[2] = CUSTOM_RFDC_DAC_TILE_CFG(1U),
			[3] = CUSTOM_RFDC_DAC_TILE_CFG(0U)
		},
		.ADCTile_Config = {0}
	}
};

#endif
