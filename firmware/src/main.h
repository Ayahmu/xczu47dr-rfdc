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

// Necessary to use this define when using jtagterminal but not SDK jtaguart console
//#define STRIP_CHAR_CR

// Memory and GPIO definitions
#define DDR4_BASE 0x00000000  // DDR base address for ZynqMP
#define GPIO_BASE_ADDR XPAR_M_AXI_GPIO_BASEADDR
#define GPIO_TRI_CH1_OFFSET 0x04
#define GPIO_TRI_CH2_OFFSET 0x08

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
