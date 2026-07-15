cmake_minimum_required(VERSION 3.14)
project(baion_std_c C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

add_compile_options(-Wall -Wextra -Werror -pedantic)
add_compile_definitions(_GNU_SOURCE)

include(FetchContent)

# Fetch cJSON (single .c/.h JSON parser).
# Offline builds: pre-populate with -DFETCHCONTENT_SOURCE_DIR_CJSON=/path/to/cJSON
FetchContent_Declare(
    cjson
    GIT_REPOSITORY https://github.com/DaveGamble/cJSON.git
    GIT_TAG v1.7.18
)
FetchContent_GetProperties(cjson)
if(NOT cjson_POPULATED)
    FetchContent_Populate(cjson)
endif()

# Static library — public cut: canonical JSON + SHA-256 only
add_library(baion_std_c STATIC
    src/sha256.c
    src/canonical_json.c
    ${cjson_SOURCE_DIR}/cJSON.c
)

target_include_directories(baion_std_c
    PUBLIC include
    PUBLIC ${cjson_SOURCE_DIR}
)

target_link_libraries(baion_std_c PRIVATE m)

# Suppress warnings in vendored cJSON
set_source_files_properties(${cjson_SOURCE_DIR}/cJSON.c PROPERTIES
    COMPILE_FLAGS "-Wno-pedantic -Wno-float-equal"
)

# CLI: stdin JSON -> canonical bytes -> SHA-256 lowercase hex
add_executable(baion_canon_hash tools/baion_canon_hash.c)
target_link_libraries(baion_canon_hash PRIVATE baion_std_c)
set_target_properties(baion_canon_hash PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/bin"
)

# Tests
enable_testing()
add_subdirectory(tests)
