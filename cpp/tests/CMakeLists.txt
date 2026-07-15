# BAION canonical JSON + SHA-256 for C++ — tests
enable_testing()

# Shared cross-implementation fixture at the repo root (one level above cpp/)
set(FIXTURE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../../conformance_reference.json")

# Google Test — prefer an installed package; fall back to FetchContent.
# (Offline builds: set -DFETCHCONTENT_SOURCE_DIR_GOOGLETEST=<local checkout>.)
find_package(GTest 1.14 QUIET)
if(NOT GTest_FOUND)
    include(FetchContent)
    FetchContent_Declare(
        googletest
        GIT_REPOSITORY https://github.com/google/googletest.git
        GIT_TAG        v1.14.0
        GIT_SHALLOW    TRUE
    )
    FetchContent_MakeAvailable(googletest)
endif()

# ── Conformance tests ──────────────────────────────────────────

add_executable(test_canonical_json test_canonical_json.cpp)
target_link_libraries(test_canonical_json PRIVATE baion_std_public GTest::gtest_main)
add_test(NAME CanonicalJSON COMMAND test_canonical_json)

add_executable(test_hash test_hash.cpp)
target_link_libraries(test_hash PRIVATE baion_std_public GTest::gtest_main)
add_test(NAME Hash COMMAND test_hash)

add_executable(test_conformance test_conformance.cpp)
target_link_libraries(test_conformance PRIVATE baion_std_public GTest::gtest_main)
target_compile_definitions(test_conformance PRIVATE FIXTURE_PATH="${FIXTURE_PATH}")
add_test(NAME Conformance COMMAND test_conformance)
