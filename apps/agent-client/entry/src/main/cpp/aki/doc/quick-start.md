## <a id="quick_start">Quick Start</a>

- [1 Configuring Dependencies](#1-configuring-dependencies)
- [2 Customizing Service Code](#2-customizing-service-code)
- [3 Using AKI](#3-using-aki)
- [4 Calling the Code](#4-calling-the-code)
- [5 Compilation Configuration](#5-compilation-configuration)

### **1 Configuring Dependencies**  
* **Source Code Dependencies** (Recommended)

  Specify the project root path, for example, **/entry/src/main/cpp**.
    ```
    cd entry/src/main/cpp
    git clone https://gitee.com/openharmony-sig/aki.git
    ```
  Add the dependencies to **CMakeLists.txt** (for example, the dynamic library name is **libhello.so**).

    ```cmake
    add_subdirectory(aki)
    target_link_libraries(hello PUBLIC aki_jsbind)
    ```
  
* **OpenHarmony HAR Dependencies**

  Install the OpenHarmony HAR dependency in the specified directory, for example, **/entry** of the project.
    ```
    cd entry
    ohpm install @ohos/aki
    ```
  Add the dependencies to **CMakeLists.txt** (for example, the dynamic library name is **libhello.so**).

    ```cmake
    set(AKI_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR}/../../../oh_modules/@ohos/aki) # Set the AKI root path.
    set(CMAKE_MODULE_PATH ${AKI_ROOT_PATH})
    find_package(Aki REQUIRED)

    ...

    target_link_libraries(hello PUBLIC Aki::libjsbind) # Link the binary dependencies and header files.
    ```


### **2 Customizing Service Code**

Write the C++ service code in **hello.cpp**.<br>
You do not need to bother with using Node-API.

```C++
#include <string>

std::string SayHello(std::string msg)
{
  return msg + " too.";
}

```

### **3 Using AKI**

Use **JSBind** to declare the classes and functions to be bound.

```C++
#include <aki/jsbind.h>

// Step 1 Register an AKI addon.
JSBIND_ADDON(hello) // Name of the registered AKI addon, that is, the name of the compiled .so file. The naming rule is the same as that of Node-API.

// Step 2 Register the FFI feature.
JSBIND_GLOBAL()
{
  JSBIND_FUNCTION(SayHello);
}
```

### **4 Calling the Code**

Call the OpenHarmony project code:

```javascript
import aki from'libhello.so' // The .so file built by the project.

aki.SayHello("hello world");
```

### **5 Compilation Configuration**

AKI supports C++11 and C++17, and C++17 is enabled by default.

Use **-DAKI_ENABLE_CXX_STANDARD_11=ON** to switch to C++ 11 (for example, **/entry/build-profile.json5** of the project):
```
"arguments": "-DAKI_ENABLE_CXX_STANDARD_11=ON",

```
