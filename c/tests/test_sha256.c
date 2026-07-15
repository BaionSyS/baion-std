/* BAION STD C — SHA-256 Tests (public cut)
   FIPS 180-4 standard vectors plus streaming-update equivalence. */

#include "baion/sha256.h"
#include "test_util.h"

static void hex32(const uint8_t hash[32], char hex[65])
{
    for (int i = 0; i < 32; i++)
        sprintf(hex + i * 2, "%02x", hash[i]);
    hex[64] = '\0';
}

static void test_fips_empty(void)
{
    uint8_t hash[32];
    char hex[65];
    baion_sha256((const uint8_t*)"", 0, hash);
    hex32(hash, hex);
    ASSERT_STR_EQ(hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
}

static void test_fips_abc(void)
{
    uint8_t hash[32];
    char hex[65];
    baion_sha256((const uint8_t*)"abc", 3, hash);
    hex32(hash, hex);
    ASSERT_STR_EQ(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

static void test_fips_448_bit(void)
{
    const char* msg = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    uint8_t hash[32];
    char hex[65];
    baion_sha256((const uint8_t*)msg, strlen(msg), hash);
    hex32(hash, hex);
    ASSERT_STR_EQ(hex, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
}

static void test_streaming_matches_one_shot(void)
{
    const char* msg = "the quick brown fox jumps over the lazy dog, repeatedly, "
                      "until the buffer boundary at 64 bytes is crossed twice.";
    uint8_t one_shot[32];
    baion_sha256((const uint8_t*)msg, strlen(msg), one_shot);

    /* Feed in uneven chunks to exercise the 64-byte block boundary */
    baion_sha256_ctx ctx;
    baion_sha256_init(&ctx);
    size_t len = strlen(msg);
    size_t pos = 0;
    size_t chunk = 7;
    while (pos < len)
    {
        size_t n = (pos + chunk > len) ? (len - pos) : chunk;
        baion_sha256_update(&ctx, (const uint8_t*)msg + pos, n);
        pos += n;
        chunk += 5;
    }
    uint8_t streamed[32];
    baion_sha256_final(&ctx, streamed);

    ASSERT_MEM_EQ(one_shot, streamed, 32);
}

int main(void)
{
    printf("test_sha256:\n");
    RUN_TEST(test_fips_empty);
    RUN_TEST(test_fips_abc);
    RUN_TEST(test_fips_448_bit);
    RUN_TEST(test_streaming_matches_one_shot);
    TEST_SUMMARY();
    return _test_failed;
}
