# Rat v1.3 — 面向 Apple Silicon 与未来 macOS 28 的鼠标平滑滚动工具

**Rat** 是对标开源软件 **Mos** 体验设计的原生 macOS 鼠标增强工具，采用纯原生 **AppKit + CoreGraphics + CADisplayLink + IOKit + SMAppService** 构建，零第三方依赖、零 Swift 宏插件依赖（仅安装系统 Command Line Tools 即可 2 秒完成编译）。

## 核心功能

1. **物理惯性平滑滚动**：基于 `NSScreen.displayLink` (`CADisplayLink`) 的帧率无关指数衰减算法，原生适配 ProMotion 120Hz+，自动区分外接鼠标滚轮与触控板连续手势。
2. **独立方向翻转与修饰键控制**：鼠标垂直/水平滚轮与触控板自然滚动彻底分离，支持 Option 加速、Shift 转水平、Control 临时关闭平滑。
3. **分应用黑/白名单与悬停识别**：自动识别鼠标指针下方窗口所属应用，支持后台非激活窗口规则。
4. **实时滚动监控窗口（⌘M）**：纯 CoreGraphics 60fps 示波器双通道波形图（橙/紫原始输入脉冲 + 青色平滑输出曲线），支持窗口置顶、暂停/继续、垂直/水平通道切换与事件日志。
5. **罗技 HID++ 2.0 高分辨率滚轮模块**：基于公开 `IOKit.hid` (`IOHIDManager`)，自动识别 USB / Bolt / Unifying / 蓝牙罗技鼠标，支持开启 `0x2121`/`0x2120` 高分辨率滚轮、`0x2111` SmartShift 棘轮/无极模式切换与 `0x1004` 电量读取。
6. **面向未来 macOS 28 兼容设计**：纯 `arm64` 原生编译、零废弃 API、零私有系统框架。

## 一键编译

```bash
chmod +x build_app.sh
./build_app.sh
```
