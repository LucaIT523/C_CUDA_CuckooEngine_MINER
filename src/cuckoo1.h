// Cuckoo Cycle, a memory-hard proof-of-work
// Copyright (c) 2013-2017 John Tromp
#ifndef __CUCKOO_H__
#define __CUCKOO_H__
#include <stdint.h> // for types uint32_t,uint64_t
#include <string.h> // for functions strlen, memset
#ifdef __cplusplus
extern "C" {
#endif
//void sha256(const unsigned char *message, unsigned int len, unsigned char *digest);

#include "siphash1.h"
#ifdef __cplusplus
}
#endif

#include "sha256.cuh"

// proof-of-work parameters
#ifndef EDGEBITS
// the main parameter is the 2-log of the graph size,
// which is the size in bits of the node identifiers
#define EDGEBITS 23
#endif
#ifndef PROOFSIZE
// the next most important parameter is the (even) length
// of the cycle to be found. a minimum of 12 is recommended
#define PROOFSIZE 42
#endif

#if EDGEBITS > 32
typedef u64 edge_t;
#else
typedef u32 edge_t;
#endif
#if EDGEBITS > 31
typedef u64 node_t;
#else
typedef u32 node_t;
#endif

// number of edges
#define NEDGES ((node_t)1 << EDGEBITS)
#define NNODES (2 * NEDGES)

// used to mask siphash output
#define EDGEMASK ((edge_t)NEDGES - 1)

// generate edge endpoint in cuckoo graph without partition bit
edge_t _sipnode(siphash_keys *keys, edge_t nonce, u32 uorv) {
  return siphash24(keys, 2*nonce + uorv) & EDGEMASK;
}

// generate edge endpoint in cuckoo graph
node_t sipnode(siphash_keys *keys, edge_t nonce, u32 uorv) {
  return _sipnode(keys, nonce, uorv) << 1 | uorv;
}

enum verify_code { POW_OK, POW_HEADER_LENGTH, POW_TOO_BIG, POW_TOO_SMALL, POW_NON_MATCHING, POW_BRANCH, POW_DEAD_END, POW_SHORT_CYCLE};

// length of header hashed into siphash key
#ifndef HEADERLEN
#define HEADERLEN 80
#endif

void getDoubleHash(const BYTE* data, const u32 datalen, BYTE* hashInfo) {

    BYTE hdrkey[32];

    SHA256_CTX ctx;
    sha256_init(&ctx);
    sha256_update(&ctx, data, datalen);
    sha256_final(&ctx, hdrkey);
    //    sha256_update(&ctx, hdrkey, 32);
    //    sha256_final(&ctx, hashInfo);

    SHA256_CTX ctx1;
    sha256_init(&ctx1);
    sha256_update(&ctx1, hdrkey, 32);
    sha256_final(&ctx1, hashInfo);
}

void setheader(const BYTE *header, const u32 headerlen, siphash_keys *keys) {
  //u64 hdrkey[4] = {0};
  //sha256((unsigned char*) header, headerlen, (unsigned char*) hdrkey);

  BYTE hdrkey[32] = { 0, };

  SHA256_CTX ctx;
  sha256_init(&ctx);
  sha256_update(&ctx, (BYTE*)header, 80);
  sha256_final(&ctx, hdrkey);

  setkeys(keys, hdrkey);
}

// verify that nonces are ascending and form a cycle in header-generated graph
int verify(edge_t nonces[PROOFSIZE], siphash_keys* keys) {
  //if (headerlen != HEADERLEN)
  //  return POW_HEADER_LENGTH;
  //siphash_keys keys;
  //setheader(header, headerlen, &keys);


  node_t uvs[2*PROOFSIZE];
  node_t xor0=0,xor1=0;
  for (u32 n = 0; n < PROOFSIZE; n++) {
    if (nonces[n] > (node_t)NNODES)
      return POW_TOO_BIG;
    if (n && nonces[n] <= nonces[n-1])
      return POW_TOO_SMALL;
    xor0 ^= uvs[2*n  ] = sipnode(keys, nonces[n], 0);
    xor1 ^= uvs[2*n+1] = sipnode(keys, nonces[n], 1);
  }
  if (xor0|xor1)              // matching endpoints imply zero xors
    return POW_NON_MATCHING;
  u32 n = 0, i = 0, j;
  do {                        // follow cycle
    for (u32 k = j = i; (k = (k+2) % (2*PROOFSIZE)) != i; ) {
      if (uvs[k] == uvs[i]) { // find other edge endpoint identical to one at i
        if (j != i)           // already found one before
          return POW_BRANCH;
        j = k;
      }
    }
    if (j == i) return POW_DEAD_END;  // no matching endpoint
    i = j^1;
    n++;
  } while (i != 0);           // must cycle back to start or we would have found branch
  return n == PROOFSIZE ? POW_OK : POW_SHORT_CYCLE;
}


//void cuckoo_regenhash(struct work *work);

int cuckoo_scanhash(const BYTE* aHeader, uint32_t nonce, uint32_t* proof);

#endif // define __CUCKOO_H__
