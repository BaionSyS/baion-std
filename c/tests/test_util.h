#ifndef BAION_TEST_UTIL_H
#define BAION_TEST_UTIL_H

#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static int _test_passed = 0;
static int _test_failed = 0;
static int _current_test_ok = 1;

#define RUN_TEST(fn)                                                                               \
    do                                                                                             \
    {                                                                                              \
        printf("  %-50s ", #fn);                                                                   \
        fflush(stdout);                                                                            \
        _current_test_ok = 1;                                                                      \
        fn();                                                                                      \
        if (_current_test_ok)                                                                      \
        {                                                                                          \
            printf("PASS\n");                                                                      \
            _test_passed++;                                                                        \
        }                                                                                          \
        else                                                                                       \
        {                                                                                          \
            _test_failed++;                                                                        \
        }                                                                                          \
    } while (0)

#define ASSERT_TRUE(cond)                                                                          \
    do                                                                                             \
    {                                                                                              \
        if (!(cond))                                                                               \
        {                                                                                          \
            printf("FAIL\n    line %d: %s\n", __LINE__, #cond);                                    \
            _current_test_ok = 0;                                                                  \
            return;                                                                                \
        }                                                                                          \
    } while (0)

#define ASSERT_INT_EQ(a, b)                                                                        \
    do                                                                                             \
    {                                                                                              \
        long long _a = (long long)(a), _b = (long long)(b);                                        \
        if (_a != _b)                                                                              \
        {                                                                                          \
            printf("FAIL\n    line %d: %" PRId64 " != %" PRId64 "\n",                              \
                   __LINE__,                                                                       \
                   (int64_t)_a,                                                                    \
                   (int64_t)_b);                                                                   \
            _current_test_ok = 0;                                                                  \
            return;                                                                                \
        }                                                                                          \
    } while (0)

#define ASSERT_U64_EQ(a, b)                                                                        \
    do                                                                                             \
    {                                                                                              \
        uint64_t _a = (uint64_t)(a), _b = (uint64_t)(b);                                           \
        if (_a != _b)                                                                              \
        {                                                                                          \
            printf("FAIL\n    line %d: 0x%016" PRIx64 " != 0x%016" PRIx64 "\n", __LINE__, _a, _b); \
            _current_test_ok = 0;                                                                  \
            return;                                                                                \
        }                                                                                          \
    } while (0)

#define ASSERT_STR_EQ(a, b)                                                                        \
    do                                                                                             \
    {                                                                                              \
        const char *_a = (a), *_b = (b);                                                           \
        if (strcmp(_a, _b) != 0)                                                                   \
        {                                                                                          \
            printf("FAIL\n    line %d:\n      got:    \"%s\"\n      expect: \"%s\"\n",             \
                   __LINE__,                                                                       \
                   _a,                                                                             \
                   _b);                                                                            \
            _current_test_ok = 0;                                                                  \
            return;                                                                                \
        }                                                                                          \
    } while (0)

#define ASSERT_DOUBLE_EQ(a, b)                                                                     \
    do                                                                                             \
    {                                                                                              \
        double _a = (double)(a), _b = (double)(b);                                                 \
        if (fabs(_a - _b) > 1e-12)                                                                 \
        {                                                                                          \
            printf("FAIL\n    line %d: %g != %g\n", __LINE__, _a, _b);                             \
            _current_test_ok = 0;                                                                  \
            return;                                                                                \
        }                                                                                          \
    } while (0)

#define ASSERT_MEM_EQ(a, b, n)                                                                     \
    do                                                                                             \
    {                                                                                              \
        if (memcmp((a), (b), (n)) != 0)                                                            \
        {                                                                                          \
            printf("FAIL\n    line %d: memory mismatch (%zu bytes)\n", __LINE__, (size_t)(n));     \
            _current_test_ok = 0;                                                                  \
            return;                                                                                \
        }                                                                                          \
    } while (0)

#define TEST_SUMMARY()                                                                             \
    do                                                                                             \
    {                                                                                              \
        printf("\n  %d passed, %d failed\n", _test_passed, _test_failed);                          \
    } while (0)

#endif /* BAION_TEST_UTIL_H */
