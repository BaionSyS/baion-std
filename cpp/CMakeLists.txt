# BAION canonical JSON + SHA-256 for C++ — public standalone library.
cmake_minimum_required(VERSION 3.20)
project(baion_std_cpp_public
    VERSION 0.1.0
    LANGUAGES CXX
    DESCRIPTION "BAION canonical JSON + SHA-256 (C++)"
)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ── Compiler flags ──────────────────────────────────────────────
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    add_compile_options(
        -Wall -Wextra -Wpedantic -Werror
        -fno-exceptions                 # library components don't throw
        -fno-rtti                       # no runtime type info needed
    )
endif()

# ── Third-party ─────────────────────────────────────────────────
# nlohmann/json — prefer an installed package; fall back to FetchContent.
find_package(nlohmann_json 3.11 QUIET)
if(NOT nlohmann_json_FOUND)
    include(FetchContent)
    FetchContent_Declare(
        nlohmann_json
        GIT_REPOSITORY https://github.com/nlohmann/json.git
        GIT_TAG        v3.11.3
        GIT_SHALLOW    TRUE
    )
    FetchContent_MakeAvailable(nlohmann_json)
endif()

# picosha2 — header-only SHA-256 (MIT), vendored in third_party/.

# ── Library target ─────────────────────────────────────────────
add_library(baion_std_public STATIC
    src/canonical_json.cpp
    src/hash.cpp
)

target_include_directories(baion_std_public
    PUBLIC  ${PROJECT_SOURCE_DIR}/include
    PRIVATE ${PROJECT_SOURCE_DIR}/third_party/picosha2
)

target_link_libraries(baion_std_public
    PUBLIC nlohmann_json::nlohmann_json
)

# ── CLI: baion_canon_hash ──────────────────────────────────────
# stdin JSON → canonicalize → SHA-256 → lowercase hex + newline.
add_executable(baion_canon_hash tools/baion_canon_hash.cpp)
target_link_libraries(baion_canon_hash PRIVATE baion_std_public)
set_target_properties(baion_canon_hash PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${PROJECT_SOURCE_DIR}/bin
)

# ── Tests ──────────────────────────────────────────────────────
option(BAION_STD_BUILD_TESTS "Build conformance tests" ON)
if(BAION_STD_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
