# 参考插件解剖报告（2026-11-15，来源 E:\desktop\插件，解包 _unpack/）

> 三个第三方插件的机制逆向笔记，供 Andromeda/JoyRun-deb 借鉴。只读分析，未执行任何插件代码。

## 一、UCStep（app.weiphone.ucstep 6.0.6）—— 全局刷步数

**三件套架构**（这才是"全局"的正确姿势）：
| 件 | 路径 | 作用 |
|---|---|---|
| App | /Applications/UCStep.app | UI（目标步数/距离/楼层设置、徽章） |
| **Daemon** | /usr/bin/UCStepDaemon + LaunchDaemons/ucstepdaemon.plist（KeepAlive+RunAtLoad） | **root 守护进程，直连 libsqlite3 写健康数据库** |
| dylib | MobileSubstrate/DynamicLibraries/UCStep.dylib | 过滤器 Bundles=["UGGD"]，只注入一个特定 App |

- daemon 机制实锤（strings）：链接 libsqlite3 → 打开 /var/mobile/Library/Health/healthdb（roothide jbroot 路径解析）→ 写 **StepCountHistory 表**（healthCreateTime/healthStartTime/targetSt·Dis·Fl 字段）→ `killall -9 health` 类进程让数据生效
- **全局生效原理：健康 App 数据库是所有读 Health 的 App（微信运动/健康/悦跑圈首页步数）的数据源头，root 直写 = 零注入零闪退**
- dylib 是补充：hook 特定 App 自己的步数服务实现类（APStepCountServiceImpl / setStepCount: / monitorStepCountNotChangedForApp:numberOfSteps:），处理不走 Health 的 App
- roothide 适配：/var/mobile/Library/pkgmirror 镜像安装 + @loader_path/.jbroot 路径解析

**对我方 JoyRun-deb 的启示**：闪退根因是 hook CMPedometer 结构体 getter；ucstep 证明的稳定路线 = ①daemon 直写 HealthDB（全局步数）②hook 目标 App 自己的步数服务实现类（需先 class-dump 悦跑圈找类名）。放弃 hook 结构体 getter。

## 二、LocationExpert（me.liuming.locationexpert 3.3.9 = LocSuper.app）—— 虚拟定位+扫街自定义轨迹

**注入过滤器（核心学习点）**：dylib `locsuperunit.dylib` 注入 **11 个系统进程**：
com.apple.corelocation（**locationd 本体**）、springboard、UIKit、com.apple.icloud.FMF、FindMyDevice、fmflocatord、findmydeviced、mobileme.fmf1、bulletinboard、aosnotifyd
- 手段：MSHookFunction + MSHookMessageEx，劫持 **CLLocationManager 全部 delegate 回调**（didUpdateLocations/heading/visit/beacon 等类型签名齐全）
- 效果：免 DDI、免 Developer Mode、重启自动生效（substrate 注入常驻）、**连查找 iPhone/FM 系列都看到假位置**
- 特性符号：routeCountForLoop / currentRouteCount（绕圈计数）、initWithSoftwareSimulationState（软件模拟状态机）
- App 侧：GPX 完整框架（Parser/Root/Track/Route/Waypoint）、GMapRouteStep（高德路线步段）、DDKJoystickEngine（摇杆）、播放控制（play/pause/rewind/fast-forward = 轨迹回放倍速）、APTrackManager/MQPTrackManager（轨迹管理）
- 无步数功能（无 cadence/stride/step 符号）

**对 Andromeda 的启示**：Andromeda 现用 DDI+lockdownd simulatelocation（会话制、重启失效、需开发者模式）。locationd 注入是更深一级的机制（常驻+全消费端覆盖）。作为远期高级模式规划：RootHelper 安装 dylib+filter 到系统 → 免 DDI 常驻。工程量大（需 hook locationd 内部），暂不动。

## 三、Crack It-Rootless（com.yourepo.lly.crack 3.4.8）—— 通用会员破解器

- 依赖：mobilesubstrate + preferenceloader + **com.lenglengyu.libsupervipp-rootless（自家 hook 库）**
- 注入目标 App → 解锁内购/会员校验。老总实测：注入 LocSuper 后全功能解锁（含扫街自定义轨迹）
- 学习点：通用破解器的"规则库"模式（每个插件一份 hook 规则），与我方无关但确认了 LocSuper 会员墙在 App 内可被 hook 绕过

## 四、结论与行动项

1. **JoyRun-deb v2（待口令）**：改用 ucstep 双路架构——daemon 直写 HealthDB（全局步数：健康/微信运动）+ JoyRun 专属 dylib（先获取悦跑圈二进制 class-dump 找步数服务类，hook 该类替代 CMPedometer 结构体 getter——闪退根除）
2. **Andromeda 远期**：locationd 注入模块（locexp 模式，11 bundle filter + CLLocationManager delegate 劫持）作为「常驻模式」选项
3. **不做**：会员破解（与本方无关）；LocSuper 无步数功能，不构成 Andromeda 步数方案参考
4. 通用工程点：roothide 插件 = pkgmirror 镜像 + jbroot 解析 + .roothidepatch 软链（AutoPatches.dylib），我方 deb 流水线已覆盖

## 五、LocSuper 的「选区域 / 选轨迹」怎么做的（2026-11-16 反向，v2.7.6 落地）

来源：`me.liuming.locationexpert_3.3.9` 解包（`LocSuper` 主二进制 + `zh-Hans.lproj/Localizable.strings`）。
它的功能拆成三块，参数都写在明文文案里，不需要跑起来猜。

### 1. 扫街（Sweep）= 选区域
| 项 | 它的做法 | 说明 |
|---|---|---|
| **随机扫街** | **中心点 + 半径**，配「定位刷新时间频率」（`sweep_interval`，秒）和「速度」 | 中心点在地图长按放置，半径用档位选（`sweep_radius = 半径 N 米`）。没有画多边形这一步 |
| **路径扫街** | 在一条**折线**上来回扫（`sweepPoints` + `pathSweepCurrentPointIndex` + `pathSweepEndAction`） | 锚点数有免费上限（超了要买 Pro），沿路径循环 |
| 收藏 / 历史 | `LESweepFavoriteResource`、`LESweepHistoryResource`，落 `com.appl.bridge.lesweep` | 扫过的线可收藏、可重放 |
| 状态机 | `LESweepController`：working / paused / stopped，停止要二次确认 | 停止后第三方 App 立刻拿到真实位置 |

**关键结论**：它把「选区域」拆成**两个数字**（中心、半径），而不是让用户画形状。
这是它比我们好用的地方——画多边形手一抖就自交/太小，用户还得重画。

### 2. 模拟导航（Navi）= 选轨迹
| 项 | 它的做法 |
|---|---|
| 起点 / 途经节点 / 终点 | 地图长按加点，`navi_node = 节点`，可清空全部 |
| **速度浮动百分比** | `ns_cell_speed_offset`，在设定速度上叠一个百分比浮动 |
| **停留时间** | `ns_header_delays`：路口、红绿灯、左转、右转、掉头各有固定停留秒数 |
| **请求多条路线** | `ns_cell_route_alternatives`（Google Directions 的 alternatives） |
| **循环次数 + 结束动作** | 「从起点到终点算 1 次；从终点回起点也算 1 次；0 = 无限」，结束可「停在终点」或「回到起点再来」 |
| 路线数据 | 可导入路线数据（`nf_item_import`）、导出 GPX（`navi_menu_export_gpx`）、收藏路线 |

### 3. 我们抄了什么、没抄什么（v2.7.6）
- **抄了（已落地）**：**圆形区域** —— 中心点长按放置 + 半径滑杆（80~1500 m）+ 100/200/300/500/800 快捷档，实时显示面积/亩；内部转 48 边形，面积校验、蛇形绕行、贴路全部走原有代码，不新增第二条算法。
  理由：这是「选区域」最省事的一步，且不会产生自交多边形，正好补掉手画的两个高发失败点。
- **没抄：随机扫街的「随机取点」**。它是在圆里随机撒点再连直线，交叉很多；我们保留蛇形/扫描线，视觉上更像真人在一片场地里跑。
- **没抄：路口/红绿灯停留**。悦跑圈按 GPS 算配速，插入定点停顿会拉低平均配速、还可能触发它自己的异常判定；速度起伏我们已经用「速度区间 + 1 Hz 重采样」表达。
- **早已具备，无需再抄**：途经点长按连续加点、线路保存/改名/删除/排序、GPX 导入导出、中断续跑。这些在 v2.5~2.7 都已完成，对照后确认功能对齐。

