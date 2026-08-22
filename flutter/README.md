# voice_ui

fcitx5-ai-input 的悬浮卡片 UI（Flutter / Material 3）。

不以独立进程运行：Flutter 引擎经 raw embedder API **进程内嵌入 fcitx5 addon**（`kSoftware` 软渲染），整窗帧由 addon 直接写入 wayland `wl_shm` 缓冲。入口与协议见 `lib/main.dart` 头注释（channel `fcitx5/flutterui`）。

- 生产构建：仓库根 `make build`（JIT bundle，嵌入 addon 安装包）
- 开发调试：`flutter run -d linux`（`linux/` GTK runner 仅为调试保留，不是产品形态）
- C++ 侧宿主：`addon/src/flutter_engine.{h,cpp}`
