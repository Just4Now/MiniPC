### <a id="aki_value"> aki::Value <sup> v1.2.0 </sup> </a>

JS is a weakly typed language, and generic **any** can be used to represent any type. In C/C++, **aki::Value** maps the JS **any** type.

#### <a id="aki_value_from_global"> aki::Value::FromGlobal </a>

```C++
static Value FromGlobal(const char* key = nullptr)
```

Obtains a property of JS **globalThis**.

**Parameters**
|  **Name** | **Type**| **Mandatory**| **Description**|
| ----------- | -------- | ------- | ------------------------ | 
| key   | string        | Y       | Name of the property to obtain.|

**Return value**
| **Type**| **Description**|
| -------- | ------------------------ | 
| aki::Value | Handle to the JS object of the property.|

**Example**
```C++
  // Obtain globalThis.JSON.
  aki::Value json = aki::Value::FromGlobal("JSON");
  json["stringify"](obj);
```

#### <a id="aki_value_as"> aki::Value::As </a>

```C++
template<typename T>
T As() const;
```
Converts a JS object to the specified C/C++ data type.

**Parameters**
|  **Name** | **Type**| **Mandatory**| **Description**|
| ----------- | -------- | ------- | ------------------------ | 
| T   | any        | Y       | C/C++ data type converted.|

**Return value**
| **Type**| **Description**|
| -------- | ------------------------ | 
| T | Value of the specified type.|

**Example**
```C++
  value.As<bool>(); // Convert the JS object value to a bool.
  value.As<int>(); // Convert the JS object value to an int.
  value.As<std::string>(); // Convert the JS object value to a string.
```

#### <a id="aki_value_get_handle"> aki::Value::GetHandle </a>

```C++
napi_value GetHandle() const
```
Obtains the **napi_value** handle to a JS object.

**Return value**
| **Type**| **Description**|
| -------- | ------------------------ | 
| napi_value | **napi_value** handle obtained.|

#### <a id="aki_value_call_method"> aki::Value::CallMethod </a>

```C++
template<typename... Args>
Value CallMethod(const char* name, Args&&... args)
```

Calls a member function of a JS object.

**Parameters**
|  **Name** | **Type**| **Mandatory**| **Description**|
| ----------- | -------- | ------- | ------------------------ | 
| name   | string        | Y       | Name of the function to call.|
| args   | any        | N       | Parameters of the member function.|

**Return value**
| **Type**| **Description**|
| -------- | ------------------------ | 
| aki::Value | A generic object.|

**Example**
```C++
  // The value is mapped to the JS array object let value = ['aki'].
  // Call value.push('jsbind');
  value.CallMethod("push", "jsbind");
```

#### aki::Value::operator[]

```C++    
Value operator[](const std::string& key) const;
Value operator[](const size_t index) const;
```
Accesses elements within an **aki::Value** object using a string key or an index.

**Parameters**
|  **Name** | **Type**| **Mandatory**| **Description**|
| ----------- | -------- | ------- | ------------------------ | 
| key   | string        | Y       | Property to access.|
| index   | size_t        | Y       | Array to access.|

**Return value**
| **Type**| **Description**|
| -------- | ------------------------ | 
| aki::Value | A generic object.|

**Example**
```C++
  // The value is mapped to the JS array object let value = ['aki', 'jsbind'].
  // Access the value whose subscript is 0.
  aki::Value str = value[0]; // str = "aki"

  // Call JSON.stringify(...).
  aki::Value::FromGlobal("JSON")["stringify"](...);
```

#### aki::Value::operator()

```C++    
template<typename... Args>
Value operator()(Args&&... args) const;
```
Calls an **aki::Value** object like a function with the given parameters.

**Parameters**
|  **Name** | **Type**| **Mandatory**| **Description**|
| ----------- | -------- | ------- | ------------------------ | 
| args   | any        | N       | Parameters of the function.|

**Return value**
| **Type**| **Description**|
| -------- | ------------------------ | 
| aki::Value | A generic object.|

**Example**
```C++
  // Call JSON.parse({'aki':'jsinbd'});
  aki::Value::FromGlobal("JSON")["parse"]({"aki": "jsinbd"});
```

#### aki::Value::Set

```C++
template<typename V>
void Set(const char* key, const V& value);
```
Sets the property value of the generic object **aki::Value**.

**Parameters**
|  **Name** | **Type**| **Mandatory**| **Description**|
| ----------- | -------- | ------- | ------------------------ | 
| key   | string        | Y       | Name of the property.|
| value   | any        | Y       | Value of the property.|

**Example**
```C++
  // The value is a JS object.
    value.Set("name", "aki");
```

#### aki::Value::NewObject

```C++
static Value NewObject();
```
Creates a **aki::Value** object.

**Return value**
| **Type**| **Description**|
| -------- | ------------------------ | 
| aki::Value | A generic object.|

**Example**
```C++
  aki::Value val = aki::Value::NewObject();
  val.Set("name", "aki"); // {'name': 'aki'};
```

#### aki::Value::IsUndefined

```C++
bool IsUndefined() const
```

Checks whether the JS object type is undefined.

**Return value**
| **Type**| **Description**|
| -------- | ------------------------ | 
| bool | **true** or **false**.|

#### aki::Value::IsNull

```C++
bool IsNull() const
```

Checks whether the JS object type is null.

**Return value**
| **Type**| **Description**|
| -------- | ------------------------ | 
| bool | **true** or **false**.|

#### aki::Value::IsBool

```C++
bool IsBool() const
```

Checks whether the JS object type is boolean.

**Return value**
| **Type**| **Description**|
| -------- | ------------------------ | 
| bool | **true** or **false**.|

#### aki::Value::IsNumber

```C++
bool IsNumber() const
```

Checks whether the JS object is a number.

**Return value**
| **Type**| **Description**|
| -------- | ------------------------ | 
| bool | **true** or **false**.|

#### aki::Value::IsString

```C++
bool IsString() const
```

Checks whether the JS object is a string.

**Return value**
| **Type**| **Description**|
| -------- | ------------------------ | 
| bool | **true** or **false**.|

#### aki::Value::IsArray

```C++
bool IsArray() const
```

Checks whether the JS object is an array.

**Return value**
| **Type**| **Description**|
| -------- | ------------------------ | 
| bool | **true** or **false**.|

#### aki::Value::IsFunction

```C++
bool IsFunction() const
```

Checks whether the JS object is a function.

**Return value**
| **Type**| **Description**|
| -------- | ------------------------ | 
| bool | **true** or **false**.|


#### Calling @ohos.bundle.bundleManager from C/C++

For example, to call [@ohos.bundle.bundleManager](https://docs.openharmony.cn/pages/v3.2/en/application-dev/reference/apis/js-apis-bundleManager.md/) as shown in the following example from C++:
  
  ```JavaScript
  import bundleManager from '@ohos.bundle.bundleManager';
  import hilog from '@ohos.hilog';
  let bundleFlags = bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT;
  try {
      bundleManager.getBundleInfoForSelf(bundleFlags).then((data) => {
          hilog.info(0x0000, 'testTag', 'getBundleInfoForSelf successfully. Data: %{public}s', JSON.stringify(data));
      }).catch(err => {
          hilog.error(0x0000, 'testTag', 'getBundleInfoForSelf failed. Cause: %{public}s', err.message);
      });
  } catch (err) {
      hilog.error(0x0000, 'testTag', 'getBundleInfoForSelf failed: %{public}s', err.message);
  }
  ```
  Use the following C++ code:
  ```C++
    /* Execute the following code on ArkTS:
    * import bundleManager from '@ohos.bundle.bundleManager';
    * globalThis.bundleManager = bundleManager;
    */
    aki::Value bundleManager = aki::Value::FromGlobal("bundleManager");
    
    /* The following C++ code is equivalent to JS code:
    * let bundleFlags = bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT;
    * bundleManager.getBundleInfoForSelf(bundleFlags).then((data) => {
    *   console.log('getBundleInfoForSelf successfully. Data:', JSON.stringify(data));
    * })
    */
    std::function<void(aki::Value)> thenFunc = [](aki::Value data) {
        AKI_LOG(INFO) << aki::Value::FromGlobal("JSON")["stringify"](data).As<std::string>();
    };
    int bundleFlags = bundleManager["BundleFlag"]["GET_BUNDLE_INFO_DEFAULT"].As<int>();
    bundleManager["getBundleInfoForSelf"](bundleFlags).CallMethod("then", thenFunc);
  ```

- [Example](https://gitee.com/openharmony-sig/aki/tree/master/example/ohos/15_aki_value)
