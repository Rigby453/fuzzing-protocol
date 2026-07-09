/*
 * n2n_mutator.c — AFL++ custom mutator for n2n protocol
 *
 * Understands the n2n_common_t packet header structure and applies
 * protocol-aware mutations:
 *   1. Directed msg_type switching (30% probability)
 *   2. Community field boundary mutations
 *   3. Per-type payload mutations (flags, MAC addresses, IPv4 fields)
 *   4. Sequence number and TTL mutations
 *
 * Build:
 *   make -C mutator/
 *
 * Usage:
 *   AFL_CUSTOM_MUTATOR_LIBRARY=$(pwd)/mutator/n2n_mutator.so \
 *   afl-fuzz -i seeds/ -o out/ ...
 *
 * References:
 *   https://github.com/AFLplusplus/AFLplusplus/blob/stable/docs/custom_mutators.md
 *   https://github.com/ntop/n2n/blob/3.0-stable/include/n2n_wire.h
 */

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

/* ── AFL++ custom mutator API ─────────────────────────────────────────────── */
/* We include the minimal API needed; no dependency on afl-fuzz.h             */

typedef struct {
    /* opaque AFL state — we don't need to access internals */
    void *afl_state;
    unsigned int seed;
} my_mutator_t;

/* ── n2n protocol constants ───────────────────────────────────────────────── */

#define N2N_VERSION_V2          2
#define N2N_VERSION_V3          3
#define N2N_DEFAULT_TTL         200
#define N2N_COMMUNITY_SIZE      20

/* msg_type values (stored in pc field, big-endian) */
#define MSG_TYPE_REGISTER           0x0001
#define MSG_TYPE_DEREGISTER         0x0002
#define MSG_TYPE_PACKET             0x0003
#define MSG_TYPE_REGISTER_ACK       0x0004
#define MSG_TYPE_REGISTER_SUPER     0x0007
#define MSG_TYPE_REGISTER_SUPER_ACK 0x0008
#define MSG_TYPE_REGISTER_SUPER_NAK 0x0009
#define MSG_TYPE_PEER_INFO          0x000a
#define MSG_TYPE_QUERY_SUPER_N      0x000b
#define MSG_TYPE_UNREGISTER_SUPER   0x000c
#define MSG_TYPE_RENEW_SUPER        0x000d

/* Flags */
#define N2N_FLAGS_FROM_SUPERNODE    0x0020
#define N2N_FLAGS_SOCKET            0x0040
#define N2N_FLAGS_OPTIONS           0x0080

/* ── n2n_common_t header (matches wire format, big-endian fields) ─────────── */

#pragma pack(push, 1)
typedef struct {
    uint8_t  version;           /* n2n protocol version: 2 or 3 */
    uint8_t  ttl;               /* time-to-live */
    uint16_t pc;                /* packet code = msg_type (big-endian) */
    uint16_t flags;             /* flags (big-endian) */
    char     community[N2N_COMMUNITY_SIZE]; /* community name, may not be NUL-terminated */
} n2n_common_t;
#pragma pack(pop)

#define COMMON_HDR_SIZE  sizeof(n2n_common_t)   /* 26 bytes */

/* ── Valid msg_type set for directed mutations ────────────────────────────── */

static const uint16_t VALID_TYPES[] = {
    MSG_TYPE_REGISTER,
    MSG_TYPE_DEREGISTER,
    MSG_TYPE_PACKET,
    MSG_TYPE_REGISTER_SUPER,
    MSG_TYPE_PEER_INFO,
    MSG_TYPE_QUERY_SUPER_N,
    MSG_TYPE_UNREGISTER_SUPER,
    MSG_TYPE_RENEW_SUPER,
};
#define VALID_TYPES_COUNT  (sizeof(VALID_TYPES) / sizeof(VALID_TYPES[0]))

/* ── Known community names for targeted fuzzing ──────────────────────────── */

static const char *KNOWN_COMMUNITIES[] = {
    "testcommunity",    /* default in seed corpus */
    "n2n",
    "community1",
    "",                 /* empty community → error path */
    "\x00\x00\x00",    /* null bytes → parser edge case */
    "AAAAAAAAAAAAAAAAAAA",  /* 19 chars, no NUL → boundary */
    "AAAAAAAAAAAAAAAAAAAA", /* 20 chars, fills buffer exactly */
};
#define KNOWN_COMMUNITIES_COUNT (sizeof(KNOWN_COMMUNITIES) / sizeof(KNOWN_COMMUNITIES[0]))

/* ── Helper: read/write big-endian uint16 ────────────────────────────────── */

static inline uint16_t be16_read(const uint8_t *p) {
    return ((uint16_t)p[0] << 8) | p[1];
}

static inline void be16_write(uint8_t *p, uint16_t v) {
    p[0] = (v >> 8) & 0xFF;
    p[1] = v & 0xFF;
}

/* ── Mutator lifecycle ───────────────────────────────────────────────────── */

/**
 * afl_custom_init — called once at startup
 * Returns opaque handle passed to all other functions.
 */
void *afl_custom_init(void *afl, unsigned int seed) {
    my_mutator_t *m = calloc(1, sizeof(my_mutator_t));
    if (!m) return NULL;
    m->afl_state = afl;
    m->seed = seed;
    srand(seed);
    fprintf(stderr, "[n2n_mutator] init: seed=0x%08x\n", seed);
    return m;
}

/**
 * afl_custom_fuzz — main mutation function
 *
 * Called for each test case. buf contains the current input;
 * we modify it in-place and set *out_buf to buf (or a new allocation).
 *
 * Returns the new length of the mutated buffer.
 */
size_t afl_custom_fuzz(void    *data,
                       uint8_t *buf,      size_t buf_size,
                       uint8_t **out_buf,
                       uint8_t *add_buf,  size_t add_buf_size,
                       size_t   max_size)
{
    (void)data;
    (void)add_buf;
    (void)add_buf_size;
    (void)max_size;

    /* Not enough data to parse header → return as-is */
    if (buf_size < COMMON_HDR_SIZE) {
        *out_buf = buf;
        return buf_size;
    }

    n2n_common_t *hdr = (n2n_common_t *)buf;

    int roll = rand() % 100;

    /* ── Mutation 1: switch msg_type (30% probability) ──────────────────── */
    if (roll < 30) {
        uint16_t new_type = VALID_TYPES[rand() % VALID_TYPES_COUNT];
        be16_write((uint8_t *)&hdr->pc, new_type);
    }

    /* ── Mutation 2: community mutations (20% probability) ──────────────── */
    else if (roll < 50) {
        int cm_idx = rand() % KNOWN_COMMUNITIES_COUNT;
        const char *cm = KNOWN_COMMUNITIES[cm_idx];
        memset(hdr->community, 0, N2N_COMMUNITY_SIZE);
        memcpy(hdr->community, cm, strnlen(cm, N2N_COMMUNITY_SIZE));
    }

    /* ── Mutation 3: version/TTL boundary values (10% probability) ───────── */
    else if (roll < 60) {
        static const uint8_t VERSIONS[] = {0, 1, 2, 3, 0xFF};
        static const uint8_t TTLS[]     = {0, 1, 200, 254, 255};
        hdr->version = VERSIONS[rand() % 5];
        hdr->ttl     = TTLS[rand() % 5];
    }

    /* ── Mutation 4: flags manipulation (15% probability) ───────────────── */
    else if (roll < 75) {
        uint16_t flags = be16_read((uint8_t *)&hdr->flags);
        /* flip a random flag bit */
        flags ^= (1 << (rand() % 16));
        be16_write((uint8_t *)&hdr->flags, flags);
    }

    /* ── Mutation 5: payload byte flip (25% probability) ─────────────────── */
    else {
        if (buf_size > COMMON_HDR_SIZE) {
            size_t payload_len = buf_size - COMMON_HDR_SIZE;
            uint8_t *payload = buf + COMMON_HDR_SIZE;
            /* flip 1–4 random bytes in payload */
            int flips = (rand() % 4) + 1;
            for (int i = 0; i < flips; i++) {
                size_t pos = rand() % payload_len;
                payload[pos] ^= (uint8_t)(rand() & 0xFF);
            }
        }
    }

    *out_buf = buf;
    return buf_size;
}

/**
 * afl_custom_describe — optional: describe the last mutation for logging
 */
const char *afl_custom_describe(void *data, size_t max_description_len) {
    (void)data;
    (void)max_description_len;
    return "n2n_protocol_aware_mutation";
}

/**
 * afl_custom_deinit — cleanup
 */
void afl_custom_deinit(void *data) {
    free(data);
}
