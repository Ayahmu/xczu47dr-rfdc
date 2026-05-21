#ifndef __LWIP_H__
#define __LWIP_H__

#include "lwip/tcp.h"
#include "netif/xadapter.h"

extern volatile int TcpFastTmrFlag;
extern volatile int TcpSlowTmrFlag;
extern struct netif *echo_netif;

void init_lwip();
void tcp_fasttmr(void);
void tcp_slowtmr(void);

#endif /* __LWIP_H__ */
