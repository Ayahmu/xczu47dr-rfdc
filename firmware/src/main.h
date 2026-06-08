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

// Necessary to use this define when using jtagterminal but not SDK jtaguart console
//#define STRIP_CHAR_CR

// Memory and GPIO definitions
#if defined(BOARD_CUSTOM_XCZU47DR) && defined(XPAR_DDR4_0_C0_DDR4_MEMORY_MAP_BASEADDR)
#define DDR4_BASE ((UINTPTR)XPAR_DDR4_0_C0_DDR4_MEMORY_MAP_BASEADDR)
#elif defined(BOARD_CUSTOM_XCZU47DR) && defined(XPAR_TOP_I_DESIGN_1_I_M_AXI_PS_DDR_BASEADDR)
#define DDR4_BASE ((UINTPTR)XPAR_TOP_I_DESIGN_1_I_M_AXI_PS_DDR_BASEADDR)
#elif defined(BOARD_CUSTOM_XCZU47DR)
#define DDR4_BASE ((UINTPTR)0x0000000500000000ULL)
#else
#define DDR4_BASE ((UINTPTR)0x00000000U)  // ZynqMP PS DDR base address
#endif
#define GPIO_BASE_ADDR XPAR_M_AXI_GPIO_BASEADDR
#define GPIO_DATA_CH1_OFFSET 0x00
#define GPIO_TRI_CH1_OFFSET 0x04
#define GPIO_DATA_CH2_OFFSET 0x08
#define GPIO_TRI_CH2_OFFSET 0x0C
#define HMC7044_DONE_MASK 0x80000000U

// RFDC defines
#define RFDC_DEVICE_ID 	XPAR_XRFDC_0_DEVICE_ID
#define RFDC_BASE       XPAR_XRFDC_0_BASEADDR

// Number of Tiles and Blocks in device
#define NUM_TILES 4
#define NUM_BLOCKS 4



/**************************** Type Definitions *******************************/


/***************** Macros (Inline Functions) Definitions *********************/


/************************** Function Prototypes *****************************/


/************************** Variable Definitions ****************************/

extern XRFdc RFdcInst;      /* RFdc driver instance */


#endif /* SRC_MAIN_H_ */
