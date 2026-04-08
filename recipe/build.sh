#!/bin/bash

set -ex

# remove outdated vendored headers
# These should be necessary, but it is temporary commented
# out as cuda headers are needed even for rocm builds,
# and the vendored headers are necessary in that case.
# rm -rf $SRC_DIR/python/triton/third_party

# disable downloading dependencies entirely
export TRITON_OFFLINE_BUILD=1

export JSON_SYSPATH=$PREFIX
export PYBIND11_SYSPATH=$SP_DIR/pybind11

export MAX_JOBS=$CPU_COUNT

# Proton currently expects NVIDIA CUDA/CUPTI headers when enabled.
# Disable it for ROCm builds to avoid hard dependency on cuda.h/cupti.h.
if [[ "${hip_compiler_version:-None}" != "None" ]]; then
    export TRITON_BUILD_PROTON=OFF
fi

# the build does not run C++ unittests, and they implicitly fetch gtest
# no easy way of passing this, not really worth a whole patch
sed -i -e '/TRITON_BUILD_UT/s:\bON:OFF:' CMakeLists.txt

# LLVM's bundled benchmark adds -pedantic-errors, which breaks with newer
# clang when parsing __COUNTER__ in C++11 mode (-Wc2y-extensions).
# Remove the full helper invocation to avoid generating add_cxx_compiler_flag().
sed -i -e '/add_cxx_compiler_flag(-pedantic-errors)/d' llvm-project/third-party/benchmark/CMakeLists.txt

CMAKE_HOST_ARGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DLLVM_BUILD_UTILS=ON
    -DLLVM_BUILD_TOOLS=OFF
    -DLLD_BUILD_TOOLS=OFF
    -DLLVM_BUILD_TELEMETRY=OFF
    -DLLVM_ENABLE_PROJECTS="mlir;lld"
    -DLLVM_TARGETS_TO_BUILD="host;NVPTX;AMDGPU"
    -DLLVM_ENABLE_TERMINFO=OFF
    -DLLVM_INCLUDE_TESTS=OFF
    -DMLIR_INCLUDE_TESTS=OFF
    ${TRITON_BUILD_WITH_CCACHE:+-DLLVM_CCACHE_BUILD=ON}
)

# build LLVM first
if [[ ${HOST} != ${BUILD} ]]; then
    CMAKE_BUILD_ARGS=(
        -DCMAKE_C_COMPILER="${CC_FOR_BUILD}"
        -DCMAKE_CXX_COMPILER="${CXX_FOR_BUILD}"
        -DCMAKE_BUILD_TYPE=Release
        -DLLVM_ENABLE_ZSTD=OFF
        -DLLVM_ENABLE_LIBXML2=OFF
        -DLLVM_ENABLE_ZLIB=OFF
        -DLLVM_ENABLE_PROJECTS="mlir"
        ${TRITON_BUILD_WITH_CCACHE:+-DLLVM_CCACHE_BUILD=ON}
    )
    NATIVE_EXECUTABLES=(
        llvm-tblgen
        mlir-tblgen
        mlir-linalg-ods-yaml-gen
        mlir-src-sharder
        mlir-pdll
    )

    cmake -G Ninja "${CMAKE_BUILD_ARGS[@]}" \
        -Bllvm-project/build-native -Sllvm-project/llvm
    cmake --build llvm-project/build-native -j "${MAX_JOBS}" \
        -t "${NATIVE_EXECUTABLES[@]}"

    NATIVE_BIN=$PWD/llvm-project/build-native/bin
    CMAKE_HOST_ARGS+=(
        -DCMAKE_CROSSCOMPILING=ON
        -DLLVM_NATIVE_TOOL_DIR=$PWD/llvm-project/build-native/bin
        #-DLLVM_TABLEGEN=$NATIVE_BIN/llvm-tblgen
        #-DMLIR_TABLEGEN=$NATIVE_BIN/mlir-tblgen
        #-DMLIR_LINALG_ODS_YAML_GEN
    )
fi

cmake -G Ninja "${CMAKE_HOST_ARGS[@]}" \
    -Bllvm-project/build -Sllvm-project/llvm
cmake --build llvm-project/build -j "${MAX_JOBS}"

export LLVM_SYSPATH=$PWD/llvm-project/build
export LLVM_INCLUDE_DIRS=$LLVM_SYSPATH/include
export LLVM_LIBRARY_DIR=$LLVM_SYSPATH/lib

$PYTHON -m pip install . -vv
