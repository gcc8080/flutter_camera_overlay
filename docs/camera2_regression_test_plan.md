# Camera2 CaptureSession 竞态修复测试回归方案

## 1. 文档信息

| 项目 | 固定基线 |
| --- | --- |
| 最终测试对象 | 集成修复分支后的业务 App |
| `flutter_camera_overlay` 分支 | `fix/use-patched-camera-android` |
| overlay 代码提交 | `03018982eee580b6d7a2c3475193429ab67b3a9f` |
| `camera_android` 分支 | `fix/capture-session-close-race` |
| Camera2 补丁提交 | `e61427e9ad09754aee6767bf996a4d436cb3ab31` |
| Camera2 官方基线 | `camera_android-v0.10.10+3` / `b2ce3b02a27b6e055fb9e2c11fdc30fd2c962669` |
| 回移来源 | `flutter/packages#12224` / `a6c8a09b12560bb760ae6fc3db6d06cb5a7a9ee6` |
| Flutter | `3.27.4` |
| Dart | Flutter 3.27.4 自带版本，实际值写入测试记录 |
| Android | `minSdk 23`、`targetSdk 34` |
| iOS | 最低 iOS 13 |
| app-facing camera 包 | `camera 0.11.2` |
| Camera2 实现 | Git 固定的 `camera_android 0.10.10+3` |

本方案只验证 Camera2 原生补丁路线，不适用于 CameraX 分支。测试包必须固定上述两个代码
提交，不能只引用可移动分支名。

## 2. 缺陷与修复边界

历史 Bugly 崩溃签名：

```text
java.lang.NullPointerException
Attempt to invoke virtual method
'void android.hardware.camera2.CameraCaptureSession.close()'
on a null object reference

io.flutter.plugins.camera.Camera.closeCaptureSession(Camera.java:1322)
io.flutter.plugins.camera.Camera$1.onClosed(Camera.java:409)
```

根因是多个 Camera2 生命周期路径并发读写共享的 `captureSession`：线程先判断字段非空，
另一线程随后将字段清空，原线程再次解引用时触发 NPE。

补丁的核心保证：

- `captureSession` 使用 `volatile` 保证跨线程可见性；
- 每个异步操作只使用进入操作时捕获的局部 Session 快照；
- `closeCaptureSession()` 先清共享字段，再关闭局部快照；
- 旧 Session 的完成回调不能操作新 Session；
- null、已关闭或已替换的 Session 被安全忽略或转换成可处理错误；
- 初始化仍保留 `0.10.10+3` 已有的 CaptureSession 创建等待逻辑。

本补丁不保证消除 Camera2、设备 HAL、权限或业务代码产生的所有相机错误。因此验收既要确认
历史签名归零，也要监控同类 Session 异常是否转化为黑屏、ANR 或不可恢复失败。

## 3. 测试目标

1. 证明业务 APK 实际注册的是补丁版 Camera2，而不是 `camera` 默认的 CameraX。
2. 证明原生单元测试覆盖 Session 清空、替换、关闭及旧回调场景。
3. 证明快速退出、前后台切换、拍照中断等动作不再触发历史 NPE。
4. 证明修复没有引入黑屏、重复回调、资源占用、图片异常或明显性能回退。
5. 证明 `camera 0.11.2` 升级没有破坏 iOS 13+ 的现有拍照流程。
6. 通过 Bugly 灰度数据验证真实 OEM/API 分布中的历史签名归零。

## 4. 执行阶段与阻断规则

| 阶段 | 内容 | 下一阶段准入 |
| --- | --- | --- |
| G0 | 提交、依赖来源及 Camera2 实现选择 | 所有阻断项通过 |
| G1 | Camera2 单元测试、静态检查及构建 | 所有命令成功 |
| G2 | 核心功能、权限及图片结果 | P0/P1 用例通过 |
| G3 | 生命周期竞态与资源释放专项 | 0 crash、0 ANR、0 不可恢复黑屏 |
| G4 | API/OEM 矩阵、稳定性及 iOS 回归 | 必测矩阵通过 |
| G5 | Bugly 内测和分阶段灰度 | 达到时间与暴露量门槛 |

任何阶段出现历史 NPE、相机 ANR、永久黑屏、相机永久占用或核心拍照结果错误，立即停止扩大
测试或灰度范围，保存证据后回到研发处理。

## 5. G0：测试基线与依赖选择

### 5.1 宿主 App 必须直接选择 Camera2

Flutter 3.27 只有在宿主 App 直接依赖某个非默认 federated plugin 时，才会用它覆盖默认实现。
因此业务 App 自己的 `pubspec.yaml` 必须同时包含：

```yaml
dependencies:
  flutter_camera_overlay:
    git:
      url: https://github.com/gcc8080/flutter_camera_overlay.git
      ref: 03018982eee580b6d7a2c3475193429ab67b3a9f

  camera_android:
    git:
      url: https://github.com/gcc8080/camera_android.git
      ref: e61427e9ad09754aee6767bf996a4d436cb3ab31
```

只让 `flutter_camera_overlay` 传递依赖 `camera_android` 不足以选择 Camera2。宿主 App 未直接声明
上述 Git 依赖时，构建可能成功，但运行时仍可能选择 CameraX，必须判定 G0 失败。

### 5.2 记录可追溯信息

在业务 App 根目录执行并保存完整输出：

```bash
flutter --version
flutter doctor -v
git rev-parse HEAD
flutter pub get
flutter pub deps --style=compact
```

预期：

- Flutter 精确为 `3.27.4`；
- `flutter_camera_overlay` 的 resolved ref 为 `03018982...`；
- `camera_android` 来源为 `https://github.com/gcc8080/camera_android.git`；
- `camera_android` 的 resolved ref 为 `e61427e9...`；
- `camera` 为 `0.11.2`；
- 不存在指向其他仓库、分支或 hosted 版本的 `camera_android` override。

检查宿主锁文件：

```bash
rg -n -A 14 '^  (flutter_camera_overlay|camera_android):' pubspec.lock
```

### 5.3 验证 federated plugin 最终选择

先清理旧生成物，再重新生成插件清单：

```bash
flutter clean
flutter pub get
jq -r '.plugins.android[].name' .flutter-plugins-dependencies \
  | grep '^camera_android' \
  | sort -u
```

唯一预期输出：

```text
camera_android
```

以下输出属于阻断失败：

```text
camera_android_camerax
```

注意：`flutter pub deps` 的完整包图中仍可能出现 `camera_android_camerax`，因为 `camera 0.11.2`
声明了默认实现；这本身不是失败。判定依据是 `.flutter-plugins-dependencies` 中已解析的
`plugins.android` 列表。

构建后再检查实际生成的 Android registrant，避免在 package cache 中误匹配未被选择的 CameraX
源码：

```bash
registrant=$(find build android -type f -name GeneratedPluginRegistrant.java -print -quit)
test -n "$registrant"
rg -n 'CameraPlugin|CameraAndroidCameraxPlugin' "$registrant"
```

必须注册 `io.flutter.plugins.camera.CameraPlugin`，不得注册
`io.flutter.plugins.camerax.CameraAndroidCameraxPlugin`。

建议在内部测试包启动时上报以下自定义字段：

```text
camera_impl=Camera2
camera_android_sha=e61427e9ad09754aee6767bf996a4d436cb3ab31
overlay_sha=03018982eee580b6d7a2c3475193429ab67b3a9f
```

## 6. G1：单元测试、静态检查与构建

### 6.1 `camera_android` 原生回归测试

先使用 Flutter 3.27.4 检出补丁提交，执行 package 的 Dart 检查：

```bash
git clone https://github.com/gcc8080/camera_android.git
cd camera_android
git checkout e61427e9ad09754aee6767bf996a4d436cb3ab31
flutter pub get
flutter analyze
flutter test
```

然后在已经按 G0 配置、并直接依赖补丁包的业务 App 中执行原生测试。业务 App 自带的 Gradle
wrapper 会加载 Git 依赖中的 `camera_android` module：

```bash
cd <业务 App 根目录>
flutter pub get
cd android
./gradlew projects
./gradlew :camera_android:testDebugUnitTest --rerun-tasks
```

若 `./gradlew projects` 显示的 module 名不同，对实际 Camera2 module 执行
`testDebugUnitTest`。不要使用系统全局 Gradle 代替宿主项目 wrapper。

重点确认以下测试执行且通过：

| 测试 | 关键断言 |
| --- | --- |
| `closeCaptureSession_shouldClearAndCloseSessionSnapshot` | 先清字段，再只关闭捕获的快照 |
| `closeCaptureSession_shouldPreserveReplacementAssignedDuringClose` | close 期间产生的新 Session 不会被误清或误关 |
| `closeCaptureSession_shouldIgnoreNullSession` | 已为空时安全返回 |
| `setFocusMode_shouldUseSessionSnapshotCapturedAtEntryForUnlockAutoFocus` | 连续 AF 操作使用同一快照 |
| `runPrecaptureSequence_shouldUseSessionSnapshotCapturedAtEntry` | 预拍序列不在中途重读共享字段 |
| `onConverge_stillCaptureCallback_ignoresStaleSessionCompletion` | 旧回调不能操作新 Session |
| stale/null Session 相关用例 | 已关闭或为空时不产生未处理异常 |

可在 CI 中对三个 close 用例重复运行 20 次以检查稳定性：

```bash
for run in $(seq 1 20); do
  ./gradlew :camera_android:testDebugUnitTest \
    --tests 'io.flutter.plugins.camera.CameraTest.closeCaptureSession*' \
    --rerun-tasks || exit 1
done
```

通过标准：所有运行退出码为 0，0 failed、0 flaky、0 ignored。

### 6.2 业务 App 构建门禁

在业务 App 中执行：

```bash
flutter analyze
flutter test
flutter build apk --debug
flutter build appbundle --release
flutter build ios --release --no-codesign
```

如果项目有 flavor，至少覆盖生产 flavor 和一个内部测试 flavor。通过标准：

- 所有命令退出码为 0；
- Android Debug APK 与 Release AAB 都生成成功；
- iOS Release 无签名构建成功；
- Release 包进入真机回归，不能只测试 Debug；
- 没有 duplicate class、插件实现冲突或 Gradle/Java 目标不兼容错误。

同时保存：

```bash
cd android
./gradlew -version
./gradlew :app:dependencies --configuration releaseRuntimeClasspath \
  > release_runtime_dependencies.txt
```

## 7. 测试设备矩阵

### 7.1 Android 必测矩阵

Bugly 已在 API 27、31、33、34 发生历史崩溃，因此这些版本必须真机覆盖；API 23 是最低边界。

| 优先级 | Android/API | 设备要求 | 目的 |
| --- | --- | --- | --- |
| P0 | Android 6 / API 23 | 真机优先 | minSdk 边界、旧 HAL |
| P0 | Android 8.1 / API 27 | 真机，优先旧款或低内存设备 | 历史崩溃版本、竞态高强度测试 |
| P0 | Android 12 / API 31 | 真机 | 历史崩溃、隐私指示器及前后台 |
| P0 | Android 13 / API 33 | 真机 | 历史崩溃版本 |
| P0 | Android 14 / API 34 | 真机、targetSdk 边界 | 历史崩溃、竞态高强度测试 |
| P1 | 当前生产最高支持 API | 真机 | 新系统兼容性 |

OEM 至少包括：

- 一台 Pixel/AOSP；
- 一台 Samsung；
- 一台小米/Redmi/POCO；
- 一台 OPPO/realme 或 vivo；
- 一台 4 GB RAM 或更低设备；
- 一台多后摄或具有特殊 Camera HAL 的近年设备。

如果历史 Bugly 数据恢复设备型号，应优先纳入崩溃量最高的前三个型号。模拟器只能补充权限和
API 边界，不得替代 Camera2 真机竞态测试。

每台设备记录：

```bash
adb shell getprop ro.product.manufacturer
adb shell getprop ro.product.model
adb shell getprop ro.build.version.release
adb shell getprop ro.build.version.sdk
adb shell getprop ro.product.cpu.abi
```

### 7.2 iOS 必测矩阵

| 优先级 | 系统 | 要求 |
| --- | --- | --- |
| P0 | iOS 13.x | 真机，最低兼容边界 |
| P0 | 线上占比最高的 iOS 大版本 | 真机 |
| P1 | 当前最高支持的 iOS 大版本 | 真机 |

`camera_android` 不参与 iOS 运行，但 overlay 从旧 `camera 0.9.x` 升级到 `camera 0.11.2`，
iOS 的 transitive implementation 也发生变化，因此不能跳过 iOS 回归。

## 8. G2：功能与权限回归

以下 P0 用例在 API 27、34 和 iOS 13 全量执行，其余设备至少执行 F-01 至 F-10。

| ID | 优先级 | 操作 | 预期结果 |
| --- | --- | --- | --- |
| F-01 | P0 | 首次安装进入相机页并允许权限 | 预览正常出现，无崩溃或永久 loading |
| F-02 | P0 | 首次进入时拒绝权限 | 不崩溃；显示可恢复提示 |
| F-03 | P0 | 选择“不再询问”，到系统设置开启后返回 | 可重新初始化并出现预览 |
| F-04 | P0 | 后置摄像头正常拍照 | 一张有效图片、一次回调 |
| F-05 | P0 | 连续快速点击拍照键 10 次 | 无崩溃；业务防重策略符合预期 |
| F-06 | P0 | 连续正常拍照 20 次 | 每次成功且无状态残留 |
| F-07 | P0 | 闪光灯关闭/自动，在明暗环境分别拍照 | 状态正确，无未处理异常 |
| F-08 | P1 | 无闪光灯摄像头或前摄使用 flash 配置 | 安全降级或返回可处理错误 |
| F-09 | P0 | 校验 ID1、ID2、ID3、SIM overlay | 遮罩比例、位置和层级无回归 |
| F-10 | P0 | 横竖屏及四个设备方向拍照 | 图片方向、EXIF、宽高与业务裁剪正确 |
| F-11 | P1 | 前后摄切换（若业务支持） | 旧摄像头释放后新摄像头成功打开 |
| F-12 | P1 | `enableCaptureButton=false` | 内置按钮隐藏，外部流程正常 |
| F-13 | P1 | label、info、margin、自定义 loading | 文案布局无溢出或闪烁 |
| F-14 | P0 | 拍照后确认、上传/识别并返回 | 文件有效，完整业务链路成功 |
| F-15 | P0 | 拍照失败或相机被占用后重试 | 错误可恢复，不需杀进程 |

## 9. G3：Camera2 生命周期竞态专项

这是本次修复的核心验收，不能用普通拍照冒烟替代。

| ID | 操作 | API 27/34 | API 23/31/33 | 关键断言 |
| --- | --- | ---: | ---: | --- |
| L-01 | 预览出现后立即返回 | 100 次 | 30 次 | 无崩溃；摄像头释放；可再次进入 |
| L-02 | loading/初始化阶段立即返回 | 100 次 | 30 次 | initialize/close 交错安全 |
| L-03 | 点击拍照后立即返回 | 100 次 | 30 次 | 无 close NPE；无过期业务回调 |
| L-04 | 拍照后立即 Home，再返回 App | 50 次 | 20 次 | 恢复或可重试，无旧 Session 操作 |
| L-05 | 预览时反复 Home/恢复 | 50 次 | 20 次 | 每次可恢复，无永久黑屏 |
| L-06 | 预览时锁屏/解锁 | 30 次 | 10 次 | 恢复正常，无永久占用 |
| L-07 | 快速 push/pop 相机路由 | 100 次 | 30 次 | 0 crash/ANR，资源不累积 |
| L-08 | 与系统相机或其他相机 App 争用后返回 | 30 次 | 10 次 | 正常恢复或给出可恢复错误 |
| L-09 | 初始化、预览、拍照阶段分别旋转设备 | 各 30 次 | 各 10 次 | Activity 重建无重复 Session |
| L-10 | 拍照过程中改变 flash 配置 | 30 次 | 10 次 | 不对已关闭 Session 提交请求 |
| L-11 | 初始化/拍照时切换前后摄（若支持） | 30 次 | 10 次 | 旧 Session 回调不能操作新 Session |
| L-12 | 权限弹窗期间 Home、锁屏或切 App | 20 次 | 10 次 | 返回后状态一致且可重试 |
| L-13 | 后台后杀进程，再从入口重启 | 10 次 | 5 次 | 重建成功，无旧句柄残留 |
| L-14 | 拍照连点与返回手势交叉执行 | 50 次 | 20 次 | 无双重 close、无崩溃 |
| L-15 | 进入/退出与相机描述切换交叉执行 | 30 次 | 10 次 | replacement Session 不被旧 close 清除 |

可补充开启“开发者选项 → 不保留活动”执行 L-01、L-02、L-05 各 20 次，用于扩大 Activity
重建窗口。该设置属于压力条件，结果应单独标记，不能代替正常用户条件测试。

每组循环结束必须确认：

- API 31+ 的摄像头隐私指示器在退出后关闭；
- 其他相机 App 可以立即打开摄像头；
- 业务相机页再次进入可以成功预览；
- 没有历史 NPE、`CameraDevice was already closed` 未处理异常或 stale callback 错误；
- 没有必须杀进程才能恢复的黑屏或 camera in use 状态。

## 10. 日志、资源与性能证据

### 10.1 Android 日志

每组竞态用例前清空日志，结束后导出：

```bash
adb logcat -c
# 执行测试
adb logcat -d -v threadtime > camera2_<device>_<case>.log
rg -n 'FATAL EXCEPTION|ANR in|closeCaptureSession|CameraCaptureSession|CameraDevice was already closed|CameraAccessException|NullPointerException' \
  camera2_<device>_<case>.log
```

权限拒绝、其他 App 占用相机等场景可以产生已处理的 `CameraAccessException`；这类日志必须结合
UI 和恢复结果判断。任何未捕获异常、FATAL、ANR 或历史 close NPE 都直接失败。

### 10.2 相机资源释放

在页面退出并稳定 5 秒后采集：

```bash
adb shell dumpsys media.camera > media_camera_after_exit.txt
adb shell dumpsys meminfo <业务包名> > meminfo_after_exit.txt
```

通过标准：

- 退出后没有该 App 的活动 camera client；
- 摄像头指示器关闭；
- 另一相机 App 可立即使用；
- 连续进出 20、50、100 次后没有持续单调增长的 Camera、Surface 或 controller 资源；
- 100 次循环后的稳定 PSS 中位数原则上不高于首次稳定基线的 120%，超出时必须用
  Profiler/heap dump 解释并经研发确认。

### 10.3 性能对照

在同一设备、相同构建类型和相同光照条件下，对生产旧包与补丁包各执行至少 20 次，记录：

- 进入相机页到首帧预览耗时；
- 前台恢复到首帧耗时；
- 点击拍照到收到有效文件的耗时；
- 成功率、P50、P95。

补丁包 P95 原则上不得比旧包劣化超过 20%；超过 10 秒仍无首帧或无法恢复直接失败。

## 11. 稳定性压测

在 API 27 和 API 34 真机各执行不少于 60 分钟，或累计 500 次相机状态转换，以较晚满足者
为准。随机组合：

- 进入/退出相机页；
- loading 时返回；
- 拍照、连点、拍照时返回；
- Home/恢复、锁屏/解锁；
- 旋转、闪光灯切换、前后摄切换；
- 其他相机 App 争用；
- 权限撤销和恢复。

通过标准：0 crash、0 ANR、0 历史签名、0 永久黑屏、0 相机永久占用，且完成后仍可正常
拍照并完成业务上传/识别流程。

## 12. A/B 对照验证

在至少一台 API 27 和一台 API 34 真机制作：

- A 包：当前线上生产版本；
- B 包：固定 overlay `03018982...` 和 Camera2 `e61427e9...` 的补丁版本。

在同设备、同系统设置下，对 A/B 执行 L-02、L-03、L-05、L-07 各 100 次，记录每个包的
crash、ANR、黑屏、恢复失败和相机占用次数。

竞态具有随机性：A 包本轮未复现不能证明旧实现安全，B 包仍须完成全部矩阵和线上灰度。

## 13. iOS 回归

iOS 13 真机和主流 iOS 真机至少执行：

1. 首次授权、拒绝、系统设置重新授权；
2. 正常连续拍照 20 次；
3. 快速连点拍照按钮；
4. loading 时返回 30 次；
5. 拍照后立即返回 30 次；
6. Home/恢复 30 次；
7. 锁屏/解锁 10 次；
8. 连续进入/退出相机页 50 次；
9. 横竖屏图片方向、尺寸、可解码性；
10. 完整上传/识别流程和退出后的系统相机使用。

通过标准：无 crash、永久黑屏、重复回调、销毁后回调或相机资源残留。

## 14. Bugly 与灰度验证

### 14.1 上报完整性

历史截图中设备信息显示 `fail`。这不是本次 NPE 的根因，但会阻碍 OEM 聚类。灰度前必须让
Bugly 或自定义字段至少记录：

- App version/build、业务 Git SHA；
- overlay SHA、camera implementation、`camera_android` SHA；
- 设备厂商、型号、Android API、ABI；
- 相机页进入、初始化、拍照、后台、恢复、释放等关键面包屑；
- 相机初始化成功率、拍照成功率和相机页会话数。

如需验证崩溃上报，只能在独立内测包触发 Bugly 测试崩溃，不得在生产包或用户设备执行。

### 14.2 监控签名

首要查询：

```text
io.flutter.plugins.camera.Camera.closeCaptureSession
或
Attempt to invoke virtual method ... CameraCaptureSession.close()
```

同时监控：

- `CameraDevice was already closed`；
- `unlockAutoFocus`、`runPrecaptureSequence`、`takePictureAfterPrecapture`；
- 全部 camera crash/ANR；
- 预览初始化和拍照成功率；
- 按 API、OEM、型号、ABI、App version 聚类；
- 每 10,000 次相机页会话的 crash/ANR 率。

### 14.3 灰度节奏

| 阶段 | 流量 | 最短观察 | 最低有效暴露 | 放量条件 |
| --- | ---: | ---: | ---: | --- |
| 内测 | QA/研发 | 24 小时 | 完成全部 G0-G4 | 所有门禁通过 |
| 灰度 1 | 5% | 24 小时 | 1,000 次相机页会话 | 历史签名 0，无新 P0/P1 聚类 |
| 灰度 2 | 20% | 48 小时 | 累计 5,000 次会话 | 指标不差于旧版基线 |
| 灰度 3 | 50% | 48 小时 | 累计 10,000 次会话 | API/OEM 无异常集中 |
| 全量 | 100% | 持续 7 天 | 达到旧版历史暴露量的 3 倍 | 历史签名持续为 0 |

时间和暴露量必须同时满足。如果业务量不足，以达到旧版同签名平均出现间隔所对应暴露量的
3 倍为替代门槛，不能仅等待固定小时数。

## 15. 发布准入标准

以下条件必须全部满足：

- 宿主 App 直接依赖补丁版 `camera_android`；
- `.flutter-plugins-dependencies` 最终选择 `camera_android`，而非 CameraX；
- 两个 Git resolved ref 与本方案固定 SHA 完全一致；
- Camera2 原生测试、Flutter analyze/test、Android Debug/Release、iOS Release 构建通过；
- API 23、27、31、33、34 真机必测项通过；
- API 27/34 生命周期专项和稳定性压测为 0 crash/ANR；
- iOS 13 和主流 iOS 真机回归通过；
- 无 P0/P1 遗留缺陷；
- 无相机资源残留或持续内存增长；
- 图片方向、质量、overlay、上传/识别业务流程无回归；
- Bugly 上报可以追溯 App、设备及两个修复 SHA；
- 灰度期间历史 close NPE 为 0，整体 camera crash/ANR 不高于旧版基线。

## 16. 停止放量与回滚

满足任一条件立即停止放量：

- 再次出现历史 `closeCaptureSession` NPE；
- 出现新的可复现 camera crash、ANR、永久黑屏或相机永久占用；
- stale Session 异常在特定 OEM/API 形成聚类；
- 相机页成功率相对旧版下降超过 20%，且已有至少 1,000 次有效会话；
- camera crash-free rate 下降超过 0.02 个百分点；
- 图片方向、清晰度、裁剪、上传或识别发生核心业务回归。

优先回滚到已验证的 CameraX 修复分支或其他已验证版本，不要回滚到未打补丁的 Camera2 实现。
回滚前保留问题包、完整日志、Bugly 聚类、设备样本和复现录像。

## 17. 测试记录模板

### 17.1 测试包信息

| 字段 | 记录值 |
| --- | --- |
| App version/build |  |
| App Git SHA |  |
| Flutter/Dart version |  |
| overlay resolved ref | `03018982eee580b6d7a2c3475193429ab67b3a9f` |
| camera_android resolved ref | `e61427e9ad09754aee6767bf996a4d436cb3ab31` |
| `.flutter-plugins-dependencies` Android 实现 |  |
| targetSdk/minSdk |  |
| flavor/环境 |  |
| QA/日期 |  |

### 17.2 设备与结果

| 用例 ID | 设备/OEM | OS/API | 构建类型 | 执行次数 | 通过/失败 | 日志或缺陷链接 |
| --- | --- | --- | --- | ---: | --- | --- |
|  |  |  |  |  |  |  |

### 17.3 稳定性与灰度

| 指标 | 旧版 | 补丁版 | 门槛 | 结论 |
| --- | ---: | ---: | ---: | --- |
| 相机页会话数 |  |  |  |  |
| 历史 close NPE |  |  | `0` |  |
| camera crash/10k 会话 |  |  | 不高于旧版 |  |
| camera ANR/10k 会话 |  |  | 不高于旧版 |  |
| 初始化成功率 |  |  | 不低于旧版 |  |
| 拍照成功率 |  |  | 不低于旧版 |  |
| 首帧 P95 |  |  | 劣化不超过 20% |  |
| 拍照 P95 |  |  | 劣化不超过 20% |  |

## 18. QA 最终签字

- [ ] G0 依赖来源与 Camera2 选择通过
- [ ] G1 单元测试、静态检查和构建通过
- [ ] G2 核心功能与权限通过
- [ ] G3 生命周期竞态专项通过
- [ ] G4 Android/iOS 矩阵与稳定性通过
- [ ] G5 Bugly 灰度达到时间和暴露量门槛
- [ ] 无 P0/P1 未关闭缺陷
- [ ] QA、研发、发布负责人共同确认可以全量
