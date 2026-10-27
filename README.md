# HealthMi

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)

把小米运动健康（Mi Fitness）云端的健康数据，写入 Apple 健康（HealthKit）的纯 iOS App。

本 fork 基于 [ShawnDiego/HealthMi](https://github.com/ShawnDiego/HealthMi)，增加同步时间窗、原生版本更新、睡眠重复校验和失败恢复。具体行为、旧记录迁移范围和验证方法见 [同步可靠性说明](docs/sync-reliability.md)。

可在 Mac 直接运行 `swift test` 验证同步核心；不需要模拟器、小米账号或真实健康数据。真机签名可在忽略提交的 `Config/Signing.local.xcconfig` 中设置，详见说明。

## 功能特性

- **9 类数据同步**：日常活动（步数/距离/卡路里）、心率（含静息）、睡眠（含分期）、血氧、呼吸频率、心率变异性、体重/体脂/BMI/肌肉量/基础代谢、运动记录（含心率）、压力
- **多区域支持**：中国大陆 / 俄罗斯 / 欧洲 / 国际 / 新加坡 / 美国，自动适配 API 域名和时区
- **增量同步 + 回填**：按类型独立记录游标，增量只拉新数据；支持 7/30/90/全部天数强制回填
- **后台自动同步**：`BGAppRefreshTask` 后台周期增量同步，失败时发送本地通知
- **Swift Charts 趋势图**：7 天步数/心率/睡眠/HRV 趋势可视化
- **每日详情页**：点击趋势图中任一天查看当日全部数据 + 压力记录
- **同步历史日志**：持久化每次同步的结果（成功/失败/拉取数/新增数），自动裁剪 200 条
- **数据导出**：一键导出最近 7 天每日数据为 CSV，通过系统分享面板发送
- **快捷指令**：通过 Siri 或快捷指令触发同步（"同步 HealthMi 健康数据"）
- **压力数据展示**：从小米云端读取 stress key，存入 App 内 SwiftData 展示（HealthKit 无对应类型）
- **WebView 登录**：App 内 WKWebView 登录小米账号页面，自动捕获 Cookie

## 原理

`HealthMi` 用 Swift 重新实现了已验证的开源工具 [mi-fitness-mcp-cn](tools/mi-fitness-mcp-cn) 的取数逻辑：

1. **登录**：用小米账号 `userId` / `passToken`（account.xiaomi.com 的 Cookie）经 `serviceLogin` 换取 `ssecurity` 与会话 Cookie；
2. **签名请求**：每个请求用 `signed_nonce = SHA256(ssecurity||nonce)` 做 RC4 加密 + SHA1 签名，调用 `hlth.io.mi.com` 的 `get_fitness_data_by_time` / `get_sport_records_by_time`；
3. **数据映射**：步数/距离/卡路里、心率（含静息）、睡眠（含分期）、血氧、呼吸频率、心率变异性、体重/体脂/BMI/肌肉量/基础代谢、运动记录、压力 → HealthKit 类型（压力无对应类型，存 App 内）；
4. **幂等更新**：使用账号命名空间、稳定业务 ID 和 `HKMetadataKeySyncIdentifier` / `HKMetadataKeySyncVersion` 更新样本；新版本读回验证通过后，只清理本 App 精确匹配的过时记录。未完成的写入计划保存在本机，重试不会重复递增版本。

## 数据映射

| 小米数据 | Apple Health 类型 | 换算 |
|---|---|---|
| 步数 | `stepCount` | count |
| 距离 | `distanceWalkingRunning` | m |
| 活动卡路里 | `activeEnergyBurned` | kcal |
| 心率采样 / 静息 | `heartRate` / `restingHeartRate` | count/min |
| 睡眠 | `sleepAnalysis` | inBed + 分期（awake / AsleepCore / AsleepDeep / AsleepREM），不写整晚 asleep 聚合 |
| 血氧 | `oxygenSaturation` | **百分比 → 分数**（98% → 0.98） |
| 呼吸频率（睡眠均値） | `respiratoryRate` | count/min |
| 心率变异性（睡眠 HRV） | `heartRateVariabilitySDNN` | ms |
| 体重 / 体脂 / BMI / 肌肉量 / 基础代谢 | `bodyMass` / `bodyFatPercentage` / `bodyMassIndex` / `leanBodyMass` / `basalEnergyBurned` | 体脂百分比 → 分数 |
| 运动 | `HKWorkout` | 关键词映射 `HKWorkoutActivityType`，关联平均/最大心率样本 |
| 压力 | App 内 SwiftData 展示 | HealthKit 无对应类型，存 App 内不写入 HealthKit |

> abnormal_heart_beat 暂无 HealthKit 对应类型，未纳入（数据仍可从小米云端读到）。

## 目录结构

```
project.yml          XcodeGen 工程定义（改配置后 xcodegen generate 重新生成）
HealthMi/
  App/               入口、引导、主界面、Keychain 凭据、App 状态
    DataExporter      CSV 数据导出
    DayDetailView     每日详情页
    SyncHistoryView   同步历史日志
    SyncIntent        App Intents / 快捷指令
    TrendChartView    Swift Charts 趋势图
  MiFitness/         小米云 API 的 Swift 移植（Crypto/Session/API/Models/Parser/Region）
  Health/            HealthKit 授权、幂等写入器、数据映射、读取器
  Sync/              同步引擎、SwiftData 游标、后台任务、压力存储、日志、迁移
  Support/           Info.plist、HealthKit entitlement、通知管理、统一日志
  Resources/         资源（AppIcon 等）
HealthMiTests/       加密向量 / 解析 / 映射 / 引擎 / 游标 / 区域 单测
tools/               已验证的 Python 参考实现（mi-fitness-mcp-cn）
```

## 前置条件

- Xcode 16+（Swift 6.0）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）
- iOS 17.0+（部署目标）
- 真机写入 HealthKit 需要付费开发者账号

## 构建与测试

```bash
# 生成工程（首次或改 project.yml 后）
xcodegen generate

# 编译（iOS 模拟器）
xcodebuild -project HealthMi.xcodeproj -scheme HealthMi \
  -destination 'generic/platform=iOS Simulator' build

# 运行单测（对某一台已创建的模拟器）
xcodebuild -project HealthMi.xcodeproj -scheme HealthMi \
  -destination 'platform=iOS Simulator,name=iPhone 17' test

# 真机构建（需自己的开发团队）
xcodebuild -project HealthMi.xcodeproj -scheme HealthMi \
  -destination 'platform=iOS,id=<设备UDID>' \
  DEVELOPMENT_TEAM=<团队ID> -allowProvisioningUpdates build
```

## 使用

1. 首次打开 App，通过 WebView 登录小米账号，或手动输入 `userId` / `passToken`；
2. 同意 HealthKit 读写权限；
3. 在账号区域选择所在区域（默认中国大陆）；
4. 点「立即增量同步」，选择首次回填天数（7/30/90/全部）；
5. 之后在「健康」App 里即可看到小米设备的数据；
6. 日常使用：打开 App 点同步，或依赖后台自动同步；
7. 在趋势区域查看 7 天图表，点击某天进入每日详情；
8. 点击导航栏时钟图标查看同步历史日志；
9. 数据导出区域可导出 CSV。

## 注意事项

- **非官方接口**：本项目通过小米**非官方私有 API**（`account.xiaomi.com` / `hlth.io.mi.com`）读取数据，非小米官方产品，接口随时可能变更或失效；请自行评估使用风险，勿高频请求。`passToken` 等同账号凭证，请妥善保管，本项目仅在设备本地 Keychain 中保存，不会上传。
- **passToken 有效期短**：过期后同步会报「登录被拒绝（code=70016）」，重新登录 account.xiaomi.com 复制新 token 更新即可。
- **HealthKit 仅 iOS 可用**：原生 macOS App 无法写 HealthKit（需 Mac Catalyst + entitlement），因此本方案做成纯 iOS。
- **后台同步**：已接入 `BGAppRefreshTask`（每小时周期刷新），模拟器不触发，需真机验证。用户从多任务划掉 App 后后台任务不触发，直到再次打开 App。
- **真机部署**：把 `project.yml` 里的 `PRODUCT_BUNDLE_IDENTIFIER` 换成你自己的，并在 Xcode 中配置开发团队（HealthKit entitlement 需要付费开发者账号）。
- **运动记录**：用 `HKWorkoutBuilder` 构建（iOS 17 起旧 `HKWorkout` 构造器已废弃）；关联平均/最大心率样本（不与日总计重复计数）；不关联能量/距离样本，避免与每日活动总量重复计算。
- **压力数据**：从小米云端读取 stress key，存入 App 内 SwiftData 展示（不写入 HealthKit，因其无对应类型）。
- **API 健壮性**：网络错误自动重试（指数退避 + 抖动，最多 3 次），分页请求间 200ms 间隔避免限流，认证错误（code=70016）不重试。

## 测试说明

`MiCryptoTests` 使用 `tools/mi-fitness-mcp-cn`（已验证的 Python 实现）作为"预言机"生成固定向量，保证 Swift 移植的 RC4/签名算法与 Python 逐字节一致，不依赖网络。`SyncEngineTests` 验证窗口计算逻辑（首次/增量/回填），`SyncStateStoreTests` 验证游标记录与清除，`MiRegionTests` 验证区域配置。可选的真实 API 集成测试需要提供有效凭据，未包含在默认单测中。

## 许可证

本项目以 **Apache License 2.0** 开源，详见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。

内置参考工具 [mi-fitness-mcp-cn](tools/mi-fitness-mcp-cn) 使用 **MIT License** 发布（Copyright © 2026 Aleksej Kubulashvili），详见 [tools/mi-fitness-mcp-cn/LICENSE](tools/mi-fitness-mcp-cn/LICENSE)。

## 更新日志

详见 [CHANGELOG.md](CHANGELOG.md)。
