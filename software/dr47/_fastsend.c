/* Bulk waveform sender core for dr47.bulk (loaded with ctypes).
 *
 * Python opens, binds and connects one UDP socket and enables UDP
 * segmentation offload with the datagram size; this file only does the part
 * the interpreter is too slow for: building the 22-byte bulk headers and
 * handing header/payload pairs to the kernel, up to 64 datagrams per sendmsg.
 * A packed image is referenced in place; an image that is still eight channel
 * arrays is gathered one batch at a time into a buffer of the sending thread.
 *
 * All threads send on the same socket.  A socket keeps to one transmit queue
 * of the network card, so a batch reaches the wire as one unbroken run of
 * consecutive addresses.  With a socket per thread the card interleaves the
 * queues frame by frame; the board then alternates between DDR4 rows on every
 * frame, each switch costs it about ten clock cycles, and at line rate it
 * drops a fifth of the frames.
 *
 * Wire format of one datagram (see dr47.protocol.pack_wave_bulk_header):
 *   "WBLK"  session:u32  byte_offset:u64  words:u16  epoch:u8  0 0 0   payload
 * all little endian; payload is words * 64 bytes.
 *
 * Build: cc -O2 -shared -fPIC -pthread -o _fastsend.so _fastsend.c
 */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>

#define HEADER_BYTES 22
#define WORD_BYTES 64
#define LANES 8                 /* channels in one 64-byte DDR word */
#define LANE_BYTES 8            /* four int16 values of one channel */
#define LANE_SAMPLES 4
#define MAX_BATCH 64
#define MAX_THREADS 64

typedef struct {
    int fd;
    const uint8_t *image;              /* the packed image, or 0 when gathering from lanes */
    const int16_t *const *lanes;       /* LANES channel arrays (0 = silent channel) */
    const uint64_t *lane_samples;      /* int16 values in each */
    uint64_t start, end;
    uint32_t session, payload_bytes, batch;
    uint8_t epoch;
    atomic_uint_fast64_t next_batch;   /* shared cursor: index of the next unsent batch */
    atomic_int error;                  /* first errno seen by any thread */
    atomic_uint_fast64_t sent;         /* datagrams handed to the kernel */
} job_t;

static void put_le(uint8_t *p, uint64_t v, int n) { for (int i = 0; i < n; i++) p[i] = (uint8_t)(v >> (8 * i)); }

/* Build image[offset:offset+length) from the channel arrays: word w holds
 * samples 4w..4w+3 of every channel, zeros past the end of a channel. */
static void gather(const job_t *job, uint64_t offset, uint64_t length, uint8_t *out)
{
    const uint64_t first = offset / WORD_BYTES * LANE_SAMPLES, words = length / WORD_BYTES;
    for (int c = 0; c < LANES; c++) {
        const uint8_t *src = (const uint8_t *)job->lanes[c];
        const uint64_t have = src ? job->lane_samples[c] : 0;
        uint64_t whole = have > first ? (have - first) / LANE_SAMPLES : 0;
        if (whole > words) whole = words;
        uint8_t *dst = out + c * LANE_BYTES;
        for (uint64_t i = 0; i < whole; i++)
            memcpy(dst + i * WORD_BYTES, src + (first + i * LANE_SAMPLES) * 2, LANE_BYTES);
        for (uint64_t i = whole; i < words; i++) {
            uint8_t lane[LANE_BYTES] = {0};
            const uint64_t at = first + i * LANE_SAMPLES;
            if (have > at) memcpy(lane, src + at * 2, (size_t)(have - at) * 2);   /* the channel ends inside this lane */
            memcpy(dst + i * WORD_BYTES, lane, LANE_BYTES);
        }
    }
}

/* Each thread takes the next batch of consecutive datagrams until none is left. */
static void *run(void *arg)
{
    job_t *job = (job_t *)arg;
    uint8_t headers[MAX_BATCH][HEADER_BYTES];
    struct iovec iov[2 * MAX_BATCH];
    const uint64_t batch_bytes = (uint64_t)job->batch * job->payload_bytes;
    uint8_t *staging = 0;              /* this thread's batch, when it is gathered from lanes */

    if (!job->image && !(staging = malloc(batch_bytes))) {
        int expected = 0;
        atomic_compare_exchange_strong(&job->error, &expected, ENOMEM);
        return 0;
    }
    while (!atomic_load(&job->error)) {
        uint64_t offset = job->start + atomic_fetch_add(&job->next_batch, 1) * batch_bytes;
        if (offset >= job->end) break;
        const uint8_t *data = job->image ? job->image + offset : staging;
        if (!job->image)
            gather(job, offset, job->end - offset < batch_bytes ? job->end - offset : batch_bytes, staging);
        unsigned n = 0;
        while (n < job->batch && offset < job->end) {
            uint64_t length = job->end - offset;
            if (length > job->payload_bytes) length = job->payload_bytes;
            uint8_t *h = headers[n];
            memcpy(h, "WBLK", 4);
            put_le(h + 4, job->session, 4);
            put_le(h + 8, offset, 8);
            put_le(h + 16, length / WORD_BYTES, 2);
            h[18] = job->epoch; h[19] = 0; h[20] = 0; h[21] = 0;
            iov[2 * n].iov_base = h;
            iov[2 * n].iov_len = HEADER_BYTES;
            iov[2 * n + 1].iov_base = (void *)data;
            iov[2 * n + 1].iov_len = (size_t)length;
            data += length;
            offset += length;
            n++;
        }
        struct msghdr msg;
        memset(&msg, 0, sizeof msg);
        msg.msg_iov = iov;
        msg.msg_iovlen = 2 * n;
        ssize_t r;
        do { r = sendmsg(job->fd, &msg, 0); } while (r < 0 && errno == EINTR);
        if (r < 0) {
            int expected = 0;
            atomic_compare_exchange_strong(&job->error, &expected, errno);
            break;
        }
        atomic_fetch_add(&job->sent, n);
    }
    free(staging);
    return 0;
}

static int64_t send_range(job_t *job, int nthreads, uint64_t start, uint64_t end,
                          uint32_t session, uint32_t epoch, uint32_t payload_bytes, uint32_t batch)
{
    if (nthreads < 1 || nthreads > MAX_THREADS || end <= start || payload_bytes == 0 ||
        payload_bytes % WORD_BYTES || batch < 1 || batch > MAX_BATCH)
        return -EINVAL;

    job->start = start;
    job->end = end;
    job->session = session;
    job->payload_bytes = payload_bytes;
    job->batch = batch;
    job->epoch = (uint8_t)epoch;
    atomic_init(&job->next_batch, 0);
    atomic_init(&job->error, 0);
    atomic_init(&job->sent, 0);

    uint64_t batches = (end - start + (uint64_t)batch * payload_bytes - 1) / ((uint64_t)batch * payload_bytes);
    int workers = batches < (uint64_t)nthreads ? (int)batches : nthreads;
    pthread_t threads[MAX_THREADS];
    int started = 0;
    /* The calling thread is one of the workers. */
    for (int i = 0; i + 1 < workers; i++) {
        if (pthread_create(&threads[started], 0, run, job) != 0) break;   /* the others cover for it */
        started++;
    }
    run(job);
    for (int i = 0; i < started; i++) pthread_join(threads[i], 0);

    int error = atomic_load(&job->error);
    return error ? -(int64_t)error : (int64_t)atomic_load(&job->sent);
}

/* Send image[start:end) on socket fd from nthreads threads.  batch is the
 * number of datagrams per sendmsg (1 when segmentation offload is off).
 * Returns the datagram count, or -errno. */
int64_t dr47_bulk_send(int fd, int nthreads, const uint8_t *image,
                       uint64_t start, uint64_t end,
                       uint32_t session, uint32_t epoch,
                       uint32_t payload_bytes, uint32_t batch)
{
    job_t job;
    job.fd = fd;
    job.image = image;
    job.lanes = 0;
    job.lane_samples = 0;
    return send_range(&job, nthreads, start, end, session, epoch, payload_bytes, batch);
}

/* The same for an image that is still eight separate channel arrays:
 * lanes[c] holds lane_samples[c] int16 values of channel c + 1, or is 0 for a
 * silent channel.  start and end are byte offsets in the image they would
 * pack into. */
int64_t dr47_bulk_send_lanes(int fd, int nthreads, const int16_t *const *lanes, const uint64_t *lane_samples,
                             uint64_t start, uint64_t end,
                             uint32_t session, uint32_t epoch,
                             uint32_t payload_bytes, uint32_t batch)
{
    job_t job;
    if (!lanes || !lane_samples || start % WORD_BYTES || end % WORD_BYTES) return -EINVAL;
    job.fd = fd;
    job.image = 0;
    job.lanes = lanes;
    job.lane_samples = lane_samples;
    return send_range(&job, nthreads, start, end, session, epoch, payload_bytes, batch);
}
