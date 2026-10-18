# iOS 26 多任务修复记录 (2026-10-19)

## 问题
独立版 LiveContainer 在 iOS 26 上多任务报错：
1. "JITLess mode is required since iOS 26" / "JIT was not enabled"
2. "file system sandbox blocked mmap()"

## 根因
1. `bypass_seg_count_check()` 只在 iOS 27+ 调用，iOS 26 上 mmap hook 没安装
2. mmap hook (`jitless_hook_mmap`) 通过临时改名绕过沙盒：
   - 失败时把文件 rename 到 `%s/Documents/.fd%d.dylib` (LP_HOME_PATH)
   - mmap 成功后再 rename 回去
3. 3.8.8 mod 版有此 hook 且在 iOS 26 上安装，所以能用

## 修复 (commit b85c4ba)
`LiveContainer/LCBootstrap.m`:
- 把 `BOOL is27up` 改为 `BOOL is26up`
- 条件从 `if(is27up && segCountMismatch)` 改为 `if(is26up)`
- iOS 26+ 都调用 `bypass_seg_count_check(dlopenBlock)` 安装 mmap hook

## 教训
- 不要凭感觉删代码：iOS 26 检查字符串在 3.8.8 mod 里也有，说明不是多余的
- hook 的安装时机和触发条件要看全，不能只看函数存在
