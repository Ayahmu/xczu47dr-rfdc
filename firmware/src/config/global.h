#ifndef __GLOBAL_H__
#define __GLOBAL_H__

#include "xscugic.h"

#define CH0_MM2S_INTR_ID 121U
#define CH0_DMA_DEV_ID 0
#define CH0_DMA_BASE XPAR_M_AXI_DMA_BASEADDR

#define GPIO_BASE_ADDR 0xA0010000

#define GPIO_DATA_CH1_OFFSET 0x00
#define GPIO_TRI_CH1_OFFSET 0x04
#define GPIO_DATA_CH2_OFFSET 0x08
#define GPIO_TRI_CH2_OFFSET 0x0C

#define RFDC_DEVICE_ID XPAR_XRFDC_0_DEVICE_ID
#define RFDC_BASE XPAR_XRFDC_0_BASEADDR

#define DDR4_BASE (UINTPTR) XPAR_DDR4_0_C0_DDR4_MEMORY_MAP_BASEADDR
#define INST_FIFO_BASE XPAR_M_AXI_INST_BASEADDR

#define MAX_BUF_SIZE 8192

static uint32_t current_offset = 0;
static uint32_t expected_total_len = 0;

extern volatile u8 *data_buffer;
extern int data_len;
extern int data_ready;

extern u32 Ch0BdTxChainBuffer[0x40 * 16] __attribute__((aligned(64)));

extern volatile int TcpFastTmrFlag;
extern volatile int TcpSlowTmrFlag;
extern struct netif server_netif;
extern struct netif *echo_netif;

extern XScuGic INST;

#endif /* __GLOBAL_H__ */
