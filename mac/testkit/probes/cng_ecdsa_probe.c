/*
 * cng_ecdsa_probe.exe - does Windows CNG ECDSA P-256 verification work (under our Wine)?
 * Copyright (c) 2026 the PeakPack project. MIT licence.
 *
 * Why: .NET's ECDsa (PeakPack's mod-list signature check) imports the public key through NCrypt with a
 * generic EC blob plus an NCRYPTBUFFER_ECC_CURVE_NAME parameter. CrossOver 26.3's Wine ncrypt only imports RSA
 * and rejects any parameter list ("NCryptImportKey Parameter information not implemented").
 * Three paths, each with a known-good signature (must verify) and a tampered one (must be rejected):
 *   bcrypt          BCryptImportKeyPair(ECDSA_P256, ECCPUBLICBLOB "ECS1") + BCryptVerifySignature
 *   ncrypt_specific NCryptImportKey(ECCPUBLICBLOB "ECS1", no parameters) + NCryptVerifySignature
 *   ncrypt_dotnet   NCryptImportKey(ECCPUBLICBLOB generic "ECDP", NCRYPTBUFFER_ECC_CURVE_NAME "nistP256")
 *                   + NCryptVerifySignature (the .NET path)
 * Test vector: P-256 key, SHA-256 of VEC_MSG, signature r||s, generated with OpenSSL (no secret involved).
 * Output: "RESULT key=value" lines; exit 0 when every path behaves, else 1.
 * Build: x86_64-w64-mingw32-clang -O1 -Wall -o cng_ecdsa_probe.exe cng_ecdsa_probe.c -lbcrypt -lncrypt
 */
#include <windows.h>
#include <bcrypt.h>
#include <ncrypt.h>
#include <stdio.h>
#include <string.h>

#ifndef BCRYPT_ECDSA_PUBLIC_GENERIC_MAGIC
#define BCRYPT_ECDSA_PUBLIC_GENERIC_MAGIC 0x50444345 /* ECDP */
#endif
#ifndef NCRYPTBUFFER_ECC_CURVE_NAME
#define NCRYPTBUFFER_ECC_CURVE_NAME 60
#endif
#ifndef STATUS_INVALID_SIGNATURE
#define STATUS_INVALID_SIGNATURE ((NTSTATUS)0xC000A000L)
#endif

static const unsigned char VEC_X[32] = {0x5b,0xcd,0x56,0x6e,0xcf,0x0e,0x2f,0xe6,0x0e,0x6b,0xac,0xdf,0x7b,0x05,0xc2,0xa7,0xed,0x78,0x0e,0x91,0xd6,0xf1,0x03,0xa1,0xef,0x8d,0x4e,0x71,0x55,0xc6,0x09,0x69};
static const unsigned char VEC_Y[32] = {0xf2,0xf5,0xd8,0x9c,0x0a,0x50,0xc1,0x15,0x66,0x8f,0x26,0xae,0x90,0xcc,0x14,0x8c,0x1b,0x2c,0x2d,0xfb,0xad,0xc1,0x44,0x30,0x53,0x9e,0xad,0xc9,0x9c,0xde,0xaa,0x9e};
static const unsigned char VEC_SIG[64] = {0x1d,0x8a,0x03,0x94,0x62,0x03,0xdb,0x3a,0x4e,0x93,0xe0,0x81,0x10,0x50,0x13,0xd8,0x94,0x0e,0x3a,0x44,0xec,0x39,0x58,0x1c,0x4d,0x0d,0x5a,0xfe,0xf6,0x3c,0x98,0xfe,0x1e,0xd0,0xeb,0x7c,0xd8,0xf1,0x0a,0xe2,0xac,0x33,0x8b,0xdb,0x03,0x75,0x64,0xae,0x3c,0x18,0x23,0x9d,0xab,0x07,0xca,0x2e,0xec,0x91,0xef,0x3a,0x28,0x42,0x85,0x90};
static const char VEC_MSG[] = "PeakPack ECDSA P-256 probe message v1";

static int failures;

static void blob(unsigned char *out, ULONG magic)
{
    BCRYPT_ECCKEY_BLOB h;
    h.dwMagic = magic;
    h.cbKey = 32;
    memcpy(out, &h, sizeof(h));
    memcpy(out + sizeof(h), VEC_X, 32);
    memcpy(out + sizeof(h) + 32, VEC_Y, 32);
}

static int sha256(unsigned char *out)
{
    BCRYPT_ALG_HANDLE alg;
    BCRYPT_HASH_HANDLE h;
    NTSTATUS st;
    if ((st = BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, NULL, 0))) return (int)st;
    if (!(st = BCryptCreateHash(alg, &h, NULL, 0, NULL, 0, 0)))
    {
        if (!(st = BCryptHashData(h, (PUCHAR)VEC_MSG, (ULONG)strlen(VEC_MSG), 0)))
            st = BCryptFinishHash(h, out, 32, 0);
        BCryptDestroyHash(h);
    }
    BCryptCloseAlgorithmProvider(alg, 0);
    return (int)st;
}

/* expect: good signature verifies, bad one is rejected */
static void report(const char *path, long imp, long good, long bad, int good_ok, int bad_ok)
{
    printf("RESULT %s_import=0x%08lx\nRESULT %s_verify_good=0x%08lx\nRESULT %s_verify_tampered=0x%08lx\n",
           path, (unsigned long)imp, path, (unsigned long)good, path, (unsigned long)bad);
    printf("RESULT %s=%s\n", path, (imp == 0 && good_ok && bad_ok) ? "ok" : "FAIL");
    if (!(imp == 0 && good_ok && bad_ok)) failures++;
}

int main(void)
{
    unsigned char key_blob[sizeof(BCRYPT_ECCKEY_BLOB) + 64], hash[32], bad_sig[64];
    BCRYPT_ALG_HANDLE alg = NULL;
    BCRYPT_KEY_HANDLE bkey = NULL;
    NCRYPT_PROV_HANDLE prov = 0;
    NCRYPT_KEY_HANDLE nkey = 0;
    NTSTATUS st, g, b;
    SECURITY_STATUS ss, ng, nb;
    int hs;

    setvbuf(stdout, NULL, _IONBF, 0);
    memcpy(bad_sig, VEC_SIG, 64);
    bad_sig[10] ^= 0x01;
    hs = sha256(hash);
    printf("RESULT probe=cng_ecdsa\nRESULT sha256_status=0x%08x\n", hs);
    if (hs) { printf("RESULT exit=1\n"); return 1; }

    /* 1. bcrypt */
    blob(key_blob, BCRYPT_ECDSA_PUBLIC_P256_MAGIC);
    st = BCryptOpenAlgorithmProvider(&alg, BCRYPT_ECDSA_P256_ALGORITHM, NULL, 0);
    if (!st) st = BCryptImportKeyPair(alg, NULL, BCRYPT_ECCPUBLIC_BLOB, &bkey, key_blob, sizeof(key_blob), 0);
    g = b = (NTSTATUS)-1;
    if (!st)
    {
        g = BCryptVerifySignature(bkey, NULL, hash, 32, (PUCHAR)VEC_SIG, 64, 0);
        b = BCryptVerifySignature(bkey, NULL, hash, 32, bad_sig, 64, 0);
        BCryptDestroyKey(bkey);
    }
    if (alg) BCryptCloseAlgorithmProvider(alg, 0);
    report("bcrypt", (long)st, (long)g, (long)b, g == 0, b == STATUS_INVALID_SIGNATURE);

    /* 2. ncrypt, specific P-256 blob, no parameters */
    ss = NCryptOpenStorageProvider(&prov, MS_KEY_STORAGE_PROVIDER, 0);
    printf("RESULT ncrypt_open_provider=0x%08lx\n", (unsigned long)ss);
    ng = nb = -1;
    if (!ss) ss = NCryptImportKey(prov, 0, BCRYPT_ECCPUBLIC_BLOB, NULL, &nkey, key_blob, sizeof(key_blob), 0);
    if (!ss)
    {
        ng = NCryptVerifySignature(nkey, NULL, hash, 32, (PBYTE)VEC_SIG, 64, 0);
        nb = NCryptVerifySignature(nkey, NULL, hash, 32, bad_sig, 64, 0);
        NCryptFreeObject(nkey); nkey = 0;
    }
    report("ncrypt_specific", (long)ss, (long)ng, (long)nb, ng == 0, nb != 0);

    /* 3. ncrypt, generic EC blob + curve-name parameter (what .NET's ECDsa does) */
    if (prov)
    {
        static WCHAR curve[] = L"nistP256";
        NCryptBuffer buf;
        NCryptBufferDesc desc;
        WCHAR group[64];
        DWORD got = 0;
        buf.cbBuffer = (ULONG)sizeof(curve);
        buf.BufferType = NCRYPTBUFFER_ECC_CURVE_NAME;
        buf.pvBuffer = curve;
        desc.ulVersion = NCRYPTBUFFER_VERSION;
        desc.cBuffers = 1;
        desc.pBuffers = &buf;
        blob(key_blob, BCRYPT_ECDSA_PUBLIC_GENERIC_MAGIC);
        ng = nb = -1;
        ss = NCryptImportKey(prov, 0, BCRYPT_ECCPUBLIC_BLOB, &desc, &nkey, key_blob, sizeof(key_blob), 0);
        if (!ss)
        {
            group[0] = 0;
            if (!NCryptGetProperty(nkey, NCRYPT_ALGORITHM_GROUP_PROPERTY, (PBYTE)group, sizeof(group), &got, 0))
                printf("RESULT ncrypt_dotnet_algorithm_group=%ls\n", group);
            ng = NCryptVerifySignature(nkey, NULL, hash, 32, (PBYTE)VEC_SIG, 64, 0);
            nb = NCryptVerifySignature(nkey, NULL, hash, 32, bad_sig, 64, 0);
            NCryptFreeObject(nkey);
        }
        report("ncrypt_dotnet", (long)ss, (long)ng, (long)nb, ng == 0, nb != 0);
        NCryptFreeObject(prov);
    }
    else
        report("ncrypt_dotnet", -1, -1, -1, 0, 0);

    printf("RESULT exit=%d\n", failures ? 1 : 0);
    return failures ? 1 : 0;
}
