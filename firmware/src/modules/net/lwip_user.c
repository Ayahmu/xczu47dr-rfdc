#include "lwip_user.h"

#include <stdio.h>
#include <string.h>

#include "../../config/platform_config.h"
#include "lwip/init.h"
#include "lwip/ip_addr.h"
#include "lwip/pbuf.h"
#include "../../platform/platform.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xparameters.h"

#define TCP_SERVER_PORT 7U
#define RX_BUFFER_SIZE 65536U
#define HEADER_SIZE 8U
#define WAVEFORM_ADDR_SIZE 8U
#define INSTRUCTION_SIZE 16U
#define INST_FIFO_BASE XPAR_M_AXI_INST_BASEADDR

extern volatile u8 *data_buffer;
extern int data_len;
extern int data_ready;

static struct tcp_pcb *server_pcb;
static u8 rx_buffer[RX_BUFFER_SIZE];
static u32 rx_len;

static u32 read_le32(const u8 *data)
{
	return ((u32)data[0]) | ((u32)data[1] << 8) |
	       ((u32)data[2] << 16) | ((u32)data[3] << 24);
}

static u64 read_le64(const u8 *data)
{
	return ((u64)read_le32(data)) | ((u64)read_le32(data + 4) << 32);
}

static err_t send_response(struct tcp_pcb *tpcb, const char *response)
{
	err_t err;
	u16_t len = (u16_t)strlen(response);

	if (tcp_sndbuf(tpcb) < len) {
		xil_printf("TCP send buffer too small for response\r\n");
		return ERR_MEM;
	}

	err = tcp_write(tpcb, response, len, TCP_WRITE_FLAG_COPY);
	if (err == ERR_OK) {
		tcp_output(tpcb);
	}

	return err;
}

static err_t ack_packet(struct tcp_pcb *tpcb, u32 type, u32 len)
{
	char response[32];

	snprintf(response, sizeof(response), "ACK %lu %lu\n",
		 (unsigned long)type, (unsigned long)len);
	return send_response(tpcb, response);
}

static err_t nak_packet(struct tcp_pcb *tpcb, const char *reason)
{
	char response[48];

	snprintf(response, sizeof(response), "NAK %s\n", reason);
	return send_response(tpcb, response);
}

static err_t handle_waveform_packet(struct tcp_pcb *tpcb, const u8 *payload, u32 len)
{
	u64 ddr_addr;
	UINTPTR dest_addr;
	u32 wave_len;

	if (len < WAVEFORM_ADDR_SIZE) {
		xil_printf("Waveform packet too short: %lu\r\n", (unsigned long)len);
		return nak_packet(tpcb, "WAVE_LEN");
	}

	ddr_addr = read_le64(payload);
	dest_addr = (UINTPTR)ddr_addr;
	wave_len = len - WAVEFORM_ADDR_SIZE;

	memcpy((void *)dest_addr, payload + WAVEFORM_ADDR_SIZE, wave_len);
	Xil_DCacheFlushRange(dest_addr, wave_len);
	Xil_DCacheInvalidateRange(dest_addr, wave_len);

	data_buffer = (volatile u8 *)dest_addr;
	data_len = (int)wave_len;
	data_ready = 0;

	xil_printf("Waveform copied: addr=0x%08lx%08lx len=%lu\r\n",
		 (unsigned long)(ddr_addr >> 32), (unsigned long)(ddr_addr & 0xffffffffU),
		 (unsigned long)wave_len);
	return ack_packet(tpcb, 0U, len);
}

static err_t handle_instruction_packet(struct tcp_pcb *tpcb, const u8 *payload, u32 len)
{
	if ((len % INSTRUCTION_SIZE) != 0U) {
		xil_printf("Instruction packet length is not 16-byte aligned: %lu\r\n",
			 (unsigned long)len);
		return nak_packet(tpcb, "INST_ALIGN");
	}

#ifdef INST_FIFO_BASE
	memcpy((void *)(UINTPTR)INST_FIFO_BASE, payload, len);
	Xil_DCacheFlushRange((UINTPTR)INST_FIFO_BASE, len);
	xil_printf("Instructions copied: count=%lu addr=0x%08lx\r\n",
		 (unsigned long)(len / INSTRUCTION_SIZE), (unsigned long)INST_FIFO_BASE);
#else
	xil_printf("Instructions received: count=%lu, no INST_FIFO_BASE defined\r\n",
		 (unsigned long)(len / INSTRUCTION_SIZE));
#endif

	return ack_packet(tpcb, 1U, len);
}

static err_t handle_trigger_packet(struct tcp_pcb *tpcb, const u8 *payload, u32 len)
{
	(void)payload;
	data_ready = 1;
	xil_printf("Trigger received: len=%lu\r\n", (unsigned long)len);
	return ack_packet(tpcb, 2U, len);
}

static err_t handle_packet(struct tcp_pcb *tpcb, u32 type, const u8 *payload, u32 len)
{
	switch (type) {
	case 0U:
		return handle_waveform_packet(tpcb, payload, len);
	case 1U:
		return handle_instruction_packet(tpcb, payload, len);
	case 2U:
		return handle_trigger_packet(tpcb, payload, len);
	default:
		xil_printf("Unknown packet type: %lu\r\n", (unsigned long)type);
		return nak_packet(tpcb, "TYPE");
	}
}

static err_t process_rx_buffer(struct tcp_pcb *tpcb)
{
	while (rx_len >= HEADER_SIZE) {
		u32 type = read_le32(rx_buffer);
		u32 payload_len = read_le32(rx_buffer + 4);
		u32 packet_len = HEADER_SIZE + payload_len;

		if (payload_len > (RX_BUFFER_SIZE - HEADER_SIZE)) {
			rx_len = 0U;
			return nak_packet(tpcb, "LEN");
		}

		if (rx_len < packet_len) {
			break;
		}

		handle_packet(tpcb, type, rx_buffer + HEADER_SIZE, payload_len);

		rx_len -= packet_len;
		if (rx_len != 0U) {
			memmove(rx_buffer, rx_buffer + packet_len, rx_len);
		}
	}

	return ERR_OK;
}

static err_t recv_callback(void *arg, struct tcp_pcb *tpcb, struct pbuf *p, err_t err)
{
	struct pbuf *q;

	(void)arg;

	if (p == NULL) {
		rx_len = 0U;
		tcp_recv(tpcb, NULL);
		tcp_close(tpcb);
		return ERR_OK;
	}

	if (err != ERR_OK) {
		pbuf_free(p);
		return err;
	}

	if ((rx_len + p->tot_len) > RX_BUFFER_SIZE) {
		tcp_recved(tpcb, p->tot_len);
		pbuf_free(p);
		rx_len = 0U;
		return nak_packet(tpcb, "RX_OVERFLOW");
	}

	for (q = p; q != NULL; q = q->next) {
		memcpy(rx_buffer + rx_len, q->payload, q->len);
		rx_len += q->len;
	}

	tcp_recved(tpcb, p->tot_len);
	pbuf_free(p);

	return process_rx_buffer(tpcb);
}

static err_t accept_callback(void *arg, struct tcp_pcb *newpcb, err_t err)
{
	(void)arg;
	(void)err;

	rx_len = 0U;
	tcp_arg(newpcb, NULL);
	tcp_recv(newpcb, recv_callback);
	xil_printf("TCP client connected\r\n");
	return ERR_OK;
}

static int start_tcp_server(void)
{
	err_t err;

	server_pcb = tcp_new_ip_type(IPADDR_TYPE_ANY);
	if (server_pcb == NULL) {
		xil_printf("Error creating TCP PCB\r\n");
		return -1;
	}

	err = tcp_bind(server_pcb, IP_ANY_TYPE, TCP_SERVER_PORT);
	if (err != ERR_OK) {
		xil_printf("Unable to bind TCP port %u: err=%d\r\n", TCP_SERVER_PORT, err);
		return -2;
	}

	server_pcb = tcp_listen(server_pcb);
	if (server_pcb == NULL) {
		xil_printf("Out of memory while listening on TCP port %u\r\n", TCP_SERVER_PORT);
		return -3;
	}

	tcp_accept(server_pcb, accept_callback);
	xil_printf("TCP server listening on port %u\r\n", TCP_SERVER_PORT);
	return 0;
}

void init_lwip()
{
	unsigned char mac_ethernet_address[] = {0x00, 0x0a, 0x35, 0x00, 0x01, 0x02};
	ip_addr_t ipaddr;
	ip_addr_t netmask;
	ip_addr_t gw;

	IP4_ADDR(&ipaddr, 10, 87, 5, 241);
	IP4_ADDR(&netmask, 255, 255, 255, 0);
	IP4_ADDR(&gw, 10, 87, 5, 1);

	xil_printf("Initializing lwIP TCP server\r\n");
	lwip_init();

	if (!xemac_add(echo_netif, &ipaddr, &netmask, &gw,
		       mac_ethernet_address, PLATFORM_EMAC_BASEADDR)) {
		xil_printf("Error adding network interface\r\n");
		return;
	}

	netif_set_default(echo_netif);
	platform_enable_interrupts();
	netif_set_up(echo_netif);

	xil_printf("Board IP: 10.87.5.241\r\n");
	start_tcp_server();
}
