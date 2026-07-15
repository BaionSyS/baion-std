# BAION STD C — Tests (public cut)

# Shared cross-lineage fixture at the repo root (one level above c/)
set(FIXTURE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../../conformance_reference.json")

# --- test_sha256 ---
add_executable(test_sha256 test_sha256.c)
target_link_libraries(test_sha256 PRIVATE baion_std_c)
target_include_directories(test_sha256 PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
add_test(NAME test_sha256 COMMAND test_sha256)

# --- test_canonical_json ---
add_executable(test_canonical_json test_canonical_json.c)
target_link_libraries(test_canonical_json PRIVATE baion_std_c)
target_include_directories(test_canonical_json PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
add_test(NAME test_canonical_json COMMAND test_canonical_json)

# --- test_conformance ---
add_executable(test_conformance test_conformance.c)
target_link_libraries(test_conformance PRIVATE baion_std_c)
target_include_directories(test_conformance PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_definitions(test_conformance PRIVATE FIXTURE_PATH="${FIXTURE_PATH}")
add_test(NAME test_conformance COMMAND test_conformance)
