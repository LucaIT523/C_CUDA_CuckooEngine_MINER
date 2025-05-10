// Cuckoo Cycle, a memory-hard proof-of-work
// Copyright (c) 2013-2016 John Tromp

// The edge-trimming memory optimization is due to Dave Andersen
// http://da-data.blogspot.com/2014/03/a-public-review-of-cuckoo-cycle.html

#include <stdint.h>
#include <string.h>
#include "cuckoo1.h"
#include "CCuckooEngine.h"

//#define printf(x...) 


#define bswap_16(value)  \
  ((((value) & 0xff) << 8) | ((value) >> 8))

#define bswap_32(value) \
  (((uint32_t)bswap_16((uint16_t)((value) & 0xffff)) << 16) | \
  (uint32_t)bswap_16((uint16_t)((value) >> 16)))

#define bswap_64(value) \
  (((uint64_t)bswap_32((uint32_t)((value) & 0xffffffff)) \
      << 32) | \
  (uint64_t)bswap_32((uint32_t)((value) >> 32)))


static inline void flip80(void *dest_p, const void *src_p)
{
  uint32_t *dest = (uint32_t *)dest_p;
  const uint32_t *src = (uint32_t *)src_p;
  int i;

  for (i = 0; i < 20; i++)
    dest[i] = bswap_32(src[i]);
}

const char *errstr[] = { "OK", "wrong header length", "nonce too big", "nonces not ascending", "endpoints don't match up", "branch in cycle", "cycle dead ends", "cycle too short"};
// d(evice s)ipnode
#if (__CUDA_ARCH__  >= 320) // redefine ROTL to use funnel shifter, 3% speed gain

static __device__ __forceinline__ uint2 operator^ (uint2 a, uint2 b) { return make_uint2(a.x ^ b.x, a.y ^ b.y); }
static __device__ __forceinline__ void operator^= (uint2 &a, uint2 b) { a.x ^= b.x, a.y ^= b.y; }
static __device__ __forceinline__ void operator+= (uint2 &a, uint2 b) {
  asm("{\n\tadd.cc.u32 %0,%2,%4;\n\taddc.u32 %1,%3,%5;\n\t}\n\t"
    : "=r"(a.x), "=r"(a.y) : "r"(a.x), "r"(a.y), "r"(b.x), "r"(b.y));
}
#undef ROTL
__inline__ __device__ uint2 ROTL(const uint2 a, const int offset) {
  uint2 result;
  if (offset >= 32) {
    asm("shf.l.wrap.b32 %0, %1, %2, %3;" : "=r"(result.x) : "r"(a.x), "r"(a.y), "r"(offset));
    asm("shf.l.wrap.b32 %0, %1, %2, %3;" : "=r"(result.y) : "r"(a.y), "r"(a.x), "r"(offset));
  } else {
    asm("shf.l.wrap.b32 %0, %1, %2, %3;" : "=r"(result.x) : "r"(a.y), "r"(a.x), "r"(offset));
    asm("shf.l.wrap.b32 %0, %1, %2, %3;" : "=r"(result.y) : "r"(a.x), "r"(a.y), "r"(offset));
  }
  return result;
}
__device__ __forceinline__ uint2 vectorize(const uint64_t x) {
  uint2 result;
  asm("mov.b64 {%0,%1},%2; \n\t" : "=r"(result.x), "=r"(result.y) : "l"(x));
  return result;
}
__device__ __forceinline__ uint64_t devectorize(uint2 x) {
  uint64_t result;
  asm("mov.b64 %0,{%1,%2}; \n\t" : "=l"(result) : "r"(x.x), "r"(x.y));
  return result;
}
__device__ node_t dipnode(siphash_keys &keys, edge_t nce, u32 uorv) {
  uint2 nonce = vectorize(2*nce + uorv);
  uint2 v0 = vectorize(keys.k0),
        v1 = vectorize(keys.k1),
        v2 = vectorize(keys.k2),
        v3 = vectorize(keys.k3) ^ nonce;
  SIPROUND; SIPROUND;
  v0 ^= nonce;
  v2 ^= vectorize(0xff);
  SIPROUND; SIPROUND; SIPROUND; SIPROUND;
  return devectorize(v0 ^ v1 ^ v2  ^ v3) & EDGEMASK;
}

#else

__device__ node_t dipnode(siphash_keys &keys, edge_t nce, u32 uorv) {
  u64 nonce = 2*nce + uorv;
  u64 v0 = keys.k0, v1 = keys.k1, v2 = keys.k2, v3 = keys.k3 ^ nonce;
  SIPROUND; SIPROUND;
  v0 ^= nonce;
  v2 ^= 0xff;
  SIPROUND; SIPROUND; SIPROUND; SIPROUND;
  return (v0 ^ v1 ^ v2  ^ v3) & EDGEMASK;
}
 
#endif

#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <set>

// algorithm parameters
#ifndef PART_BITS
// #bits used to partition edge set processing to save memory
// a value of 0 does no partitioning and is fastest
// a value of 1 partitions in two, making twice_set the
// same size as shrinkingset at about 33% slowdown
// higher values are not that interesting
#define PART_BITS 0
#endif

#ifndef IDXSHIFT
// we want sizeof(cuckoo_hash) == sizeof(twice_set), so
// CUCKOO_SIZE * sizeof(u64) == TWICE_WORDS * sizeof(u32)
// CUCKOO_SIZE * 2 == TWICE_WORDS
// (NNODES >> IDXSHIFT) * 2 == 2 * ONCE_BITS / 32
// NNODES >> IDXSHIFT == NEDGES >> PART_BITS >> 5
// IDXSHIFT == 1 + PART_BITS + 5
#define IDXSHIFT (PART_BITS + 6)
#endif

#define NODEBITS (EDGEBITS + 1)
#define NODEMASK (NNODES-1)

// grow with cube root of size, hardly affected by trimming
#define MAXPATHLEN (8 << (NODEBITS/3))

#define checkCudaErrors(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true) {
  if (code != cudaSuccess) {
    fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
    if (abort) exit(code);
  }
}

// set that starts out full and gets reset by threads on disjoint words
class shrinkingset {
public:
  u32 *bits;
  __device__ void reset(edge_t n) {
    bits[n/32] |= 1 << (n%32);
  }
  __device__ bool test(node_t n) const {
    return !((bits[n/32] >> (n%32)) & 1);
  }
  __device__ u32 block(node_t n) const {
    return ~bits[n/32];
  }
};

#define PART_MASK ((1 << PART_BITS) - 1)
#define ONCE_BITS (NEDGES >> PART_BITS)
#define TWICE_WORDS ((2 * ONCE_BITS) / 32)

class twice_set {
public:
  u32 *bits;
  __device__ void reset() {
    memset(bits, 0, TWICE_WORDS * sizeof(u32));
  }
  __device__ void set(node_t u) {
    node_t idx = u/16;
    u32 bit = 1 << (2 * (u%16));
    u32 old = atomicOr(&bits[idx], bit);
    u32 bit2 = bit<<1;
    if ((old & (bit2|bit)) == bit) atomicOr(&bits[idx], bit2);
  }
  __device__ u32 test(node_t u) const {
    return (bits[u/16] >> (2 * (u%16))) & 2;
  }
};

#define CUCKOO_SIZE (NNODES >> IDXSHIFT)
#define CUCKOO_MASK (CUCKOO_SIZE - 1)
// number of (least significant) key bits that survives leftshift by NODEBITS
#define KEYBITS (64-NODEBITS)
#define KEYMASK ((1L << KEYBITS) - 1)
#define MAXDRIFT (1L << (KEYBITS - IDXSHIFT))

class cuckoo_hash {
public:
  u64 *cuckoo;

  cuckoo_hash() {
    cuckoo = (u64 *)calloc(CUCKOO_SIZE, sizeof(u64));
    assert(cuckoo != 0);
  }
  ~cuckoo_hash() {
    free(cuckoo);
  }
  void set(node_t u, node_t v) {
    u64 niew = (u64)u << NODEBITS | v;
    for (node_t ui = u >> IDXSHIFT; ; ui = (ui+1) & CUCKOO_MASK) {
#ifdef ATOMIC
      u64 old = 0;
      if (cuckoo[ui].compare_exchange_strong(old, niew, std::memory_order_relaxed))
        return;
      if ((old >> NODEBITS) == (u & KEYMASK)) {
        cuckoo[ui].store(niew, std::memory_order_relaxed);
#else
      u64 old = cuckoo[ui];
      if (old == 0 || (old >> NODEBITS) == (u & KEYMASK)) {
        cuckoo[ui] = niew;
#endif
        return;
      }
    }
  }
  node_t operator[](node_t u) const {
    for (node_t ui = u >> IDXSHIFT; ; ui = (ui+1) & CUCKOO_MASK) {
#ifdef ATOMIC
      u64 cu = cuckoo[ui].load(std::memory_order_relaxed);
#else
      u64 cu = cuckoo[ui];
#endif
      if (!cu)
        return 0;
      if ((cu >> NODEBITS) == (u & KEYMASK)) {
        assert(((ui - (u >> IDXSHIFT)) & CUCKOO_MASK) < MAXDRIFT);
        return (node_t)(cu & NODEMASK);
      }
    }
  }
};
#define __htole32__(x) (((x) >> 24) | (((x) >> 8) & 0xFF00) | (((x) << 8) & 0xFF0000) | ((x) << 24))
class cuckoo_ctx {
public:
  siphash_keys sip_keys;
  shrinkingset alive;
  twice_set nonleaf;
  int nthreads;

  cuckoo_ctx(const u32 n_threads) {
    nthreads = n_threads;
  }
  void setheadernonce(BYTE* headernonce, const u32 nonce) {
    ((u32 *)headernonce)[HEADERLEN/sizeof(u32)-1] = __htole32__(nonce); // place nonce at end

    //printf("C_Header --- ");
    //for (int i = 0; i < 80; i++) {
    //    printf("%02X", headernonce[i]);
    //}
    //printf("\n ");

    setheader(headernonce, HEADERLEN, &sip_keys);
  }
};

__global__ void count_node_deg(cuckoo_ctx *ctx, u32 uorv, u32 part) {
  shrinkingset &alive = ctx->alive;
  twice_set &nonleaf = ctx->nonleaf;
  siphash_keys sip_keys = ctx->sip_keys; // local copy sip context; 2.5% speed gain
  int id = blockIdx.x * blockDim.x + threadIdx.x;
#pragma unroll

  for (edge_t block = id*32; block < NEDGES; block += ctx->nthreads*32) {
    u32 alive32 = alive.block(block);
    for (edge_t nonce = block-1; alive32; ) { // -1 compensates for 1-based ffs
      u32 ffs = __ffs(alive32);
      nonce += ffs; alive32 >>= ffs;
      node_t u = dipnode(sip_keys, nonce, uorv);
      if ((u & PART_MASK) == part) {
        nonleaf.set(u >> PART_BITS);
      }
    }
  }
}

__global__ void kill_leaf_edges(cuckoo_ctx *ctx, u32 uorv, u32 part) {
  shrinkingset &alive = ctx->alive;
  twice_set &nonleaf = ctx->nonleaf;
  siphash_keys sip_keys = ctx->sip_keys;
  int id = blockIdx.x * blockDim.x + threadIdx.x;
#pragma unroll
  for (edge_t block = id*32; block < NEDGES; block += ctx->nthreads*32) {
    u32 alive32 = alive.block(block);
    for (edge_t nonce = block-1; alive32; ) { // -1 compensates for 1-based ffs
      u32 ffs = __ffs(alive32);
      nonce += ffs; alive32 >>= ffs;
      node_t u = dipnode(sip_keys, nonce, uorv);
      if ((u & PART_MASK) == part) {
        if (!nonleaf.test(u >> PART_BITS)) {
          alive.reset(nonce);
        }
      }
    }
  }
}

u32 path(cuckoo_hash &cuckoo, node_t u, node_t *us) {
  u32 nu;
#pragma unroll

  for (nu = 0; u; u = cuckoo[u]) {
    if (nu >= MAXPATHLEN) {
      while (nu-- && us[nu] != u) ;
      if (nu == ~0)
        printf("maximum path length exceeded\n");
      else printf("illegal % 4d-cycle\n", MAXPATHLEN-nu);
      return UINT_MAX;
    }
    us[nu++] = u;
  }
  return nu-1;
}

typedef std::pair<node_t,node_t> edge;

#ifdef _WINDOWS
u32 __builtin_ffsll(u64 x) {
    if (x == 0)
        return 0; // No set bit found

    // Find the position of the first set bit using a loop
    for (int i = 1; i <= 64; ++i) {
        if (x & 1)
            return i;
        x >>= 1;
    }

    return 0; // Should never reach here
}

u32 _popcountll(u64 x) {
    u32 count = 0;
    while (x) {
        count += x & 1;
        x >>= 1;
    }
    return count;
}

#endif
#include <string>                      // std::string
#include <stdio.h>
#include <vector>
#include <sstream>

BYTE* reverseBytes(BYTE* bytes, int len)
{
    BYTE* buf = new BYTE[len];
    for (int i = 0; i < len; i++)
        buf[i] = bytes[len - 1 - i];
    return buf;
}


//bool compareWithZero(const mpz_class& value) {
//    return mpz_cmp_si(value.get_mpz_t(), 0) == -1;
//}
//
//bool compareBigInt(const mpz_class& value1, const mpz_class& value2) {
//    return mpz_cmp(value1.get_mpz_t(), value2.get_mpz_t()) == 1;
//}

std::string byteArrayToString(BYTE* byteArray, size_t length) {
    std::stringstream ss;
    for (size_t i = 0; i < length; ++i) {
        ss << static_cast<int>(byteArray[i]); // Append the digit to the stringstream
    }
    return ss.str(); // Convert stringstream to string and return
}
static int Inteter_reverseBytes(int i) {
    return ((i >> 24)) |
        ((i >> 8) & 0xFF00) |
        ((i << 8) & 0xFF0000) |
        ((i << 24));
}

std::vector<unsigned char> hexStringToByteArray(const std::string& hexString) {
    std::vector<unsigned char> byteArray;

    // Iterate over the hexadecimal string two characters at a time
    for (size_t i = 0; i < hexString.length(); i += 2) {
        // Extract two characters representing one byte
        std::string byteString = hexString.substr(i, 2);

        // Convert the two characters to an integer value
        unsigned char byte = static_cast<unsigned char>(std::stoi(byteString, nullptr, 16));

        // Store the byte in the byte array
        byteArray.push_back(byte);
    }

    return byteArray;
}
static int* stripLeadingZeroBytes(byte* a, int len) {
    int byteLength = len;
    int keep;

    // Find first nonzero byte
    for (keep = 0; keep < byteLength && a[keep] == 0; keep++)
        ;

    // Allocate new array and copy relevant part of input array
    int intLength = ((byteLength - keep) + 3) >> 2;
    int* result = new int[intLength];
    int b = byteLength - 1;
    for (int i = intLength - 1; i >= 0; i--) {
        result[i] = a[b--] & 0xff;
        int bytesRemaining = b - keep + 1;
        int bytesToTransfer = (3 < bytesRemaining) ? 3 : bytesRemaining;
        //int bytesToTransfer = Math.min(3, bytesRemaining);
        for (int j = 8; j <= (bytesToTransfer << 3); j += 8)
            result[i] |= ((a[b--] & 0xff) << j);
    }
    return result;
}
int  meetTargets(int* p_Soln, int    p_nLen, int range)
{
    int             w_Rtn = -1;
    BYTE            w_SolnData[256];
    BYTE            w_SolnDataHash[32];
    BYTE* w_SolnHashByte;

    std::string     sb = "";
    std::string     strFinalHash = "";
    char            w_buff[24];


    for (int n = 0; n < p_nLen; n++)
    {
        sprintf(w_buff, "%08x", Inteter_reverseBytes(p_Soln[n]));
        sb += w_buff;
    }
    std::vector<unsigned char> byteArray = hexStringToByteArray(sb);

    int tt = 0;
    memset(w_SolnData, 0x00, 256);
    for (unsigned char byte : byteArray) {
        w_SolnData[tt] = static_cast<int>(byte);
        tt++;
    }
       //. Get Hash 
    getDoubleHash(w_SolnData, tt, w_SolnDataHash);

    w_SolnHashByte = reverseBytes(w_SolnDataHash, 32);



    std::string   hashString = byteArrayToString(w_SolnHashByte, 32);
    for (int i = 0; i < 32; i++) {
        sprintf(w_buff, "%02x", w_SolnHashByte[i]);
        strFinalHash += w_buff;
    }


    int* aaa = stripLeadingZeroBytes(w_SolnHashByte, 32);

    if (aaa[0] < 0)
    {
        delete[] w_SolnHashByte;
        return w_Rtn;
    }
    else {
        printf("SolnHashByte range = %d ", range);
        for (int k = 0; k < 32; k++) {
            printf("%02x", w_SolnHashByte[k]);
        }
        printf("\n ");
    }
    delete[] aaa;
    //return 0;

    bool    w_bFind = false;
    for (int i = 0; i < 32; i++) {
        //printf("w_SolnHashByte = %d \n", w_SolnHashByte[i]);
        //printf("g_target_data = %d \n", g_target_data[i]);
        if (w_SolnHashByte[i] == g_target_data[i]) {
            continue;
        }
        else if (w_SolnHashByte[i] < g_target_data[i]) {
            w_bFind = true;
            break;
        }
        else {
            w_bFind = false;
            break;
        }

    }
    delete[] w_SolnHashByte;

    if (w_bFind == true) {
        //. OK
        w_Rtn = 0;
    }
    return w_Rtn;
}

int cuckoo_scanhash(const BYTE *aHeader, uint32_t p_nonce, uint32_t *proof) {
  int nthreads = 16384;
  int trims   = 32;
  int tpb = 0;
  int range = 1;
  u64 *bits = NULL;
  int ret = -1;
  unsigned char header[80];

  if (!tpb) // if not set, then default threads per block to roughly square root of threads
    for (tpb = 1; tpb*tpb < nthreads; tpb *= 2) ;

  //if (range > 1)
    //printf("-%d", nonce+range-1);
  //printf(") with 50%% edges, %d trims, %d threads %d per block\n", trims, nthreads, tpb);

  //flip80(header, aHeader);

  cuckoo_ctx ctx(nthreads);

  BYTE headernonce[HEADERLEN];
  u32 hdrlen = HEADERLEN-4;
  memcpy(headernonce, aHeader, hdrlen);
  memset(headernonce+hdrlen, 0, sizeof(headernonce)-hdrlen);

  u64 edgeBytes = NEDGES/8, nodeBytes = TWICE_WORDS*sizeof(u32);
  checkCudaErrors(cudaMalloc((void**)&ctx.alive.bits, edgeBytes));
  checkCudaErrors(cudaMalloc((void**)&ctx.nonleaf.bits, nodeBytes));

  int edgeUnit=0, nodeUnit=0;
  u64 eb = edgeBytes, nb = nodeBytes;
  for (; eb >= 1024; eb>>=10) edgeUnit++;
  for (; nb >= 1024; nb>>=10) nodeUnit++;
  //printf("Using %d%cB edge and %d%cB node memory.\n",
     //(int)eb, " KMGT"[edgeUnit], (int)nb, " KMGT"[nodeUnit]);

  cuckoo_ctx *device_ctx;
  checkCudaErrors(cudaMalloc((void**)&device_ctx, sizeof(cuckoo_ctx)));

  cudaEvent_t start, stop;
  checkCudaErrors(cudaEventCreate(&start));
  checkCudaErrors(cudaEventCreate(&stop));
  for (int r = 0; r < range; r++) {
    cudaEventRecord(start, NULL);
    checkCudaErrors(cudaMemset(ctx.alive.bits, 0, edgeBytes));
    ctx.setheadernonce(headernonce, p_nonce + r);
    /*
    printf("Cuckoo miner working on header: ");
    for (int i=0; i<HEADERLEN; i++) {
      printf("%x", (unsigned char)*(headernonce + i));
    }
    printf("\n");
    */
    cudaMemcpy(device_ctx, &ctx, sizeof(cuckoo_ctx), cudaMemcpyHostToDevice);
    for (u32 round=0; round < trims; round++) {
      for (u32 uorv = 0; uorv < 2; uorv++) {
        for (u32 part = 0; part <= PART_MASK; part++) {
          checkCudaErrors(cudaMemset(ctx.nonleaf.bits, 0, nodeBytes));
          count_node_deg<<<nthreads/tpb,tpb >>>(device_ctx, uorv, part);
          kill_leaf_edges<<<nthreads/tpb,tpb >>>(device_ctx, uorv, part);
        }
      }
    }
  
    bits = (u64 *)calloc(NEDGES/64, sizeof(u64));
    assert(bits != NULL);
    cudaMemcpy(bits, ctx.alive.bits, (NEDGES/64) * sizeof(u64), cudaMemcpyDeviceToHost);

    cudaEventRecord(stop, NULL);
    cudaEventSynchronize(stop);
    float duration;
    cudaEventElapsedTime(&duration, start, stop);
    u32 cnt = 0;
    for (int i = 0; i < NEDGES/64; i++)
      cnt += _popcountll(~bits[i]);
    u32 load = (u32)(100L * cnt / CUCKOO_SIZE);
    //printf("nonce %d: %d trims completed in %.3f seconds final load %d%%\n",
      //      nonce+r, trims, duration / 1000.0f, load);
  
    if (load >= 90) {
      printf("overloaded! exiting...\n");
      goto out;
    }
  
    cuckoo_hash cuckoo = cuckoo_hash();
    node_t us[MAXPATHLEN], vs[MAXPATHLEN];
    for (edge_t block = 0; block < NEDGES; block += 64) {
      u64 alive64 = ~bits[block/64];
      for (edge_t nonce = block-1; alive64; ) { // -1 compensates for 1-based ffs
        u32 ffs = __builtin_ffsll(alive64);
        nonce += ffs; alive64 >>= ffs;
        node_t u0=sipnode(&ctx.sip_keys, nonce, 0), v0=sipnode(&ctx.sip_keys, nonce, 1);
        if (u0) {
          u32 nu = path(cuckoo, u0, us), nv = path(cuckoo, v0, vs);
          if (nu == UINT_MAX || nv == UINT_MAX) 
            break;
          if (us[nu] == vs[nv]) {
            u32 min = nu < nv ? nu : nv;
            for (nu -= min, nv -= min; us[nu] != vs[nv]; nu++, nv++) ;
            u32 len = nu + nv + 1;
            if (len == PROOFSIZE) {
	          //printf("%4d-cycle found at %d:%d%%   nonce = %d\n", len, 0, (u32)(nonce*100L/NEDGES), nonce);
              //printf("Solution");
              std::set<edge> cycle;
              u32 n = 0;
              cycle.insert(edge(*us, *vs));
              while (nu--)
                cycle.insert(edge(us[(nu+1)&~1], us[nu|1])); // u's in even position; v's in odd
              while (nv--)
                cycle.insert(edge(vs[nv|1], vs[(nv+1)&~1])); // u's in odd position; v's in even

              for (edge_t blk = 0; blk < NEDGES; blk += 64) {
                u64 alv64 = ~bits[blk/64];
                for (edge_t nce = blk-1; alv64; ) { // -1 compensates for 1-based ffs
                  u32 ffs = __builtin_ffsll(alv64);
                  nce += ffs; alv64 >>= ffs;
                  edge e(sipnode(&ctx.sip_keys, nce, 0), sipnode(&ctx.sip_keys, nce, 1));
                  if (cycle.find(e) != cycle.end()) {
                    //printf(" %jx", (uintmax_t)nce);
		                
                    proof[n] = nce;
                    if (PROOFSIZE > 2)
                      cycle.erase(e);
                    n++;
                  }
                  if (ffs & 64) break; // can't shift by 64
                }
              }
              assert(n==PROOFSIZE);
              //printf("\n");
              //. Soluttion OK
              int pow_rc =  verify(proof, &ctx.sip_keys);
              if (pow_rc == POW_OK) {
                  //printf("verify OK\n");
                  if (meetTargets((int*)proof, PROOFSIZE, p_nonce) == 0) {
                      //printf("CCC test - cipher -- k1=%llx, k2=%llx, k3=%llx, k4=%llx \n",
                      //    ctx.sip_keys.k0,
                      //    ctx.sip_keys.k1,
                      //    ctx.sip_keys.k2,
                      //    ctx.sip_keys.k3
                      //);

                      ret = 0;
                      goto out;
                  }
              }
              else {
                  //printf("verify Faild");
              }
            }
          } 
          else if (nu < nv) {
            while (nu--)
              cuckoo.set(us[nu+1], us[nu]);
            cuckoo.set(u0, v0);
          } else {
            while (nv--)
              cuckoo.set(vs[nv+1], vs[nv]);
            cuckoo.set(v0, u0);
          }
        }
        if (ffs & 64) break; // can't shift by 64
      }
    }
  }
out:
  checkCudaErrors(cudaEventDestroy(stop));
  checkCudaErrors(cudaEventDestroy(start));
  checkCudaErrors(cudaFree(device_ctx));
  checkCudaErrors(cudaFree(ctx.nonleaf.bits));
  checkCudaErrors(cudaFree(ctx.alive.bits));
  free(bits);
  return ret;
}
