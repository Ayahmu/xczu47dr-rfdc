#ifndef __LWIP_H__
#define __LWIP_H__

#include "xil_printf.h"

// Stub implementation without lwip
struct netif {
    int dummy;  // Placeholder
};

// Global variables
extern volatile int TcpFastTmrFlag;
extern volatile int TcpSlowTmrFlag;
extern struct netif *echo_netif;

// Function declarations
void init_lwip();
void tcp_fasttmr(void);
void tcp_slowtmr(void);
void xemacif_input(struct netif *netif);

#endif /* __LWIP_H__ */
