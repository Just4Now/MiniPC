# 更新日志

## 1.2.15 （2024-12-30）
### fixed
- 修改worker场景多次新建worker且绑定同一JS函数，运行逻辑调用该绑定的函数时，会crash问题
- 删除Callback中通过napi_handle_scope管理napi value生命周期不合理的逻辑
- 修改部分文件缺少版权许可信息的问题
- 修改个别单词拼写错误的问题
- 添加多线程场景测试demo

## 1.2.14 （2024-9-13）
### fixed
- 修复NapiPMethodBinder/NapiPFunctionBinder有返回值时导致内存泄露的问题
- 优化CMakeLists.txt脚本，在源码依赖编译release版本的时候，限制-s的扩散范围，保持只在aki中生效

## 1.2.13 （2024-8-16）
### fixed
- 修复线程安全函数内存泄露的问题

## 1.2.12 （2024-8-5）

### feat
- 新增支持主线程下同一个so只加载一次的能力  </br>
  新增接口: <br>
  1. napi_value aki::JSBind::BindSymbols(napi_env env, napi_value exports, std::string moduleName);
### fixed
- 修复多线程同时操作一个全局变量导致线程crash、崩溃栈指向BindSymbols的问题
- 修复uint32类型导致部分应用无法使用的问题  </br>
  废弃接口： 以下接口在部分场景中使用会导致应用crash，因此将其废弃</br>
  1. uint32_t aki::value::GetUInt()
  2. uint64_t aki::value::GetUInt64()

## 1.2.12-rc0 （2024-7-30）

- 修复多线程同时操作一个全局变量导致线程crash的问题
- 修复uint32类型导致部分应用无法使用的问题

## 1.2.11 （2024-7-21）

### fixed

- 更新SDK(ohos_sdk_public 5.0.0.25)

## 1.2.10 （2024-7-17）

### fixed

- 修复BindSymbols函数在部分场景只初始化一次的问题

## 1.2.9 （2024-6-29）

### fixed

- 修复invokeAsync接口内存泄漏问题
- 修复napi_call_function的返回值为Array<T>时，对象内容为空的问题

### feat

- 新增支持绑定std::optional类型
- 优化主线程BindSymbols被反复加载问题
- 新增AsyncWorker类

## 1.2.8 （2024-5-28）

### fixed

- invoke回调JS函数时，当函数入参为function时，存在内存泄漏，function的参数无法析构

## feat

- aki::Promise 类新增Reject接口
- aki::Value类支持创建数组
- aki支持在napi_call_function后，进行napi_is_exception_pending的异常判断，如果存在异常，则打印异常信息
- 绑定类时支持类继承的特性
- 支持枚举类的绑定
- 支持JS的null和C++的空指针自动转化
- 支持JS层的Map, HashMap, HashSet映射 C++层的 Map, HashMap, HashSet
- aki兼容C++11

## 1.2.8-rc.0（2024-5-5）

## feat

- 支持在napi_call_function后做pending exception判断

## 1.2.6（2024-1-27）

## feat

- value支持uint32_t、uint64_t
- invoke支持异步调用

## 1.2.5 (2023-12-12)

### fixed

* 修复enum重定义问题
* 修复debug模式，非线程下触发aki::Value默认构造crash问题
* 修复safety_callback因生命周期管理crash问题
* 修复部分编译告警问题
* 修复worker场景下，多线程覆盖问题

### feat

- 支持aki::Value::IsObject
- 支持aki::Value数组赋值

## 1.2.3 (2023-09-20)

### fixed
* 修复异步接口 napi_value 生命周期未被GC托管

## 1.2.2 (2023-09-10)

### fixed
* 修复 ArrayBuffer 在工作线程支持

## 1.2.0 (2023-08-20)

### feat
* 支持 JS 类型 any 映射 C++ 类型 aki::Value

## 1.1.1 (2023-08-15)

### fixed
* 修复 JSBIND_ENUM 找不到头文件问题

## 1.1.0 (2023-08-10)

### feat
* 支持uint8_t/int8_t/uint16_t/int16_t 转为 number
* 支持传递对象引用

### fixed
* 修复 callback 在 C++ 侧时，带返回值类型；

### deprecated
* C++侧对于std::vector<uint8_t> 不再被解析成 JS 侧的 Uint8Array。即std::vector<T>类型全部视为数组，如需使用TypedArray，请使用C++ 的 aki::ArrayBuffer 类型进行映射

### example
* 3_callback 增加示例: callback 实现在 cpp 侧，并支持callback带返回值
* 6_structure 更新 JSBIND_PROPERTY 用例 + 对象指针用例
* 14_reference_and_pointer 对象引用用例

### docs

* README.md 文档更新

## 1.0.8 (2023-07-27)

### docs

* README.md 文档更新

### fixed

* 修复 JSBind 绑定 std::vector<long> 类型必现编译出错；

### example
* 新增arrar_to_native 数组用例

## 1.0.7 (2023-07-24)

### feat

* 支持 JSBIND_PROPERTY，无需定义Get/Set函数，即可绑定类成员属性

## 1.0.6 (2023-07-16)

### feat

* 支持传参napi_value类型

### fixed

- README.md锚点跳转

## 1.0.5 (2023-07-11)

## 1.0.4 (2023-07-10)

### fixed

* JSBIND_PFUNCTION 绑定返回值为void类型函数编译报错

## 1.0.3 (2023-07-09)

### feat

* 支持类型转换：map<std::string, T>  <---> object；

### fixed

* JSBIND_PFUNCTION 绑定返回值为long类型编译错误

## 1.0.2 (2023-07-06)

### feat

* 新增枚举类型绑定特性；

## 1.0.1 (2023-07-05)

### fixed

* 修复PMETHOD宏绑定异步接口返回值为类对象时编译报错；

## 1.0.0 (2023-06-29)

