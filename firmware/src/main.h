/*
 * main.h
 *
 *  Created on: Sep 17, 2017
 *      Author:
 */

#ifndef SRC_MAIN_H_
#define SRC_MAIN_H_

/***************************** Include Files ********************************/
#include "xparameters.h"
#include "xil_types.h"
#include "xrfdc.h"

/******************** Constant Definitions **********************************/

#if defined(BOARD_CUSTOM_XCZU47DR) && !defined(XPAR_XRFDC_NUM_INSTANCES)
#define XPAR_XRFDC_NUM_INSTANCES 1U
#define XPAR_XRFDC_0_DEVICE_ID 0U
#define XPAR_XRFDC_0_BASEADDR 0xA0040000U
#endif

#if defined(BOARD_CUSTOM_XCZU47DR) && !defined(XPAR_M_AXI_GPIO_BASEADDR)
#if defined(XPAR_TOP_I_DESIGN_1_I_M_AXI_GPIO_BASEADDR)
#define XPAR_M_AXI_GPIO_BASEADDR XPAR_TOP_I_DESIGN_1_I_M_AXI_GPIO_BASEADDR
#else
#define XPAR_M_AXI_GPIO_BASEADDR 0xA0010000U
#endif
#endif

/* PL firmware status register (firmware_status_reg.v): write the status word,
 * read back the HMC7044 done flag in bit 31. */
#define GPIO_BASE_ADDR XPAR_M_AXI_GPIO_BASEADDR
#define GPIO_DATA_CH2_OFFSET 0x08
#define HMC7044_DONE_MASK 0x80000000U
#define HMC7044_INPUT_REF_HZ 250000000U
#define HMC7044_PLL1_PFD_HZ 10000000U
#define HMC7044_DAC_REFCLK_HZ 128000000U

// RFDC defines
#define RFDC_DEVICE_ID 	XPAR_XRFDC_0_DEVICE_ID
#define RFDC_BASE       XPAR_XRFDC_0_BASEADDR

// Number of DAC tiles in the device
#define NUM_TILES 4



/**************************** Type Definitions *******************************/


/***************** Macros (Inline Functions) Definitions *********************/


/************************** Function Prototypes *****************************/


/************************** Variable Definitions ****************************/

extern XRFdc RFdcInst;      /* RFdc driver instance */


#endif /* SRC_MAIN_H_ */
