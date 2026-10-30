# 构建安装入口使用说明

## 功能概述

`src/` 是安装器、生成管理器和辅助脚本模板的维护源码；仓库根目录的 `install-singbox.sh` 是供用户下载和直接运行的单文件发布产物。构建器离线拼接文本，不会在安装目标环境加载源码模块。

## 使用方法

构建器要求 Bash 4 或更高版本（使用 Bash 4 引入的关联数组）；macOS 自带 Bash 3.2 不满足要求，请使用已安装的 Bash 4+。

在仓库根目录执行：

```bash
bash scripts/build.sh
bash scripts/build.sh --check
bash scripts/build.sh --help
```

修改 `src/` 中对应职责的源码或 `src/templates/` 中的辅助脚本模板后，运行默认构建命令更新发布文件，再运行 `--check` 确认提交产物与源码同步。

## 参数说明

- 不带参数：校验构建输入和标记、运行 Bash 语法检查，然后更新 `install-singbox.sh`。
- `--check`：构建临时候选并与发布文件逐字节比较；不一致返回非零且不改写发布文件。
- `--help`：显示用法。
- 其他参数或多个参数：明确报错并返回非零。

## 示例

```bash
# 修改管理器协议事务源码后生成单文件发布入口
$EDITOR src/manager/protocols.sh
bash scripts/build.sh
bash scripts/build.sh --check
```

## 输出说明

成功构建时只更新仓库根目录的 `install-singbox.sh`。构建候选与目标位于同一文件系统，语法和标记检查通过后才替换；失败时保留旧产物并清理临时文件。

## 注意事项

- 不要直接维护生成后的 `install-singbox.sh`；源码修改后需重新构建。
- 构建器使用 Bash 和标准文件工具，不联网、不安装依赖、不调用 Docker 或 sing-box。
- 标记及片段顺序是固定映射。不要添加未登记标记或调整片段顺序；错误标记会使构建失败。
- 发布的单文件及其安装后生成的管理器/辅助脚本不依赖 `src/` 或 `scripts/`。
