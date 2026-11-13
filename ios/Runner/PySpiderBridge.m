#import "PySpiderBridge.h"

#import <Python/Python.h>

/// iOS 侧 py 蜘蛛引擎实现。
///
/// 解释器：BeeWare Python-Apple-support 的 Python.xcframework（CPython 3.13，
/// 官方 PEP 730 iOS 嵌入式构建），初始化顺序与 CPython 自带 iOS testbed
/// 一致（隔离配置 + UTF-8 + 无缓冲 stdio + 不写字节码 + 装信号处理 +
/// PYTHONHOME 指包内 `python/` 目录）。
///
/// 宿主协议与安卓侧完全一致：解释器里跑同一份 `py_spider_host.py`，
/// `handle_json(siteId, method, argsJson)` / `status_json()` /
/// `release_json(siteId)` 三个入口，JSON 进出。蜘蛛源码每次随
/// args["source"] 传来，Dart 侧 `PySourceStore` 负责内置/导入两路取源码，
/// 本文件不分内置导入、不碰 jar。
///
/// 调用一律走单线程串行队列（与安卓单线程执行器同义），结果回主线程；
/// 超时由 Dart 侧 60 秒封顶，这里不另设。

/// 结构化错误（与安卓 BridgeError 同义），经 @throw 送到 runAsync 转 FlutterError。
@interface PyBridgeError : NSException

@property (nonatomic, copy, readonly) NSString *code;
@property (nonatomic, copy, readonly) NSString *message;

- (instancetype)initWithCode:(NSString *)code message:(NSString *)message;

@end

@interface PySpiderBridge ()

@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) BOOL pythonReady;
@property (nonatomic, assign) PyObject *hostModule;

@end

@implementation PySpiderBridge

#pragma mark - 注册

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  PySpiderBridge *bridge = [[PySpiderBridge alloc] init];
  FlutterMethodChannel *channel = [FlutterMethodChannel
      methodChannelWithName:@"wxyy/pybridge"
            binaryMessenger:[registrar messenger]];
  [channel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
    [bridge handleMethodCall:call result:result];
  }];
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _queue = dispatch_queue_create("com.wxyy.pyspider", DISPATCH_QUEUE_SERIAL);
    _pythonReady = NO;
    _hostModule = NULL;
  }
  return self;
}

#pragma mark - 通道方法

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSString *method = call.method;
  if ([method isEqualToString:@"status"]) {
    [self runAsync:result
             block:^id _Nullable {
               return [self pyStatus];
             }];
    return;
  }
  if ([method isEqualToString:@"call"]) {
    NSDictionary *args = call.arguments;
    NSString *siteId = [self stringArg:args key:@"siteId"];
    NSString *spiderMethod = [self stringArg:args key:@"method"];
    if (siteId.length == 0 || spiderMethod.length == 0) {
      result([FlutterError errorWithCode:@"bad_args"
                                 message:@"缺少 siteId 或 method"
                                 details:nil]);
      return;
    }
    NSDictionary *callArgs = args[@"args"];
    if (![callArgs isKindOfClass:[NSDictionary class]]) {
      callArgs = @{};
    }
    [self runAsync:result
             block:^id _Nullable {
               return [self pyCall:siteId method:spiderMethod args:callArgs];
             }];
    return;
  }
  if ([method isEqualToString:@"release"]) {
    NSDictionary *args = call.arguments;
    NSString *siteId = [self stringArg:args key:@"siteId"];
    [self runAsync:result
             block:^id _Nullable {
               [self pyRelease:siteId];
               return nil;
             }];
    return;
  }
  result(FlutterMethodNotImplemented);
}

- (void)runAsync:(FlutterResult)result block:(id _Nullable (^)(void))block {
  dispatch_async(self.queue, ^{
    @try {
      id value = block();
      dispatch_async(dispatch_get_main_queue(), ^{
        result(value);
      });
    } @catch (PyBridgeError *error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        result([FlutterError errorWithCode:error.code
                                   message:error.message
                                   details:nil]);
      });
    } @catch (NSException *exception) {
      NSString *message = exception.reason ?: exception.name;
      dispatch_async(dispatch_get_main_queue(), ^{
        result([FlutterError errorWithCode:@"ENGINE_ERROR"
                                   message:message
                                   details:nil]);
      });
    }
  });
}

- (NSString *)stringArg:(id)args key:(NSString *)key {
  if (![args isKindOfClass:[NSDictionary class]]) return @"";
  id value = args[key];
  if ([value isKindOfClass:[NSString class]]) return value;
  return @"";
}

#pragma mark - JSON 转换（与安卓 sanitize / jsonValue 同义）

/// 通道参数 → 可进 NSJSONSerialization 的值（字节数组转 base64，空值保留）。
- (id)sanitize:(id)value {
  if (value == nil || value == [NSNull null]) return [NSNull null];
  if ([value isKindOfClass:[NSDictionary class]]) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (id key in value) {
      out[[key description]] = [self sanitize:value[key]];
    }
    return out;
  }
  if ([value isKindOfClass:[NSArray class]]) {
    NSMutableArray *out = [NSMutableArray array];
    for (id item in value) {
      [out addObject:[self sanitize:item]];
    }
    return out;
  }
  if ([value isKindOfClass:[FlutterStandardTypedData class]]) {
    return [[value data] base64EncodedStringWithOptions:0];
  }
  if ([value isKindOfClass:[NSData class]]) {
    return [value base64EncodedStringWithOptions:0];
  }
  if ([value isKindOfClass:[NSString class]] ||
      [value isKindOfClass:[NSNumber class]]) {
    return value;
  }
  return [value description];
}

#pragma mark - 引擎调用

- (NSDictionary *)pyStatus {
  NSString *error = nil;
  if (![self ensurePython:&error]) {
    return @{@"connected" : @NO, @"error" : error ?: @"Python 解释器启动失败"};
  }
  NSString *text = [self callHostFunction:"status_json" args:@[] error:&error];
  if (text == nil) {
    return @{@"connected" : @NO, @"error" : error ?: @"status_json 调用失败"};
  }
  NSDictionary *obj = [self parseJsonObject:text];
  if (obj == nil) {
    return @{@"connected" : @NO, @"error" : @"Python 引擎返回了无法解析的结果"};
  }
  return @{
    @"connected" : @YES,
    @"python" : obj[@"python"] ?: @"",
    @"requests" : obj[@"requests"] ?: @NO,
  };
}

- (NSDictionary *)pyCall:(NSString *)siteId
                  method:(NSString *)method
                    args:(NSDictionary *)args {
  NSString *error = nil;
  if (![self ensurePython:&error]) {
    @throw [[PyBridgeError alloc] initWithCode:@"NOT_CONNECTED"
                                       message:error ?: @"Python 解释器启动失败"];
  }
  NSError *jsonError = nil;
  NSData *argsData = [NSJSONSerialization dataWithJSONObject:[self sanitize:args]
                                                     options:0
                                                       error:&jsonError];
  if (argsData == nil) {
    @throw [[PyBridgeError alloc] initWithCode:@"SPIDER_ERROR"
                                       message:@"请求参数无法序列化为 JSON"];
  }
  NSString *argsJson = [[NSString alloc] initWithData:argsData
                                             encoding:NSUTF8StringEncoding];
  NSString *text = [self callHostFunction:"handle_json"
                                     args:@[ siteId, method, argsJson ]
                                    error:&error];
  if (text == nil) {
    @throw [[PyBridgeError alloc] initWithCode:@"SPIDER_ERROR"
                                       message:error ?: @"Python 引擎调用失败"];
  }
  NSDictionary *obj = [self parseJsonObject:text];
  if (obj == nil) {
    @throw [[PyBridgeError alloc] initWithCode:@"SPIDER_ERROR"
                                       message:@"Python 引擎返回了无法解析的结果"];
  }
  if (![obj[@"ok"] boolValue]) {
    @throw [[PyBridgeError alloc] initWithCode:@"SPIDER_ERROR"
                                       message:obj[@"error"] ?: @"蜘蛛执行失败"];
  }
  id data = obj[@"data"];
  if ([data isKindOfClass:[NSDictionary class]]) {
    return data;
  }
  if (data == nil || data == [NSNull null]) {
    return @{};
  }
  return @{@"value" : data};
}

- (void)pyRelease:(NSString *)siteId {
  NSString *error = nil;
  if (![self ensurePython:&error]) return;
  [self callHostFunction:"release_json" args:@[ siteId ] error:&error];
}

- (NSDictionary *)parseJsonObject:(NSString *)text {
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
  if (data == nil) return nil;
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if ([obj isKindOfClass:[NSDictionary class]]) return obj;
  return nil;
}

#pragma mark - 解释器初始化与宿主调用（只在串行队列上跑）

/// 确保解释器已初始化且宿主模块已导入；失败时 error 置真实原因。
/// 已初始化后只做模块导入重试（与安卓每次调用重试语义一致）。
- (BOOL)ensurePython:(NSString **)errorOut {
  if (self.pythonReady) return YES;
  if (!Py_IsInitialized()) {
    NSString *error = [self initializeInterpreter];
    if (error != nil) {
      if (errorOut) *errorOut = error;
      return NO;
    }
  }
  NSString *error = [self importHostModule];
  if (error != nil) {
    if (errorOut) *errorOut = error;
    return NO;
  }
  self.pythonReady = YES;
  return YES;
}

/// 初始化解释器：顺序与 CPython iOS testbed 一致，失败返回原因，成功返回 nil。
- (NSString *)initializeInterpreter {
  PyPreConfig preconfig;
  PyConfig config;
  PyPreConfig_InitIsolatedConfig(&preconfig);
  PyConfig_InitIsolatedConfig(&config);

  preconfig.utf8_mode = 1;
  config.buffered_stdio = 0;
  config.write_bytecode = 0;
  config.install_signal_handlers = 1;
  // 注：use_system_logger 是 3.14 才有的字段，3.13 头文件里没有，不设。

  PyStatus status = Py_PreInitialize(&preconfig);
  if (PyStatus_Exception(status)) {
    NSString *message = [NSString stringWithUTF8String:status.err_msg ?: ""];
    PyConfig_Clear(&config);
    return [NSString stringWithFormat:@"Python 预初始化失败：%@", message];
  }

  NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
  NSString *pythonHome = [resourcePath stringByAppendingPathComponent:@"python"];
  wchar_t *homeWide = Py_DecodeLocale([pythonHome UTF8String], NULL);
  if (homeWide == NULL) {
    PyConfig_Clear(&config);
    return @"PYTHONHOME 路径无法编码";
  }
  status = PyConfig_SetString(&config, &config.home, homeWide);
  PyMem_RawFree(homeWide);
  if (PyStatus_Exception(status)) {
    NSString *message = [NSString stringWithUTF8String:status.err_msg ?: ""];
    PyConfig_Clear(&config);
    return [NSString stringWithFormat:@"PYTHONHOME 设置失败：%@", message];
  }

  status = PyConfig_Read(&config);
  if (PyStatus_Exception(status)) {
    NSString *message = [NSString stringWithUTF8String:status.err_msg ?: ""];
    PyConfig_Clear(&config);
    return [NSString stringWithFormat:@"读取站点配置失败：%@", message];
  }

  char *argv[] = {"wxyy"};
  status = PyConfig_SetBytesArgv(&config, 1, argv);
  if (PyStatus_Exception(status)) {
    NSString *message = [NSString stringWithUTF8String:status.err_msg ?: ""];
    PyConfig_Clear(&config);
    return [NSString stringWithFormat:@"argv 设置失败：%@", message];
  }

  status = Py_InitializeFromConfig(&config);
  PyConfig_Clear(&config);
  if (PyStatus_Exception(status)) {
    NSString *message = [NSString stringWithUTF8String:status.err_msg ?: ""];
    return [NSString stringWithFormat:@"Python 解释器启动失败：%@", message];
  }
  return nil;
}

/// 挂 sys.path 并导入宿主模块；失败返回原因，成功返回 nil。
/// GIL 由调用方（串行队列上的每次调用）经 PyGILState_Ensure 持有。
- (NSString *)importHostModule {
  PyGILState_STATE gstate = PyGILState_Ensure();
  NSString *error = [self importHostModuleLocked];
  PyGILState_Release(gstate);
  return error;
}

- (NSString *)importHostModuleLocked {
  NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
  NSString *packagesPath = [resourcePath stringByAppendingPathComponent:@"py_packages"];
  NSString *codePath = [resourcePath stringByAppendingPathComponent:@"pycode"];

  // 第三方纯 Python 包走 site.addsitedir（与 testbed 一致，.pth 也能生效）。
  PyObject *siteModule = PyImport_ImportModule("site");
  if (siteModule == NULL) {
    return [NSString stringWithFormat:@"导入 site 模块失败：%@", [self fetchPythonError]];
  }
  PyObject *addSiteDir = PyObject_GetAttrString(siteModule, "addsitedir");
  Py_DECREF(siteModule);
  if (addSiteDir == NULL || !PyCallable_Check(addSiteDir)) {
    Py_XDECREF(addSiteDir);
    PyErr_Clear();
    return @"取不到 site.addsitedir";
  }
  PyObject *packagesArg = PyUnicode_FromString([packagesPath UTF8String]);
  if (packagesArg == NULL) {
    Py_DECREF(addSiteDir);
    PyErr_Clear();
    return @"py_packages 路径无法编码为 Python 字符串";
  }
  PyObject *siteResult =
      PyObject_CallFunctionObjArgs(addSiteDir, packagesArg, NULL);
  Py_DECREF(packagesArg);
  Py_DECREF(addSiteDir);
  if (siteResult == NULL) {
    return [NSString stringWithFormat:@"addsitedir(py_packages) 失败：%@",
                                      [self fetchPythonError]];
  }
  Py_DECREF(siteResult);

  // 宿主代码目录插到 sys.path 最前面。
  PyObject *sysModule = PyImport_ImportModule("sys");
  if (sysModule == NULL) {
    return [NSString stringWithFormat:@"导入 sys 模块失败：%@", [self fetchPythonError]];
  }
  PyObject *sysPath = PyObject_GetAttrString(sysModule, "path");
  Py_DECREF(sysModule);
  if (sysPath == NULL) {
    return [NSString stringWithFormat:@"取不到 sys.path：%@", [self fetchPythonError]];
  }
  PyObject *codeArg = PyUnicode_FromString([codePath UTF8String]);
  if (codeArg == NULL) {
    Py_DECREF(sysPath);
    PyErr_Clear();
    return @"pycode 路径无法编码为 Python 字符串";
  }
  int inserted = PyList_Insert(sysPath, 0, codeArg);
  Py_DECREF(codeArg);
  Py_DECREF(sysPath);
  if (inserted != 0) {
    return [NSString stringWithFormat:@"sys.path 插入 pycode 失败：%@",
                                      [self fetchPythonError]];
  }

  PyObject *module = PyImport_ImportModule("py_spider_host");
  if (module == NULL) {
    return [NSString stringWithFormat:@"导入 py_spider_host 失败：%@",
                                      [self fetchPythonError]];
  }
  if (self.hostModule != NULL) {
    Py_DECREF(self.hostModule);
  }
  self.hostModule = module;  // 持有引用，随桥同寿。
  return nil;
}

/// 调宿主函数并取字符串结果；失败时 error 置真实原因并返回 nil。
- (NSString *)callHostFunction:(const char *)name
                          args:(NSArray<NSString *> *)args
                         error:(NSString **)errorOut {
  PyGILState_STATE gstate = PyGILState_Ensure();
  NSString *result = [self callHostFunctionLocked:name args:args error:errorOut];
  PyGILState_Release(gstate);
  return result;
}

- (NSString *)callHostFunctionLocked:(const char *)name
                                args:(NSArray<NSString *> *)args
                               error:(NSString **)errorOut {
  PyObject *func = PyObject_GetAttrString(self.hostModule, name);
  if (func == NULL || !PyCallable_Check(func)) {
    Py_XDECREF(func);
    PyErr_Clear();
    if (errorOut) {
      *errorOut = [NSString stringWithFormat:@"宿主缺少方法 %s", name];
    }
    return nil;
  }
  PyObject *pyArgs[4];
  NSUInteger count = MIN(args.count, 3);
  for (NSUInteger i = 0; i < count; i++) {
    pyArgs[i] = PyUnicode_FromString([args[i] UTF8String]);
    if (pyArgs[i] == NULL) {
      for (NSUInteger j = 0; j < i; j++) {
        Py_DECREF(pyArgs[j]);
      }
      Py_DECREF(func);
      PyErr_Clear();
      if (errorOut) {
        *errorOut = @"请求参数无法编码为 Python 字符串";
      }
      return nil;
    }
  }
  PyObject *result = NULL;
  if (count == 0) {
    result = PyObject_CallFunctionObjArgs(func, NULL);
  } else if (count == 1) {
    result = PyObject_CallFunctionObjArgs(func, pyArgs[0], NULL);
  } else if (count == 2) {
    result = PyObject_CallFunctionObjArgs(func, pyArgs[0], pyArgs[1], NULL);
  } else {
    result =
        PyObject_CallFunctionObjArgs(func, pyArgs[0], pyArgs[1], pyArgs[2], NULL);
  }
  for (NSUInteger i = 0; i < count; i++) {
    Py_DECREF(pyArgs[i]);
  }
  Py_DECREF(func);
  if (result == NULL) {
    if (errorOut) {
      *errorOut = [NSString stringWithFormat:@"Python 引擎调用失败：%@",
                                             [self fetchPythonError]];
    }
    return nil;
  }
  const char *utf8 = PyUnicode_AsUTF8(result);
  NSString *text = nil;
  if (utf8 != NULL) {
    text = [NSString stringWithUTF8String:utf8];
  } else {
    PyErr_Clear();
  }
  Py_DECREF(result);
  if (text == nil && errorOut) {
    *errorOut = @"Python 引擎返回了非字符串结果";
  }
  return text;
}

/// 取当前 Python 异常并格式化为一行；调用后异常指示已清除。
- (NSString *)fetchPythonError {
  PyObject *type = NULL;
  PyObject *value = NULL;
  PyObject *traceback = NULL;
  PyErr_Fetch(&type, &value, &traceback);
  if (type == NULL) {
    return @"未知 Python 错误";
  }
  NSString *typeName = [NSString stringWithUTF8String:((PyTypeObject *)type)->tp_name];
  NSString *detail = @"";
  if (value != NULL) {
    PyObject *text = PyObject_Str(value);
    if (text != NULL) {
      const char *utf8 = PyUnicode_AsUTF8(text);
      if (utf8 != NULL) {
        detail = [NSString stringWithUTF8String:utf8];
      } else {
        PyErr_Clear();
      }
      Py_DECREF(text);
    } else {
      PyErr_Clear();
    }
  }
  Py_XDECREF(type);
  Py_XDECREF(value);
  Py_XDECREF(traceback);
  if (detail.length > 0) {
    return [NSString stringWithFormat:@"%@: %@", typeName, detail];
  }
  return typeName;
}

@end

#pragma mark - 结构化错误（与安卓 BridgeError 同义）

@implementation PyBridgeError

- (instancetype)initWithCode:(NSString *)code message:(NSString *)message {
  self = [super initWithName:@"PyBridgeError" reason:message userInfo:nil];
  if (self) {
    _code = [code copy];
    _message = [message copy];
  }
  return self;
}

@end
