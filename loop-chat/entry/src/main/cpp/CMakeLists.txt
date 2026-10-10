cmake_minimum_required(VERSION 3.5.0)
project(Gewu)

set(CMAKE_CXX_STANDARD 17)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# AKI 源码依赖 (需要先 git clone aki 到当前目录)
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/aki/CMakeLists.txt)
    add_subdirectory(aki)
else()
    message(FATAL_ERROR "aki directory not found. Please run: git clone https://github.com/AKI-Project/aki.git ${CMAKE_CURRENT_SOURCE_DIR}/aki")
endif()

add_library(llm SHARED llm_bridge.cpp)

#target_link_libraries(llm PUBLIC aki_jsbind)
target_link_libraries(llm PUBLIC aki_jsbind libhilog_ndk.z.so librawfile.z.so libace_napi.z.so)

# 头文件路径
include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

target_include_directories(llm PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/gewu/include
)



# 链接 libqos.so (系统库)
target_link_libraries(llm PUBLIC libqos.so)

# 其他系统库依赖 (如果需要)
# target_link_libraries(llm PUBLIC libhilog_ndk.z.so librawfile.z.so libace_napi.z.so)
