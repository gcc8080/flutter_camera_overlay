# flutter_camera_overlay 相机崩溃修复测试回归方案

## 1. 文档信息

| 项目 | 内容 |
| --- | --- |
| 测试对象 | `gcc8080/flutter_camera_overlay` 及其接入的业务 App |
| 修复分支 | `fix/camera-capture-session-crash` |
| 固定测试提交 | `5d694da8c115216309d0746977b2a7c2c7d7c27c` |
| 提交说明 | `Migrate camera overlay to CameraX` |
| Flutter | `3.27.4` |
| Android | `minSdk 23`、`targetSdk 34` |
| iOS | 最低 iOS 13 |
| 插件基线 | `camera 0.11.2`、`camera_android_camerax 0.6.17` |
| 重点历史异常 | `Camera.closeCaptureSession` 调用空 `CameraCaptureSession.close()` 导致 NPE |

测试时应使用固定提交 SHA，而不是只写分支名，避免测试期间分支继续变化：

```yaml
dependencies:
  flutter_camera_overlay:
    git:
      url: https://github.com/gcc8080/flutter_camera_overlay.git
      ref: 5d694da8c115216309d0746977b2a7c2c7d7c27c
```

> 本方案的最终验收对象是实际业务 App。仅运行 package 示例工程不足以证明业务工程选择了正确的 Android 相机实现，也无法覆盖业务路由、权限封装和生命周期管理。

## 2. 测试目标

1. 确认 Android 实际加载的是 `camera_android_camerax`，没有被业务工程中的直接或间接配置切回旧的 `camera_android` Camera2 实现。
2. 确认相机初始化、拍照、切换、后台/前台和销毁操作已串行化，不再出现关闭会话竞态。
3. 确认修复没有引入黑屏、相机占用不释放、重复回调、拍照失败、权限异常或内存持续增长。
4. 确认共用 Dart 生命周期代码没有破坏 iOS 13+ 的既有行为。
5. 通过 Bugly 灰度数据确认历史崩溃签名在真实用户环境中归零，并监控新的 CameraX/OEM 兼容问题。

## 3. 缺陷判定口径

### 3.1 历史崩溃签名

以下任一特征出现，都判定为本缺陷未修复：

```text
java.lang.NullPointerException
Attempt to invoke virtual method
'void android.hardware.camera2.CameraCaptureSession.close()'
on a null object reference

io.flutter.plugins.camera.Camera.closeCaptureSession
io.flutter.plugins.camera.Camera$1.onClosed
```

### 3.2 同类生命周期失败

即使没有上述完全相同的栈，以下现象也按阻断问题处理：

- 进入或退出相机页时 App 崩溃、ANR 或原生进程退出；
- 返回前台后持续黑屏、一直停在 loading，10 秒内不能自恢复；
- 退出相机页后摄像头指示灯仍亮，或其他 App 提示摄像头被占用；
- 日志出现 `setState() called after dispose`、`Disposed CameraController`、重复 dispose、未处理的 `CameraException`；
- 一次拍照操作触发多次 `onCapture`，或页面已退出后仍触发回调；
- 连续进出后相机再也无法打开，必须杀进程才能恢复。

## 4. 回归策略与执行顺序

| 阶段 | 内容 | 是否阻断下一阶段 |
| --- | --- | --- |
| G0 | 测试包、Flutter 版本、Git SHA 和依赖实现核验 | 是 |
| G1 | 静态检查、单元测试、Android/iOS 构建 | 是 |
| G2 | Android 关键功能与权限冒烟 | 是 |
| G3 | 生命周期竞态专项及稳定性压测 | 是 |
| G4 | Android API/OEM 矩阵与 iOS 回归 | 是 |
| G5 | Bugly 内测与分阶段灰度 | 是 |

任何阶段发现 P0/P1 问题，应停止扩大测试或灰度范围，保存设备信息、操作录像和完整日志后回到研发定位。

## 5. G0：测试基线和依赖验收

### 5.1 记录环境

每个测试包至少保存以下信息：

```bash
flutter --version
flutter doctor -v
git rev-parse HEAD
flutter pub deps --style=compact
```

预期结果：

- Flutter 必须为 `3.27.4`；
- `flutter_camera_overlay` 必须解析到提交 `5d694da8...`；
- 宿主 App 使用唯一的测试版本号和 build number，不能与线上旧包混用；
- Android 的 `minSdk`、`targetSdk` 与待发布配置一致；
- iOS Deployment Target 不低于 13，且与待发布配置一致。

### 5.2 确认 Android 插件选择

在业务 App 根目录执行：

```bash
flutter clean
flutter pub get
flutter pub deps --style=compact | grep -E 'camera|flutter_camera_overlay'
grep -Eo '"name"[[:space:]]*:[[:space:]]*"camera_android(_camerax)?"' .flutter-plugins-dependencies | sort -u
```

必须同时满足：

- 存在 `camera 0.11.2`；
- 存在 `camera_android_camerax 0.6.17`；
- `.flutter-plugins-dependencies` 中 Android 实现是 `camera_android_camerax`；
- 不存在独立的 `camera_android` 条目；
- 业务 App 的 `pubspec.yaml`、`dependency_overrides` 和其他本地 package 均未直接依赖 `camera_android`。

如果出现 `camera_android`，立即停止后续测试。此时构建仍可能成功，但测试的不是本次修复路径。

### 5.3 记录 Android 真机信息

每台 Android 设备执行并附到测试记录：

```bash
adb shell getprop ro.product.manufacturer
adb shell getprop ro.product.model
adb shell getprop ro.build.version.release
adb shell getprop ro.build.version.sdk
adb shell getprop ro.product.cpu.abi
```

同时记录后置/前置摄像头、是否支持闪光灯、设备内存档位及厂商系统版本。

## 6. G1：代码与构建门禁

在固定 Flutter 版本下执行：

```bash
flutter analyze
flutter test
flutter build apk --debug
flutter build appbundle --release
flutter build ios --release --no-codesign
```

若 CI 分开构建平台，可分别在 Android 和 macOS Runner 上执行。通过标准：

- 所有命令退出码为 0；
- 无新的 analyzer error/warning；
- Android debug APK 与 release AAB 均成功；
- iOS release 构建成功；
- Release 包必须进入真机测试，不能只验证 Debug 包；
- 若业务工程已有 flavor，至少覆盖生产 flavor 和一个内部测试 flavor。

建议补充以下自动化测试，作为后续长期门禁：

| 自动化用例 | 核心断言 |
| --- | --- |
| 生命周期串行化 | `inactive/paused/resumed/detached` 快速切换时初始化与 dispose 不重叠 |
| 快速返回 | 初始化未完成即销毁 Widget，不发生销毁后更新 UI |
| 重复拍照 | 连续点击期间最多执行一次 `takePicture`，只回调一次 |
| 拍照后销毁 | 页面销毁后不再调用 `onCapture` |
| 相机切换 | `CameraDescription` 改变时先释放旧 controller，再初始化新 controller |
| 闪光灯更新 | `flash` 属性变化不在 `build()` 中产生重复原生调用 |

Widget 单元测试可以使用 fake camera platform 验证状态机；真实 CameraX 行为仍必须用 Android 真机 integration test 验证。

## 7. 测试设备矩阵

### 7.1 Android 必测矩阵

Bugly 已出现 API 27、31、33、34，因此这些版本必须使用真机覆盖；API 23 是最低兼容边界，也必须验证。

| 优先级 | Android/API | 设备要求 | 覆盖目的 |
| --- | --- | --- | --- |
| P0 | Android 8.1 / API 27 | 真机，优先低内存或旧款 OEM | 已出现崩溃，验证老 Camera HAL |
| P0 | Android 12 / API 31 | 真机 | 已出现崩溃，验证前后台与隐私指示器 |
| P0 | Android 13 / API 33 | 真机 | 已出现崩溃 |
| P0 | Android 14 / API 34 | 真机，与 targetSdk 34 对齐 | 已出现崩溃及目标版本边界 |
| P1 | Android 6 / API 23 | 真机优先，至少模拟器加一台近似低端真机 | minSdk 边界 |

厂商覆盖至少包括：

- 一台 Pixel/AOSP 系设备；
- 一台 Samsung；
- 一台小米/Redmi/POCO、OPPO/realme 或 vivo 设备；
- 一台 4 GB RAM 或更低的设备；
- 一台具有多后摄、自动镜头选择或特殊相机 HAL 的近年设备。

若资源有限，执行顺序为 API 27 → API 34 → API 31 → API 33 → API 23。模拟器只能用于权限和 API 边界补充，不能替代 CameraX 真机稳定性测试。

### 7.2 iOS 必测矩阵

| 优先级 | 系统 | 设备要求 | 覆盖目的 |
| --- | --- | --- | --- |
| P0 | iOS 13.x | 支持该版本的真机 | 最低兼容边界 |
| P0 | 当前线上用户占比最高的 iOS 大版本 | 真机 | 主流回归 |
| P1 | 当前生产支持的最高 iOS 大版本 | 真机 | 新系统兼容 |

iOS 模拟器不能代替真实摄像头测试。由于本次生命周期逻辑位于共享 Dart 层，iOS 虽没有原 Android NPE，也必须完整执行进出页面、后台恢复和拍照中断用例。

## 8. G2：核心功能与权限回归

以下用例在 Android API 27、34 及 iOS 13 上全量执行，其他设备执行 P0/P1 项。

| ID | 优先级 | 前置条件与操作 | 预期结果 |
| --- | --- | --- | --- |
| F-01 | P0 | 首次安装，进入相机页并允许权限 | 预览在合理时间内出现，无黑屏/崩溃 |
| F-02 | P0 | 首次进入时拒绝权限 | App 不崩溃；显示业务定义的可恢复提示 |
| F-03 | P0 | 选择“不再询问”后再次进入，再到系统设置开启权限 | 返回 App 后可以重新打开预览 |
| F-04 | P0 | 正常拍照一次 | 仅触发一次 `onCapture`；文件存在、非 0 字节且可解码 |
| F-05 | P0 | 连续快速点击拍照键 10 次 | 一次拍摄未完成前按钮不可重复触发；最多生成一张照片和一次回调 |
| F-06 | P0 | 拍照完成后再次拍照 | 第二次可以正常拍摄，不因上次状态残留失效 |
| F-07 | P0 | `flash=false` 拍照 | 闪光灯保持关闭，预览和拍照正常 |
| F-08 | P0 | `flash=true`，分别在明亮和昏暗环境拍照 | 自动闪光行为符合设备能力；无未处理异常 |
| F-09 | P1 | 使用无闪光灯的摄像头或前摄，并测试 `flash` 配置 | 不发生崩溃；若产品不支持该组合，应有明确限制或降级 |
| F-10 | P0 | 校验 ID1、ID2、ID3、SIM overlay | 遮罩比例、位置、预览层级与修复前一致 |
| F-11 | P1 | 校验 `label`、`info`、`infoMargin`、自定义 loading | 文案及布局正确，无溢出或闪烁 |
| F-12 | P1 | `enableCaptureButton=false` | 不显示内置拍照按钮；外部业务流程不受影响 |
| F-13 | P1 | 前后摄切换；若业务没有该功能则标记 N/A | 旧摄像头先释放，新摄像头正常初始化 |
| F-14 | P0 | 拍摄横屏、竖屏及不同设备方向 | 输出方向、EXIF、宽高和业务裁剪结果正确 |
| F-15 | P0 | 连续完成业务完整流程：进入、拍摄、确认/上传、返回 | 图片路径在消费完成前有效；业务上传或识别不受影响 |

权限拒绝后的 UI 属于宿主 App 的责任。即使插件将异常上报为 Flutter error，也不能接受用户只能停留在无限 loading 的结果。

## 9. G3：生命周期竞态专项

这是本次修复的核心，不得用普通功能冒烟替代。所有 P0 Android 真机都要执行，其中 API 27 和 API 34 使用高强度次数。

| ID | 操作 | API 27/34 次数 | API 23/31/33 次数 | 关键断言 |
| --- | --- | ---: | ---: | --- |
| L-01 | 进入相机页，预览出现后立即返回 | 100 | 30 | 无崩溃；摄像头释放；可再次进入 |
| L-02 | 进入相机页后在 loading 阶段立即返回 | 100 | 30 | 初始化与 dispose 不冲突；无页面退出后更新 |
| L-03 | 点击拍照后立刻返回上一页 | 100 | 30 | 无 NPE；退出后不触发过期回调 |
| L-04 | 点击拍照后立刻按 Home，再回到 App | 50 | 20 | 后台释放、前台重建；最多一次有效回调 |
| L-05 | 预览状态下 Home/App 来回切换 | 50 | 20 | 每次恢复可预览，无永久黑屏 |
| L-06 | 预览状态锁屏/解锁 | 30 | 10 | 恢复正常；相机没有被永久占用 |
| L-07 | 快速连续 push/pop 相机路由 | 100 | 30 | 无崩溃、ANR、黑屏及资源累积 |
| L-08 | 打开相机后切到另一个使用摄像头的 App，再返回 | 30 | 10 | 能恢复或给出可恢复错误，不崩溃 |
| L-09 | 拍照过程中切换 `flash` 属性 | 30 | 10 | 操作有序；没有并发原生调用异常 |
| L-10 | 初始化或拍照过程中切换前后摄 | 30 | 10 | 若产品支持切换：旧 controller 释放后再初始化新 controller |
| L-11 | 允许旋转时，在初始化、预览、拍照三个阶段旋转设备 | 各 30 | 各 10 | Activity 重建后正常，无重复 controller |
| L-12 | 后台停留后由系统回收进程，再从最近任务恢复 | 10 | 5 | 业务可重建；无旧相机句柄残留 |
| L-13 | 权限弹窗显示期间按 Home、锁屏或切 App | 20 | 10 | 回到 App 后状态一致、可重试 |
| L-14 | 拍照按钮连点与返回手势交叉执行 | 50 | 20 | 无双重拍照、无销毁后回调、无崩溃 |

每完成一组循环，退出相机页并检查：

- 摄像头隐私指示器/硬件指示灯关闭；
- 立即打开系统相机或另一相机 App 可以正常使用；
- 再次进入业务相机页可以恢复；
- 没有出现历史 NPE 或同类未处理异常。

## 10. 稳定性、资源和性能

### 10.1 混合稳定性压测

在 API 27 与 API 34 真机各执行一次不少于 60 分钟的混合操作，或累计达到 500 次相机状态转换，以较晚满足者为准。随机组合以下动作：

- 进入/退出相机页；
- loading 时返回；
- 拍照、连点、拍照时返回；
- Home/恢复；
- 锁屏/解锁；
- 旋转；
- 切换闪光灯或摄像头；
- 权限撤销后恢复。

通过标准：0 crash、0 ANR、0 历史签名、0 永久黑屏、0 相机永久占用。

### 10.2 内存与相机资源

在进入相机页前、首次预览后、连续进出 20/50/100 次后各采样 5 次：

```bash
adb shell dumpsys meminfo <业务包名>
adb shell dumpsys media.camera
```

判定标准：

- 退出相机页并稳定 30 秒后，`media.camera` 中不应残留该 App 的活动 camera client；
- PSS 允许短期波动，但回收后不能随循环次数持续单调增长；
- 100 次后的稳定 PSS 中位数建议不高于首次稳定基线的 120%；超出时必须进一步用 Profiler/heap dump 判断是否存在 controller、Surface 或图片缓存泄漏；
- 相机页打开耗时、恢复耗时和拍照回调耗时的 P95 不应比旧版本同设备基线劣化超过 20%；没有旧基线时，任何超过 10 秒仍未预览或未恢复的情况直接判失败。

## 11. 日志与证据留存

每个失败用例必须附：测试包版本/build、Git SHA、设备厂商/型号、Android API 或 iOS 版本、操作录像、发生时间、重现次数和日志。

Android 每组专项前清空日志，结束后导出：

```bash
adb logcat -c
# 执行测试用例
adb logcat -d -v threadtime > camera_regression_<device>_<case>.log
grep -E 'FATAL EXCEPTION|CameraCaptureSession.close|closeCaptureSession|CameraException|CameraAccessException|Disposed CameraController|setState.*after dispose' camera_regression_<device>_<case>.log
```

正常生命周期下，上述错误关键字应为 0。若有 CameraX 普通状态日志但没有 error，不应仅凭日志量判失败。

iOS 使用 Xcode Devices and Simulators 导出对应时间段的设备日志和 crash report。日志必须能与具体用例、设备和时间关联。

## 12. 新旧版本对照验证

在至少一台 API 27 和一台 API 34 真机上制作两个包：

- A 包：线上旧版本/旧 camera 实现；
- B 包：固定提交 `5d694da8...`。

在同一设备、同一系统设置下，对 A/B 执行相同的 L-02、L-03、L-05、L-07 各 100 次并记录结果。若 A 能复现而 B 不能，且 B 的依赖核验确认为 CameraX，这是强支持证据。由于原问题是竞态问题，A 偶尔未复现不能反向证明修复无效，因此 B 仍须完成全部压测和线上灰度。

## 13. iOS 共享逻辑回归

iOS 13 真机和主流 iOS 真机至少执行：

1. 首次授权、拒绝、系统设置重新授权；
2. 正常预览与连续拍照 20 次；
3. 快速连点拍照键；
4. loading 时返回 30 次；
5. 拍照后立即返回 30 次；
6. Home/恢复 30 次；
7. 锁屏/解锁 10 次；
8. 连续进入/退出相机页 50 次；
9. 输出图片方向、尺寸、可解码性和业务上传/识别流程；
10. 退出页面后系统相机可立即使用。

通过标准与 Android 一致：无 crash、无永久黑屏、无重复回调、无销毁后回调、无相机资源残留。

## 14. Bugly 内测与灰度验证

### 14.1 上报完整性

当前历史截图中的“设备”列显示 `fail`。这不是崩溃原因，但会阻碍 OEM 聚类和定点回归。灰度前必须用内部测试包验证 Bugly 至少能记录：

- App version 与 build number；
- Git SHA/发布批次自定义字段；
- 设备厂商、型号、系统版本/API、ABI；
- 相机页进入、初始化成功/失败、拍照、后台、恢复、销毁等关键面包屑或自定义日志；
- 当前选择的 camera implementation/version（建议上报 `CameraX`、`camera 0.11.2`、`camera_android_camerax 0.6.17`）。

如需验证崩溃上报，只能在独立内测包执行 Bugly 测试崩溃，不得在生产包或用户设备执行。

### 14.2 观测指标

首要查询条件：

```text
io.flutter.plugins.camera.Camera.closeCaptureSession
或
Attempt to invoke virtual method ... CameraCaptureSession.close()
```

同时观察：

- 全部 camera 相关 crash/ANR 数；
- 相机页会话 crash-free rate；
- 预览初始化成功率；
- 拍照回调成功率；
- 初始化、前台恢复、拍照回调 P95；
- 按 Android API、厂商、型号、ABI、App 版本分组后的异常集中度。

如果还没有“相机页会话数”作为分母，建议在灰度前补充埋点；仅按 DAU 计算会稀释真实相机失败率。

### 14.3 灰度节奏

| 阶段 | 流量 | 最短观察 | 最低有效暴露 | 放量条件 |
| --- | ---: | ---: | ---: | --- |
| 内测 | QA/研发 | 24 小时 | 完成全部专项循环 | G0-G4 全通过 |
| 灰度 1 | 5% | 24 小时 | 1,000 次相机页会话 | 历史签名 0；无新增 P0/P1 聚类 |
| 灰度 2 | 20% | 48 小时 | 累计 5,000 次相机页会话 | 指标不差于旧版基线 |
| 灰度 3 | 50% | 48 小时 | 累计 10,000 次相机页会话 | API/OEM 分组无异常集中 |
| 全量 | 100% | 持续 7 天 | 至少达到旧版历史崩溃平均暴露量的 3 倍 | 历史签名持续为 0，整体稳定性达标 |

时间和暴露量两个条件都要满足。若业务量不足，以“达到旧版同签名平均两次出现间隔对应暴露量的 3 倍”作为替代门槛，而不是仅等待固定小时数。

## 15. 发布准入标准

以下条件全部满足后才允许全量：

- G0 证明实际选中 `camera_android_camerax`，不存在旧 `camera_android`；
- `flutter analyze`、`flutter test`、Android Debug/Release、iOS Release 构建全部通过；
- Android API 23、27、31、33、34 的必测项通过，尤其 API 27/34 高强度生命周期专项 0 crash/ANR；
- iOS 13 和主流 iOS 真机回归通过；
- 所有 P0/P1 缺陷关闭，P2 有明确风险接受人和跟进版本；
- 退出相机页后无资源占用，压力测试无持续内存增长；
- 一次拍照最多一次回调，页面销毁后不产生回调；
- Bugly 设备信息不再为 `fail`，测试版本与 Git SHA 可追踪；
- 灰度期间历史崩溃签名为 0，其他 camera crash/ANR 不高于旧版基线；
- 预览/拍照成功率和 P95 延迟无明显回退。

## 16. 停止发布与回滚条件

满足任一项立即停止放量：

- 补丁版本再次出现历史 `closeCaptureSession` NPE；
- 出现可复现的新 camera P0 crash、ANR、永久黑屏或摄像头永久占用；
- 同一 OEM/API 形成明确的 CameraX 崩溃聚类；
- 相机页成功率相对旧版下降超过 20%，且至少有 1,000 次有效会话；
- 相机相关 crash-free rate 下降超过 0.02 个百分点；
- 图片方向、可读性、上传或识别流程发生影响核心业务的回归。

处理顺序：先暂停灰度并保留问题版本的日志与设备样本，再判断是否回退。旧版本包含已知 Camera2 NPE，不应在没有权衡新旧故障严重度时机械回滚。若必须回滚，应回到已验证的宿主 App 版本，同时保留本修复分支用于后续定点修正；不得通过重新加入 `camera_android` 作为长期方案。

## 17. 测试记录模板

### 17.1 测试包信息

| 字段 | 记录值 |
| --- | --- |
| App version/build |  |
| Flutter version |  |
| App Git SHA |  |
| overlay Git SHA | `5d694da8...` |
| camera 版本 |  |
| Android camera implementation |  |
| 测试 flavor/环境 |  |
| 测试负责人/日期 |  |

### 17.2 用例结果

| 用例 ID | 设备/型号 | OS/API | 执行次数 | 通过/失败 | Bugly ID/日志文件 | 备注 |
| --- | --- | --- | ---: | --- | --- | --- |
|  |  |  |  |  |  |  |

### 17.3 最终结论

```text
G0 依赖门禁：通过 / 不通过
G1 构建门禁：通过 / 不通过
G2 功能回归：通过 / 不通过
G3 生命周期专项：通过 / 不通过
G4 平台矩阵：通过 / 不通过
G5 Bugly 灰度：通过 / 不通过

历史崩溃签名次数：
新增 camera crash/ANR：
遗留风险与负责人：
是否建议全量：是 / 否
```

## 18. 最小执行集（紧急发版时）

若必须缩短周期，下列项目仍不可省略：

1. G0 依赖核验，确认 CameraX 且无 `camera_android`；
2. Flutter analyze/test、Android Release 和 iOS Release 构建；
3. API 27 与 API 34 真机执行 L-02、L-03、L-05、L-07 各 100 次；
4. API 31/33 各完成一次核心功能、权限、后台恢复和 30 次进出；
5. iOS 13 真机完成核心功能、后台恢复和 30 次进出；
6. API 27/34 各完成 60 分钟混合压测；
7. Bugly 5% 灰度至少 24 小时且达到 1,000 次相机页会话，历史签名必须为 0。

最小执行集只用于缩短测试排期，不降低全量发布的 Bugly 观测门槛。
