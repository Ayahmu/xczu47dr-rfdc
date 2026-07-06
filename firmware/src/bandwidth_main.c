#ifdef BOARD_CUSTOM_XCZU47DR_BW

#include <stdio.h>
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "sleep.h"
#include "xtime_l.h"
#include "config/global.h"

#define REG_CONTROL          0x000U
#define REG_TRIGGER          0x004U
#define REG_SAMPLE_PERIOD    0x008U
#define REG_CH_SELECT        0x00cU
#define REG_STATUS           0x100U
#define REG_TOTAL_LO         0x104U
#define REG_TOTAL_HI         0x108U
#define REG_TOTAL_BURSTS     0x10cU
#define REG_TOTAL_STALLS     0x110U
#define REG_TOTAL_UNDER      0x114U
#define REG_SAMPLE_INDEX     0x118U
#define REG_SAMPLE_LO        0x11cU
#define REG_SAMPLE_HI        0x120U
#define REG_SAMPLE_STALLS    0x124U
#define REG_SAMPLE_UNDER     0x128U
#define REG_SAMPLE_VALID     0x12cU
#define REG_CH_LO            0x140U
#define REG_CH_HI            0x144U
#define REG_CH_BURSTS        0x148U
#define REG_CH_STALLS        0x14cU
#define REG_CH_UNDER         0x150U
#define REG_CH_FIFO_MIN      0x154U
#define REG_CH_FIFO_MAX      0x158U

#define CMD_PLAY             2U
#define CMD_END              3U
#define END_AUTO_START       15U
#define LOOP_ENABLE          1U
#define TEST_BYTES_PER_CH    (32U * 1024U * 1024U)
#define TEST_TOTAL_BYTES     ((u64)TEST_BYTES_PER_CH * (u64)BW_CHANNELS)
#define SAMPLE_PERIOD_CYCLES 300000000U
#define TEST_RUN_SECONDS     0U
#define WINDOW_SECONDS       30U
#define CHANNEL_SUMMARY_INTERVAL 60U

static inline void bw_write(u32 offset, u32 value)
{
    Xil_Out32(BW_CTRL_BASE + offset, value);
}

static inline u32 bw_read(u32 offset)
{
    return Xil_In32(BW_CTRL_BASE + offset);
}

static void write_instr(u32 w0, u32 w1, u32 w2, u32 w3)
{
    Xil_Out32(BW_INST_BASE + 0x0U, w0);
    Xil_Out32(BW_INST_BASE + 0x4U, w1);
    Xil_Out32(BW_INST_BASE + 0x8U, w2);
    Xil_Out32(BW_INST_BASE + 0xcU, w3);
}

static void send_play_instruction(u32 channel, u32 length_bytes, u64 addr_offset)
{
    u32 w0 = ((channel & 0xfU) << 4) | CMD_PLAY;
    write_instr(w0, length_bytes, (u32)(addr_offset & 0xffffffffU), (u32)(addr_offset >> 32));
}

static void send_end_instruction(void)
{
    u32 w0 = ((END_AUTO_START & 0xfU) << 4) | CMD_END | (LOOP_ENABLE << 8);
    write_instr(w0, 0U, 0U, 0U);
}

static void fill_ddr_patterns(void)
{
    u32 ch;
    u32 samples_per_ch = TEST_BYTES_PER_CH / sizeof(u64);
    u64 *ptr = (u64 *)BW_DDR_BASE;
    u32 i;

    xil_printf("layout,interleaved_512b,lanes,8,lane_bytes,8,total_physical_bytes,%llu,bytes_per_channel,%lu\r\n",
               (unsigned long long)TEST_TOTAL_BYTES,
               (unsigned long)TEST_BYTES_PER_CH);
    xil_printf("prefill,interleaved,addr,0x%08lx%08lx,bytes,%llu\r\n",
               (unsigned long)(((u64)BW_DDR_BASE) >> 32),
               (unsigned long)(((u64)BW_DDR_BASE) & 0xffffffffU),
               (unsigned long long)TEST_TOTAL_BYTES);

    if (TEST_TOTAL_BYTES > BW_DDR_SIZE_BYTES) {
        xil_printf("error,test_region_exceeds_configured_ddr,total,%llu,configured,%llu\r\n",
                   (unsigned long long)TEST_TOTAL_BYTES,
                   (unsigned long long)BW_DDR_SIZE_BYTES);
        while (1) {
            sleep(1);
        }
    }

    for (i = 0U; i < samples_per_ch; i++) {
        for (ch = 0U; ch < BW_CHANNELS; ch++) {
            ptr[((u64)i * BW_CHANNELS) + ch] =
                0x5a00000000000000ULL |
                (((u64)(ch + 1U) & 0xffULL) << 48) |
                ((u64)i & 0x0000ffffffffffffULL);
        }
    }
    Xil_DCacheFlushRange(BW_DDR_BASE, (u32)TEST_TOTAL_BYTES);

    for (ch = 0U; ch < BW_CHANNELS; ch++) {
        xil_printf("prefill_lane,ch%lu,logical_bytes,%lu,lane_offset_bytes,%lu\r\n",
                   (unsigned long)(ch + 1U),
                   (unsigned long)TEST_BYTES_PER_CH,
                   (unsigned long)(ch * sizeof(u64)));
    }
}

static u64 read_u64_regs(u32 hi_offset, u32 lo_offset)
{
    u32 hi1;
    u32 lo;
    u32 hi2;

    hi1 = bw_read(hi_offset);
    lo = bw_read(lo_offset);
    hi2 = bw_read(hi_offset);
    if (hi1 != hi2) {
        lo = bw_read(lo_offset);
        hi1 = hi2;
    }
    return (((u64)hi1) << 32) | lo;
}

static u64 read_total_bytes(void)
{
    return read_u64_regs(REG_TOTAL_HI, REG_TOTAL_LO);
}

static u32 delta_u32(u32 now, u32 prev)
{
    return now - prev;
}

int main(void)
{
    u32 ch;
    u32 sample = 0U;
    u32 prev_total_bursts = 0U;
    u32 prev_sample_idx = 0U;
    u32 window_index = 0U;
    u32 window_elapsed = 0U;
    u64 window_bytes = 0U;
    u64 window_bursts = 0U;
    u64 window_stalls = 0U;
    u64 window_underflows = 0U;
    xil_printf("\r\nXCZU47DR DDR DataMover bandwidth test\r\n");
    xil_printf("ctrl_base,0x%08lx,inst_base,0x%08lx,ddr_base,0x%08lx%08lx\r\n",
               (unsigned long)BW_CTRL_BASE,
               (unsigned long)BW_INST_BASE,
               (unsigned long)(BW_DDR_BASE >> 32),
               (unsigned long)(BW_DDR_BASE & 0xffffffffU));

    fill_ddr_patterns();

    bw_write(REG_CONTROL, 1U);
    usleep(1000);
    bw_write(REG_SAMPLE_PERIOD, SAMPLE_PERIOD_CYCLES);

    for (ch = 0U; ch < BW_CHANNELS; ch++) {
        send_play_instruction(ch + 1U, TEST_BYTES_PER_CH, 0U);
    }
    send_end_instruction();
    bw_write(REG_TRIGGER, 1U);

    xil_printf("run,mode,%s,run_seconds,%lu,sample_period_cycles,%lu,window_seconds,%lu\r\n",
               (TEST_RUN_SECONDS == 0U) ? "continuous" : "fixed",
               (unsigned long)TEST_RUN_SECONDS,
               (unsigned long)SAMPLE_PERIOD_CYCLES,
               (unsigned long)WINDOW_SECONDS);
    prev_sample_idx = bw_read(REG_SAMPLE_INDEX);
    prev_total_bursts = bw_read(REG_TOTAL_BURSTS);

    xil_printf("csv,second,sample,total_bytes,delta_bytes,total_bursts,delta_bursts,total_stalls,delta_stalls,total_underflows,delta_underflows,status\r\n");
    xil_printf("win,index,seconds,bytes,bursts,stalls,underflows,status\r\n");
    while ((TEST_RUN_SECONDS == 0U) || (sample < TEST_RUN_SECONDS)) {
        u32 status;
        u32 sample_idx;
        u64 total_bytes;
        u64 delta_bytes;
        u32 total_bursts;
        u32 total_stalls;
        u32 total_underflows;
        u32 delta_bursts;
        u32 delta_stalls;
        u32 delta_underflows;
        do {
            usleep(1000);
            sample_idx = bw_read(REG_SAMPLE_INDEX);
        } while (sample_idx == prev_sample_idx);
        prev_sample_idx = sample_idx;
        sample++;
        status = bw_read(REG_STATUS);
        total_bytes = read_total_bytes();
        delta_bytes = read_u64_regs(REG_SAMPLE_HI, REG_SAMPLE_LO);
        total_bursts = bw_read(REG_TOTAL_BURSTS);
        total_stalls = bw_read(REG_TOTAL_STALLS);
        total_underflows = bw_read(REG_TOTAL_UNDER);
        delta_bursts = delta_u32(total_bursts, prev_total_bursts);
        delta_stalls = bw_read(REG_SAMPLE_STALLS);
        delta_underflows = bw_read(REG_SAMPLE_UNDER);
        xil_printf("csv,%lu,%lu,%llu,%llu,%lu,%lu,%lu,%lu,%lu,%lu,0x%08lx\r\n",
                   (unsigned long)sample,
                   (unsigned long)sample_idx,
                   (unsigned long long)total_bytes,
                   (unsigned long long)delta_bytes,
                   (unsigned long)total_bursts,
                   (unsigned long)delta_bursts,
                   (unsigned long)total_stalls,
                   (unsigned long)delta_stalls,
                   (unsigned long)total_underflows,
                   (unsigned long)delta_underflows,
                   (unsigned long)status);
        prev_total_bursts = total_bursts;
        window_elapsed++;
        window_bytes += delta_bytes;
        window_bursts += delta_bursts;
        window_stalls += delta_stalls;
        window_underflows += delta_underflows;

        if ((WINDOW_SECONDS != 0U) && (window_elapsed >= WINDOW_SECONDS)) {
            window_index++;
            xil_printf("win,%lu,%lu,%llu,%llu,%llu,%llu,0x%08lx\r\n",
                       (unsigned long)window_index,
                       (unsigned long)window_elapsed,
                       (unsigned long long)window_bytes,
                       (unsigned long long)window_bursts,
                       (unsigned long long)window_stalls,
                       (unsigned long long)window_underflows,
                       (unsigned long)status);
            window_elapsed = 0U;
            window_bytes = 0U;
            window_bursts = 0U;
            window_stalls = 0U;
            window_underflows = 0U;
        }

        if ((CHANNEL_SUMMARY_INTERVAL != 0U) && ((sample % CHANNEL_SUMMARY_INTERVAL) == 0U)) {
            xil_printf("channel,ch,total_bytes,bursts,stalls,underflows,fifo_min,fifo_max\r\n");
            for (ch = 0U; ch < BW_CHANNELS; ch++) {
                u64 ch_bytes;
                bw_write(REG_CH_SELECT, ch);
                ch_bytes = read_u64_regs(REG_CH_HI, REG_CH_LO);
                xil_printf("channel,%lu,%llu,%lu,%lu,%lu,%lu,%lu\r\n",
                           (unsigned long)(ch + 1U),
                           (unsigned long long)ch_bytes,
                           (unsigned long)bw_read(REG_CH_BURSTS),
                           (unsigned long)bw_read(REG_CH_STALLS),
                           (unsigned long)bw_read(REG_CH_UNDER),
                           (unsigned long)bw_read(REG_CH_FIFO_MIN),
                           (unsigned long)bw_read(REG_CH_FIFO_MAX));
            }
        }
    }

    xil_printf("channel,ch,total_bytes,bursts,stalls,underflows,fifo_min,fifo_max\r\n");
    for (ch = 0U; ch < BW_CHANNELS; ch++) {
        u64 ch_bytes;
        bw_write(REG_CH_SELECT, ch);
        ch_bytes = read_u64_regs(REG_CH_HI, REG_CH_LO);
        xil_printf("channel,%lu,%llu,%lu,%lu,%lu,%lu,%lu\r\n",
                   (unsigned long)(ch + 1U),
                   (unsigned long long)ch_bytes,
                   (unsigned long)bw_read(REG_CH_BURSTS),
                   (unsigned long)bw_read(REG_CH_STALLS),
                   (unsigned long)bw_read(REG_CH_UNDER),
                   (unsigned long)bw_read(REG_CH_FIFO_MIN),
                   (unsigned long)bw_read(REG_CH_FIFO_MAX));
    }

    xil_printf("done\r\n");
    while (1) {
        sleep(1);
    }
    return 0;
}

#endif /* BOARD_CUSTOM_XCZU47DR_BW */
