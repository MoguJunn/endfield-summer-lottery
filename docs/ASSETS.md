# 素材与字体

公开仓库只包含项目自制的通用素材和通过 npm 获取的可再分发字体。

## 项目素材

- `public/favicon.svg`：项目自制；
- `public/prize-placeholder.svg`：项目自制的通用奖品占位图。

除文件中另有说明外，这些项目自制通用素材与项目源码一并采用 Apache License 2.0。Apache-2.0 不授予项目名称、第三方品牌或商标的额外使用权。

## 字体

- 中文默认使用系统字体栈：`PingFang SC`、`Hiragino Sans GB`、`Microsoft YaHei UI`、`Noto Sans SC`；
- 数字与倒计时只加载 `@fontsource-variable/roboto-mono` 的 Latin 子集；上游采用 Apache License 2.0。

这样可以避免把完整简体中文可变字体打进公开构建产物。部署者如果需要统一中文字体，可以通过自有 CDN 或私有素材包注入，并在活动配置中说明来源与许可。

## 私有品牌包

真实活动可以通过 `LOTTERY_PRIZES_JSON[].imageUrl` 和品牌环境变量注入自己的图片与文案。私有品牌包不应放入公共仓库，除非维护者已经确认著作权、商标权和再分发许可。
