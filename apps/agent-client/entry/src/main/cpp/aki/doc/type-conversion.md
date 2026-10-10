# Data Types

|  **JavaScript**  | **C++** | 
| ---------------- | ------------------------ | 
| Boolean          | `bool`  <br> [Reference](https://gitee.com/openharmony-sig/aki/blob/master/doc/type-conversion.en.md#boolean)                                    |
| Number           | `uint8_t`, `int8_t`, `uint16_t`, `int16_t`, `short`, `int32`, `uint32`, `int64`, `float`, `double`, `enum` <br> [Reference](https://gitee.com/openharmony-sig/aki/blob/master/doc/type-conversion.en.md#number)|
| String           | `const char*`, `std::string` <br> [Reference](https://gitee.com/openharmony-sig/aki/blob/master/doc/type-conversion.en.md#string)               |
| Array            | `std::vector<T>`, `std::array<T, N>` <br> [Reference](https://gitee.com/openharmony-sig/aki/blob/master/doc/type-conversion.en.md#array)           |
| Function         | `std::function<R (P...)>` <br> `aki::Callbackn<R (P...)>` <br> `aki::SafetyCallbackn<R (P...)>` <br> [Reference](https://gitee.com/openharmony-sig/aki/blob/master/doc/type-conversion.en.md#function)|
| Class Object      | `class`                                     |
| JsonObject       | `std::map<std::string,T>` <br> [Reference](https://gitee.com/openharmony-sig/aki/blob/master/doc/type-conversion.en.md#jsonobject)                                 |
| ArrayBuffer, <br> TypedArray      | `aki::ArrayBuffer` <br> [Reference](https://gitee.com/openharmony-sig/aki/blob/master/doc/type-conversion.en.md#arrarbuffer) |
| Promise          | `JSBIND_PFUNCTION`, `JSBIND_PMETHOD` |
| any          | `aki::Value`, `napi_value` |

Since **AKI** supports declarative type conversion, you do not need to manually convert the data type to **JavaScript** or **C++** type. The framework layer automatically converts the parameter type that you declare for the APIs.

### Boolean
Declare the input parameters and type of the return value of the function, and bind the function using AKI. The framework then adaptively converts the C/C++ bool into the JS Boolean.

**Example**

- C++

  ``` C++
  #include <aki/jsbind.h>
  bool Foo(bool flag) {
    ...
    return true;
  }
  JSBIND_GLOBAL() {
      JSBIND_FUNCTION(Foo, "foo");
  }
  JSBIND_ADDON(hello)
  ```

- JavaScript

  ``` JavaScript
  import libAddon from 'libhello.so'
  let flag = libAddon.foo(true);
  ```

### Number

Declare the input parameter and type of the return value of the function, and bind the function using AKI. The framework then adaptively converts C++ uint8_t, int8_t, uint16_t, int16_t, short, int32, uint32, int64, float, double, or enum into a JS number.

* float: The precision will be comprised for the data converted between a C/C++ floating-point number and a JS number. For high-precision conversion, use **double**.
* enum: For details about how to convert enums, see [Reference](https://gitee.com/openharmony-sig/aki/blob/master/doc/bind_enum.en.md).

**Example**

- C++

  ``` C++
  #include <aki/jsbind.h>
  int Foo(int num) {
    ...
    return 666;
  }
  JSBIND_GLOBAL() {
      JSBIND_FUNCTION(Foo, "foo");
  }
  JSBIND_ADDON(hello)
  ```

- JavaScript

  ``` JavaScript
  import libAddon from 'libhello.so'
  let num = libAddon.foo(888);
  ```

### String

Declare the input parameters and type of the return value of the function, and bind the function using AKI. The framework then adaptively converts C/C++ **const char*** or **std::string** into a JS string.

* **const char*** is used to pass parameters by reference. For asynchronous operations, use **std::string** to pass parameters.

**Example**

- C++

  ``` C++
  #include <aki/jsbind.h>
  std::string Foo(const char* c_str, std::string str) {
    ...
    return "AKI 666";
  }
  JSBIND_GLOBAL() {
      JSBIND_FUNCTION(Foo, "foo");
  }
  JSBIND_ADDON(hello)
  ```

- JavaScript

  ``` JavaScript
  import libAddon from 'libhello.so'
  let str = libAddon.foo("AKI", "666");
  ```

### Array

Declare the input parameters and type of the return value of the function, and bind the function using AKI. The framework then adaptively converts C/C++ **std::vector<T>** or **std::array<T, N>** into a JS **[]**.

* Only the same type of array can be declared.

**Example**

- C++

  ``` C++
  #include <aki/jsbind.h>
  std::vector<double> Foo(std::array<int, 3>) {
    std::vector<double> result;
    ...
    return result;
  }
  JSBIND_GLOBAL() {
      JSBIND_FUNCTION(Foo, "foo");
  }
  JSBIND_ADDON(hello)
  ```

- JavaScript

  ``` JavaScript
  import libAddon from 'libhello.so'
  let array = libAddon.foo([1, 2, 3]);
  ```

### ArrarBuffer

AKI provides the built-in struct **aki::ArrayBuffer** to support the binary data buffers such as ArrayBuffer and TypedArray.

- **GetData()*** is used to obtain the address of ArrayBuffer. **aki::ArrayBuffer** does not apply for data memory, data is stored in the memory allocated by the JS VM, and memory lifecycle management is not required. Do not release the memory.

- **GetLength()** is used to obtain the length of ArrayBuffer, in bytes.

- **GetTyped()** is used to obtain the types of ArrayBuffer.

- **GetCount()** is used to obtain the number of typed elements in ArrayBuffer.

**Example**

- C++

``` C++
#include <aki/jsbind.h>
aki::ArrayBuffer PassingArrayBufferReturnArrayBuffer(aki::ArrayBuffer origin) {
    aki::ArrayBuffer buff(origin.GetData(), origin.GetCount());
    uint8_t* data = buff.GetData();
    data[4] = 4;
    data[5] = 5;
    data[6] = 6;
    data[7] = 7;

    return buff;
}
```

- JavaScript

``` JavaScript
import libAddon from 'libarraybuffer2native.so'

let buff: ArrayBuffer = new ArrayBuffer(8);
let uint8Buff1: Uint8Array = new Uint8Array(buff);
uint8Buff1[0] = 0;
uint8Buff1[1] = 1;
uint8Buff1[2] = 2;
uint8Buff1[3] = 3;
let result: ArrayBuffer = libAddon.PassingArrayBufferReturnArrayBuffer(buff);
uint8Buff1 = new Uint8Array(result);
let message: String = uint8Buff1.toString();
```

### Reference or Pointer
As parameters and return types, C++ objects can be passed in any of the following C++ and JS code format:
- Value.
- Reference (T&) or pointer (T*).
- [Example](https://gitee.com/openharmony-sig/aki/tree/master/example/ohos/14_reference_and_pointer)

### JsonObject

In JS, **JsonObject** is provided to indicate the data in the key-value structure, for example:
```javascript
{
  name: 'hanmeimei',
  age: '17',
  date: '1999-02-02'
}
```
In AKI, C/C++ **std::map<std::string, T>** is used to map JS **JsonObject**.

  - The value type of **JsonObject** must be the same as that of the corresponding **std::map<std::string, T>**.

- [Example](https://gitee.com/openharmony-sig/aki/tree/master/example/ohos/10_map_for_object)

- C++

``` C++
void Foo(std::map<std::string, int> obj)
{
    for (auto& iter : obj) {
        ......; // key: iter.first; value: iter.second
    }
}

JSBIND_GLOBAL() {
    JSBIND_FUNCTION(Foo);
}
```

- JavaScript

``` JavaScript
import libmap_for_object from 'libmap_for_object.so'

let a = {age: 100};
libmap_for_object.Foo(a);
```

### Function

Function is a basic data type of JS. When a JS function is passed as a parameter, it can be called at a proper time to trigger a native callback. AKI supports the following three C++ data types as parameters to process callbacks:

- **aki::Callback<R (P...)>**: specifies a high-performance callback of the **R (*)(P...)** type. This callback is not thread-safe and cannot be used in non-JS threads. Otherwise, exceptions may occur.
- **aki::SafetyCallback<R (P...)>**: specifies a thread-safe callback of the **R (*)(P...)** type. Since thread-safe resources need to be created in this callback, it is less performant than **aki::Callback**.
- **std::function<R (P...) >**: the usage is the same as that of **aki::SafetyCallback**.
