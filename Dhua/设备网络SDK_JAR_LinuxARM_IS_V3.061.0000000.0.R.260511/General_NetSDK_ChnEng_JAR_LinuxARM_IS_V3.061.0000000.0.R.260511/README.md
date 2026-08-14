# NetSDK jar包说明

本工程为netsdk jar包demo. demo在com.netsdk.demo下

1. NetSDKDemo: netsdk简单使用流程,初始化->登录->登出
2. RealPlayByDataTypeDemo: 拉流转码demo

## jar文件说明

jar包主要存放在resources和source文件夹。

### resources下jar包说明

1. jna.jar: netsdk依赖包,jna版本为5.13.0,可使用maven仓库引入

```xml

<dependency>
    <groupId>net.java.dev.jna</groupId>
    <artifactId>jna</artifactId>
    <version>5.13.0</version>
</dependency>
```

3. netsdk-api-{type}-{version}.jar : netsdk java封装层,集成时需要引入。关于type说明
    1. main:netsdk通用版本,适用于win64,linux64,mac64系统,建议使用该版本
    2. win32: 适用于win32系统
    3. linux32: 适用于linux32系统
4. netsdk-dynamic-lib-{type}-{version}.jar : netsdk所依赖的动态库,与netsdk-api.jar配合使用，集成时需要引入。type含义同上。  
### source下jar包说明
1. netsdk-api-{type}-{version}-sources.jar: 是netsdk-api.jar的源码包,方便查看一些接口参数和注释