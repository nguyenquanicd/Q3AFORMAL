cmake_minimum_required(VERSION 3.20)
project(Q3AFORMAL LANGUAGES CXX)
if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
    message(FATAL_ERROR "Use the PowerShell build on Windows.")
endif()
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
find_package(Python3 REQUIRED COMPONENTS Interpreter)
set(src "${CMAKE_CURRENT_SOURCE_DIR}/prototype/source")
set(checker "${CMAKE_CURRENT_SOURCE_DIR}/prototype/checker")
set(includes "${checker}" "${CMAKE_CURRENT_BINARY_DIR}")
foreach(component IN ITEMS source_manager frontend elaborator lowering sat replay bundle cache liveness four_state)
    list(APPEND includes "${src}/${component}")
endforeach()
file(GLOB_RECURSE sources CONFIGURE_DEPENDS "${src}/*.cpp")
list(FILTER sources EXCLUDE REGEX "_win32[.]cpp$|/platform_support[.]cpp$")
file(GLOB_RECURSE identity_sources CONFIGURE_DEPENDS
    "${src}/*.cpp" "${src}/*.hpp" "${src}/*.inc" "${checker}/*.cpp" "${checker}/*.hpp")
set(features Q3A_ENABLE_DEVELOPMENT_MEMORY Q3A_ENABLE_DEVELOPMENT_EVENT_MASK
    Q3A_ENABLE_DEVELOPMENT_SAMPLED_VALUES Q3A_ENABLE_DEVELOPMENT_LIVENESS Q3A_ENABLE_DEVELOPMENT_FOUR_STATE)
set(identity "${CMAKE_CURRENT_BINARY_DIR}/q3a_build_info.hpp")
file(GENERATE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/q3a-build-configuration-$<CONFIG>.txt"
    CONTENT "Linux ${CMAKE_SYSTEM_PROCESSOR} | $<CONFIG> | ${CMAKE_CXX_FLAGS} | ${CMAKE_CXX_FLAGS_RELEASE} | ${CMAKE_CXX_FLAGS_DEBUG} | ${features}")
add_custom_command(OUTPUT "${identity}"
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/scripts/linux_build_identity.py"
        "${identity}" "${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}"
        "${CMAKE_CURRENT_BINARY_DIR}/q3a-build-configuration-$<CONFIG>.txt"
    DEPENDS ${identity_sources} CMakeLists.txt scripts/linux_build_identity.py
        "${CMAKE_CURRENT_BINARY_DIR}/q3a-build-configuration-$<CONFIG>.txt"
    VERBATIM)

add_library(q3a-proof-core STATIC "${checker}/drat_checker.cpp" "${checker}/drat_prover.cpp"
    "${checker}/proof_artifact.cpp" "${src}/source_manager/platform_support.cpp")
target_include_directories(q3a-proof-core PUBLIC ${includes})
add_executable(q3aformal-sourcecheck ${sources} "${identity}")
target_compile_definitions(q3aformal-sourcecheck PRIVATE ${features})
target_link_libraries(q3aformal-sourcecheck PRIVATE q3a-proof-core)
add_executable(q3aformal-proofcheck "${checker}/proof_cli.cpp")
target_link_libraries(q3aformal-proofcheck PRIVATE q3a-proof-core)

install(TARGETS q3aformal-sourcecheck q3aformal-proofcheck RUNTIME DESTINATION prototype/bin)
install(FILES prototype/pdr-pipeline.q3a prototype/pdr-cover.q3a
    prototype/four-state-cover.q3a prototype/batch-pipeline.q3b DESTINATION prototype)
install(FILES prototype/corpus/source-model-vectors/pdr_pipeline.sv
    prototype/corpus/source-model-vectors/pdr_cover.sv prototype/corpus/source-model-vectors/four_state_cover.sv
    DESTINATION prototype/corpus/source-model-vectors)
install(FILES docs/linux.md DESTINATION . RENAME README.md)
install(FILES ../LICENSE DESTINATION .)

enable_testing()
add_test(NAME linux-cli COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_SOURCE_DIR}/prototype/tests/test_linux_cli.py"
    "$<TARGET_FILE:q3aformal-sourcecheck>" "$<TARGET_FILE:q3aformal-proofcheck>")

set(CPACK_GENERATOR TGZ)
set(CPACK_PACKAGE_FILE_NAME q3aformal-linux-x64)
set(CPACK_INCLUDE_TOPLEVEL_DIRECTORY OFF)
include(CPack)
