#ifndef INCLUDE_SIPHASH_H
#define INCLUDE_SIPHASH_H
#include <stdint.h>    // for types uint32_t,uint64_t
#include <immintrin.h> // for _mm256_* intrinsics
#ifndef __APPLE__
#include <endian.h>    // for htole32/64
#else
#include <machine/endian.h>
#include <libkern/OSByteOrder.h>
#define htole32(x) OSSwapHostToLittleInt32(x)
#define htole64(x) OSSwapHostToLittleInt64(x)
#endif

#include <stdint.h>
#include <string.h>

// save some keystrokes since i'm a lazy typer
typedef uint32_t u32;
typedef uint64_t u64;

// siphash uses a pair of 64-bit keys,
typedef struct {
  u64 k0;
  u64 k1;
  u64 k2;
  u64 k3;
} siphash_keys;
 
#define U8TO64_LE(p) ((p))
#define CK_U8(b) ((unsigned long long)(b & 0xFF))
#define CK_U8TO64(p, i) ( CK_U8(p[i])					\
						| (CK_U8(p[i + 1]) << 8)		\
						| (CK_U8(p[i + 2]) << 16)		\
						| (CK_U8(p[i + 3]) << 24)		\
						| (CK_U8(p[i + 4]) << 32)		\
						| (CK_U8(p[i + 5]) << 40)		\
						| (CK_U8(p[i + 6]) << 48)		\
						| (CK_U8(p[i + 7]) << 56))

// set siphash keys from 16 byte char array
static void setkeys(siphash_keys *keys, const BYTE *keybuf) {
  keys->k0 = CK_U8TO64(keybuf, 0);
  keys->k1 = CK_U8TO64(keybuf, 8);
  keys->k2 = CK_U8TO64(keybuf, 16);
  keys->k3 = CK_U8TO64(keybuf, 24);
  //k0 = CK_U8TO64(keybuf, 0);
  //k1 = CK_U8TO64(keybuf, 8);
  //k2 = CK_U8TO64(keybuf, 16);
  //k3 = CK_U8TO64(keybuf, 24);
  // printf("C Set Key - k0=%llu, k1=%llu, k2=%llu, k3=%llu \n",
		//keys->k0, keys->k1, keys->k2, keys->k3);
}

#define ROTL(x,b) (u64)( ((x) << (b)) | ( (x) >> (64 - (b))) )
#define SIPROUND \
  do { \
    v0 += v1; v2 += v3; v1 = ROTL(v1,13); \
    v3 = ROTL(v3,16); v1 ^= v0; v3 ^= v2; \
    v0 = ROTL(v0,32); v2 += v1; v0 += v3; \
    v1 = ROTL(v1,17);   v3 = ROTL(v3,21); \
    v1 ^= v2; v3 ^= v0; v2 = ROTL(v2,32); \
  } while(0)
 
// SipHash-2-4 specialized to precomputed key and 8 byte nonces
static u64 siphash24(const siphash_keys *keys, const u32 nonce) {
  u64 v0 = keys->k0, v1 = keys->k1, v2 = keys->k2, v3 = keys->k3 ^ nonce;
  SIPROUND; SIPROUND;
  v0 ^= nonce;
  v2 ^= 0xff;
  SIPROUND; SIPROUND; SIPROUND; SIPROUND;
  return (v0 ^ v1) ^ (v2  ^ v3);

/*
  unsigned long long v0 = keys->k0, v1 = keys->k1, v2 = keys->k2, v3 = keys->k3 ^ nonce;
  v0 += v1;
  v2 += v3;
  v1 = (v1 << 13) | v1 >> 51;
  v3 = (v3 << 16) | v3 >> 48;
  v1 ^= v0;
  v3 ^= v2;
  v0 = (v0 << 32) | v0 >> 32;
  v2 += v1;
  v0 += v3;
  v1 = (v1 << 17) | v1 >> 47;
  v3 = (v3 << 21) | v3 >> 43;
  v1 ^= v2;
  v3 ^= v0;
  v2 = (v2 << 32) | v2 >> 32;

  v0 += v1;
  v2 += v3;
  v1 = (v1 << 13) | v1 >> 51;
  v3 = (v3 << 16) | v3 >> 48;
  v1 ^= v0;
  v3 ^= v2;
  v0 = (v0 << 32) | v0 >> 32;
  v2 += v1;
  v0 += v3;
  v1 = (v1 << 17) | v1 >> 47;
  v3 = (v3 << 21) | v3 >> 43;
  v1 ^= v2;
  v3 ^= v0;
  v2 = (v2 << 32) | v2 >> 32;

  v0 ^= nonce;
  v2 ^= 0xff;

  v0 += v1;
  v2 += v3;
  v1 = (v1 << 13) | v1 >> 51;
  v3 = (v3 << 16) | v3 >> 48;
  v1 ^= v0;
  v3 ^= v2;
  v0 = (v0 << 32) | v0 >> 32;
  v2 += v1;
  v0 += v3;
  v1 = (v1 << 17) | v1 >> 47;
  v3 = (v3 << 21) | v3 >> 43;
  v1 ^= v2;
  v3 ^= v0;
  v2 = (v2 << 32) | v2 >> 32;

  v0 += v1;
  v2 += v3;
  v1 = (v1 << 13) | v1 >> 51;
  v3 = (v3 << 16) | v3 >> 48;
  v1 ^= v0;
  v3 ^= v2;
  v0 = (v0 << 32) | v0 >> 32;
  v2 += v1;
  v0 += v3;
  v1 = (v1 << 17) | v1 >> 47;
  v3 = (v3 << 21) | v3 >> 43;
  v1 ^= v2;
  v3 ^= v0;
  v2 = (v2 << 32) | v2 >> 32;

  v0 += v1;
  v2 += v3;
  v1 = (v1 << 13) | v1 >> 51;
  v3 = (v3 << 16) | v3 >> 48;
  v1 ^= v0;
  v3 ^= v2;
  v0 = (v0 << 32) | v0 >> 32;
  v2 += v1;
  v0 += v3;
  v1 = (v1 << 17) | v1 >> 47;
  v3 = (v3 << 21) | v3 >> 43;
  v1 ^= v2;
  v3 ^= v0;
  v2 = (v2 << 32) | v2 >> 32;

  v0 += v1;
  v2 += v3;
  v1 = (v1 << 13) | v1 >> 51;
  v3 = (v3 << 16) | v3 >> 48;
  v1 ^= v0;
  v3 ^= v2;
  v0 = (v0 << 32) | v0 >> 32;
  v2 += v1;
  v0 += v3;
  v1 = (v1 << 17) | v1 >> 47;
  v3 = (v3 << 21) | v3 >> 43;
  v1 ^= v2;
  v3 ^= v0;
  v2 = (v2 << 32) | v2 >> 32;

  return (v0 ^ v1) ^ (v2 ^ v3);
*/
}

#endif // ifdef INCLUDE_SIPHASH_H
