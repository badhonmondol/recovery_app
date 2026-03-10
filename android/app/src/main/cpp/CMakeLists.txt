cmake_minimum_required(VERSION 3.22.1)
project("recovery_engine")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(
    recovery_engine
    SHARED
    recovery_engine.cpp
)

find_library(log-lib log)

target_link_libraries(
    recovery_engine
    ${log-lib}
)