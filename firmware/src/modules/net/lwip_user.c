#include "lwip_user.h"

// Global variables
volatile int TcpFastTmrFlag = 0;
volatile int TcpSlowTmrFlag = 0;

void init_lwip() {
    xil_printf("Network functionality disabled (lwip not available)\r\n");
}

void tcp_fasttmr(void) {
    // Empty stub
}

void tcp_slowtmr(void) {
    // Empty stub
}

void xemacif_input(struct netif *netif) {
    // Empty stub
    (void)netif;
}
