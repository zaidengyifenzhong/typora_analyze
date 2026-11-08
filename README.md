# Typora Activator for macOS

## 使用

需要 macOS、Python 3.9+ 和系统自带的 `codesign`。运行前保存文档并退出 Typora，确保当前用户可写入目标应用。

先检查目标，不写入文件：

```bash
bash activate.sh --dry-run
```

执行：

```bash
bash activate.sh
```

自定义应用位置：

```bash
APP='/path/to/Typora.app' bash activate.sh --dry-run
APP='/path/to/Typora.app' bash activate.sh
```

查看参数：

```bash
bash activate.sh --help
```

脚本不创建备份、不提供 `--restore`。写入或签名中途失败时可能需要从官方安装包重新安装。应用更新会覆盖修改。不要把许可证页面的显示状态视为真实购买或授权凭证。

## 工作方式

`src/patcher.py` 搜索原生二进制中与界面许可状态、角标脚本有关的固定字节串并进行等长替换；随后 `activate.sh` 对应用重新签名。修改不会生成许可证或服务器签名。重新签名使用本机 ad-hoc 签名，不保留厂商 Developer ID 身份。

`--dry-run` 只验证字节特征是否命中，不证明应用运行正常。当前匹配器没有完整解析 Mach-O，命中特征也不等于完整版本兼容性验证。

## 可选原生模块

`src/bypass.m` 是实验性的 Objective-C 模块。`--with-dylib` 会编译并放入应用，要求 Xcode Command Line Tools；编译安装不等于已经加载。该模式未做完整功能验收，不属于默认运行路径。

## 验证范围

| 项目 | 已完成的验证 |
| --- | --- |
| Typora 1.14.15 (7789) | 原厂安装的字节特征预检；旧构建副本启动、文字输入和角标观察 |
| 当前直接修改入口 | 参数检查、只读预检和合成文件测试 |
| 正式安装上的完整修改、导出、长期使用 | 尚未验证 |
| 其他 Typora 版本 | 尚未验证 |

## 项目结构

```text
.
├── activate.sh
├── src/
│   ├── patcher.py
│   └── bypass.m
├── .gitignore
├── NOTICE.md
└── README.md
```

## 来源与许可

原生模块参考 [X1lyS/typroa_cracked](https://github.com/X1lyS/typroa_cracked)。第三方来源与许可状态见 [NOTICE.md](NOTICE.md)。本项目尚未指定开源许可证。

仓库不包含 Typora 应用、原厂二进制、许可证或私钥。Typora 产品权利归其权利人所有；正版与官方激活信息见 [Typora 官网](https://typora.io/) 和 [激活文档](https://support.typora.io/activation/)。
