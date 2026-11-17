cmake_minimum_required(VERSION 3.20)
project(superfiles_kio LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Install into $HOME/.local by default (see scripts/install-kio.sh), so the
# build never needs root. KIO worker discovery then needs one privileged
# copy of the .so into /usr/lib/qt6/plugins/kf6/kio (KF6 scans only that
# compiled-in dir — see scripts/install-kio.sh).
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
    set(CMAKE_INSTALL_PREFIX "$ENV{HOME}/.local" CACHE PATH "..." FORCE)
endif()

find_package(ECM REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${ECM_MODULE_PATH})

# Deliberately NOT include(KDEInstallDirs): its ECMQueryQt probing resolves
# qmake through PATH, where /opt/cuda/bin wins (CUDA bundles a full Qt5) and
# the resulting Qt5Core metadata sets QT_DEFAULT_MAJOR_VERSION=5, which
# later aborts Qt6Qml's configure-time macros. Pin what matters ourselves:
set(QT_MAJOR_VERSION 6)
set(QT_DEFAULT_MAJOR_VERSION 6)
# …and never resolve Qt/KF packages out of CUDA's bundled (stale) cmake trees.
list(PREPEND CMAKE_PREFIX_PATH "/usr")
if(EXISTS "/opt/cuda")
    list(PREPEND CMAKE_IGNORE_PREFIX_PATH "/opt/cuda")
endif()

find_package(Qt6 REQUIRED COMPONENTS Core)
find_package(KF6 REQUIRED COMPONENTS CoreAddons KIO)

add_library(kio_superfiles MODULE kio_superfiles.cpp superfiles.json)
# System workers are named kio_<protocol>.so; strip CMake's default MODULE "lib" prefix.
set_target_properties(kio_superfiles PROPERTIES AUTOMOC ON PREFIX "")
target_link_libraries(kio_superfiles PRIVATE
    Qt6::Core
    KF6::CoreAddons
    KF6::KIOCore
)

# Hardcoded Qt6 layout under the install prefix; keep it mirroring the
# system worker dir KIO actually scans.
install(TARGETS kio_superfiles DESTINATION lib/qt6/plugins/kf6/kio)
