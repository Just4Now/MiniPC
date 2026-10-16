### <a id="bind_enum">Binding an Enum</a>

The JSBind syntactic sugar **JSBIND_ENUM** and **JSBIND_ENUM_VALUE** are used to bind C/C++ enums, which are mapped to JS numbers.

- The default C/C++ enum is **int32_t** in the POD.
- The corresponding JS property is **readonly**.

#### JSBIND_ENUM(enum)

**Parameters**

|  **Name** | **Type**| **Mandatory**| **Description**|
| ----------- | -------- | ------- | ------------------------ | 
| enum        | enum  | Y       | C++ enum to be bound.|

#### JSBIND_ENUM_VALUE(value)

**Parameters**

|  **Name** | **Type**| **Mandatory**| **Description**|
| ----------- | -------- | ------- | ------------------------ | 
| value        | enum::value  | Y       | Value of the C++ enum to be bound.|

**Example**
- C++

``` C++
#include <string>
#include <aki/jsbind.h>

enum TypeFlags {
    NONE,
    NUM,
    STRING,
    BUTT = -1
};

JSBIND_ENUM(TypeFlags) {
    JSBIND_ENUM_VALUE(NONE);
    JSBIND_ENUM_VALUE(NUM);
    JSBIND_ENUM_VALUE(STRING);
}

TypeFlags Passing(TypeFlags flag) {
    return flag;
}

JSBIND_GLOBAL()
{
    JSBIND_FUNCTION(Passing);
}

JSBIND_ADDON(enumeration);
```

- JavaScript

``` JavaScript
import libAddon from 'libenumeration.so' // Addon name.


console.log('AKI libAddon.TypeFlags.NONE = ' + libAddon.TypeFlags.NONE);
console.log('AKI libAddon.TypeFlags.NUM = ' + libAddon.TypeFlags.NUM);
console.log('AKI libAddon.TypeFlags.Passing() = ' + libAddon.Foo(libAddon.TypeFlags.STRING));
try {
  libAddon.TypeFlags.NUM = 10; // TypeError: Cannot set readonly property
} catch (error) {
  console.error('AKI catch: ' + error);
}
```
